# Research: Redis Stream → Redpanda Connect → NATS JetStream → Redpanda Connect → Region Redis

## Topic

A two-stage Redpanda Connect bridge that propagates KV writes from a "central" Redis to a "region" Redis through a NATS JetStream backbone, using the central Redis Stream as the change-data feed and JetStream `Nats-Msg-Id` for idempotent delivery.

## Property demonstrated

For every KV write that lands in central Redis, the same key/value lands in region Redis within a bounded delay, visible per-key on a live dashboard that shows the wall-clock delta from central SET to region SET.

## Concept summary

- **Two Redis instances, one change feed.** A producer writes to central Redis atomically — `SET <key> <json>` *plus* `XADD app.events ...` in the same `MULTI/EXEC`. The stream entry carries `event_id`, `key`, `value`, `pattern`, and `t_send_ms`.
- **Redpanda Connect handles both legs.** Forward leg reads the central stream via `redis_streams` (consumer-group `propagator`) and publishes to JetStream subject `app.events.<pattern>` with a `Nats-Msg-Id` header derived from `event_id`. Reverse leg consumes that subject via `nats_jetstream` (durable consumer `region-writer`) and writes the value into region Redis via the `redis` output's `set` command.
- **Exactly-once-effective comes from two layers.** Redpanda Connect's transaction model gives at-least-once from Redis (XACK only after PubAck). JetStream's `Nats-Msg-Id` + 5-minute `duplicate_window` discards redeliveries. Net effect: each Redis entry appears in JetStream exactly once provided redelivery happens within the window.
- **Latency is measured by the dashboard, not the writer.** The dashboard `PSUBSCRIBE`s `__keyspace@0__:lb:*` on both central and region Redis; on every key event it `GET`s the value, parses `t_send_ms`, computes `delta_ms = now() - t_send_ms`, and streams the result to a browser over WebSocket. Per-pattern p50/p95 are computed in-process.
- **9 keys, 3 patterns.** `lb:company:employees:id:{55688,55689,55690}`, `lb:functions:groups:id:{89889,89890,89891}`, `lb:general:items:id:{9123,9124,9125}`. A single writer rotates through them on a configurable interval.

## Wire / API contract

**Redis Streams (central):** entries written by the producer:
```
XADD app.events * \
  event_id <uuid> \
  key <key> \
  value <stringified-json-of-value> \
  pattern <one of: company|functions|general> \
  t_send_ms <unix-ms>
```
The `body_key` for the `redis_streams` input is set to `value`, so the message body is the JSON payload; the other four fields land as metadata (`meta("event_id")`, `meta("key")`, `meta("pattern")`, `meta("t_send_ms")`).
Reference: [Redis Streams commands](https://redis.io/docs/latest/commands/?group=stream).

**NATS JetStream:** stream `APP_EVENTS`, subjects `app.events.>`, storage `file`, replicas 1, retention `limits`, `max_age=1h`, `duplicate_window=5m`. Created at startup by a one-shot `nats-init` container running `nats stream add APP_EVENTS …`.
Reference: [JetStream stream config](https://docs.nats.io/nats-concepts/jetstream/streams), [Nats-Msg-Id deduplication](https://docs.nats.io/using-nats/developer/develop_jetstream/model_deep_dive#message-deduplication).

**Redpanda Connect — forward (`connect-forward`):**
```yaml
input:
  redis_streams:
    url: redis://redis-central:6379
    streams: [app.events]
    consumer_group: propagator
    body_key: value
    limit: 50
    commit_period: 200ms
output:
  nats_jetstream:
    urls: [nats://nats:4222]
    subject: app.events.${! meta("pattern") }
    headers:
      Nats-Msg-Id: ${! meta("event_id") }
      X-Key: ${! meta("key") }
      X-T-Send-Ms: ${! meta("t_send_ms") }
    max_in_flight: 256
```
References: [`redis_streams` input](https://docs.redpanda.com/redpanda-connect/components/inputs/redis_streams/), [`nats_jetstream` output](https://docs.redpanda.com/redpanda-connect/components/outputs/nats_jetstream/).

**Redpanda Connect — reverse (`connect-reverse`):**
```yaml
input:
  nats_jetstream:
    urls: [nats://nats:4222]
    subject: app.events.>
    durable: region-writer
    deliver: all
output:
  redis:
    url: redis://redis-region:6379
    command: set
    args_mapping: 'root = [ meta("X-Key"), content().string() ]'
```
References: [`nats_jetstream` input](https://docs.redpanda.com/redpanda-connect/components/inputs/nats_jetstream/), [`redis` output](https://docs.redpanda.com/redpanda-connect/components/outputs/redis/).

**Dashboard:** plain HTTP `GET /` returns the HTML, `GET /ws` upgrades to a WebSocket. Server-pushed messages are JSON:
```json
{"type":"event","side":"region","key":"lb:company:employees:id:55688","value":"...","t_send_ms":1715000000000,"delta_ms":42}
{"type":"stats","pattern":"company","p50_ms":35,"p95_ms":82,"count":140}
```

## Design decisions

- **Topology pinned to 5 service types (7 instances):** `redis-central`, `redis-region`, `nats`, `nats-init` (one-shot), `connect-forward`, `connect-reverse`, `writer`, `dashboard`. The two Redises are identical images with different roles, as are the two Redpanda Connect containers — same image, different YAML config mounted in.
- **Versions pinned:** `redis:7.4-alpine`, `nats:2.10-alpine`, `natsio/nats-box:0.14.5`, `docker.redpanda.com/redpandadata/connect:4.45.1` (header interpolation requires ≥ 4.1.0; we pin a recent stable). `golang:1.23-alpine` for the multi-stage builds.
- **Atomic central write** via `MULTI/SET/XADD/EXEC` because the spec says "server periodically updates KV in central Redis" — the KV must be real, not derived. The stream is the change feed, written in the same transaction so observers can never see a value in central without a corresponding event in flight.
- **`Nats-Msg-Id = event_id`** because the `redis_streams` input does not expose the Redis entry ID as metadata (the docs say "all other keys/value pairs are saved as metadata fields" but say nothing about the entry ID). Producer-supplied UUID is the only reliable dedup key.
- **`duplicate_window=5m`** is generous for a lab; at the 1 msg/s default rate the dedup index is trivial. A real deployment would tune this against MTTR.
- **Dashboard observes via keyspace notifications**, not by tailing the stream or JetStream. This gives a true SET-to-SET latency measurement using a single observer's wall clock — no cross-process clock skew. Requires `CONFIG SET notify-keyspace-events KEA` on both Redises at startup (done in dashboard init).
- **Host ports ≥ 15000:** `redis-central:15379`, `redis-region:15380`, `nats:15222` (client) + `18222` (monitoring), `connect-forward:15195`, `connect-reverse:15196`, `dashboard:15080`.
- **Healthchecks** on every long-running service: `redis-cli ping` for the Redises, `wget --spider http://localhost:8222/healthz` for NATS, `wget --spider http://localhost:4195/ready` for Connect, HTTP GET on `/healthz` for writer and dashboard. `nats-init` is `restart: "no"` and exits 0 after stream creation. Downstreams wait via `depends_on: { condition: service_healthy }` (or `service_completed_successfully` for `nats-init`).
- **Deliberately excluded:**
  - **Multi-instance HA + XAUTOCLAIM supervisor** — the demo is single-region pipeline correctness, not fault tolerance.
  - **NATS replicas=3** — single-node JetStream is enough for a propagation demo.
  - **DLQ via `fallback` output** — would obscure the latency property; not needed for the happy path.
  - **Duplicate-burst dedup demo** — `Nats-Msg-Id` is wired in, but the dashboard does not have a "fire 5 dups" button. The property under test is propagation delay, not idempotency.
  - **Authentication on Redis / NATS** — lab is on a private Docker network.
  - **Cross-host clock sync** — single-host docker-compose; `t_send_ms` and `now()` come from the same kernel clock for the dashboard's purposes (writer and dashboard run on the same Docker host).

## References

- [Redis Streams commands](https://redis.io/docs/latest/commands/?group=stream) — `XADD`, `XREADGROUP`, `XACK`, keyspace notifications.
- [Redis Keyspace Notifications](https://redis.io/docs/latest/develop/use/keyspace-notifications/) — `notify-keyspace-events KEA`, `__keyspace@<db>__:<key>` pattern.
- [Redpanda Connect `redis_streams` input](https://docs.redpanda.com/redpanda-connect/components/inputs/redis_streams/) — consumer group semantics, `body_key`, metadata caveat.
- [Redpanda Connect `nats_jetstream` output](https://docs.redpanda.com/redpanda-connect/components/outputs/nats_jetstream/) — header interpolation (v4.1.0+), `max_in_flight`.
- [Redpanda Connect `nats_jetstream` input](https://docs.redpanda.com/redpanda-connect/components/inputs/nats_jetstream/) — durable consumer, deliver policy.
- [Redpanda Connect `redis` output](https://docs.redpanda.com/redpanda-connect/components/outputs/redis/) — `command: set`, `args_mapping` Bloblang.
- [JetStream streams and deduplication](https://docs.nats.io/nats-concepts/jetstream/streams) — `Nats-Msg-Id`, `duplicate_window`, retention.
- Local reference: `redis-connect-js/research.md` — full technical deep-dive that informed this design.
- Local reference: `redis-connect-js/lab-requirement.md` — original problem statement.
