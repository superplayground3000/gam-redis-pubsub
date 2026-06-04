# Redis → Connect Last-Write-Wins (Kubernetes) — RESEARCH

## Property demonstrated

A stale change (lower version) can never overwrite a newer change at the Redis KV
sink, regardless of arrival order across a parallel pipeline — and we measure the
sustained applied-write throughput of a single-instance sink that relies on this
fence instead of strict ordering.

This lab is a Kubernetes/Helm fork of `../redis-redpanda-connect-stress-k8s`. The
mechanism it verifies comes from `../../last-write-wins-lab/research.md` (the upstream
design answer): a **last-write-wins compare-and-set (CAS) fence at the sink**.

## Essentials (what is load-bearing)

Pipeline: `writer → redis-central stream → connect-source → NATS JetStream →
connect-sink → redis-region`. Same as the parent, with exactly one change in the data
path: the sink's blind `SET` becomes a version-gated CAS.

- **Per-key monotonic version.** The writer owns each key with a single goroutine
  (`keyID % workers == i`) and stamps a strictly-increasing `version`. No clock
  dependence; no two writers ever touch the same key.
- **The CAS fence (`chart/files/connect/lww_set.lua`).** A Redis Lua `EVAL` applied
  at connect-sink: `HSET val/ver` only if the incoming version is strictly greater
  than the stored one. Returns `1` applied / `0` stale (strictly older) / `-1`
  duplicate (equal). Order-independent and idempotent by construction; Redis
  serializes per key, so it is correct without any pipeline ordering guarantees.
- **The relaxation is the point.** Because correctness lives at the sink, the sink
  runs `pipeline.threads: 4` and the source publishes with `max_in_flight: 256` —
  which *causes* same-key reordering. The lab proves the fence survives it.

### Wire contract (enough to re-implement a client)

- Writer XADD fields on `app.events`: `value` (JSON body), `event_id`, `key`
  (`lww:<epoch>:<id>`), `pattern`, `t_send_ms`, `version` (int).
- connect-sink CAS call: `EVAL lww_set.lua 1 <key> <value> <version>`.
- Sink metric: `lww_apply_total{result=applied|stale|duplicate}` at `:4195/metrics`.
- Writer control plane: `POST /reset {"epoch":"<id>"}`, `GET /state` →
  `{boot_id, epoch, keys{<key>:<maxVer>}, distinct_keys, total_versions}`,
  `POST /rate {"rate":n}`, `GET /metrics`.

## How the proof is made unambiguous (spec §3.4.1)

`stale > 0` only proves reordering-was-fenced under a precondition the verifier
*asserts*, not assumes:

> the run's keys begin with no stored version, numbered by a single non-restarting
> monotonic writer.

Guards: a **fresh per-run epoch key namespace** (`lww:<epoch>:<id>`) so the store is
provably empty for the run; a **writer `boot_id`** checked unchanged across the window
(no mid-run restart); **windowed counter deltas** (baseline at sustain start) so a
prior run / warmup / the deterministic Proof A cannot satisfy the signal; and the
**3-way Lua** so equal-version duplicates (routine at-least-once redelivery) are
counted separately and excluded from the proof. A no-op fence fails two independent
ways (`stale==0` and, under reorder, `mismatches>0`).

## Validated result (kind, single instance)

`scripts/verify-lww.sh` on a local `kind` cluster:

- **Proof A** (deterministic): apply versions 3,1,2 then replay 3 to one key →
  returns `1 0 0 -1`, final `ver=3 val=v3`. The fence works in isolation.
- **Proof B** (end-to-end): drive the writer through the real parallel pipeline,
  wait for quiescence, compare every key's region version to the writer's source max.
  - @ 5,000 msg/s: `rate_achieved≈4999.96`, `stale=2726`, `mismatches=0`,
    `regressions=0`, `writes_per_key≈5091`, **pass**.
  - @ 20,000 msg/s (writer cap): `rate_achieved≈19999.6`, `stale=7014`,
    `mismatches=0`, **pass**.

**Throughput estimate:** a single connect-sink pod sustains **≥20,000 applied
writes/s** with zero LWW violations (the writer's `MAX_RATE` cap, not an observed
ceiling — the sink kept up with no backlog, so the true ceiling is higher). The
non-zero `stale` count is the system working: thousands of strictly-older arrivals
were reordered and fenced while the final per-key state stayed exactly correct.

## Design decisions

- **Version token = per-key logical counter, single writer per key** (research's
  "best" option) — clean integer compare, no clock skew, makes the reorder proof
  deterministic.
- **Single instance** — one pod per service; the parallelism (and thus reordering)
  is intra-pod (`threads`/`max_in_flight`). Demonstrates the fence without HA noise.
- **Small keyspace (32)** — same-key messages must land inside the pipeline's
  in-flight windows to reorder; a large keyspace spaces them out and yields
  inconclusive (`stale=0`) runs. Empirically tuned (see `chart/values.yaml`).
- **Lua embedded at Helm render time** (`toJson`) rather than a mounted file —
  single source of truth, no per-message file read. (The image's `redis` processor
  has no `result_map`; the eval result is captured by a trailing `mapping`.)

### Rejected alternatives (from upstream research)

- **NATS-side timestamp/discard** — JetStream discard is limit-triggered, never
  "apply only if newer"; `DiscardNewPerSubject` is first-write-wins (the opposite).
- **Source-side `now()` timestamp** — stamps processing time; redelivery/reclaim
  makes a stale event look newer. The version must come from the source of truth.

## Deliberately excluded

- HA / multi-pod sink and Redis Cluster (single instance only here).
- Chaos/crash-replay, the tier × mode × QoS matrix, latency SLOs (carried by the
  parent lab; dropped to keep one concern).
- Event-time / wall-clock LWW and its skew hazard (we use a logical counter).
- Deletes / tombstones (keys are never deleted).

## Further reading

- `../../last-write-wins-lab/research.md` — the upstream mechanism design.
- `../../docs/superpowers/specs/2026-06-04-redis-connect-lww-k8s-design.md` — this lab's spec (§3.4.1 precondition).
- `../redis-redpanda-connect-stress-k8s/` — the parent stress lab this forks.
