# Redis → Connect LWW under Multiple Connect Instances (Kubernetes) — RESEARCH

## Property demonstrated

Horizontally scaling the **relay** tier — N>1 `connect-source` *and* N>1
`connect-sink` replicas — preserves the LWW compare-and-set fence exactly
(`mismatches=0`, with `stale>0` now driven by *cross-instance* reordering),
because correctness lives in Redis's atomic per-key `EVAL` and not in the
pipeline; **but** scaling the **version-origin** tier (the writer) breaks LWW via
a silent lost update that a version-only check cannot even detect.

This lab is a fork of `../redis-connect-lww-k8s` (single-instance LWW), which
itself forks `../redis-redpanda-connect-stress-k8s`. The fence mechanism comes
from `../../last-write-wins-lab/research.md`.

## Why this is the right question

The parent lab deliberately excludes "HA / multi-pod sink" and runs exactly one
pod per service; its parallelism — and therefore its reordering — is *intra-pod*
(`pipeline.threads`, source `max_in_flight`). This lab takes the excluded case
head-on: does the fence still hold when the reordering is *inter-pod* — when
same-key messages are processed concurrently by *different* sink pods, and when
the source stream is consumed in parallel by *different* source pods?

The hypothesis (and the result this lab must prove or falsify) is that
**multi-instance connect is safe**: `connect` never *mints* a version, it only
*relays* one. Correctness is enforced by `chart/files/connect/lww_set.lua`, which
Redis executes atomically and serially per key regardless of how many client
connections or pods call it. Scaling the relay tier therefore adds reordering
pressure that the fence absorbs; it does not add a new way to lose a write —
correctness is independent of pod count and arrival order.

The sharp contrast — and the reason this lab is more than a replica-count bump —
is that scaling the **writer** is *not* safe, and the existing proof instrument is
**blind** to the breakage. See "The negative result" below.

## Essentials (what is load-bearing)

Pipeline is identical to the parent: `writer → redis-central stream →
connect-source → NATS JetStream → connect-sink → redis-region`. Exactly two knobs
change from `replicas: 1`: `connect-source` and `connect-sink` each run **3**
pods (values-driven, `connect.source.replicas` / `connect.sink.replicas`). This
introduces two **new inter-pod reorder vectors** that the parent (intra-pod only)
never exercised:

1. **Source-side parallel consumption.** Three source pods share the
   Redis-Streams consumer group `propagator` via distinct consumers
   (`client_id: ${HOSTNAME}`). Redis Streams delivers each entry to exactly one
   consumer, so the three pods drain `app.events` in parallel. The order in which
   entries reach NATS no longer matches XADD order across pods.
2. **Sink-side concurrent CAS.** Three sink pods share **one** JetStream durable
   via a `queue` deliver group, so same-key messages can land on *different* pods
   *concurrently*, each issuing an `EVAL` for the same key. Redis serializes them
   per key; the fence must yield the correct final state regardless of the
   inter-pod interleaving.

## Wire contract delta vs parent

The writer XADD fields, the `EVAL lww_set.lua 1 <key> <value> <version>` CAS
call, and the sink metric `lww_apply_total{result=applied|stale|duplicate}` are
all unchanged from the parent. The deltas are:

- **Sink input** (`chart/files/connect/lww-reverse.yaml`) adds a queue-only deliver
  group `queue: region-writer` to its `nats_jetstream` input (no separate `durable`,
  since connect 4.92.0 forbids `durable`+`queue` together; the queue name must equal
  the durable name `region-writer` so the derived consumer name matches the
  subscriber JWT grants). All N sink pods join this one deliver group and
  load-balance deliveries (each message → exactly one pod).
- **Verifier metric scrape.** `lww_apply` is a per-pod counter. The parent
  scraped one ClusterIP URL, which round-robins to a single pod and can hit
  different pods on baseline vs. final scrape → garbage deltas. The verifier now
  resolves the headless Service `lab-connect-sink-headless` (`clusterIP: None`,
  one DNS A-record per ready pod), scrapes every pod's `:4195/metrics`, and
  **sums** applied/stale/duplicate for both the baseline and the end-of-window
  scrape; the proof delta is `sum_end − sum_baseline`.
- **Fail-loud guard.** The per-IP set and per-IP baseline are captured at sustain
  start and re-scraped at end. If the pod set changed, an IP is unreachable, or
  any pod's current counter is *below* its baseline (a restart resetting
  cumulative counters), the scrape is a hard precondition failure — never a
  silent under-count.
- **Correctness check UNCHANGED.** `verifier/lww.go::CompareVersions` reads region
  Redis directly (the single source of truth) and is already pod-count-independent;
  `mismatches=0` remains the robust correctness signal.

## The negative result (Proof C)

`verifier/lww.go::CompareVersions` tallies a mismatch on `regionVer != srcMax` —
it compares **version only, never value**. Consequence, with two uncoordinated
writers on a shared key:

- Both stamp the key with the *same* monotonic version sequence (each starts at 1
  and increments independently) and both reach some max version `K`. Region ends
  at version `K`, which **equals** each writer's max → `CompareVersions` reports
  `mismatches=0` → verdict PASS.
- But the two writers wrote *different values* at version `K`. The fence's `EVAL`
  keeps whichever landed first; the second arrives with an *equal* version and is
  dropped down the Lua's `duplicate` (`-1`) branch. **A committed update is
  silently lost** — no `stale`, no `mismatch`, no `regression`.

So a version-only fence verified by a version-only check cannot see a concurrent
same-version lost update. This is why multi-**writer** breaks LWW *invisibly*, and
why the single-writer-per-key precondition is load-bearing. The fence is safe
under multi-**connect** precisely because connect never violates that precondition;
multi-**writer** does.

## How the proof is made unambiguous

The harness runs three proofs (see `scripts/verify-lww.sh`); exit 0 requires all
three:

- **Proof A — deterministic mechanism.** Apply versions 3,1,2 then replay 3 to one
  key, direct to redis-region → returns `1 0 0 -1`, final `ver=3 val=v3`. The
  fence works in isolation.
- **Proof C — deterministic negative.** Scripted, direct against redis-region via
  `lww_set.lua` (`scripts/proof-c.sh`): two uncoordinated writers apply
  interleaved versions `1..K`, asserting (a) the version-only check would report
  `mismatches=0` (PASS) yet (b) the value check shows exactly one writer's
  version-`K` commit survives — the other was rejected as `duplicate` with no
  signal. Labelled unambiguously: *single-writer-per-key precondition violated →
  LWW broken, invisibly to the version-only instrument.*
- **Proof B′ — end-to-end positive.** Drive the writer through the real pipeline
  with 3 source + 3 sink pods. It keeps the parent's precondition guards — fresh
  per-run epoch key namespace (store provably empty at start), writer `boot_id`
  checked unchanged (no mid-run restart), pipeline quiesced, windowed counter
  deltas, and `stale > 0` required — *and* adds the per-pod metric aggregation
  across all sink pods with the restart guard above. Pass requires
  `mismatches == 0` and `regressions == 0` and `stale > 0`. This is the parent's
  exact bar, now met under inter-pod concurrency.

## Validated result

Validated on a 3-pod kind cluster (`lwwm`, namespace `lwwm-k8s`), `profile=lww`,
`scripts/verify-lww.sh` exit 0 — Proof A (mechanism), Proof C (negative), and
Proof B′ (multi-instance end-to-end) all green.

- **Sink pods:** 3 × `connect-sink` (all `1/1 Running`).
- **Per-pod `lww_apply` counters** (from each pod's `:4195/metrics`):

  | sink pod | applied | duplicate |
  |---|---|---|
  | `lab-connect-sink-…-chz5t` | 42920 | 0 |
  | `lab-connect-sink-…-crf6f` | 42960 | 0 |
  | `lab-connect-sink-…-kd474` | 42862 | 0 |

  Applied work is split ~1/3 per pod (≈42.9k each, sum ≈128.7k) with **zero
  duplicates** — confirming **DISTRIBUTION** mode: all pods bind to one shared
  consumer, so each message is delivered to exactly one pod. (A FAN-OUT layout
  would show each pod ≈ the full message count, or duplicate ≈ applied.)

- **Proof B′ result** (`lww` block, rate target 5000):

  | metric | value |
  |---|---|
  | `rate_achieved_avg` | 4999.92 msg/s |
  | `stale` | 31236 |
  | `duplicate` | 0 |
  | `mismatches` | 0 |
  | `regressions` | 0 |
  | `writes_per_key_avg` | 5090.625 |
  | `keys_checked` | 32 |
  | verdict | **pass** |

  `mismatches=0` with `stale>0` is the load-bearing outcome: same-key messages
  were reordered across pods, the CAS fence rejected 31236 strictly-older
  arrivals, and every key converged to its highest version.

This lab's ethos is that docs do not assert throughput numbers, stale counts, or
"it passes" before an actual validation run; the figures above are taken verbatim
from that run's Proof B′ JSON and per-pod metrics.

## Design decisions / rejected alternatives

- **Deliver group (shared durable) over per-pod-durable fan-out.** A `queue`
  deliver group lets all N sink pods share one JetStream consumer so each message
  is processed once — realistic HA work-distribution. A per-pod-durable fan-out
  (every pod processes every message) would still prove the fence's idempotency
  under concurrent duplicate CAS, but is not realistic HA. The observed run was
  **DISTRIBUTION** (each pod applied ≈1/3 of writes, duplicate=0), confirming the
  shared-consumer path.
- **Queue-only consumer, queue name == durable name (connect 4.92.0 constraint).**
  This Redpanda Connect build (4.92.0) rejects `durable` and `queue` set together
  ("both 'queue' and 'durable' can't be set simultaneously"), so the
  `nats_jetstream` input uses a `queue` with **no** explicit `durable`. The NATS
  client derives the consumer/durable name *from the queue name*, so the queue
  name is set equal to `.Values.nats.stream.consumer.durable` (`region-writer`).
  This is load-bearing: the subscriber JWT (`scripts/gen-nats-auth.sh`) grants
  `CONSUMER.CREATE`/`INFO` and `$JS.ACK.APP_EVENTS.region-writer.>` scoped to that
  exact name; a mismatched queue name (e.g. the earlier `region-writer-q`) derives
  consumer `region-writer-q`, which the JWT does not authorize, and the sink pods
  stay `0/1`. The init job creates only the stream (no consumer), so there is no
  pre-existing-consumer conflict on a fresh install.
- **DNS enumeration over the Kubernetes API.** The verifier discovers sink pods by
  resolving the headless Service name (`net.LookupHost`), not by listing pods via
  the API server — no RBAC / ServiceAccount permissions needed.
- **Version token = per-key logical counter, single writer per key** (carried from
  the parent): clean integer compare, no clock skew, deterministic reorder proof.

## Deliberately excluded

- **The writer-HA fix.** Proof C shows the *break* only; leader election or
  hash-partitioned key ownership across writer pods (the cure) is out of scope.
- **Redis Cluster / sharded region.** Single region instance; the fence's per-key
  atomicity is under test, not cross-shard coordination.
- **Sink autoscaling (HPA), chaos / pod-kill mid-run, latency SLOs.** Carried or
  excluded by ancestor labs; dropped here to keep one concern.
- **Event-time / wall-clock LWW.** The version is a logical per-key counter, as in
  the parent.

## Further reading

- `../../last-write-wins-lab/research.md` — the upstream mechanism design.
- `../../docs/superpowers/specs/2026-06-05-redis-connect-lww-multi-k8s-design.md` — this lab's spec.
- `../redis-connect-lww-k8s/` — the single-instance parent lab.
- `../redis-redpanda-connect-stress-k8s/` — the grandparent stress lab.
