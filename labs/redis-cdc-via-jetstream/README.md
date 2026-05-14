# redis-cdc-via-jetstream

## What this demonstrates

A change-data-capture (CDC) bridge that mirrors data from a "source" Redis (via Redis Streams) through a NATS JetStream broker into a "sink" Redis (as a queryable KV view). Two properties are exercised end-to-end:

1. **Propagation latency** — measured p50/p99 from server's `XADD` to key visibility on Redis-sink, over 100 events.
2. **Durability across consumer restart** — the consumer container is stopped mid-flight and restarted; the final count and contents on Redis-sink still match the server's output.

## Topology

```
                 +-----------+         +----------+         +-----------+         +---------+
  server  XADD ->| redis-    |  XREAD  | provider |  publish|   nats    | pull    |consumer | HSET   +-----------+
        ------>  | source    |-------->|          |-------->| (JetStream|------->|         |------->| redis-sink|<--- HGETALL  client
                 +-----------+         +----------+         +-----------+         +---------+        +-----------+
```

7 services: `redis-source`, `redis-sink`, `nats`, `server`, `provider`, `consumer`, `client`.

## Run it

```bash
cp .env.example .env             # only if you want to override defaults
docker compose up -d --wait
docker compose logs -f --tail=20 server provider consumer client
```

The server writes `MAX_MESSAGES` (default 100) entries to the source Redis stream at `INTERVAL_MS` (default 100ms) intervals. The provider forwards them via NATS JetStream. The consumer writes each event into the sink Redis as a HASH (`event:<id>`). The client polls the sink, records latencies, and prints stats once all events are seen.

## Expected output

Toward the end of the run, `docker compose logs client` should show something like:

```
=== LATENCY STATS ===
events_observed: 100
min_ms: 1.234
p50_ms: 3.456
p99_ms: 18.912
max_ms: 25.678
```

(Numbers vary by hardware. On a developer laptop, expect single-digit-millisecond p50 and tens-of-milliseconds p99.)

The smoke test (`scripts/smoke-test.sh`, called by `validate_lab.sh`) additionally stops and restarts the `consumer` mid-flight to verify the durability property — final count must equal `MAX_MESSAGES` despite the gap.

## Teardown

```bash
docker compose down -v
```

## Further reading

See `RESEARCH.md` in this directory for:
- The wire / API contract (Redis commands and NATS subjects used).
- Design decisions (why Streams + durable consumer + idempotent HSET, what was deliberately excluded).
- A qualitative comparison between this hybrid architecture, pure NATS JetStream, and pure Redis Streams.
