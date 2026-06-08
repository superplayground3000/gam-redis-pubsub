# Design — `redis-connect-lww-hincrby-k8s` lab

> Date: 2026-06-08
> Forked from: `labs/redis-connect-lww-multi-k8s/`
> Source requirements: `lww-update-delete-gc-hinc/lab-requirements.md`
> Design rationale: `lww-update-delete-gc-hinc/design-decision-tree.md`
> Coverage gap this closes: B2 (delete/tombstone+GC), B4 (rename key=name),
> C3/C4 (multi-writer-same-key safe via HINCRBY) — see
> `docs/design/lab-coverage-analysis.md`.

## 1. Property demonstrated (the one concern)

Under multiple uncoordinated writers writing to the **same** keys, with versions
minted by a **shared `HINCRBY` counter (no local counter)** across 3
connect-sources + 3 connect-sinks, the sink LWW CAS fence holds exactly
(`mismatches = 0`) across `set` / `delete` (tombstone + GC) / atomic
`standby→active` rename — and the lab finds the **max sustained throughput** at
which this stays true.

This is the exact inversion of the parent lab's lesson: the parent proved
multi-**writer**-same-key is *unsafe* with a local counter (its Proof C); this
lab proves `HINCRBY` makes it *safe*, while extending the op set to delete and
rename.

## 2. What changes vs. parent `redis-connect-lww-multi-k8s`

| Area | Parent | This lab |
|---|---|---|
| Version source | local per-key counter (`writer/version.go`) | **`HINCRBY kv:ver <key> 1`** on redis-central, before each XADD |
| Keyspace | strided, single-owner-per-key | **shared** — writers contend on the same keys on purpose |
| Operations | `set` only | `set` / `delete` / add-new / atomic `standby→active` rename |
| Sink Lua | `lww_set.lua` (set only) | extend `lww_set.lua` (+delete tombstone branch) + new `lww_rename.lua` (atomic dual-key) |
| GC | none | **tombstone GC sweeper** (periodic, metered) |
| Proof C | negative only | **positive** (HINCRBY safe) **+ keep negative** as contrast |
| Throughput | fixed rate | **automated rate sweep** → max passing tier |
| Output | live websocket dashboard | **static HTML report** generated from verifier JSON |

Everything not in this table is inherited unchanged from the parent (NATS auth
fixtures, bundled/external chart modes, kind harness shape, Proof A, Proof B′
end-to-end structure, connect source/sink topology).

## 3. Architecture / data flow

```
writer ×N  ──HINCRBY kv:ver <key>──▶ redis-central        (mint monotonic version)
   │        ──XADD app.events {event_id,key,op,version,body}──▶ redis-central
   ▼
connect-source ×3 ──redis_streams──▶ NATS JetStream  (Nats-Msg-Id dedup)
                                          │
connect-sink ×3 ──EVAL (lww_set | lww_rename)──▶ redis-region   ◀── the fence (CAS)
                 └─XADD region-events ──▶ ledger (observability)
gc-sweeper ──scan deleted=1 & age>GC_horizon──▶ redis-region (physical DEL, metered)
verifier ──drive sweep, scrape lww_apply across pods, compare──▶ RESULT_JSON
report-gen ──RESULT_JSON──▶ reports/report.html
```

**Service types (8):** redis-central, redis-region, nats (+ auth init job),
connect-source ×3, connect-sink ×3, writer, verifier (Job), gc-sweeper,
report-gen. 3+ distinct service types → implementation escalates to
`superpowers:writing-plans` after spec approval.

## 4. The fences (Lua)

### `lww_set.lua` (extended from parent)
- `op=set` → CAS: if `incoming_ver > stored_ver`, `HSET val,ver,deleted=0,updated_at`.
- `op=delete` → CAS tombstone: if `incoming_ver > stored_ver`,
  `HSET ver,deleted=1,deleted_at,val=''` (keep `ver` so a later stale set cannot
  resurrect).
- Returns `1` applied / `0` stale / `-1` duplicate (unchanged contract, so the
  existing `lww_apply` counter + verifier scrapers keep working).
- Resurrection-proof: a stale lower-version set arriving after a delete is
  rejected by the same `>` gate.

### `lww_rename.lua` (new, atomic dual-key)
- `KEYS[1]=lb:<dom>:standby:{<entity>:<id>}`, `KEYS[2]=lb:<dom>:active:{<entity>:<id>}`.
- Both keys share the hash tag `{<entity>:<id>}` → same Redis slot → multi-key
  EVAL is atomic even on Cluster.
- A single global version (from `HINCRBY kv:gver global 1`) gates **both** sides:
  tombstone old (`deleted=1`) + CAS-set new in one EVAL. No split-brain window.
- Returns applied/stale/duplicate like `lww_set.lua`.

### Sink routing
`connect-sink` reverse config branches on `meta op`: `rename` → `lww_rename.lua`
(2 keys), else → `lww_set.lua` (1 key). Lua embedded at Helm render time via
`toJson` (same single-source pattern as parent — `.Files.Get`).

## 5. Workload model (writer)

Three key patterns, ids drawn from a **shared** space across all writer
replicas (contention is intentional):
- `lb:company:active:{employees:<id>}`
- `lb:functions:active:{groups:<id>}`  *(requirement's `funtions` typo corrected)*
- `lb:general:active:{items:<id>}`

Weighted operation picker (weights configurable via Helm values):
- `set` — update an existing active key (dominant weight).
- `add-new` — set a previously-unused id (still a `set` op on the wire).
- `delete` — delete an active key → tombstone.
- `standby→active` — set `lb:<dom>:standby:{…}` then emit `op=rename` to
  atomically promote it to `active`.

**Every** operation mints its version via `HINCRBY` on redis-central before
XADD. `set`/`delete`/add-new use `HINCRBY kv:ver <kv_key> 1`; `rename` uses
`HINCRBY kv:gver global 1` (global sequencer, per design-doc §7) so the version
dominates both old and new key sequences.

## 6. Tombstone GC

A small Go `gc-sweeper` (Deployment, periodic loop) scans redis-region for
`deleted=1 AND deleted_at < now − GC_horizon` and issues physical `DEL`.
- `GC_horizon` configurable (Helm value), default ≥ max expected
  reorder/redelivery delay (analogous to `duplicate_window` /
  `gc_grace_seconds`). Too-early GC + a very late stale write = resurrection, so
  the default is conservative.
- Exposes Prometheus metrics: tombstone count, oldest-tombstone age, GC deletes.

## 7. Proofs (verifier)

1. **A** — deterministic fence (inherited: apply 3→1→2 + replay 3 → `1 0 0 -1`,
   final `ver=3 val=v3`).
2. **MW+** (headline; inverts parent Proof C) — N writers `HINCRBY` the same key
   with interleaved writes → `mismatches=0`, region holds the true
   max-version value, **no** lost update. The positive that `HINCRBY` buys.
3. **MW−** (negative control; inherited `proof-c.sh`, relabeled) — two writers
   with **local** same-version counters → silent lost update that a
   version-only check reports as `mismatches=0`. The contrast that motivates
   `HINCRBY`.
4. **delete** — after `op=delete`, key is a tombstone (`deleted=1`, `ver`
   retained, `val=''`); a later stale lower-version `set` does **not** resurrect
   it (returns `0`). GC removes it only after `GC_horizon`.
5. **rename** — atomic `standby→active`: assert pairing complete (old
   tombstoned AND new set) with no observable split; a concurrent stale write to
   either side is fenced.
6. **B′ sweep** — ramp rate tiers (default `5000,10000,20000,40000` msg/s);
   per tier require `mismatches=0` ∧ `stale>0` (reorder actually exercised) ∧
   quiescence (backlog drained). Report the **max passing tier** as the
   throughput ceiling.

Verifier emits a single `RESULT_JSON:` line (extends parent shape) carrying
per-tier sweep results, per-proof verdicts, tombstone stats, and op-mix counts.

## 8. HTML report generator

`report-gen` (Go) consumes the verifier `RESULT_JSON` and emits a
**self-contained** `reports/report.html` (inlined CSS/JS, no external assets):
- per-tier throughput vs. applied/stale/duplicate (sweep curve),
- max-passing-tier verdict banner,
- tombstone count / oldest age, GC activity,
- op-mix breakdown (set/delete/add/rename),
- proof pass/fail table.

Static so it is openable offline and archivable per run.

## 9. Helm chart portability

Inherits parent's two-mode chart (bundled NATS+Redis, or external via
pre-created Secrets + `values-external.yaml`). New/changed values:
- `writer.replicas`, `writer.opWeights` (set/delete/add/rename),
- `writer.keyspace` (ids per pattern),
- `gc.horizonS`, `gc.intervalS`,
- `sweep.tiers`, `sweep.durationS` (verifier),
- connect source/sink replica counts (inherited, default 3/3).

Chart must `helm template` clean and deploy on any conformant cluster (the
"portable" requirement) — verified by render + kind install.

## 10. Local build scripts

- `scripts/build-images.sh` (inherited) — builds + side-loads container images.
- `scripts/build-binaries.sh` (**new**) — compiles `writer`, `verifier`,
  `gc-sweeper`, `report-gen` Go binaries to `./bin/` **without Docker**
  (satisfies "binary builds must provide local build scripts").

## 11. Validation

The research-lab skill's `validate_lab.sh` targets docker-compose labs; this lab
is Kubernetes/Helm (like its parent), so validation runs through the lab's own
**`scripts/verify-lww.sh` on `kind`**: boots the chart, runs Proofs A / MW+ /
MW− / delete / rename, runs the B′ sweep, and exits 0 only when all proofs are
green and the sweep reports a max passing tier. This is the parent's proven
pattern, extended.

## 12. Deliverables checklist (maps to lab-requirements.md "Must Haves")

- [x] Use `HINCRBY` + `HSET`, no local counter — §5, §4
- [x] Multi writers writing to same key — §5, Proof MW+ §7
- [x] Multiple redpanda sources and sinks (3 + 3) — §3
- [x] HTML report generator visualizing results — §8
- [x] Forked from `labs/redis-connect-lww-multi-k8s/` — header
- [x] Portable Helm chart for different k8s clusters — §9
- [x] Local binary build scripts — §10
- [x] Key patterns + delete/standby→active/add behaviors — §4, §5

## 13. Out of scope (deliberately excluded)

- wall-clock and HLC version sources (design-doc C5/C6) — `HINCRBY` is the
  requirement; alt sources are a separate lab.
- Redis Cluster multi-node version-counter hot-slot study (design-doc F2) — this
  lab runs single-node central/region; hash tags are present so a Cluster
  follow-up is possible but not demonstrated here.
- delta/CRDT merge — design is snapshot-only, the LWW precondition.
