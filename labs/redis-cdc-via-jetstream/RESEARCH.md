# Research: Redis Streams → NATS JetStream → Redis KV (CDC bridge)

## Topic

A change-data-capture (CDC) bridge that mirrors data from a "source" Redis (via Redis Streams) through a NATS JetStream broker into a "sink" Redis (as a queryable KV view), so producers and consumers of the data can be operationally decoupled.

## Property demonstrated

Two parts:

1. **End-to-end propagation latency** — measured p50/p99 from server's `XADD` on Redis-source to key visibility on Redis-sink, over 100 events.
2. **Durability across consumer restart** — when the consumer container is killed mid-flight and restarted, no events are lost end-to-end; the final count and contents on Redis-sink match what the server produced.

## Concept summary

- **Redis Streams** is an append-only log inside Redis. `XADD` writes an entry; `XREADGROUP` lets a named consumer group read-and-track new entries with its own pending list. The source side of this bridge uses Streams because the property "no events lost" requires durable, replayable reads — keyspace notifications (`__keyspace@0__:*`) are fire-and-forget pub/sub and would lose events when the provider is offline.
- **NATS JetStream** is NATS's persistent streaming layer. A *stream* persists messages published to one or more subjects; *consumers* (durable or ephemeral) read from a stream and acknowledge. Durable consumers retain their cursor across restarts — that's the property we exercise in the kill-restart test.
- **The bridge pattern** decouples write-side and read-side. The source Redis is the "write API" the server talks to; the sink Redis is the "read API" the client talks to. NATS JetStream is the event highway between them. This is a small-scale model of a real CDC pipeline (e.g., Debezium for Postgres → Kafka → materialized views).
- **At-least-once semantics, idempotent writes.** Both the provider's `XREADGROUP` and the consumer's JetStream subscribe are at-least-once. The consumer makes its write to Redis-sink idempotent (`HSET event:<id> ...`) so re-delivery is safe.
- **Latency observability lives in the message body.** The server stamps `produced_at_ns` (host monotonic time isn't shared across containers — wall-clock `time.Now().UnixNano()` is, because all containers share the kernel). The consumer records `observed_at_ns` on write. The client reads both and reports the delta.

## Wire / API contract

Commands and subjects used by this lab:

**Redis-source (Redis Streams):**
- `XADD events * id <n> produced_at_ns <ts> payload <data>` — server appends.
- `XGROUP CREATE events bridge $ MKSTREAM` — provider creates its consumer group at start-of-stream.
- `XREADGROUP GROUP bridge provider-1 COUNT 10 BLOCK 5000 STREAMS events >` — provider reads new entries.
- `XACK events bridge <id>` — provider acks after publishing to NATS.

**NATS JetStream:**
- Stream: `EVENTS`, subject pattern `events.>`. Created on provider startup if missing.
- `NATS publish events.<id>` with a JSON body `{"id": ..., "produced_at_ns": ..., "payload": ...}` — provider publishes.
- Durable consumer: `bridge-consumer` on stream `EVENTS`. Created on consumer startup if missing. Pull-based, manual ack.
- `XACK` (NATS) after Redis-sink write.

**Redis-sink (KV):**
- `HSET event:<id> id <id> produced_at_ns <ts> observed_at_ns <ts> payload <data>` — consumer writes.
- `KEYS event:*` and `HGETALL event:<id>` — client reads (small N; `SCAN` would be needed at scale).

Primary references:
- [Redis Streams introduction](https://redis.io/docs/latest/develop/data-types/streams/)
- [NATS JetStream overview](https://docs.nats.io/nats-concepts/jetstream)
- [NATS JetStream — durable consumers](https://docs.nats.io/nats-concepts/jetstream/consumers)

## Design decisions

- **Source-side detection: Redis Streams XREADGROUP.** Durable, replayable, with per-consumer-group cursors. Keyspace notifications were rejected because they don't survive provider downtime; polling was rejected because of latency and waste; dual-write was rejected because it isn't really the requested architecture (no provider service) and creates two-phase-commit problems between Redis and NATS.
- **Sink-side shape: materialized KV** (`event:<id>` HASH). Demonstrates the CDC "read model" pattern — the client queries state, not a log. Stream-replay on the sink would have been just a stream-of-streams, less informative.
- **One consumer in the bridge group on the source side; one durable consumer on JetStream.** No load-balancing within either group. This is a propagation demo, not a scaling demo. Scaling is a separate concern that would conflate with the property.
- **Producer rate: 100 events at 100ms intervals = ~10s production phase.** Enough samples for meaningful p50/p99 without turning into a long-running benchmark.
- **Kill-restart test:** the smoke test polls Redis-sink for count ≈ N/2, then `docker compose stop consumer`, waits 3 seconds, then `docker compose start consumer`. Producer keeps running through the gap. Final assertion: all 100 events present.
- **Healthcheck pattern:** provider/consumer expose `/tmp/ready` after their respective group/durable-consumer creation succeeds, so the server's `depends_on: condition: service_healthy` blocks until the bridge is wired. This is the consumer-group race fix documented in `references/lab-layout.md`.
- **Language: Go.** Production-aligned for this user. `nats.io/nats.go` is the canonical NATS client; `go-redis/v9` is mature; uniform language across 4 microservices simplifies reading.
- **Versions pinned:** `redis:7.4-alpine`, `nats:2.10-alpine` with `-js -sd /data`, `golang:1.23-alpine` build, `alpine:3.20` runtime.

### Deliberately excluded

- **Cluster / HA for Redis or NATS** — not needed to demonstrate the propagation property; would multiply container count without changing the result.
- **TLS / auth between services** — orthogonal to the architecture's behavior; production-only concern.
- **Replay from a snapshot** — different property; the demo runs from empty state every time.
- **Multiple consumers in a durable consumer group** — load-balancing concern, not propagation.
- **A real read API in the client** (HTTP server etc.) — the client is a one-shot poller for the smoke test; an HTTP read API would be ceremony.
- **Backpressure handling under sustained load** — out of scope; throughput benchmarking was explicitly traded away.

## Comparison: hybrid vs. pure NATS JetStream vs. pure Redis Streams

The lab measures latency only for the hybrid architecture we build. The two alternatives are described qualitatively below — apples-to-apples benchmarking would require building both, which was deliberately excluded.

| Dimension | This lab (Streams → JS → KV) | Pure NATS JetStream | Pure Redis Streams |
|---|---|---|---|
| **Number of stateful systems** | 3 (2× Redis + NATS) | 1 (NATS) | 1 (Redis) |
| **Write API for app code** | Redis (familiar, transactional) | NATS publish (less familiar to web devs) | Redis `XADD` |
| **Read API for app code** | Redis KV (`GET`/`HGETALL`) | NATS subscribe (push or pull) | Redis `XRANGE`/`XREADGROUP` |
| **Durability** | Best (durable in 2 stores + NATS persistence) | High (single source of truth, JS file store) | High (single source of truth, RDB/AOF) |
| **Ordering** | Per-source-stream FIFO preserved through JS (single partition by default) | Per-subject FIFO | Per-stream FIFO |
| **Operational complexity** | Highest — three subsystems, two protocols, hand-rolled bridge | Lowest — one service, one protocol | Low — one service, one protocol |
| **Failure modes** | Many: source Redis down, sink Redis down, NATS down, bridge crashed, network partition between any pair | Few: NATS down | Few: Redis down |
| **Replay** | Replayable on source (Streams), on NATS (replay-policy), and on sink (KV is just state — stream is the log) | Single replay via JS stream | Single replay via XRANGE |
| **Fan-out to multiple consumers** | Excellent (NATS is purpose-built for this) | Excellent | Good with consumer groups, but each group lives on the same Redis |
| **Cross-region / cross-datacenter** | Good — NATS supports gateways/leaf-nodes natively | Good — same | Poor — Redis replication is async, no built-in routing |
| **Memory footprint** | High (3 daemons + bridge) | Low | Low |
| **End-to-end latency (single-host)** | Adds two extra hops (Streams→bridge→NATS, NATS→bridge→KV) vs. either pure architecture. This lab measures it on the hybrid only. | Theoretical floor; one publish, one deliver. | Theoretical floor; one `XADD`, one `XREADGROUP`. |

**When the hybrid wins:**
- You have an existing Redis app and want to expose its writes as an event stream to a NATS-native ecosystem.
- You need a materialized read model (sink Redis) separate from the write log (source Redis), and you want NATS's fan-out / cross-region semantics in the middle.
- Different teams own the write side and the read side and want operational independence.

**When the hybrid loses (and you should pick one of the pure architectures):**
- You don't have an existing constraint (legacy Redis, NATS ecosystem) that forces both — the operational overhead isn't worth it.
- Latency is critical and you can't afford two extra serialization/deserialization steps.
- You don't have a team that can run NATS *and* Redis well; pick the one your team knows.

This is the kind of architecture that ends up in real systems because of history (one team built on Redis, another on NATS) more often than because someone designed it greenfield.

## References

- [Redis Streams introduction](https://redis.io/docs/latest/develop/data-types/streams/) — primary.
- [NATS JetStream overview](https://docs.nats.io/nats-concepts/jetstream) — primary.
- [NATS JetStream consumers](https://docs.nats.io/nats-concepts/jetstream/consumers) — primary.
- [`go-redis/v9` package docs](https://pkg.go.dev/github.com/redis/go-redis/v9) — Go client.
- [`nats.go` JetStream API](https://pkg.go.dev/github.com/nats-io/nats.go/jetstream) — Go client.
