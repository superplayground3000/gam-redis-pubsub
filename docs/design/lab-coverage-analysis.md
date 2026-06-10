# Lab Coverage Analysis — `design-decision-tree.md` vs. existing labs

> Generated 2026-06-08. Maps every scenario / decision point in
> [`design-decision-tree.md`](../../lww-update-delete-gc-hinc/design-decision-tree.md) to the labs under `labs/`
> that exercise it, with a status verdict. Use this to find gaps before building
> new labs.

## How the verdicts were derived

- LWW core: `labs/redis-connect-lww-k8s` (single-instance) and
  `labs/redis-connect-lww-multi-k8s` (3 source + 3 sink). Sink fence is
  `chart/files/connect/lww_set.lua` — **set only**; returns `1` applied / `0`
  stale / `-1` duplicate.
- Version is minted by the **writer** as an **in-process per-key monotonic
  counter** (`writer/version.go`, `Versions.Next`), with **strict
  single-writer-per-key** ownership. No `HINCRBY`, no wall-clock, no HLC.
- QoS / dedup / chaos: `redis-redpanda-qos-resilience`,
  `redis-redpanda-connect-stress(-k8s)`, `redis-redpanda-throughput-stress`.
- Base CDC + Cluster + alt transport: `redis-cdc-via-jetstream`,
  `redis-cluster-multiregion-streams`, `redis-vector-cdc-multiregion`,
  `redis-multiregion-via-connect`, `redis-streams-multigroup-fanout`.

Legend: ✅ covered · ⚠️ partial/implicit · ❌ not covered.

---

## A. Core mechanism (§1–2)

| # | Scenario | Status | Lab(s) / Evidence |
|---|----------|--------|-------------------|
| A1 | Sink-side atomic LWW CAS fence (Lua compares incoming vs stored `ver`) | ✅ Covered | `redis-connect-lww-k8s` — `lww_set.lua` (`v>c`→apply, `v<c`→stale, `v==c`→dup) |
| A2 | Order-independence (reorder absorbed by CAS) | ✅ Covered | `lww-k8s` Proof B: `stale>0` proves reorder happened, `mismatches=0` |
| A3 | Resend-safe / idempotent (duplicate version rejected) | ✅ Covered | `lww-k8s` Lua returns `-1` on equal version; `duplicate` counter |
| A4 | Drop strict ordering → run sink parallel (`threads:4`, `max_in_flight:256`) | ✅ Covered | `lww-k8s` (parallel sink is the whole point) |
| A5 | version minted by **producer** (source of truth), carried to sink | ✅ Covered | writer `Versions.Next()` stamps `version` field into XADD |

## B. Operation types (§3, §5, §7)

| # | Scenario | Status | Lab(s) / Evidence |
|---|----------|--------|-------------------|
| B1 | `op=set` (snapshot LWW) | ✅ Covered | all LWW labs |
| B2 | `op=delete` (tombstone + `deleted`/`deleted_at` + GC) | ❌ Not covered | `lww_set.lua` has no delete branch; no tombstone/GC anywhere |
| B3 | `op=rename`, KV key = immutable ID (degenerates to set) | ⚠️ Implicit only | covered *by construction* (keys are IDs) but never exercised as a rename |
| B4 | `op=rename`, KV key = name (atomic dual-key + global seq + tombstone) | ❌ Not covered | no dual-key Lua, no global sequencer |

## C. Writer topology × version source (§4)

| # | Scenario | Status | Lab(s) / Evidence |
|---|----------|--------|-------------------|
| C1 | A — single writer, local monotonic counter | ✅ Covered | `lww-k8s` (single writer, in-process `Versions`) |
| C2 | B — multi-writer, one owner per key, local counter | ✅ Covered | `lww-multi-k8s` (writer shards keys by owner; precondition held) |
| C3 | C — multi-writer **sharing** a key (lost-update hazard) | ✅ Covered (negative) | `lww-multi-k8s` **Proof C**: silent lost update + false `mismatches=0` |
| C4 | Version source: **shared atomic counter `HINCRBY`** (doc's recommended pick) | ❌ Not covered | no `HINCRBY` minting in any lab; only local counters |
| C5 | Version source: wall-clock + `(version, writer_id)` tiebreaker | ❌ Not covered | — |
| C6 | Version source: HLC | ❌ Not covered | — |
| C7 | Anti-pattern: Connect-injected processing-time | ⚠️ Discussed only | argued against in doc; not built (correctly) |

## D. Connect / pipeline topology (§3)

| # | Scenario | Status | Lab(s) / Evidence |
|---|----------|--------|-------------------|
| D1 | Multiple connect **sources** (reorder, no correctness impact) | ✅ Covered | `lww-multi-k8s` (3× `connect-source`) |
| D2 | Multiple connect **sinks** (always safe via per-key CAS) | ✅ Covered | `lww-multi-k8s` (3× `connect-sink` sharing one durable via `queue`) |

## E. Delivery / dedup / QoS (§3 dedup; resilience)

| # | Scenario | Status | Lab(s) / Evidence |
|---|----------|--------|-------------------|
| E1 | `Nats-Msg-Id` dedup (optimization, not correctness) | ✅ Covered | `redis-redpanda-qos-resilience`, `redis-multiregion-via-connect` |
| E2 | ALO / AMO / EOE profiles + mid-run chaos kill | ✅ Covered | `redis-redpanda-qos-resilience`, `redis-redpanda-connect-stress(-k8s)` |
| E3 | Base CDC propagation + durability across consumer restart | ✅ Covered | `redis-cdc-via-jetstream` |

## F. Redis Cluster (§3, §6)

| # | Scenario | Status | Lab(s) / Evidence |
|---|----------|--------|-------------------|
| F1 | Cluster hash-slot / hash-tag routing behavior | ✅ Covered | `redis-cluster-multiregion-streams`; hashtag key patterns in `redis-redpanda-throughput-stress` |
| F2 | version counter on Cluster: single `kv:ver` hash vs per-key `INCR` slot spread | ❌ Not covered | tied to C4 (no shared counter built) |
| F3 | rename dual-key same-slot (hash tag) atomicity | ❌ Not covered | tied to B4 |

## G. Monitoring / production readiness (§8)

| # | Scenario | Status | Lab(s) / Evidence |
|---|----------|--------|-------------------|
| G1 | stale-reject rate (Lua returns 0) | ✅ Covered | `lww-k8s` exposes `applied/stale/duplicate` counters + dashboard |
| G2 | end-to-end latency (event-time → apply-time) | ✅ Covered | `cdc-via-jetstream`, `throughput-stress`, `vector-cdc`, `multiregion-via-connect` |
| G3 | JetStream pending / PEL lag | ✅ Covered | qos / stress labs (NATS `/jsz`, redis_exporter) |
| G4 | tombstone count / oldest-age vs GC horizon | ❌ Not covered | tied to B2 |
| G5 | resurrection assertion (set onto higher-ver tombstone) | ❌ Not covered | tied to B2 |
| G6 | rename pairing completeness | ❌ Not covered | tied to B4 |

---

## Summary

**✅ Fully covered — the snapshot-`set` happy path + scaling + QoS:**
The core thesis is proven — sink CAS fence, reorder-absorption, idempotent
resend, parallel sink, multi-source/multi-sink scaling, the
single-writer-per-key precondition (and its negative Proof C), dedup,
ALO/AMO/EOE chaos, throughput, and the key stale-reject / latency / lag metrics.

**❌ Notable gaps (no lab exercises these):**
1. **`delete` / tombstone + GC** (B2, G4, G5) — biggest gap; delete is a
   first-class op in the design but has zero coverage.
2. **`rename` where KV key = name** — atomic dual-key + global sequencer
   (B4, F3, G6).
3. **Shared atomic counter `HINCRBY`** (C4) — the design's *explicitly
   recommended*, "brainless-safe across all topologies" version source is never
   actually built; all labs use local per-key counters. This also leaves the
   Cluster counter trade-off (F2) untested. Building it would let topology C
   (multi-writer shared key) become safe.
4. **Alternative version sources** — wall-clock + tiebreaker (C5) and HLC (C6).

**⚠️ Partial / implicit:**
- rename-as-set (B3) holds by construction but is never run as a rename.
- Cluster (F1) is tested for routing/latency, but not for the *version-minting*
  concerns specific to this design.

## Suggested next labs (by priority)

1. **delete/tombstone + GC** — extends `lww_set.lua` with a delete branch
   (`deleted`/`deleted_at`), a GC sweeper, and resurrection + tombstone-age
   monitoring. Closes B2, G4, G5.
2. **`HINCRBY` shared-counter version source** — swap the writer's local counter
   for a source-Redis `HINCRBY` mint; rerun Proof C to show topology C becomes
   safe. Closes C4, informs F2.
3. **rename where key = name** — atomic dual-key Lua + global sequencer +
   pairing-completeness check. Closes B4, F3, G6.
