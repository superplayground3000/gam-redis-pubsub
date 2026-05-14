# Research: Redis → Vector → NATS JetStream → Region Redis (CDC pipeline with live propagation-delay UI)

## Topic

A change-data-capture pipeline that replicates key/value updates from a central Redis to a region Redis by writing every change to a Redis Stream, relaying through Vector and NATS JetStream, and applying the resulting events on the region side. A web dashboard shows both stores side-by-side with per-key propagation delay in milliseconds.

## Property demonstrated

KV updates written to a *central* Redis appear on a *region* Redis through the path **central‑Redis → Redis Stream → Go sidecar → Vector → NATS JetStream → Go consumer → region‑Redis**, with each key's end-to-end propagation delay observable live in a browser dashboard.

## Concept summary

- **Vector's `redis` source does not support Redis Streams** (only `list` and `channel` — confirmed in the upstream `DataTypeConfig` Rust enum). Bridging Streams into Vector therefore requires a tiny sidecar that does `XREADGROUP` and posts to a Vector source that *does* exist — here, `http_server` with NDJSON.
- **Why this pipeline (not pub/sub):** Streams persist, support consumer groups + `XACK`, and survive consumer restarts via the PEL. Pub/sub silently drops messages when the bridge restarts.
- **JetStream subject convention:** one subject per key, derived from the key's pattern + id (`cdc.<pattern>.<id>`). This makes per-key subject filters cheap if/when downstream consumers care about a single entity.
- **End-to-end delay is computed inline, not estimated.** The producer stamps `produced_at_ns` into the stream entry; the region-side consumer stamps `applied_at_ns` on apply; the dashboard's SSE feed carries both so the browser computes `delay_ms` without server-side state.
- **Two Redis instances, deliberately distinct.** They share no replication channel — every byte of data on `region-redis` arrived through the pipeline, which is what makes the demo demonstrate the pipeline rather than Redis replication.

## Wire / API contract

### Central → Redis Stream (`cdc:events`)

Producer writes per key (`MULTI`/`EXEC`):

```
SET   <key> <json-value>
XADD  cdc:events * pattern <pattern> id <id> key <key> value <json-value> produced_at_ns <int64>
```

Stream entries are picked up by `relay-publish` via:

```
XREADGROUP GROUP cdc-bridge <consumer> COUNT 64 BLOCK 5000 STREAMS cdc:events >
```

then `XACK cdc:events cdc-bridge <id>` after a successful Vector ack.

### relay-publish → Vector (`POST /` on `http_server` source)

One NDJSON object per stream entry. Body example:

```json
{"pattern":"employees","id":"55688","key":"lb:company:employees:id:55688","value":"{\"counter\":42}","produced_at_ns":1715800000000000000,"redis_id":"1715800000000-0"}
```

`http_server` returns 200 only after the downstream sink has acked.

### Vector → NATS JetStream

`nats` sink with `jetstream: true`, subject templated as `cdc.{{ pattern }}.{{ id }}` (e.g. `cdc.employees.55688`), encoding `json`. Payload is the full event body above.

### relay-consume → region-redis

JetStream durable pull consumer on filter `cdc.>`. For each message:

```
SET <key> <value>
PUBLISH cdc:applied <json{pattern,id,key,produced_at_ns,applied_at_ns}>
```

`SET` is the apply; the `PUBLISH` is the signal the dashboard subscribes to for live updates.

### dashboard → browser

- `GET /api/state` → JSON snapshot: 9 keys, `{central:value, region:value, match:bool}`.
- `GET /api/events` → Server-Sent Events; each event is the JSON `{pattern,id,key,produced_at_ns,applied_at_ns,delay_ms}` from `cdc:applied`.

## Design decisions

- **Image pins.** `redis:7.4-alpine`, `nats:2.11-alpine` (JetStream stable), `timberio/vector:0.46.0-debian` (post-`jetstream` boolean support; debian variant avoids alpine glibc/dns quirks in CI), `golang:1.23-alpine` build / `alpine:3.20` runtime for every Go service.
- **Vector config uses the boolean `jetstream: true` form**, not the structured `jetstream.enabled` + `headers` block. The boolean form has been supported since Vector v0.40 (PR #20834). The headers/`Nats-Msg-Id` form is newer and version-fragile; this lab does not need broker-side dedup to demonstrate its property, and skipping it removes one cross-version trap.
- **`relay-publish` is a Go sidecar, not a Vector source.** Forced by upstream: Vector's `redis` source is list/channel-only as of v0.55.
- **`relay-consume` is a Go program, not a Vector sink.** Vector has no `redis` sink that does `SET` (only `list`/`channel`). Requirement #4 explicitly permits this fallback.
- **Producer writes both `SET` and `XADD` inside a single `MULTI`** so the stream entry can never lead or lag the KV write — eliminates a "saw the event but the key isn't there yet" race on the region read-back. Atomic per central-side write.
- **One stream key (`cdc:events`), three patterns multiplexed by field.** Simpler than three streams and keeps ordering within the producer's emission order. Per-entity ordering is preserved by the per-subject (per-key) lane on JetStream.
- **JetStream durable pull consumer**, ack on apply. `MaxDeliver` defaulted; `AckWait` 30s. Ordering per subject is enough for this demo; we do not preserve global ordering across keys.
- **`relay-publish` and `relay-consume` write `/tmp/ready` after their setup**, and the producer `depends_on` both with `condition: service_healthy`. This avoids the classic "producer XADDs before the bridge group exists, events dropped" race that the skill's lab-layout reference calls out explicitly.
- **Dashboard uses SSE, not WebSocket.** Server-Sent Events are one-way (server → browser), require no extra library, and replay cleanly through the dashboard's Go `Flusher` interface. The lab is a viewer, not a control plane.
- **No `Nats-Msg-Id` / no dedup.** Out of scope for the demo. Documented under deliberately excluded.
- **Healthchecks everywhere; `restart: "no"` everywhere.** Crashes should be visible, not papered over.

### Topology

```
+----------+   MULTI{SET, XADD}    +-------------+   XREADGROUP   +---------------+   POST /   +--------+   NATS publish   +-------------+
| producer | --------------------> | central-    | <------------- | relay-publish | ---------> | vector | ---------------> | nats        |
|  (Go)    |                       | redis :6379 |                | (Go sidecar)  | NDJSON     | (yaml) | jetstream:true   | (JS, 4222)  |
+----------+                       +-------------+                +---------------+            +--------+                  +------+------+
                                                                                                                                  |
                                                                                                                                  | durable pull
                                                                                                                                  v
+------------+                  +-------------+   SET   +-----------------+                                              +---------------+
|  browser   | <-- SSE ---- /api/events                 | relay-consume   | <----------- JetStream cdc.>  ----- ...      | region-redis  |
|            | <-- JSON --- /api/state                  | (Go consumer)   | -- SET / PUBLISH cdc:applied --------------> |  :6379        |
+------------+                  | dashboard   |         +-----------------+                                              +---------------+
                                | (Go HTTP)   |
                                +-------------+
```

### Rejected alternatives

- *Pure Vector (no sidecars).* Rejected: Vector cannot source from Redis Streams nor sink to Redis SET.
- *Pure Go (no Vector).* Rejected: requirement #2 names Vector explicitly; removing it loses the architectural lesson.
- *Three streams (one per pattern).* Rejected: extra config, no observable benefit at this scale.
- *Redis keyspace notifications instead of XADD.* Rejected: lossy on bridge restart; XSTREAM + consumer group + PEL is the durable choice.
- *WebSocket dashboard.* Rejected: SSE is sufficient and avoids the extra dependency.

### Deliberately excluded

- **`Nats-Msg-Id` deduplication.** Demonstrating effectively-once requires both the producer-side header and a sized `duplicate_window` — see `redis-vector-js-research.md` §2.3. Adds Vector-version coupling without changing the visible property.
- **JetStream R=3 replication.** Single-node R=1 is enough to see the pipeline; multi-node adds Raft mechanics that are off-topic.
- **Vector internal metrics → Prometheus.** Useful for production sizing, distracts from the property here.
- **Authentication / TLS on every hop.** Lab network only.
- **Backfill / replay from a specific stream ID.** Producer is live-only.
- **Producer back-pressure on PEL growth.** With a 1s emit interval and 9 keys, the PEL stays at ≤9.

## References

- Vector `redis` source (data_type list/channel only) — <https://vector.dev/docs/reference/configuration/sources/redis/>
- Vector `nats` sink (jetstream support) — <https://vector.dev/docs/reference/configuration/sinks/nats/>
- Vector PR #20834 (jetstream boolean) — <https://github.com/vectordotdev/vector/pull/20834>
- Vector PR #23510 (jetstream headers) — <https://github.com/vectordotdev/vector/pull/23510>
- Redis Streams commands reference — <https://redis.io/docs/latest/develop/data-types/streams/>
- `XREADGROUP` — <https://redis.io/commands/xreadgroup/>
- `XACK` — <https://redis.io/commands/xack/>
- NATS JetStream concepts — <https://docs.nats.io/nats-concepts/jetstream>
- NATS JetStream deduplication — <https://docs.nats.io/using-nats/developer/develop_jetstream/model_deep_dive#message-deduplication>
- `nats.go` JetStream client (used by relay-consume) — <https://pkg.go.dev/github.com/nats-io/nats.go/jetstream>
- `go-redis/v9` (used by producer, relays, dashboard) — <https://pkg.go.dev/github.com/redis/go-redis/v9>
- HTML5 Server-Sent Events — <https://html.spec.whatwg.org/multipage/server-sent-events.html>
- Sibling lab `labs/redis-cdc-via-jetstream/` — same family without the Vector hop and dashboard.
- Reference research bundled with this task: `redis-vector-js/redis-vector-js-research.md`.
