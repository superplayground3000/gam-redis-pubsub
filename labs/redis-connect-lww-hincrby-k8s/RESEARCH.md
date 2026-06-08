# Redis → Connect LWW with HINCRBY Shared Counter (Kubernetes) — RESEARCH

## Property demonstrated

Under **multiple uncoordinated writers writing to the same keys**, with versions minted by
a shared `HINCRBY` counter on central Redis (`kv:ver` for set/delete, `kv:gver` for
rename), the last-write-wins compare-and-set fence holds exactly (`mismatches=0`, `stale>0`)
across **set**, **delete** (tombstone + GC), and **atomic standby→active rename** — through
3 connect-source and 3 connect-sink pods. The lab also sweeps a rate ladder and identifies
the maximum sustained throughput at which this property holds.

This inverts the parent lab's lesson: `redis-connect-lww-multi-k8s` proved multi-writer-
same-key is **unsafe** with a local counter (Proof C); this lab proves it is **safe** with
`HINCRBY` (Proof MW+). The negative control (Proof MW-) is retained in the same harness so
the contrast is immediate and unambiguous.

## Why this is the right question

The parent lab's Proof C demonstrated a silent lost update: two writers each maintaining a
local counter both reach version `K` and one's value is dropped as a `duplicate` with no
signal. The parent's conclusion was that the single-writer-per-key precondition is load-
bearing. This lab challenges that conclusion: **what if a shared, atomic version source
eliminates version collisions entirely?**

The answer, borne out by the fence and the proofs: yes. `HINCRBY` on a single Redis hash
field serializes version minting across all writers for a given key, so every `XADD` event
carries a globally unique, strictly-increasing version. The CAS fence at the sink then
works correctly regardless of how many writers are running, because no two writers ever
hold the same version for the same key at the same moment.

## Design decisions

### HINCRBY as the version source

`v = HINCRBY kv:ver <kv_key> 1` (source Redis, before `XADD`) mints the version for
set/delete operations (`writer/version.go: Minter.NextPerKey`). For rename, a separate
global counter `HINCRBY kv:gver global 1` is used (`Minter.NextGlobal`) because a rename
must atomically dominate two key sequences (active and standby), and a per-key counter
cannot guarantee it dominates both simultaneously.

**Why HINCRBY makes multi-writer-same-key safe:**
- Redis serializes all `HINCRBY` calls to a given hash field on a single thread. Every
  writer — regardless of concurrency — gets a distinct integer. No two writers share a
  version for the same key. The fence's `v > stored_ver` is always comparing distinct
  values, so the `duplicate` branch (`v == stored_ver`) is never triggered by a real
  competing write.
- There is no in-process counter in the writer. A writer restart does not reset any
  sequence; it just issues the next `HINCRBY` from wherever Redis is.
- Gaps in `kv:ver` are harmless: a minted-but-unpublished version leaves a gap that the
  fence's strict `>` absorbs without issue. The verifier compares against the minted max,
  not a contiguous sequence.

### srcmax:<epoch> — authoritative source-of-truth for the verifier

Under HINCRBY, a key's `kv:ver` in central Redis records the highest version ever minted,
not the highest version actually published to the stream. These diverge if a pipeline
execution fails after minting but before the `XADD` commits.

To give the verifier a reliable comparison target, the writer records every minted version
into `srcmax:<epoch>` via `hmax.lua` (HSET-to-max: atomically update a hash field to
`max(current, incoming)`). **Critically, the `hmax EVAL` and the `XADD` are queued onto
the same `TxPipeline` and committed together in a single `MULTI/EXEC`
(`writer/worker.go: Run`).** A failed `Exec` applies neither, so `srcmax` never claims a
version that was not published to the stream. This prevents permanent false mismatches.

The epoch token is embedded in the key name (`srcmax:<epoch>`) and in every KV key
(`lb:<domain>:<status>:{<entity>:<epoch>-<id>}`). This isolates re-runs without flushing:
a `/reset` call on the writer rotates the epoch, and subsequent events land under the new
epoch in both the KV keyspace and `srcmax`. The verifier reads `srcmax:<new-epoch>` and
only inspects keys that embed the new epoch, so a stale event from the old epoch is
invisible to the new run's comparison.

### CAS fence extended for delete: tombstone semantics

The design requires `delete` to leave the version intact so a stale (lower-version) set
cannot resurrect a deleted key (`chart/files/connect/lww_set.lua`). When `op=delete`:
- `ver` is set to the incoming version (same as a set).
- `deleted=1` and `deleted_at=<now_ms>` are recorded.
- `val` is cleared.

A subsequent stale set (`v < stored_ver`) hits the `return 0` (stale) branch before the
`op` check, so the tombstone's version blocks resurrection. A strictly newer set (`v >
stored_ver`) does revive the key (clears `deleted=0`), which is the correct LWW behavior:
a new-version set after a delete is a legitimate update.

### Tombstone GC with horizon

Physical `DEL` is deferred: `gc-sweeper/sweep.go` only reaps tombstones whose
`deleted_at` is older than `GC_HORIZON` (default 5 minutes). This matches the
`gc_grace_seconds` pattern from Cassandra: a very-late, stale write that arrives after the
tombstone is physically deleted would otherwise resurrect the key with an old value. The
horizon must be larger than the maximum possible reorder/redelivery delay. Keys whose
`deleted_at` is missing or non-numeric are never reaped (safe over corrupt partial writes).

The horizon also bounds a second race: the verifier compares region against
`srcmax:<epoch>`, and a tombstoned key still counts (its `ver` is retained). If GC
physically `DEL`ed a current-run tombstone *before* the comparison, that key would read as
a false mismatch. With the defaults this cannot happen — `GC_HORIZON` (5 min) is far larger
than a full sweep tier (~1 min), so current-epoch tombstones never age past the horizon
during a run. If you shorten `gc.horizon` or greatly lengthen tier timings, keep the horizon
comfortably above one tier's wall-clock to preserve this margin.

### Atomic dual-key rename: gate on active, tombstone standby

`lww_rename.lua` handles the standby→active promotion atomically within a single Lua
script (Redis executes it serially per the hash-tag slot):
1. Gate the entire promotion on the **new (active) key**: `v > stored_active_ver` to
   apply, `v < stored_active_ver` to return stale, `v == stored_active_ver` to return
   duplicate.
2. If the gate passes, write the active key (`deleted=0, ver=v, val=snapshot`).
3. Tombstone the **old (standby) key**: write `deleted=1, ver=v` — but only if `v >
   stored_standby_ver` (never roll a standby's version backwards; equal version is also
   skipped because a redelivery would re-tombstone with the same data, which is idempotent
   but unnecessary).

Both keys carry the same hash tag `{<entity>:<epoch>-<id>}` (see `writer/keys.go`), which
guarantees they land on the same Redis slot. The atomic dual-key operation is therefore
possible on a single-node Redis and on a Redis Cluster (all keys in the same slot). The
rename version comes from the global counter `kv:gver`, which produces a value guaranteed
to be larger than any per-key counter for either key at the time of the rename.

### Per-epoch key isolation

`writer/keys.go` embeds the epoch in the hash tag: `lb:<domain>:<status>:{<entity>:<epoch>-<id>}`.
The epoch is also the suffix of `srcmax:<epoch>`. This means:
- The region keyspace for each run is disjoint from previous runs — the empty-store
  precondition (`StoreEmptyAtStart`) checks `srcmax:<epoch>` and scans the region for
  epoch-tagged keys, so a fresh epoch is provably clean.
- A `/reset` race (the writer receives a new epoch while in-flight events use the old one)
  is benign: old-epoch events publish to `srcmax:<old-epoch>` under old-epoch keys; the
  verifier reads `srcmax:<new-epoch>` and never inspects those.

### Sink metric aggregation across pods

`lww_apply_total` is a per-pod Prometheus counter. The verifier resolves the headless
Service `lab-connect-sink-headless` (DNS A-records → one IP per ready pod), scrapes every
pod's `:4195/metrics`, and sums applied/stale/duplicate across all pods. A baseline is
captured at sustain start; the proof signals are windowed deltas. If the pod set changes,
any pod is unreachable, or any pod's counter is below its baseline (restart reset), the
scrape is a hard precondition failure — never a silent under-count.

## The proofs

- **Proof A** — deterministic fence in isolation (3→1→2 + replay 3 → `1 0 0 -1 ver=3`).
- **Proof MW+** — positive: HINCRBY + two writers + same key → `dup=0`, all writes land,
  `ver=K*2` (every write has a unique version, none dropped). This is the headline result.
- **Proof MW-** (negative control, `proof-c.sh`) — local counters + two writers + same
  key → one writer's version-K value is silently dropped as `duplicate(-1)`; a version-
  only check reports `mismatches=0` (false PASS). The proof exits 0 when it confirms the
  lost update — proving the precondition from the parent lab and underscoring why HINCRBY
  is necessary.
- **Proof delete** — tombstone retains ver; stale set cannot resurrect; newer set revives.
- **Proof rename** — atomic standby→active: both keys updated in one Lua execution;
  stale rename rejected; the pairing is never split.
- **Proof B′ sweep** — end-to-end positive under inter-pod concurrency: the verifier Job
  runs at each rate tier, compares every key's region ver against `srcmax:<epoch>`, requires
  `mismatches=0` AND `stale>0`. The report identifies the max passing tier.

## Deliberately excluded

- **Wall-clock and HLC version sources.** The design decision tree
  (`../../lww-update-delete-gc-hinc/design-decision-tree.md` §4) shows wall-clock is
  unsafe under multi-writer-same-key (clock skew produces inverted ordering); HLC is
  safe but adds complexity. HINCRBY is the simplest safe choice and is the lab's focus.
- **Redis Cluster multi-node hot-slot study.** All keys in this lab carry a hash tag
  (`{<entity>:<epoch>-<id>}`), so a follow-on Cluster lab is structurally possible without
  key-design changes. This lab uses single-node central and single-node region instances;
  cross-shard coordination is not demonstrated.
- **Delta / CRDT merge.** The design is snapshot-only. LWW with delta (incremental) values
  requires strict ordering or field-level merge; that is a different problem space.
- **Writer HA / leader election.** Proof MW- shows the break with local counters; Proof MW+
  shows HINCRBY fixes it. The "fix" for local-counter multi-writer (hash-partitioned key
  ownership, leader election) is out of scope.
- **Sink autoscaling (HPA), chaos / pod-kill mid-run, latency SLOs.** Excluded to keep one
  concern per lab.

## Further reading

- `../../lww-update-delete-gc-hinc/design-decision-tree.md` — the design document this lab
  implements (§4: writer topology × version source matrix; §6: HINCRBY placement; §7: sink
  KV fields and tombstone GC; §5: XADD envelope).
- `../../lww-update-delete-gc-hinc/lab-requirements.md` — original requirements.
- `../../docs/design/lab-coverage-analysis.md` — coverage map for the lab series.
- `../redis-connect-lww-multi-k8s/` — parent lab (multi-instance connect, local counter,
  single-writer-per-key precondition; Proof C is its Proof C).
- `../../last-write-wins-lab/research.md` — upstream mechanism design (why
  NATS/source-timestamp don't work; why the fence belongs at the sink).
