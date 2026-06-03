# RESEARCH — credential auth + external backend support

This iteration adds production-shape NATS credential auth (operator → account
→ user JWTs + .creds files) and independent bundled-vs-external toggles for
NATS and each Redis. Two design decisions worth remembering:

- **Permission narrowness.** Publisher and subscriber don't share admin
  creds; each gets exactly the JetStream API subjects it needs (publisher:
  `app.events.>` + read on `$JS.API.STREAM.INFO.<stream>`; subscriber:
  ack on `$JS.ACK.<stream>.<durable>.>` + the four narrow CONSUMER subjects
  scoped to its own durable + the same stream-info read). A compromised
  source can't drain the stream; a compromised sink can't inspect other
  consumers. This is the production pattern; lab demonstrates the format.
- **Two modes, one chart.** Bundled mode mints fixture creds at install
  for kind/local use. External mode skips deploying NATS/Redis and consumes
  user-supplied Secrets by name (production workflow: signing keys in Vault,
  creds materialized into K8s Secrets via External Secrets / SealedSecrets).
  Lab is a teaching artifact: bundled shows the FORMAT, external shows the
  WORKFLOW.

---

# RESEARCH — Kubernetes fork

This lab forks the Docker Compose stress lab to a Kubernetes substrate without
changing the pipeline or its measurement. Key substrate decisions:

- **Compose `depends_on` → initContainers + readiness probes.** Ordering that
  compose expressed declaratively becomes initContainer poll-loops (Redis ping,
  `APP_EVENTS` existence) plus real readiness probes (`/ready`, `/healthz`,
  `redis-cli ping`). The probes also make chaos recovery a true gate.
- **Stream init is a plain Job, not a Helm hook.** A `post-install` hook would
  deadlock against `helm --wait` (the Connect Deployments wait on the stream,
  the hook runs after wait). A plain Job gated by an initContainer avoids the
  circular wait.
- **Report extraction via stdout sentinel.** There is no portable shared mount
  in K8s (hostPath is non-portable), so the collector emits one compact
  `RESULT_JSON:` line and the harness reads it from `kubectl logs`. The exit
  code means "did it run", not "did it pass" — so an expected FAIL verdict
  doesn't trip Job failure/retry.
- **NATS persistence defaults to emptyDir.** Durability isn't load-bearing for a
  stress lab; emptyDir keeps the chart runnable on a bare cluster with no
  StorageClass. `pvc` mode is opt-in.

---

(Original compose-lab research follows.)

# RESEARCH — redis-redpanda-connect-stress

## What stress proves

This lab demonstrates two things about Redpanda Connect that the parent `redis-redpanda-qos-resilience` lab cannot:

1. **Connect sustains real throughput.** The parent lab runs at 1 msg/s — enough to observe QoS semantics in human time, but not enough to surface throughput, batching, or backpressure behavior. This lab pushes 10 / 1 000 / 10 000 msg/s and verifies the pipeline keeps up.
2. **QoS guarantees hold under load.** The same chaos drill the parent uses (kill `connect-sink` for ~8 s) is run at every tier — including 10 k msg/s. At that rate, ~80 000 messages back up in JetStream during the outage. The lab verifies they all reach `region-events` after recovery (under ALO/EOE) within a bounded latency.

## Why a fork, not an extension

- The parent's WebSocket dashboard, per-key keyspace notifications, and last-value-per-key model all break at high throughput. Stripping them would gut the parent lab; forking lets each lab stay true to its purpose.
- The parent runs unbounded; this lab caps Redis streams, JetStream bytes, and every container's CPU+memory so a stress run cannot stutter the host.

## Why a wide key space + monotonic seq

At 10 k msg/s, the parent's 9-cycling-keys model results in ~1 111 writes/s per key — pure last-write-wins churn at Redis with no observability value. Wide key space (100 000 distinct keys) ensures no key is hammered; verification shifts from per-key last-value to **count match + sampled e2e latency**.

## Why live `POST /rate` instead of writer recreate

Recreating the writer container between tiers takes ~5 s × 9 = ~45 s of wasted wall-clock per matrix run, and the reconnect storm can interfere with the previous tier's drain (which would corrupt counts). A live HTTP rate endpoint lets the harness flip targets in <100 ms with zero connection churn.

## Why a one-shot collector instead of a live dashboard

Two reasons:

1. **Sampling rate**: at 10 k msg/s, a WebSocket-driven UI would either drop frames or flood the browser. The collector samples at 1 Hz — fast enough to catch backpressure, slow enough to never become the bottleneck.
2. **Reproducibility**: post-run JSON reports are diffable and storable. A live dashboard is a moment in time; a JSON file is a permanent artifact.

## Why `MAXLEN ~` and `--max-bytes`

A 30 s run at 10 k msg/s produces ~300 k messages × ~300 bytes = ~90 MB in Redis and ~120 MB in NATS. Across 9 runs that compounds. `XADD ... MAXLEN ~ 100000` and JetStream `--max-bytes=256MB` bound the storage so a runaway run can't fill the disk or push the host into swap.

## Verdict logic in one sentence

A run passes iff: achieved rate ≥ `slo.rate_min_pct × target`, missing messages = 0 (unless profile = AMO), and (for latency/chaos modes) p99 latency ≤ tier SLO.

## Pointers

- Design spec: [`../../docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md`](../../docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md)
- Implementation plan: [`../../docs/superpowers/plans/2026-05-24-redis-redpanda-connect-stress.md`](../../docs/superpowers/plans/2026-05-24-redis-redpanda-connect-stress.md)
- Parent lab RESEARCH: [`../redis-redpanda-qos-resilience/RESEARCH.md`](../redis-redpanda-qos-resilience/RESEARCH.md)
- Production architecture deep-dive that informed both labs: [`../../redis-redpanda-design-ptr/research.md`](../../redis-redpanda-design-ptr/research.md)
- Redpanda Connect docs: <https://docs.redpanda.com/redpanda-connect/about/>
- NATS JetStream concepts: <https://docs.nats.io/nats-concepts/jetstream>
- HDR Histogram: <https://github.com/HdrHistogram/hdrhistogram-go>

## v2 measurement-vs-pipeline distinction

The first v1 full-matrix run on 2026-05-25 revealed that three of the lab's "failures" were measurement artifacts, not pipeline failures:

1. **Latency P99 was polling-window-biased.** v1 sampled 200 messages/s from `XRANGE`; at 10 k msg/s that captured ~2 % of messages and the reported `now − ts_ns` was inflated by up to one polling window (~1 s). v2's streaming `XREAD BLOCK` consumer reads every message at line rate, so `latency_ms.p99` now reflects true e2e propagation.
2. **`missing` confused MAXLEN trim with loss.** v1 computed `missing = sent − XLEN(region-events)`. The region stream has `MAXLEN ~ 100000`; at 10 k × 30 s, 200 k older entries were trimmed by design. v1 reported them as "missing" and failed the verdict. v2 sources `received` from the streaming consumer (untainted) and surfaces `trimmed` separately so operators can see the storage decision didn't lose messages.
3. **NATS state survived across matrix runs.** v1 ran 9 tier×mode combinations against the same persistent `nats-data` volume; the 256 MB JetStream cap accumulated bytes until the 10 k chaos run aborted on the 200 MB pre-flight. v2's harness purges `APP_EVENTS` after every run so each tier starts hermetic.

The pipeline under test (writer → connect-source → JetStream → connect-sink → region Redis) is byte-identical between v1 and v2. The only changes are in the measurement layer (collector) and the harness's between-run hygiene.

### Why a streaming consumer (not just a bigger XRANGE)

A poll that samples 1 000 messages/s instead of 200 would still miss 90 % of messages at 10 k msg/s, and its reported "latency" would still include polling-window bias. The streaming model is the only one that observes *every* message at arrival time, which is both the right metric and a side benefit: the same consumer that records latency also provides the trim-free `received` count.

### Why profile-aware quiescence

The amo-reverse leg uses an ephemeral, deliver-new, `ack_wait: 2s`, `auto_replay_nacks: false` consumer. `num_pending` is meaningless for that consumer (it's recreated each connect-sink restart and ignores backlog by design — that's how AMO loses messages). v2's pipeline-quiescence wait checks `XLEN(app.events) == 0` for all profiles plus `NATS num_pending == 0` only for ALO/EOE; AMO falls through to `slo.allow_missing=true` so any unconsumed backlog at end-of-run is accepted as the modeled loss.
