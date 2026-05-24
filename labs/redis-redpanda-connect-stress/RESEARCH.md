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
