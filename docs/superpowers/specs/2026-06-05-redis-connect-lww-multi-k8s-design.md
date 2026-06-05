# Redis → Connect LWW under Multiple Connect Instances (Kubernetes) — DESIGN

**Date:** 2026-06-05
**Topic slug:** `redis-connect-lww-multi-k8s`
**Forks:** `labs/redis-connect-lww-k8s` (single-instance LWW), which itself forks
`labs/redis-redpanda-connect-stress-k8s`. Mechanism source:
`last-write-wins-lab/research.md`.

## Property demonstrated (one sentence)

Horizontally scaling the **relay** tier — N>1 `connect-source` *and* N>1
`connect-sink` replicas — preserves the LWW compare-and-set fence exactly
(`mismatches=0`, with `stale>0` now driven by *cross-instance* reordering),
because correctness lives in Redis's atomic per-key `EVAL` and not in the
pipeline; **but** scaling the **version-origin** tier (the writer) breaks LWW via
a silent lost update that a version-only check cannot even detect.

## Why this is the right question

The parent lab (`redis-connect-lww-k8s`) deliberately excludes "HA / multi-pod
sink" and runs exactly one pod per service; its parallelism (and therefore its
reordering) is *intra-pod* (`pipeline.threads`, source `max_in_flight`). This lab
takes the excluded case head-on: does the fence still hold when the reordering is
*inter-pod* — when same-key messages are processed concurrently by *different*
sink pods, and when the source stream is consumed in parallel by *different*
source pods?

The hypothesis (and the result this lab must prove or falsify) is that
**multi-instance connect is safe**: `connect` never *generates* a version, it only
*relays* one. Correctness is enforced by `lww_set.lua`, which Redis executes
atomically and serially per key regardless of how many client connections or pods
call it. Scaling the relay tier therefore adds reordering pressure that the fence
absorbs; it does not add a new way to lose a write.

The sharp contrast — and the reason this lab is more than a replica-count bump —
is that scaling the **writer** is *not* safe, and the existing proof instrument is
**blind** to the breakage. See "Proof C" below.

## Key finding that shapes the design

`verifier/lww.go::CompareVersions` (line ~111) tallies a mismatch on
`regionVer != srcMax` — it compares **version only, never value**. Consequence:

- With two uncoordinated writers, both stamp a key with the *same* monotonic
  version sequence (each starts at 1 and increments independently). Both reach
  some max version `K`. Region ends at version `K`. That **equals** the queried
  writer's max → `CompareVersions` reports `mismatches=0` → verdict PASS.
- But the two writers wrote *different values* at version `K`. The fence's
  `EVAL` keeps whichever landed first; the second arrives with an *equal* version
  and is dropped down the Lua's `duplicate` (`-1`) branch. **A committed update is
  silently lost** with no `stale`, no `mismatch`, no `regression`.

So a version-only fence verified by a version-only check cannot see a concurrent
same-version lost update. This is the most convincing possible argument for the
single-writer-per-key precondition, and Proof C is built to expose it.

## Topology

Identical to the parent lab. Exactly two knobs change from `replicas: 1`:

| Service          | Parent | This lab | Role |
|------------------|:------:|:--------:|------|
| writer           |   1    |    1     | single owner per key; stamps monotonic version (UNCHANGED — scaling it is the *negative* case) |
| redis-central    |   1    |    1     | ingest stream `app.events` |
| **connect-source** | 1    |  **3**   | Redis-Streams consumer group `propagator` → publishes to NATS JetStream |
| nats             |   1    |    1     | JetStream `APP_EVENTS` |
| **connect-sink** |   1    |  **3**   | JetStream consumer → `EVAL lww_set.lua` against redis-region |
| redis-region     |   1    |    1     | KV sink + `region-events` ledger; single source of truth for the proof |
| dashboard        |   1    |    1     | live view (unchanged) |

Replica counts are values-driven (`connect.source.replicas`,
`connect.sink.replicas`, default 3) so a run can be dialed up or down; the
verifier aggregates across however many sink pods exist.

### Two reorder vectors (both new vs. the parent)

1. **Source-side parallel consumption.** Three source pods share consumer group
   `propagator` with distinct consumers (`client_id: ${HOSTNAME}`). Redis Streams
   delivers each entry to exactly one consumer, so the three pods drain
   `app.events` in parallel. The order in which entries reach NATS no longer
   matches XADD order across pods.
2. **Sink-side concurrent CAS.** Three sink pods share the JetStream durable, so
   same-key messages can be processed *simultaneously* by different pods, each
   issuing an `EVAL` for the same key. Redis serializes them per key; the fence
   must yield the correct final state regardless of interleaving.

## Proofs

Mirrors the parent's "Proof A deterministic + Proof B end-to-end" structure, with
the deterministic slot repurposed as a *negative* proof.

### Proof B′ — positive, end-to-end (headline)

Drive the writer through the real pipeline at a target rate with 3 source + 3 sink
pods. After quiescence, compare every key's region version to the writer's source
max (the existing `CompareVersions`). Pass requires:

- `mismatches == 0` and `regressions == 0` — final per-key state exactly correct.
- `stale > 0` — strictly-older arrivals were observed in the measured window,
  proving cross-instance reordering was actually exercised and fenced.
- the parent's precondition guards still hold (fresh epoch namespace, writer
  `boot_id` unchanged, store empty at start, pipeline quiesced).

This is the parent's exact bar, now met under inter-pod concurrency.

### Proof C — negative, deterministic (contrast)

Scripted, direct against redis-region using `lww_set.lua` (no full pipeline; same
style as the parent's Proof A). Simulate two uncoordinated writers on a shared key:

- Writer A applies versions `1..K` with values `A:v1..A:vK`.
- Writer B applies versions `1..K` with values `B:v1..B:vK`.
- The two sequences are interleaved (e.g. A:v1, B:v1, A:v2, B:v2, …) to model two
  pods racing.

Assertions:

- **(a) Version-only check is satisfied:** `HGET key ver == K`, equal to each
  writer's max → the existing `CompareVersions` would report `mismatches=0`
  (PASS). Demonstrated by reusing the same comparison logic.
- **(b) Value check reveals the loss:** `HGET key val` is exactly one of
  `A:vK` / `B:vK`; the other writer's version-`K` commit is gone, having been
  rejected as `duplicate` (`-1`). At least one committed update was lost with no
  `stale`/`mismatch`/`regression` signal.

Output is labelled unambiguously: *single-writer-per-key precondition violated →
LWW broken, and invisibly to the version-only proof instrument.* This is what
makes the positive result meaningful: the fence is safe under multi-**connect**
precisely because connect never violates this precondition; multi-**writer** does.

## Implementation pieces

### 1. Replica knobs (chart)

- `values.yaml`: add `connect.source.replicas` and `connect.sink.replicas`
  (default `3`).
- `templates/connect-source.yaml`, `templates/connect-sink.yaml`: replace
  hardcoded `replicas: 1` with the values.
- `values-dev.yaml`: may pin lower counts if kind resource budget requires; keep
  ≥2 each so the multi-instance property is actually exercised.

### 2. Per-pod sink-metric aggregation (verifier + chart)

The verifier currently scrapes `http://connect-sink:4195/metrics` through the
ClusterIP Service, which round-robins to one pod. `lww_apply` is a per-pod
counter, so a single-URL scrape (a) sees only one pod's count and (b) can hit
different pods on the baseline vs. final scrape → garbage deltas.

- **Chart:** add a headless Service `connect-sink-headless`
  (`clusterIP: None`, `publishNotReadyAddresses: false`) selecting
  `app: connect-sink`, so DNS returns the full set of ready pod IPs.
- **Verifier:** resolve the headless name via `net.LookupHost`, scrape every pod's
  `:4195/metrics`, and **sum** applied/stale/duplicate. Do this for both the
  baseline (`a0/s0/d0`) and each end-of-window scrape; the proof delta is
  `sum_end - sum_baseline`.
- **Fail-loud guards (consistent with the lab's ethos):** capture the per-IP set
  and per-IP baseline at sustain start; at end, re-scrape the *same* IPs. If the
  pod set changed, an IP is unreachable, or any pod's current counter is below its
  baseline (a pod restart resetting cumulative counters), mark the scrape failed →
  hard precondition failure, not a silent under-count.
- **No change to the correctness check.** `CompareVersions` reads region Redis
  directly (the single source of truth) and is already pod-count-independent.
  `mismatches=0` remains the robust correctness signal.

### 3. JetStream shared-consumer resolution (research unknown)

The sink input (`lww-reverse.yaml`) is `nats_jetstream` with
`durable: region-writer`, `deliver: all`. For three pods to *share* one durable so
each message is processed once, NATS requires either a pull consumer or a push
consumer with a deliver (queue) group. Whether the
`hpdevelop/connect:4.92.0-claudefix` image's `nats_jetstream` input supports this —
and via which fields — must be determined empirically in the Research stage.

- **Preferred outcome:** shared durable, work distributed one-message-to-one-pod
  (realistic HA). Tune `threads`/`max_in_flight` so reordering is still forced.
- **Fallback (only if the image cannot share a durable):** documented in
  RESEARCH.md; choose the variant that still produces genuine inter-pod
  work-distribution. A per-pod-durable full fan-out (every pod processes every
  message) is the last resort — it still proves the fence's idempotency under
  concurrent duplicate CAS, but is not realistic HA and must be labelled as such.
- **Hard rule:** if multiple sink pods cannot run without silently dropping or
  double-applying in a way the fence doesn't cover, fail loud and document —
  do not paper over it.

## Validation

This is a Kubernetes lab; the research-lab skill's `validate_lab.sh`
(docker-compose only) does not apply. Validation is `scripts/verify-lww.sh`
(forked), which must:

1. Boot the chart with 3 source + 3 sink pods (`--wait` for all ready).
2. Run **Proof C** (deterministic negative) and assert both (a) version-check
   passes and (b) value-check exposes a lost update.
3. Run **Proof B′** (end-to-end positive) and exit 0 only if
   `mismatches=0 && regressions=0 && stale>0` with all precondition guards holding
   and metrics aggregated across all three sink pods.

A run that cannot force `stale>0` is `inconclusive` (same semantics as the
parent: lower `KEY_SPACE_SIZE` or raise `RATE`/`DURATION_S`).

## Deliberately excluded

- **The writer-HA fix.** Proof C shows the *break* only; leader election or
  hash-partitioned key ownership across writer pods (the cure) is out of scope.
- **Redis Cluster / sharded region.** Single region instance; the fence's
  per-key atomicity is what's under test, not cross-shard coordination.
- **Sink autoscaling (HPA), chaos/pod-kill mid-run, latency SLOs.** Carried (or
  excluded) by ancestor labs; dropped here to keep one concern.
- **Event-time / wall-clock LWW.** The version is a logical per-key counter, as in
  the parent.

## Escalation note

Per research-lab Stage 3: this fork has a genuine research unknown (JetStream
shared-consumer semantics), cross-component coordination (verifier topology must
track the new headless Service), and a new negative-proof harness. After this
design is approved, proceed via the `writing-plans` skill to produce an
implementation plan before writing code.
