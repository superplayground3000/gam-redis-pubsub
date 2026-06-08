# redis-connect-lww-hincrby-k8s

## What this demonstrates

Under **multiple uncoordinated writers writing to the same keys**, the last-write-wins
compare-and-set fence holds exactly (`mismatches=0`) across **set**, **delete**
(tombstone + GC), and **atomic standby→active rename** — when versions are minted by a
**shared `HINCRBY` counter** on central Redis (`kv:ver` per key, `kv:gver` for rename).
Because Redis serializes `HINCRBY` per hash, every writer — regardless of how many run
concurrently — receives a strictly-increasing, collision-free version for each key. The
fence at the sink (`EVAL lww_set.lua` / `lww_rename.lua`) then enforces the ordering
atomically, and `mismatches=0` across 3 connect-source + 3 connect-sink pods proves it
holds under inter-pod reordering. This **inverts the parent lab's finding**: the parent
(`redis-connect-lww-multi-k8s`) proved that multi-writer-same-key is unsafe with a local
counter (Proof C); here `HINCRBY` makes it safe (Proof MW+), while the same negative
control (Proof MW-) is retained as a contrast. The lab also finds the maximum sustained
throughput at which this property holds, via a rate sweep reported in `reports/report.html`.

## Architecture

```
                     ┌──────────────────────────────────────────────────────┐
                     │               redis-central                           │
                     │   kv:ver  (HINCRBY per key, version mint)            │
                     │   kv:gver (HINCRBY global, rename version mint)      │
                     │   srcmax:<epoch>  (hmax EVAL — HSET-to-max)          │
                     │   app.events  (XADD stream)                          │
                     └────────────────────────┬─────────────────────────────┘
                                              │
 writer×N ──HINCRBY mint──► XADD+hmax EVAL ──┤
 (op-mix: set/delete/rename                  │
  shared keyspace, same keys)                │
                                             │
           ┌─────────────────────────────────┼──────────────────────┐
           │  connect-source ×3              │                      │
           │  (redis_streams consumer group  │                      │
           │   "propagator", one entry       │                      │
           │   → exactly one pod)            │                      │
           └──────────┬──────────────────────┘                      │
                      │                                             │
                      ▼                                             │
           ┌──────────────────────┐                                 │
           │   NATS JetStream     │                                 │
           │   stream APP_EVENTS  │                                 │
           │   queue: region-writer│                                │
           └──────────┬───────────┘                                 │
                      │                                             │
           ┌──────────▼──────────────────────┐                      │
           │  connect-sink ×3                │                      │
           │  (queue deliver group — each    │                      │
           │   message → exactly one pod)    │                      │
           │  EVAL lww_set.lua  (set/delete) │                      │
           │  EVAL lww_rename.lua  (rename)  │                      │
           └──────────┬──────────────────────┘                      │
                      │                                             │
                      ▼                                             │
           ┌──────────────────────┐   gc-sweeper                   │
           │   redis-region        │◄──(reap tombstones older      │
           │   (KV Hash per key)   │    than gc.horizon)           │
           └──────────────────────┘                                 │
                      │                                             │
                      ▼                                             │
           verifier Job ──HGetAllInt srcmax:<epoch>──► compare ────┘
           (CompareSrcMax: per-key region ver vs HINCRBY-minted max)
                      │
                      ▼
           reports/sweep.json ──► report-gen ──► reports/report.html
```

## Run it (kind)

```bash
kind create cluster --name lwwh

# NATS auth fixtures are committed under chart/files/nats-auth/.
# Regenerate only on a fresh checkout if missing:
#   scripts/gen-nats-auth.sh

scripts/build-images.sh --kind --kind-name=lwwh   # build + load all images into kind

RRCS_NS=lwwh-k8s RRCS_RELEASE=lwwh scripts/verify-lww.sh
```

The script runs all proofs then performs a **rate sweep** (default tiers: 5000, 10000,
20000, 40000 msg/s) and writes `reports/report.html`. The report shows the maximum
passing tier for your hardware.

To override sweep tiers or timing:

```bash
SWEEP_TIERS=5000,10000 DURATION_S=60 RRCS_NS=lwwh-k8s RRCS_RELEASE=lwwh scripts/verify-lww.sh
```

Available timing env vars (see `scripts/lib/run-defaults.sh`): `DURATION_S` (default 30),
`WARMUP_S` (default 5), `DRAIN_S` (default 10).

## Local binaries (no Docker)

```bash
scripts/build-binaries.sh
# Builds writer, verifier, gc-sweeper, report-gen into ./bin
```

## Proofs

`verify-lww.sh` runs these proofs sequentially; exit 0 requires all to pass and the sweep
to clear at least the lowest configured tier.

- **Proof A** — deterministic fence mechanism: apply versions 3,1,2 then replay 3 to one
  key, direct to redis-region → returns `1 0 0 -1`, final `ver=3 val=v3`. The fence works
  in isolation before any pipeline is involved.

- **Proof MW+** (headline) — `scripts/proof-mwplus.sh`: two writers apply to the **same
  key** using a shared `HINCRBY vKEY <key> 1` counter. Every write gets a distinct,
  strictly-increasing version → zero duplicates, final version equals total writes. Proves
  HINCRBY makes multi-writer-same-key safe: no update is silently lost.

- **Proof MW-** (negative control, `scripts/proof-c.sh`) — two uncoordinated writers each
  apply versions 1..K using their **own local counter**. Both reach version K; the second
  writer's version-K value is dropped as a `duplicate(-1)` with no signal. A version-only
  check would report `mismatches=0` (a false PASS) while one update vanishes. Passes
  (exit 0) when it confirms the lost update — proving the single-writer-per-key
  precondition is load-bearing without HINCRBY.

- **Proof delete** (`scripts/proof-delete.sh`) — a delete writes a tombstone (`deleted=1`,
  `ver` retained); a later stale (lower-version) set does NOT resurrect it; a strictly
  newer set does revive it. The fence extends cleanly to delete semantics.

- **Proof rename** (`scripts/proof-rename.sh`) — atomic standby→active: after
  `EVAL lww_rename.lua`, the active key is live (`deleted=0`, `ver=global`) **and** the
  standby key is tombstoned (`deleted=1`) — the pairing is atomic with no split. A stale
  (lower-version) rename is rejected.

- **Proof B′ sweep** — the verifier Job runs at each rate tier: writer drives the real
  3-source + 3-sink pipeline, pipeline quiesces, then `CompareSrcMax` reads
  `srcmax:<epoch>` from central and compares every key's minted max against the region.
  Pass requires `mismatches=0` AND `stale>0` (reordering was exercised and fenced). The
  highest passing tier is the lab's throughput result.

## Knobs

| Value | Default | Description |
|---|---|---|
| `writer.env.OP_W_SET` | `8` | Relative weight for set operations |
| `writer.env.OP_W_DELETE` | `1` | Relative weight for delete operations |
| `writer.env.OP_W_RENAME` | `1` | Relative weight for rename operations |
| `writer.env.KEY_SPACE_SIZE` | `64` | Shared keyspace size (all writers draw from the same pool, forcing same-key contention) |
| `gc.horizon` | `5m` | Tombstone GC horizon — do not reap tombstones newer than this |
| `gc.interval` | `30s` | How often gc-sweeper scans for expired tombstones |
| `sweep.tiers` | `5000,10000,20000,40000` | Rate ladder (msg/s) for the sweep; also overridable via `SWEEP_TIERS` env var |
| `sweep.durationS` | `30` | Sustain window per tier (seconds) |

## Expected output

`verify-lww.sh` prints a `RESULT_JSON` line per tier whose `.lww` object carries
`rate_achieved_avg`, `stale`, `duplicate`, `mismatches`, `tombstones`, and a `.verdict`.
The actual numbers depend on your hardware. The static report is written to
`reports/report.html` and shows a per-tier pass/fail table and the max passing tier.

## Validation note

This is a Kubernetes lab; `scripts/verify-lww.sh` is the validation. It exits 0 only when
all proofs pass (A, MW+, MW-, delete, rename) **and** the sweep cleared at least the
lowest configured tier (`mismatches=0`, `stale>0`, pipeline quiesced).

## Teardown

```bash
helm uninstall lwwh -n lwwh-k8s
kind delete cluster --name lwwh
```

## Further reading

- `RESEARCH.md` — HINCRBY version source, srcmax design, GC horizon reasoning, and
  the full list of deliberately excluded concerns.
- `../../lww-update-delete-gc-hinc/design-decision-tree.md` — source design document
  (writer topology × version source decision matrix; §4 is the key table).
- `../../lww-update-delete-gc-hinc/lab-requirements.md` — original requirements.
- `../../docs/design/lab-coverage-analysis.md` — where this lab fits in the broader
  coverage map.
- `../redis-connect-lww-multi-k8s/` — parent lab (multi-instance connect, local counter,
  single-writer-per-key precondition).
