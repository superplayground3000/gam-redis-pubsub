# Research: Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Region Redis with switchable QoS and chaos drills

## Topic

A two-stage Redpanda Connect bridge that propagates KV writes from a "central" Redis to a "region" Redis through a NATS JetStream backbone, with three switchable QoS profiles (at-least-once, at-most-once, exactly-once-effective) and scripted disconnect/reconnect drills against each hop.

## Property demonstrated

Under the default `PROFILE_QOS=alo` profile, every `event_id` written to `app.events` on central Redis is present in `region-events` on region Redis within a bounded recovery window — even when `connect-sink` is killed mid-flight for ~8 seconds. Switching profiles (and re-running the same chaos drill) makes loss (AMO) and dedup (EOE) directly observable in the same `region-events` stream.

## Concept summary

- **Two Redis instances, one change feed.** The writer atomically `SET <key> <json>` + `XADD app.events ...` on central in one `MULTI/EXEC`. The stream entry carries `event_id`, `key`, `value`, `pattern`, `t_send_ms`. The dashboard's keyspace subscription observes both Redises and computes wall-clock `delta_ms`.
- **Region also has a change feed.** `connect-sink` no longer writes only the value — it fans out to `SET <key> <value>` (KV state) **and** `XADD region-events ...` (delivery ledger). The delivery ledger is what makes loss, duplicates, and dedup directly countable by `event_id`.
- **QoS is selected at compose time, not runtime.** A `PROFILE_QOS` env var (`alo`/`amo`/`eoe`) decides which YAML pair is mounted into `connect-source` and `connect-sink`. Switching profiles is `docker compose up -d --force-recreate connect-source connect-sink`.
- **Three QoS profiles, three observable shapes:**
  - **ALO** (default): full at-least-once. Forward leg uses `consumer_group: propagator` + `Nats-Msg-Id: ${! meta("event_id") }` so the JetStream 5-minute duplicate window absorbs forward-side retries. Reverse leg uses durable consumer `region-writer`, ack-explicit, `auto_replay_nacks: true`. After chaos, `region-events` may have duplicate `event_id`s but zero missing ones.
  - **AMO**: lossy by construction. Forward leg uses `auto_replay_nacks: false` on the Redis input and omits `Nats-Msg-Id`. Reverse leg uses an **ephemeral** consumer (no `durable:`) with `deliver: new` and `ack_wait: 2s` — when `connect-sink` is killed the ephemeral consumer is destroyed; on reconnect a fresh one starts from "new" and skips everything produced during the outage. After a 10 s drill at 1 Hz, `compare-streams.sh` reports ~10 missing event_ids.
  - **EOE**: ALO + an idempotency gate. Reverse leg inserts a `cache add` (`SET event:<event_id> 1 NX EX 86400`) before the fan-out. If the add errors (key exists), the message is dropped. After chaos, `region-events` has zero missing and zero duplicate `event_id`s.
- **Resilience is exercised, not narrated.** Five scripts in `scripts/chaos/` stop+restart a single service for `DOWNTIME_S` seconds: `kill-connect-source.sh`, `kill-connect-sink.sh`, `kill-nats.sh`, `kill-region-redis.sh`, and a `compare-streams.sh` audit. The smoke test runs `kill-connect-sink.sh` and asserts the no-loss property under ALO.
- **Metrics are scrapable, no Grafana required.** Connect exposes `/metrics` on `:4195`. NATS exposes `/varz`, `/jsz`, `/healthz` on `:8222`. Writer and dashboard each expose `/metrics` next to `/healthz`, surfacing `rrqr_writer_writes_total{pattern}`, `rrqr_dashboard_events_observed_total{side,pattern}`, `rrqr_propagation_delay_ms{pattern}` histogram, and `rrqr_{source,region}_stream_len`.

## Wire / API contract

**Redis Streams (central) — written by the writer:**
```
MULTI
  SET <key> <{"v":<int>,"event_id":<uuid>,"t_send_ms":<unix-ms>}>
  XADD app.events * \
    event_id <uuid> \
    key <key> \
    value <stringified-json> \
    pattern <company|functions|general> \
    t_send_ms <unix-ms>
EXEC
```
The Connect input uses `body_key: value`, so the message body becomes the JSON value string and the other four fields become metadata (`meta("event_id")`, `meta("key")`, `meta("pattern")`, `meta("t_send_ms")`).
Reference: [Redis Streams commands](https://redis.io/docs/latest/commands/?group=stream).

**JetStream stream APP_EVENTS:** `subjects: app.events.>`, `storage: file`, `replicas: 1`, `retention: limits`, `max-age: 1h`, `dupe-window: 5m`. Created by the one-shot `nats-init` container.
Reference: [JetStream streams](https://docs.nats.io/nats-concepts/jetstream/streams), [`Nats-Msg-Id` deduplication](https://docs.nats.io/using-nats/developer/develop_jetstream/model_deep_dive#message-deduplication).

**Redis Streams (region) — written by the reverse leg:**
```
XADD region-events * \
  event_id <uuid>        # equal to central's event_id
  key <key>
  value <json>
  pattern <pattern>
  t_send_ms <central-side ts>
  applied_ms <region-side ts at XADD>
```
This is the canonical delivery ledger inspected by `compare-streams.sh` and the smoke test.

**Connect — forward (ALO/EOE):**
```yaml
input.redis_streams:
  url: redis://redis-central:6379
  streams: [app.events]
  consumer_group: propagator
  body_key: value
  commit_period: 200ms
  auto_replay_nacks: true
output.nats_jetstream:
  urls: [nats://nats:4222]
  subject: app.events.${! meta("pattern") }
  headers:
    Nats-Msg-Id: ${! meta("event_id") }
```
**Connect — forward (AMO):** identical except `auto_replay_nacks: false`, `commit_period: 50ms`, and **no `Nats-Msg-Id` header**.

**Connect — reverse (ALO):** durable JetStream consumer + `broker { pattern: fan_out }` to `cache` (SET) and `redis_streams` (XADD region-events). Reverse (AMO) drops `durable`, sets `deliver: new`, `ack_wait: 2s`. Reverse (EOE) prepends a `try`-wrapped `cache add` (SET NX EX) gate on `event:<event_id>` and a follow-up mapping that `deleted()`s the message when the gate errored.
References: [`redis_streams` input](https://docs.redpanda.com/redpanda-connect/components/inputs/redis_streams/), [`nats_jetstream` input](https://docs.redpanda.com/redpanda-connect/components/inputs/nats_jetstream/), [`nats_jetstream` output](https://docs.redpanda.com/redpanda-connect/components/outputs/nats_jetstream/), [`redis` output](https://docs.redpanda.com/redpanda-connect/components/outputs/redis/), [`cache` output and `cache add` processor](https://docs.redpanda.com/redpanda-connect/components/processors/cache/).

**Dashboard wire:** `GET /` HTML, `GET /metrics` Prometheus, `GET /ws` WebSocket. Server-pushed JSON frames:
```json
{"type":"info","profile":"alo"}
{"type":"event","side":"region","key":"lb:company:employees:id:55688","value":"...","t_send_ms":1715000000000,"delta_ms":42}
{"type":"stream-lens","profile":"alo","source_len":120,"region_len":120,"now_ms":1715000010000}
```

## Design decisions

- **Versions pinned:** `redis:7.4-alpine`, `nats:2.10-alpine`, `natsio/nats-box:0.14.5`, `docker.redpanda.com/redpandadata/connect:4.45.1` (header interpolation requires ≥ 4.1.0), `golang:1.23-alpine` build / `alpine:3.20` runtime.
- **`PROFILE_QOS` mounts a YAML pair, not a runtime knob:** Connect supports env-var substitution but config-fork-per-profile is much easier to read and to diff than one config with conditionals. The compose volume mount is `./connect/${PROFILE_QOS:-alo}-{forward,reverse}.yaml`. Switching profiles requires `--force-recreate connect-source connect-sink` (no full teardown — Redis and NATS state persist across profile flips, which is the realistic operational pattern).
- **EOE dedup state lives in region Redis, not a separate store:** the same Redis the sink writes to. This keeps the lab to one cache backend and lets you inspect the gate with `redis-cli -p 16380 SCAN 0 MATCH 'event:*' COUNT 100`. The `event:<id>` keys carry `EX 86400` so they don't leak.
- **`region-events` is the property's observable:** SET alone is last-write-wins and idempotent regardless of QoS, so loss vs duplicates wouldn't surface there. The XADD-to-region-events delivery ledger is what `compare-streams.sh` and the smoke test actually count over.
- **Host ports moved to 16xxx range:** `redis-central:16379`, `redis-region:16380`, `nats:16222`+`18322`, `connect-source:16195`, `connect-sink:16196`, `dashboard:16080`, `writer:16081`. This lab can run alongside `labs/redis-multiregion-via-connect` (which uses 15xxx) for direct comparison.
- **Healthchecks on every long-running service** and `depends_on: { condition: service_healthy }` (or `service_completed_successfully` for `nats-init`). No `sleep` for cross-service ordering.
- **Chaos via `docker compose stop` + sleep + `docker compose start`** — no Toxiproxy, no kernel-level network manipulation. The lab demonstrates resilience of the *protocol stack*, not network-level partitions.
- **Deliberately excluded:**
  - **Multi-region NATS / Redis replication** — single-host single-node; the demo is QoS + resilience, not HA topology.
  - **Toxiproxy / packet-loss injection** — out of scope; the property is fully demonstrable with stop/start of one service at a time.
  - **XAUTOCLAIM supervisor for stranded PEL entries** — only matters if a Connect consumer dies permanently; the chaos drills bring it back.
  - **DLQ via `fallback` output** — adds a service and obscures the QoS contrast.
  - **Grafana / Prometheus container** — `/metrics` endpoints are exposed for scraping but no dashboards are bundled; this is a learning lab, not an SRE rig.
  - **Authentication on Redis / NATS** — private docker network.
  - **Cross-host clock skew** — single-host docker-compose; writer + dashboard share the kernel clock.

## References

- [Redis Streams commands](https://redis.io/docs/latest/commands/?group=stream) — `XADD`, `XREADGROUP`, `XACK`, `XAUTOCLAIM`.
- [Redis Keyspace Notifications](https://redis.io/docs/latest/develop/use/keyspace-notifications/) — `notify-keyspace-events KEA`.
- [Redpanda Connect `redis_streams` input](https://docs.redpanda.com/redpanda-connect/components/inputs/redis_streams/) — consumer group, `body_key`, `auto_replay_nacks`, the documented missing-entry-ID metadata caveat.
- [Redpanda Connect `nats_jetstream` input](https://docs.redpanda.com/redpanda-connect/components/inputs/nats_jetstream/) — durable consumer, `ack_wait`, `deliver`.
- [Redpanda Connect `nats_jetstream` output](https://docs.redpanda.com/redpanda-connect/components/outputs/nats_jetstream/) — `headers:` (v4.1.0+), `Nats-Msg-Id`.
- [Redpanda Connect `redis` output](https://docs.redpanda.com/redpanda-connect/components/outputs/redis/) — `command`, `args_mapping`.
- [Redpanda Connect `cache` output / `cache` processor](https://docs.redpanda.com/redpanda-connect/components/processors/cache/) — `add` operator → Redis `SET NX EX` semantics.
- [JetStream streams and deduplication](https://docs.nats.io/nats-concepts/jetstream/streams) — `Nats-Msg-Id`, `duplicate_window`, retention modes.
- Local: `../../redis-redpanda-design-ptr/research.md` — the deep production-architecture write-up that informed the lab.
- Local: `../../redis-redpanda-design-ptr/lab-requirement.md` — the original problem statement.
- Local: `../redis-multiregion-via-connect/` — the simpler baseline lab this one extends.
