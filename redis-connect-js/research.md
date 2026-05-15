# Propagating Redis Streams to NATS JetStream with Redpanda Connect: A Complete Technical Guide

## TL;DR
- **Yes, 500 req/s is comfortably achievable** with a single Redpanda Connect instance using the `redis_streams` input → `nats_jetstream` output pipeline; the bottleneck at that rate is the JetStream `duplicate_window` index, not Redpanda Connect or Redis (a single async JetStream publisher hits ~403,828 msg/s on a MacBook Pro M4 per the official NATS bench docs).
- **Exactly-once-effective** is achieved by combining (a) Redis consumer-group at-least-once semantics (`XREADGROUP`+`XACK` driven by Redpanda Connect's transaction model), and (b) JetStream's server-side deduplication using the `Nats-Msg-Id` header with a configured `duplicate_window` — set `Nats-Msg-Id` to a stable per-event identifier injected by the producer (NOT the Redis entry ID, which Redpanda Connect's `redis_streams` input does not currently expose as metadata).
- **The single biggest gotcha** is that Redpanda Connect's `redis_streams` input does not document any metadata key for the Redis entry ID (`<ms>-<seq>`); only the entry's own field/value pairs become metadata. You must therefore have producers write a unique idempotency key as a field of the XADD payload (e.g., `event_id`) and reference that via `${! meta("event_id") }` in the `Nats-Msg-Id` header.

## Key Findings

1. **Redpanda Connect ships first-class components for both ends.** The `redis_streams` input uses `XREADGROUP` and acknowledges with `XACK` only after the output successfully delivers a batch. The `nats_jetstream` output publishes to a JetStream-backed subject and supports arbitrary headers via Bloblang interpolation. The `nats_jetstream` output was "Introduced in version 3.46.0" per the official Redpanda Connect docs.

2. **JetStream message deduplication is the right mechanism** for the "effective" part of exactly-once-effective. JetStream stores message IDs declared in a `Nats-Msg-Id` header and rejects any subsequent publish with the same ID *within* the stream's `duplicate_window`. Default window is 2 minutes; this must be tuned to cover the worst-case redelivery interval from Redis (Redpanda Connect restart + Redis PEL idle time).

3. **Redpanda Connect provides at-least-once delivery natively**; it does not need an external state store. Its in-process transaction model means a Redis message's `XACK` is sent only after the downstream JetStream `PubAck` is received. On crash, unacked Redis PEL entries are redelivered, JetStream dedups them, and the system converges to "effective exactly once."

4. **There is no explicit `msg_id` field in the `nats_jetstream` output** — the `Nats-Msg-Id` header is set through the generic `headers` map. Per the official docs: *"Explicit message headers to add to messages. This field supports interpolation functions. Requires version 4.1.0 or later."*

5. **The Redis entry ID is not exposed as input metadata.** This is the most important practical constraint and is undocumented in the official component reference (the docs only say "all other keys/value pairs are saved as metadata fields"). Producers must therefore embed a deduplication ID as a field-value pair of the stream entry, OR you must derive one deterministically from the payload (e.g., a SHA-256 of the body).

6. **500 req/s is a very modest target.** Per the NATS official benchmark documentation, a single async JetStream publisher reached *"403,828 msgs/sec ~ 49 MiB/sec ~ 2.48us"* on a MacBook Pro M4 running nats-server 2.12.1. Redis Streams XADD/XREADGROUP single-node throughput is in a similar regime. The tuning question is therefore about latency, memory headroom for the dedup index, and operational robustness — not raw throughput.

---

## Details

### Part 1 — Redis Streams: Complete Feature Reference

#### Core data structure
Redis Streams (introduced in Redis 5.0) are append-only logs of *entries*. Each entry has:
- **Entry ID** — a string `<ms>-<seq>` where `ms` is the millisecond Unix timestamp produced by Redis at insertion time, and `seq` is a 64-bit sequence counter that disambiguates entries inserted in the same millisecond. IDs are strictly monotonic.
- **Field-value payload** — an ordered list of arbitrary field/value string pairs (small dictionary).

You can let Redis generate the ID with `*`, supply an explicit full ID (`1700000000000-0`), or supply a partial ID with the timestamp portion only and let Redis pick the sequence (`1700000000000-*`, requires Redis 7+). An ID smaller than or equal to the current top ID is rejected.

#### Commands (Redis 5.0 baseline, plus 6.2 and 7.0 additions)

| Command | Purpose |
|---|---|
| `XADD key [NOMKSTREAM] [MAXLEN\|MINID [=\|~] threshold [LIMIT count]] <*\|id> field value …` | Append an entry. `NOMKSTREAM` avoids auto-creating the stream when it doesn't exist. `MAXLEN`/`MINID` trim while appending. `~` is approximate (radix-node-aligned) and is much faster than `=`. `LIMIT` caps the number of evictions per call (only allowed with `~`). |
| `XREAD [COUNT n] [BLOCK ms] STREAMS key … id …` | Non-consumer-group read; `$` means "from the last existing ID at call time." |
| `XREADGROUP GROUP grp consumer [COUNT n] [BLOCK ms] [NOACK] STREAMS key … <id\|>>` | Consumer-group read. `>` means "messages never delivered to anyone else"; a specific ID re-reads the consumer's own pending entries. `NOACK` skips PEL insertion (best-effort, not used for exactly-once-effective). |
| `XACK key group id …` | Remove an entry from the PEL — declares "processed." |
| `XCLAIM key group consumer min-idle-time id … [IDLE ms] [TIME unix-ms] [RETRYCOUNT n] [FORCE] [JUSTID] [LASTID id]` | Transfer ownership of a pending entry that's been idle ≥ `min-idle-time`. Increments the delivery counter. |
| `XAUTOCLAIM key group consumer min-idle-time start [COUNT n] [JUSTID]` (Redis 6.2+) | Combined scan-and-claim. Returns a cursor; iterate until cursor is `0-0`. Also returns IDs that no longer exist in the stream (cleaned from PEL). |
| `XPENDING key group [[IDLE ms] start end count [consumer]]` | Inspect the PEL. Summary form returns counts; extended form returns `(id, consumer, idle-ms, delivery-count)` tuples — the **delivery count is your dead-letter signal**. |
| `XRANGE key start end [COUNT n]` / `XREVRANGE key end start [COUNT n]` | Range queries; `-` and `+` are the special "min" and "max" IDs. |
| `XLEN key` | Number of entries. |
| `XDEL key id …` | Delete by ID (tombstones; PEL references are preserved unless KEEPREF/DELREF/ACKED policies are used on XADD/XTRIM in Redis 8.2+). |
| `XTRIM key <MAXLEN\|MINID> [=\|~] threshold [LIMIT count]` | Trim the stream. |
| `XGROUP CREATE key group <id\|$> [MKSTREAM] [ENTRIESREAD n]` | Create a consumer group. `$` = only new entries; `0` = the whole stream from the beginning. |
| `XGROUP SETID key group <id\|$> [ENTRIESREAD n]` | Reposition a group's "last delivered ID." |
| `XGROUP DESTROY key group` | Delete a group (drops its PEL). |
| `XGROUP CREATECONSUMER key group consumer` (6.2+) | Pre-create a consumer name. |
| `XGROUP DELCONSUMER key group consumer` | Delete a consumer. Returns the number of pending messages it had — claim them first to avoid orphans. |
| `XSETID key last-id [ENTRIESADDED n] [MAXDELETEDID id]` | Manually set the stream's last-generated ID (used in replication/migration). |
| `XINFO STREAM key [FULL]`, `XINFO GROUPS key`, `XINFO CONSUMERS key group`, `XINFO HELP` | Introspection. The `FULL` form returns the whole group/consumer/PEL graph. |

#### Consumer groups and the PEL
A consumer group is a server-side cursor over a stream plus a per-consumer **Pending Entries List (PEL)**. When a consumer reads with `XREADGROUP … >`, matched entries are moved to that consumer's PEL with a `(consumer, idle-ms, delivery-count)` tuple. `XACK` removes them. `XCLAIM`/`XAUTOCLAIM` transfer ownership and reset idle time (and increment delivery count unless `JUSTID` is given). The group also maintains a `last-delivered-id` (visible via `XINFO GROUPS`) and, since Redis 7, `entries-read` and `lag` heuristics.

Re-reading the PEL is done by passing a specific ID (e.g., `0`) instead of `>` to `XREADGROUP` — this is how a consumer recovers its own in-flight messages after a restart.

#### Special IDs
- `*` — server-assigned ID (XADD only).
- `>` — "undelivered to anyone in this group" (XREADGROUP only).
- `$` — "the current top ID at call time" (XREAD and XGROUP CREATE).
- `-`, `+` — minimum/maximum possible IDs for range queries.
- `0` / `0-0` — start of stream.

#### Trimming, capping, memory
`MAXLEN` is a length cap; `MINID` is an ID-floor cap (useful for time-based retention: drop everything older than 1 hour by using a timestamp). Approximate trimming with `~` is dramatically cheaper because Redis only removes whole radix-tree macro nodes. The `LIMIT` clause caps per-call eviction work and is only legal with `~`. Redis 8.2 added `KEEPREF` (default), `DELREF`, and `ACKED` trimming policies that control how PEL references to trimmed entries are handled.

#### Persistence and replication
Streams are first-class Redis data structures: they participate in AOF and RDB persistence and in primary/replica replication. The XADD command is replicated, as are XACK and consumer-group state mutations (via internal XSETID / XGROUP SETID). On replica promotion, a consumer group's last-delivered-id and PEL are preserved.

#### Dead-letter pattern
There is no built-in DLQ. Implement one with `XPENDING`/`XAUTOCLAIM` plus a delivery-count threshold:

```python
# Pseudocode for a supervisor loop
for entry in r.xpending_range("jobs", "grp", "-", "+", 100, idle=30000):
    if entry["times_delivered"] >= 5:
        fields = r.xrange("jobs", entry["id"], entry["id"])[0][1]
        r.xadd("jobs-dlq", fields)
        r.xack("jobs", "grp", entry["id"])
```

---

### Part 2 — Redpanda Connect Components

#### `redis_streams` input (full advanced config, current docs)

```yaml
input:
  redis_streams:
    url: redis://localhost:6379            # required
    kind: simple                            # simple | cluster | failover
    master: ""                              # used only when kind: failover
    tls: { enabled: false, ... }
    body_key: body                          # stream entry field that becomes the message body
    streams: [my_stream]                    # required; list of stream keys
    consumer_group: my_group
    client_id: rpconnect-1                  # MUST be unique per consumer instance
    create_streams: true                    # MKSTREAM
    start_from_oldest: true                 # initial offset when group is new
    commit_period: 1s                       # flush XACKs at most this often
    timeout: 1s                             # XREADGROUP BLOCK
    limit: 10                               # COUNT per XREADGROUP call
    auto_replay_nacks: true                 # nacked output → re-read from PEL forever (set false to drop on persistent nack)
```

Acknowledgement model: the input wraps each batch in an internal transaction. When all messages in the batch are confirmed by the output, the `XACK` is queued and flushed at most every `commit_period`. On crash mid-flight, unacked entries remain in the consumer's PEL and are re-delivered by the next `XREADGROUP` call started with an ID of `0` (which Redpanda Connect does on reconnect before transitioning to `>`).

**Important — metadata caveat.** The official docs state only: *"Redis stream entries are key/value pairs, as such it is necessary to specify the key that contains the body of the message. All other keys/value pairs are saved as metadata fields."* No metadata key is documented for the Redis entry ID itself. Verified on `https://docs.redpanda.com/redpanda-connect/components/inputs/redis_streams/`. **Plan your idempotency key as a producer-supplied field on the stream entry**, not as the Redis-generated ID.

#### `nats_jetstream` output (full advanced config)

Per the official docs, the output was *"Introduced in version 3.46.0."*

```yaml
output:
  nats_jetstream:
    urls: [nats://localhost:4222]           # required
    subject: events.${! meta("event_type").or("default") }  # required; interpolation supported
    headers:                                 # interpolation supported (v4.1.0+)
      Nats-Msg-Id: ${! meta("event_id") }
      Content-Type: application/json
    metadata:                                # forwards Redpanda Connect metadata as NATS headers
      include_prefixes: []
      include_patterns: []
    max_in_flight: 1024                      # parallel async publishes
    tls: { enabled: false, ... }
    auth:
      nkey_file: ""
      user_credentials_file: ""
      user_jwt: ""
      user_nkey_seed: ""
    inject_tracing_map: ""                   # optional W3C trace propagation
```

There is no separate `msg_id` field; **the deduplication key is set purely through the `headers` map** using the standard NATS header name `Nats-Msg-Id`. Per the docs the `headers` field description is: *"Explicit message headers to add to messages. This field supports interpolation functions. Requires version 4.1.0 or later."* The output uses the asynchronous JetStream publish path and waits for `PubAck` from the server before propagating the ack upstream, which is what gives the pipeline its at-least-once guarantee.

#### Buffers, batching, pipeline, error handling
- **Buffers** are optional. Use `buffer: none` (the default and the recommended setting for exactly-once-effective) — adding `memory` or `sqlite` buffers breaks at-least-once because the buffer acknowledges the input before delivery to the output.
- **Batch policies** can be specified on the input (`batching:`) and on most outputs; they aggregate messages by `count`, `byte_size`, `period`, or a Bloblang `check`.
- **Pipeline processors** (e.g. `mapping`, `bloblang`, `mutation`, `dedupe`, `branch`, `try`, `catch`, `switch`) run between input and output.
- **Error handling** is opt-in: a failed processor flags the message but does not drop it. Use `try`/`catch` blocks, or `output: switch` / `output: reject_errored` / `output: fallback` to route failures to a DLQ.

#### Metrics
Defaults to Prometheus on `:4195/metrics`. Standardised series include `input_received`, `input_latency_ns`, `input_connection_up`, `processor_received`, `processor_sent`, `processor_error`, `processor_latency_ns`, `output_sent`, `output_batch_sent`, `output_error`, `output_latency_ns`, `output_connection_up`, `output_connection_failed`, `output_connection_lost`. The Redpanda input also emits `redpanda_lag`; the `redis_streams` and `nats_jetstream` components do not emit additional series beyond the standard set, so you must combine them with `redis-cli XPENDING` and `nats consumer info` for end-to-end lag observability.

---

### Part 3 — Exactly-Once-Effective End-to-End

#### The "effective" qualifier matters
True exactly-once requires a distributed transaction across Redis and NATS, which neither system supports. What you actually achieve is:

1. **At-least-once from Redis.** A Redis stream entry stays in the consumer's PEL until `XACK`. Redpanda Connect issues `XACK` only after the JetStream `PubAck` is received. Crash anywhere before that → the entry is redelivered on restart.

2. **De-duplication on the JetStream side.** JetStream stores, for every message published with a `Nats-Msg-Id` header, that ID in a sliding-window index. Any subsequent publish with a matching ID within `duplicate_window` returns a `PubAck` with `duplicate=true` and is **not** appended to the stream. From `https://docs.nats.io/nats-concepts/jetstream/streams`: *"Streams support deduplication using a Nats-Msg-Id header and a sliding window within which to track duplicate messages."* From the JetStream model deep dive: *"The default window to track duplicates in is 2 minutes, this can be set on the command line using --dupe-window when creating a stream, though we would caution against large windows."*

3. **Net result.** Provided every redelivery from Redis happens within `duplicate_window`, every Redis entry is appended to JetStream **exactly once**.

#### Choosing the ID
Use a producer-supplied, business-meaningful key (event UUID, transaction ID, etc.). **Do not** rely on the Redis-generated entry ID — Redpanda Connect's input does not currently expose it as metadata, and using a server-generated timestamp ID makes it harder to deduplicate against retries that originated from outside the streaming pipeline.

If you cannot change producers, the next-best fallback is a content-derived hash. The pipeline below shows both options.

#### Choosing `duplicate_window`
The window must be **≥ max(Redpanda-Connect-downtime + Redis PEL idle threshold)**. JetStream maintains an in-memory index sized roughly proportional to (publish rate × window). At 500 msg/s with a 10-minute window, that's 300,000 IDs in the dedup table — trivially small. At 500 msg/s with a 24-hour window, you're at ~43 M entries, which starts to matter. Recommendation: **`duplicate_window=5m`** for typical operational MTTRs, and run Redis claim-supervisors with `min-idle-time` well below 5 minutes (e.g., 60s).

For deduplication horizons longer than is practical to keep in memory, NATS 2.9+'s `DiscardNewPerSubject` policy combined with `MaxMsgsPerSubject=1` provides infinite deduplication keyed by subject. See Jean-Noël Moyne (Synadia)'s post *"Infinite message deduplication in JetStream"* at `https://nats.io/blog/new-per-subject-discard-policy/`, which describes it as *"One feature, released in the v2.9.0 NATS server, that flew under the radar."* This is overkill for 500 req/s and is mentioned only for completeness.

---

### Part 4 — Throughput Sizing at 500 req/s

500 req/s is roughly **2 ms per message** of budget. Each leg of the pipeline:

- **Redis XREADGROUP** with `BLOCK 1s COUNT 10` running on a LAN: ~0.2–0.5 ms per batch (so ~50 batches/s of 10 messages each → 500 msg/s with ample headroom).
- **JetStream async publish**: per NATS official bench docs, a single async publisher hits *"403,828 msgs/sec ~ 49 MiB/sec ~ 2.48us"* on a MacBook Pro M4 with nats-server 2.12.1. Real-world numbers depend on payload size, replicas, and storage backend, but 500 msg/s is two-and-a-half orders of magnitude below that ceiling.
- **Redpanda Connect overhead**: sub-millisecond per message for trivial Bloblang.

**Recommended tuning for 500 req/s exactly-once-effective:**

```yaml
input:
  redis_streams:
    limit: 50              # batch up to 50 entries per XREADGROUP
    timeout: 500ms         # poll cadence
    commit_period: 200ms   # flush XACKs frequently to bound PEL growth
output:
  nats_jetstream:
    max_in_flight: 256     # plenty for 500 req/s
    # No output batching needed; JetStream publishes per-message but in parallel.
```

You do **not** need multiple Redpanda Connect instances at this throughput. If you scale horizontally for HA, multiple instances with the same `consumer_group` but different `client_id`s share the Redis stream automatically (XREADGROUP load-balances).

JetStream stream sizing for 500 msg/s:
- **Storage**: `file` (durable). Memory storage is fine for short retention but loses data on a leader change.
- **Replicas**: 3 for production (R=1 is acceptable for dev). At 500 msg/s and 1 KB messages, replication is negligible.
- **Retention**: pick `limits` with `max_age` matched to your downstream consumer SLA. `workqueue` retention is also valid if exactly one consumer drains JetStream.
- **`duplicate_window`**: 5m (see Part 3).

---

### Part 5 — Complete Working Configuration

#### 5.1 Redis source setup
```bash
redis-cli XADD app.events '*' event_id 'evt-1001' event_type 'order_created' body '{"order_id":42,"amount":99.99}'
redis-cli XGROUP CREATE app.events propagator '$' MKSTREAM
# '$' = only new entries; use '0' to backfill from the start
```

The critical detail: **`event_id` is a producer-supplied unique key**. Treat it as the idempotency contract between producer and JetStream.

#### 5.2 JetStream target setup
```bash
nats stream add APP_EVENTS \
  --subjects 'app.events.>' \
  --storage file \
  --replicas 3 \
  --retention limits \
  --discard old \
  --max-age 168h \
  --max-bytes -1 \
  --max-msgs -1 \
  --max-msg-size 1MB \
  --dupe-window 5m \
  --ack \
  --defaults

# Verify
nats stream info APP_EVENTS | grep -E 'Duplicate Window|Replicas|Storage|Retention'
# Expected: Duplicate Window: 5m0s
```

#### 5.3 Redpanda Connect pipeline

```yaml
# redis-to-jetstream.yaml
http:
  address: 0.0.0.0:4195   # health, /metrics, /ready

input:
  label: redis_source
  redis_streams:
    url: redis://redis.internal:6379
    kind: simple
    streams: [ app.events ]
    consumer_group: propagator
    client_id: ${HOSTNAME:rpconnect-1}    # unique per process; from env
    body_key: body                        # the JSON payload lives in the 'body' field
    create_streams: true
    start_from_oldest: true
    commit_period: 200ms
    timeout: 500ms
    limit: 50
    auto_replay_nacks: true               # persistent nacks → backpressure (correct for EoE)

pipeline:
  threads: 4
  processors:
    # Defensive: if the producer omitted event_id, synthesize a deterministic one.
    # This keeps deduplication useful even when the contract is violated.
    - mapping: |
        meta event_id = meta("event_id").or(content().hash("sha256").encode("hex"))
        meta event_type = meta("event_type").or("unknown")
    # Optional schema validation / transformation could go here.
    - try:
        - mapping: |
            root = this
            root.ingested_at = now()

output:
  label: jetstream_sink
  fallback:
    - nats_jetstream:
        urls: [ nats://nats-1:4222, nats://nats-2:4222, nats://nats-3:4222 ]
        subject: app.events.${! meta("event_type") }
        headers:
          Nats-Msg-Id: ${! meta("event_id") }    # JetStream-side dedup key
          Content-Type: application/json
        max_in_flight: 256
        auth:
          user_credentials_file: /run/secrets/nats.creds
    # Any message that ultimately fails to publish is routed to a DLQ stream.
    - redis_streams:
        url: redis://redis.internal:6379
        stream: app.events.dlq
        body_key: body
        max_in_flight: 16

logger:
  level: INFO
  format: json

metrics:
  prometheus:
    use_histogram_timing: true
```

Why each choice:
- `buffer:` is omitted (= `none`), preserving the at-least-once chain.
- `limit: 50` + `commit_period: 200ms` keeps the PEL well under 100 entries in steady state, bounding recovery work after a crash.
- `max_in_flight: 256` × ~5 ms publish latency ≫ 500 msg/s.
- `fallback` ensures a message that JetStream permanently rejects (e.g., subject violates stream config) ends up in a DLQ stream rather than blocking the consumer group forever.
- `event_id` is read from input metadata (provided by the producer as a field on the XADD) and is the **only** thing that makes JetStream dedup effective.

#### 5.4 Verification
```bash
# 1. Push 5 events with the same event_id; JetStream should accept exactly 1.
for i in 1 2 3 4 5; do
  redis-cli XADD app.events '*' event_id 'evt-DUP' event_type 'order_created' body '{"n":'"$i"'}'
done

# 2. Check Redis side
redis-cli XLEN app.events       # 5
redis-cli XPENDING app.events propagator  # should drain to 0 within seconds

# 3. Check JetStream side
nats stream info APP_EVENTS | grep -E 'Messages|FirstSeq|LastSeq'
# Messages: 1   (the other 4 were deduped)

# 4. Watch for duplicates rejected in real time
nats stream view APP_EVENTS --raw
nats events --all   # 'duplicate' field on PubAck
```

---

### Part 6 — Operations

#### What to monitor
| Signal | Source | Alert threshold |
|---|---|---|
| `XPENDING <stream> <group>` count | Redis `INFO`/`XPENDING` (scrape via redis_exporter) | > 10 × steady-state, sustained 5 min |
| Max idle time in PEL | `XPENDING IDLE` | > `duplicate_window` / 2 |
| Delivery count > N for any entry | `XPENDING - + 100` extended | N=5 → move to DLQ |
| Redpanda Connect `input_received` rate | Prometheus | drops to 0 for > 1 min while Redis has entries |
| `output_error` counter | Prometheus | non-zero rate |
| `output_latency_ns` p99 | Prometheus | > 100 ms |
| `output_connection_up` / `output_connection_failed` | Prometheus | any reconnect |
| JetStream stream `messages`, `consumer.num_pending`, `consumer.num_ack_pending` | `nats stream info`, `nats consumer info` | trend, not absolute |
| `/ready` endpoint on :4195 | curl | non-200 |

#### Failure modes
- **Redpanda Connect crash mid-batch.** The Redis PEL retains the entries with delivery_count incremented on the next read; JetStream dedups via `Nats-Msg-Id`. No loss, no duplicates.
- **NATS leader election.** Async publishes pending an ack are retried by the NATS client. With `max_in_flight: 256`, you may briefly see backpressure. No data loss.
- **Redis primary failover.** With AOF + replica promotion, PEL state is preserved (it's part of the stream key). Set `client_id: ${HOSTNAME}` so the new Redpanda Connect process re-attaches to its prior PEL.
- **Persistent payload rejection** (e.g., subject not in JetStream config). With `auto_replay_nacks: true`, the entry will loop forever — set `auto_replay_nacks: false` and route via `fallback` to a DLQ to break the loop.
- **`duplicate_window` elapsed** before a Redis redelivery (e.g., a 6-hour outage with a 5-minute window) → a duplicate will land in JetStream. Mitigate by widening the window OR designing downstream consumers idempotently.

#### Trimming Redis after propagation
JetStream is now authoritative. Trim Redis aggressively to bound memory:

```bash
# Time-based: keep last 1 hour
redis-cli XTRIM app.events MINID ~ $(( ($(date +%s) - 3600) * 1000 )) LIMIT 1000

# Length-based: keep last 1 M entries (approximate, fast)
redis-cli XTRIM app.events MAXLEN '~' 1000000
```

Run as a periodic cron. On Redis 8.2+ consider `XTRIM … ACKED` to drop only entries that all consumer groups have already acknowledged — safest when multiple groups read the same stream.

#### High availability
- Run **N ≥ 2** Redpanda Connect instances with the **same** `consumer_group` and **distinct** `client_id`s. Redis XREADGROUP load-balances new entries (`>`) across consumers automatically.
- Add an XAUTOCLAIM supervisor (a separate small process, or a side pipeline) that periodically re-assigns idle PEL entries to surviving consumers — Redpanda Connect's `redis_streams` input does **not** call XAUTOCLAIM itself.
- JetStream stream `replicas: 3` across 3 NATS servers gives HA on the destination.

#### Schema evolution
Apply transformations in the `pipeline.processors` block. The Bloblang `mapping` step is reusable, testable (`benthos blobl server`), and runs inside the same transaction as the publish — schema-translation errors flag the message and route it to your DLQ via `try` / `fallback`, leaving the Redis PEL intact for replay.

---

## Recommendations

**Stage 1 — Prove the pipeline.** Start with R=1 NATS (single-node JetStream), file storage, `dupe-window 5m`, one Redpanda Connect instance, `auto_replay_nacks: true`. Use producer-supplied `event_id` from day one — retrofitting idempotency is painful.

**Stage 2 — Add HA.** Move to NATS R=3, deploy two Redpanda Connect pods behind the same `consumer_group` with distinct `client_id`s, and add an XAUTOCLAIM supervisor (Python/Go sidecar that calls `XAUTOCLAIM stream group standby_consumer 60000 0-0`). Add the Prometheus alerts in the monitoring table above.

**Stage 3 — Add a DLQ.** Switch to `auto_replay_nacks: false` and `output: fallback: [nats_jetstream, redis_streams_dlq]`. Add an XPENDING-driven dead-letter mover that promotes entries with `delivery_count ≥ 5` to a `*-dlq` stream.

**Thresholds for re-architecting:**
- If sustained throughput > **20 k msg/s**, replace JetStream `duplicate_window` dedup with `DiscardNewPerSubject` + `MaxMsgsPerSubject=1` (NATS 2.9+), or move dedup into a key/value store; the in-memory dedup index becomes a memory pressure point. (Note: at the 403,828 msg/s ceiling reported in the NATS bench docs, the dedup window dominates memory long before the publisher saturates.)
- If you need **cross-window dedup** (>1 h MTTR), do the same.
- If you need true transactional exactly-once **including a downstream sink**, you'll have to introduce a 2PC-aware destination (Kafka with EOS, or a database with idempotent upserts keyed by `event_id`).

---

## Caveats

- **Redis entry ID is not exposed as input metadata** in the current `redis_streams` input. This is the most consequential implementation detail and is undocumented; the docs only say *"All other keys/value pairs are saved as metadata fields."* Always require a producer-supplied dedup key, or hash the payload as a fallback. (Verified at `https://docs.redpanda.com/redpanda-connect/components/inputs/redis_streams/`.)
- **Redpanda Connect's `redis_streams` input does not call `XAUTOCLAIM`.** A separate supervisor is needed for recovering PEL entries owned by a dead consumer. Without it, a permanently-crashed pod's PEL entries stick forever.
- **JetStream dedup is bounded by `duplicate_window`.** Outages longer than the window will produce duplicates. The window is not infinite memory-free; size it consciously.
- **JetStream `duplicate_window` semantics are *first-arrived-wins*.** There is no last-wins option (an open issue: `github.com/nats-io/jetstream#275`). If your producers can emit corrected versions of the same `event_id`, you'll lose corrections; use distinct IDs per version.
- **Async publish acks.** The `nats_jetstream` output uses async publish under the hood. In rare network-partition edge cases the JetStream client may report a publish as failed when it actually succeeded; Redpanda Connect will then redeliver and JetStream will dedup. This is the entire reason `Nats-Msg-Id` is mandatory for "effective" semantics.
- **Throughput numbers are environment-dependent.** The 500 req/s target is comfortably within single-instance capacity in all reasonable deployments — the NATS bench docs cite a single async JetStream publisher reaching 403,828 msg/s on a MacBook Pro M4. Actual per-message latency depends on payload size, network RTT, JetStream replica count, and storage backend (memory vs file). Benchmark in your environment before committing to SLAs.
- **At-most-once edge case if `auto_replay_nacks: false` and the output keeps failing**: messages will be dropped from Redis (XACK'd despite never reaching JetStream). The provided `fallback: [..., redis_streams (DLQ)]` pattern mitigates this — make sure the fallback exists.
- **Redis Streams 8.2+ added IDMP/XACKDEL/XCFGSET commands** for first-class idempotent producers. Once your Redis is on 8.2+, prefer those for producer-side dedup *in addition to* JetStream dedup. They are listed in the Redis command reference for completeness but are not required for the pipeline described here.
- **Version requirement for header interpolation.** Per the Redpanda Connect docs for the `nats_jetstream` output: *"This field supports interpolation functions. Requires version 4.1.0 or later."* The output itself was *"Introduced in version 3.46.0."* If you are running an older Redpanda Connect / Benthos build, header interpolation (and therefore the `Nats-Msg-Id` dedup pattern shown above) will not work — upgrade first.