# RESEARCH — redis-redpanda-throughput-stress

## What this lab proves vs parent

The parent (`../redis-redpanda-connect-stress/`) is a 3-axis matrix: tiers × modes × profiles, with chaos drills and per-tier p99 ceilings. It asks: "do the QoS guarantees hold under load?"

This lab strips that to one axis. It asks: **"where does this pipeline top out, and how much of the ceiling comes from writer-side batching?"**

- One profile (ALO), no chaos.
- Two writer modes (batch vs single-XADD), exposed as a hot-swap on `POST /rate`.
- Six tiers from 5k to 50k msg/s.
- Three hashtag-wrapped key patterns (`employee`, `role`, `org`), 60 000 unique keys, weighted picker.
- Calibration-mode verdict: rate floor + `missing == 0` are gated; p99 sync-latency is reported but un-gated until calibrated.

## Sync-latency = `applied_ms − t_send_ms`

Parent's "latency" was computed at the receiver: `receiver_now − ts_ns`, including XREAD polling and regional XADD round-trip. Useful, but not strictly "central Redis vs regional Redis".

This lab reads two timestamps from each `region-events` stream entry:

- `t_send_ms` — writer-stamped, immediately before central XADD.
- `applied_ms` — Connect-sink-stamped (via `meta applied_ms = (timestamp_unix_nano() / 1000000).string()` in `connect/reverse.yaml`), immediately before regional fan-out.

Sync latency = `applied_ms − t_send_ms`. Covers writer → central XADD ack → Connect-source pull → JetStream publish/ack → Connect-sink consume. Does **not** include the final SET round-trip to regional — sub-millisecond on a single host, dominated by Connect/JetStream cost.

## Why hot-swap mode (not container restart)

Twelve mode-switches per matrix run × ~5 s container recreate = 60 s wasted + a reconnect storm against central Redis. The writer's `POST /rate` now accepts `{ "mode": "batch"|"single" }` alongside `rate`; mode swap is atomic (single `atomic.Int32`) and observed by every worker at the top of each loop iteration. Zero connection churn.

## Why hashtags on three patterns

Real workloads pin related keys to the same Cluster slot via `{...}` hashtags. Even though this lab runs single-Redis nodes (not a cluster), keeping the hashtag shape:

- Surfaces realistic key-allocation patterns for the Connect/JetStream pipeline (longer keys, JSON-envelope size).
- Lets a future Cluster topology slot-pin without rewriting the writer.
- Forces the receiver to handle per-pattern accounting, which is the more interesting per-message report than parent's anonymous `stress:<int>` keys.

20 000 unique IDs per pattern × 3 patterns = 60 000 keys. At 50k/s × 30 s = 1.5 M writes, that's ~25 hits per key — enough churn to exercise downstream cache writes, not so much that the pipeline becomes a per-key hot loop.

## Why STREAM_MAXLEN = 2 000 000 (was 100 000 in parent)

50k/s × 30s = 1.5 M peak. Parent's 100 k cap trimmed aggressively at 10k; at 50k it would discard 93% of entries before the receiver could read them. 2 M caps the stream at ~33% headroom over peak. Receiver is still untainted by MAXLEN trimming (streaming `XREAD BLOCK` reads every entry as it arrives; trim only matters for end-of-run XLEN), but the larger cap lets operators eyeball stream contents post-run.

## Why NATS_MAX_BYTES = 5GB (was 2GB)

JetStream's `APP_EVENTS` stream is configured `--storage file --retention limits --discard old --max-bytes ...`. When the stream exceeds the byte cap, the oldest retained messages are evicted regardless of ack status. If a message is evicted before the durable consumer (`region-writer`) reads it, the sink never sees it — silent loss.

Sizing math at 50k, grounded in observed data from the failed 2GB-cap matrix:

- The failed 50k batch run reported `nats.bytes` = 1.26 GB containing ~740k delivered messages, giving an observed **~1.7 KB per message in JetStream file storage** (JSON envelope + NATS headers + file-block overhead).
- At 50k msg/s × 30s sustain = 1.5M messages × 1.7 KB ≈ **2.55 GB peak buffer required**.
- A 2 GB cap evicts the overflow before the sink reads it: 1.5M sent − 740k delivered = 760k missing ≈ 1.3 GB worth, matching the order of magnitude predicted by the byte math (the 2 GB cap is exceeded for the entire second half of the sustain window). This was the main loss path on the original matrix; addressing it is the goal of this change.
- A 5 GB cap gives ~2× headroom over the 50k peak buffer. Even if the sink briefly lags 3–5 s behind the writer, the buffer absorbs it without eviction.

The match between `nats.bytes` end-state and the delivered count (1.26 GB ≈ 740k × 1.7 KB), combined with the harness's quiescence gate reporting `MaxPending == 0` at run end, suggests the sink kept pace with everything that survived eviction — the failing tier wasn't a sink-throughput limit, it was a buffer limit.

The knob is env-tunable (`NATS_MAX_BYTES`) so future tiers (60k, 80k) can raise it without docker-compose edits. nats container memory cap is 2 GiB; this was uncontended at the 2 GB stream size in prior matrix runs and should be re-checked during the 5 GB calibration via `docker stats rrts-nats` (raise the `mem_limit` in docker-compose.yml to 4 GiB if RSS approaches the cap).

## Why calibration-mode verdict

There's no reference number for what p99 sync-latency *should* be at, say, 30k batch mode on a given host. Hard-coding a guess turns the verdict into noise. Ship with `TIER_P99_MS=""` for every tier; collector's `--slo-p99-ms <= 0` flag skips the p99 gate; run the full matrix once on real hardware; pick ceilings; commit them. Future runs gate on real numbers.

## Quiescence note (inherited from parent v2)

Source-side quiescence uses `GroupLag("app.events", "propagator") == 0`, NOT `XLEN("app.events") == 0`. Redis streams don't shrink on ack, so XLEN never returns to zero during a run. The parent lab fixed this in commit `bdf31a9` ("Redis streams don't shrink on ack, so XLEN is not the right metric here"). We inherit the fixed signal. Sink-side uses `ScrapeJSZ.MaxPending == 0`. Both required; tail-flush 1500ms after observation before cancelling the receiver (parent commit `1e9e7b2`).

## Pointers

- Design spec: [`../../docs/superpowers/specs/2026-05-26-redis-redpanda-throughput-stress-design.md`](../../docs/superpowers/specs/2026-05-26-redis-redpanda-throughput-stress-design.md)
- Implementation plan: [`../../docs/superpowers/plans/2026-05-26-redis-redpanda-throughput-stress.md`](../../docs/superpowers/plans/2026-05-26-redis-redpanda-throughput-stress.md)
- Parent lab: [`../redis-redpanda-connect-stress/RESEARCH.md`](../redis-redpanda-connect-stress/RESEARCH.md)
- Redpanda Connect docs: <https://docs.redpanda.com/redpanda-connect/about/>
- Redis Cluster hashtags: <https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/#hash-tags>
- NATS JetStream: <https://docs.nats.io/nats-concepts/jetstream>
- HDR Histogram: <https://github.com/HdrHistogram/hdrhistogram-go>
