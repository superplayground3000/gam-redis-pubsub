# Propagating Redis Streams to NATS JetStream with Vector — A Production Reference

## TL;DR
- **Vector's `redis` source does not support Redis Streams** as of v0.55 (May 2026); its `data_type` enum is documented verbatim as *"The Redis data type (list or channel) to use."* To bridge Redis Streams to NATS JetStream with Vector in the pipeline, you must run a small `XREADGROUP`→stdin/HTTP sidecar (or use `exec` calling `redis-cli`) and feed the events into Vector, then publish to JetStream via Vector's `nats` sink with `jetstream.enabled = true` and `jetstream.headers.message_id = "{{ redis_id }}"`.
- **Effectively-once delivery** is achievable end-to-end: use a Redis consumer group with `XREADGROUP > / XACK`, propagate the Redis stream entry ID (`<ms>-<seq>`) into the `Nats-Msg-Id` header, and size the JetStream `duplicate_window` to cover your worst-case retry horizon. Only `XACK` Redis after the JetStream `PubAck` returns success — never before.
- **If you are not married to Vector**, Redpanda Connect (formerly Benthos) has a native `redis_streams` input with `XREADGROUP`/`XACK` semantics and a `nats_jetstream` output with `Nats-Msg-Id` support; for this specific pipeline it is the lower-friction choice. Use Vector if Redis Streams is one input among many in a broader observability fabric you already operate.

---

## Key Findings

1. **Vector status (verified May 2026):** The `redis` source's `data_type` field is documented as *"The Redis data type (list or channel) to use."* and the underlying Rust enum is `pub enum DataTypeConfig { List, Channel }`. Issues #3319, #5696, and #5697 originally requested stream support but were closed when PR #7096/#7078 shipped list+channel only. No merged or in-flight PR adds `data_type = "stream"`.
2. **Vector's NATS sink IS JetStream-aware.** PR #20834 ("feat(new sink): Add possibility to use nats jetstream in nats sink" by whatcouldbepizza, July 2024) added the boolean `jetstream: true`, and PR #23510 (merged by pront via auto-merge on Aug 6, 2025) — *"This PR adds support in the nats sink for JetStream message headers. It introduces a configurable, templated Nats-Msg-Id header that ensures a unique ID for each message."* — extended it to a structured block accepting templated headers including the dedup-critical `message_id` → `Nats-Msg-Id`.
3. **The cleanest architecture** is a stateless `XREADGROUP` relay (Go ~80 LoC) per Redis stream that emits NDJSON to Vector's `http_server`/`socket`/`stdin` source, gets `acknowledgements: true` end-to-end, and only `XACK`s after Vector hands off to JetStream successfully.
4. **Ordering is per-stream and per-subject.** Redis Streams give total order per key; JetStream gives total order per subject. Vector batching with `request.concurrency > 1` can reorder; set `request.concurrency = 1` on the `nats` sink and have a single relay-per-stream to preserve order.
5. **Throughput envelope:** XADD ~136K ops/s on a single Redis core (Arm Learning Paths benchmark on Azure Cobalt 100 Arm64: *"XADD operations reach ~136K ops/sec, making Redis Streams suitable for high-ingestion event pipelines."*); Redis 8.6 hits *"3.5M ops/sec with pipeline size 16 on a single node using only 16 cores of an m8g.24xlarge instance (ARM, Graviton4), 11 io-threads, 2000 clients, 1:10 SET:GET caching workload"*; JetStream file storage typically 50–200K msgs/s under R=3; Vector itself sustains hundreds of MB/s with disk buffers and is rarely the bottleneck for this pipeline.

---

## Details

### Part 1 — Redis Streams Feature Reference

#### 1.1 Data model and how it differs from Pub/Sub and Lists
A Redis Stream is an append-only log keyed by `<ms-time>-<sequence>` IDs, stored as a radix tree (`rax`) of listpack macro-nodes. Each entry is an ordered set of field-value pairs (a small dictionary). Key properties:

- **Vs. Pub/Sub:** Pub/Sub is fire-and-forget — if no subscriber is connected when the message is published, it is gone. Streams persist messages until trimmed or explicitly deleted; multiple consumers can replay history; consumer groups give competing-consumer semantics with explicit ack.
- **Vs. Lists:** Lists are LIFO/FIFO with destructive `LPOP/RPOP`. Streams are non-destructive: a read does not remove the entry. Streams support range queries, multiple independent consumer groups, and per-consumer pending tracking.

Per Redis docs: *"Each message is a set of field-value pairs identified by a unique, time-ordered ID. The default ID format is `<milliseconds>-<sequence>`, which Redis generates automatically when you use `*` as the ID."*

#### 1.2 XADD — appending
```
XADD key [NOMKSTREAM]
         [<MAXLEN | MINID> [= | ~] threshold [LIMIT count]]
         <* | id> field value [field value ...]
```
- `*` auto-generates a monotonically increasing ID; an explicit ID must be > the current top ID or the call fails with `ERR The ID specified in XADD is equal or smaller than the target stream top item`.
- `NOMKSTREAM`: skip creating the key if it does not exist (returns nil); useful for "send only if the consumer pipeline is bootstrapped".
- `MAXLEN`/`MINID` trim atomically with the insert. Use the `~` (approximate) flag in production — exact trimming forces Redis to walk past the threshold within a macro-node, while `~` only drops whole listpack macro-nodes, which is *"much more efficient, and it is usually what you want, although after trimming, the stream may have a few tens of additional entries over the threshold."*
- `LIMIT count` caps the number of entries the trim will evict per call (only valid with `~`). Use this to bound XADD tail latency.
- **Redis 8.2+** adds `KEEPREF | DELREF | ACKED` controlling how trims interact with consumer groups' PELs: `KEEPREF` (default) leaves PEL references intact even when entries are trimmed; `ACKED` only trims entries already acked by all groups (the safest for at-least-once pipelines).
- **Redis 8.6+** adds idempotent production: `IDMPAUTO producer-id` or `IDMP producer-id idempotent-id` lets Redis itself detect duplicate XADDs from the same producer ID.

#### 1.3 XREAD — non-grouped reads
```
XREAD [COUNT n] [BLOCK ms] STREAMS key [key ...] id [id ...]
```
- `$` = "from now on" (only entries arriving after the call). Specific ID = entries strictly greater than that ID.
- `BLOCK 0` blocks indefinitely; `BLOCK ms` is a max wait. The timeout is milliseconds and became a `double` in Redis 6.0 — pre-6.0 servers require an integer (see vectordotdev/vector#22061).
- `XREAD` is read-only and works on replicas; it does **not** maintain server-side cursor state.

#### 1.4 XRANGE / XREVRANGE
```
XRANGE key start end [COUNT n]
XREVRANGE key end start [COUNT n]
```
- `-`/`+` denote min/max IDs. Exclusive ranges use `(id`. Useful for windowed replay, audit, or reading a specific PEL ID set.

#### 1.5 XLEN / XINFO
- `XLEN key` — O(1) total entry count (excludes tombstoned XDEL entries).
- `XINFO STREAM key [FULL]` — returns length, `radix-tree-keys`, `radix-tree-nodes`, `last-generated-id`, first/last entries, and (with `FULL`) all groups, consumers, and the PEL.
- `XINFO GROUPS key`, `XINFO CONSUMERS key group` — per-group / per-consumer state including `pending`, `idle`, `last-delivered-id`.

#### 1.6 Consumer groups in depth

**Creation:**
```
XGROUP CREATE key group <id | $> [MKSTREAM] [ENTRIESREAD n]
XGROUP CREATECONSUMER key group consumer
XGROUP DELCONSUMER  key group consumer
XGROUP DESTROY      key group
XGROUP SETID        key group <id | $> [ENTRIESREAD n]
```
- `$` = "deliver only entries arriving after creation". Use `0` to replay the whole stream.
- `MKSTREAM` creates an empty stream if the key does not exist (the standard idempotent bootstrap idiom).

**Read with group:**
```
XREADGROUP GROUP group consumer [COUNT n] [BLOCK ms] [NOACK]
           STREAMS key [key ...] <> | id> [id ...]
```
- `>` = "deliver new messages never previously delivered to any consumer of this group" — and adds them to that consumer's PEL.
- A specific ID (e.g. `0`) = "give me back my own pending history from that ID onward" — this is the **recovery read** every consumer must do on restart to drain its PEL before switching to `>`.
- `NOACK` = "skip adding to PEL" — equivalent to immediate ack, suitable only when occasional message loss is acceptable.
- Redis 8.4+ adds `CLAIM min-idle-time` to fold XAUTOCLAIM into XREADGROUP for multi-stream consumers.

**Ack:** `XACK key group id [id ...]` — *"The XACK command will immediately remove the pending entry from the Pending Entries List (PEL) since once a message is successfully processed, there is no longer need for the consumer group to track it and to remember the current owner of the message."*

**PEL inspection — XPENDING:**
- Summary form: `XPENDING key group` returns `(count, min-id, max-id, [(consumer, count), ...])`.
- Extended form: `XPENDING key group [IDLE min-idle-time] start end count [consumer]` returns per-entry `(id, consumer, milliseconds-idle, deliveries)`. The deliveries counter increments on every XCLAIM/XAUTOCLAIM and on every re-read by the owning consumer.

**Claim / autoclaim:**
```
XCLAIM key group consumer min-idle-time id [id ...]
       [IDLE ms] [TIME unix-ms] [RETRYCOUNT n] [FORCE] [JUSTID]
XAUTOCLAIM key group consumer min-idle-time start [COUNT n] [JUSTID]
```
- `min-idle-time` is a guard: the claim only succeeds if the message has sat idle in the PEL at least that long, preventing two consumers from racing on the same entry.
- `FORCE` re-creates the PEL entry even if it has been removed (e.g., trimmed); the entry must still exist in the stream.
- `JUSTID` returns only IDs (and does not increment the deliveries counter on XCLAIM), useful for cheap "transfer ownership" without re-shipping payloads.
- `XAUTOCLAIM` is SCAN-like: it returns a cursor (next start ID) plus claimed messages. Its scan envelope is `COUNT × 10` PEL entries per call (hard-coded in the server).

**At-least-once recovery loop pattern:**
```python
def consume():
    # Phase 1: drain my own PEL on restart
    while True:
        msgs = r.xreadgroup('grp','worker-1', {'stream': '0'}, count=100)
        if not msgs or not msgs[0][1]: break
        process_and_ack(msgs)
    # Phase 2: live tail
    while True:
        msgs = r.xreadgroup('grp','worker-1', {'stream': '>'},
                            block=5000, count=100)
        process_and_ack(msgs)
```
And a janitor coroutine running XAUTOCLAIM on a fixed min-idle (typically 1.5× expected processing time) for the dead-consumer case.

#### 1.7 Trimming, XDEL, XSETID
- `XTRIM key MAXLEN | MINID [=|~] threshold [LIMIT count]` — same semantics as XADD's trim suffix.
- `XDEL key id [id ...]` — marks entries deleted in their listpack but **does not free memory** until the whole macro-node is empty, and **does not remove the entry from any PEL**. Heavy XDEL causes "Swiss cheese" fragmentation; in 8.2+ use `XDELEX` / `XACKDEL` with `DELREF` to also purge PEL refs.
- `XSETID key id [ENTRIESADDED n] [MAXDELETEDID id]` — forces the stream's last-generated ID; used internally for replication and for migration scenarios where you need a downstream copy to keep ID alignment.

#### 1.8 Memory and performance
A stream is `stream { rax *rax; rax *cgroups; streamID last_id; }` per the Redis source. Stream IDs live as 128-bit big-endian keys in the radix tree, which compresses common time prefixes. Entries are packed into listpack macro-nodes whose size is bounded by:
- `stream-node-max-bytes` (default **4096** bytes)
- `stream-node-max-entries` (default **100**)

When either is exceeded, a new macro-node is allocated and linked in the rax. Tuning these upward (e.g. 8 KiB / 200 entries) improves memory density and write throughput at the cost of slower entry-level seek within a node. PEL entries are ~64 bytes each (`mstime_t delivery_time + uint64 delivery_count + streamConsumer* + rax overhead`).

Published numbers to anchor sizing:
- Arm Learning Paths benchmark on Azure Cobalt 100 Arm64: *"XADD operations reach ~136K ops/sec, making Redis Streams suitable for high-ingestion event pipelines."*
- Redis 8.6 launch blog (Feb 10, 2026): *"With pipeline size set to 16, Redis 8.6 reaches 3.5M ops/sec"* (mixed 1:10 SET:GET, 16 cores of m8g.24xlarge Graviton4, 11 io-threads, 2000 clients).
- DigitalOcean / standard `redis-benchmark`: SET ~88K req/s without pipelining, ~400K req/s with `-P 16` on a MacBook Air 11" — illustrating that pipelining is the single biggest production lever.

#### 1.9 Persistence and replication
- **AOF** logs every XADD/XACK/XCLAIM/XGROUP command; the default fsync-every-second policy bounds loss to ~1s of stream activity.
- **RDB** snapshots include the full stream including all consumer groups and their PEL.
- **Replication:** Streams replicate asynchronously to replicas; **and crucially the entire consumer group state (PEL, last-delivered-id, consumers) is replicated** — so after failover, consumers resume against the new primary without losing PEL ownership information. This is unique among Redis data structures.
- **Cluster:** Each stream lives on a single shard (a single key). To consume across shards in a Redis Cluster, your consumer must hold connections to each shard's primary. XREADGROUP can fan across keys only when those keys live in the same hash slot (so co-locate via `{tag}` hash tags if you need cross-stream blocking reads).

---

### Part 2 — NATS JetStream (publisher-side concepts)

#### 2.1 Streams capture subjects
A JetStream **stream** is a persistent store that captures messages published to a configured set of NATS subjects (wildcards: `*` for one token, `>` for the tail). Publishers don't address the stream directly — they publish to a subject, and the JetStream server stores it if the subject matches.

Recommended subject design for this pipeline:
```
redis.<env>.<stream_name>.<event_type>
```
e.g. `redis.prod.orders.created`. This lets downstream consumers use `redis.prod.orders.*` or `redis.prod.>` filters cheaply and keeps a clean cardinality story.

#### 2.2 Stream configuration knobs (from `docs.nats.io/nats-concepts/jetstream/streams`)
| Field | Notes |
| --- | --- |
| `storage` | `file` (durable, recommended) or `memory` (volatile, faster) |
| `retention` | `limits` (default), `interest`, `workqueue` |
| `discard` | `old` (default, drop oldest on limit) or `new` (reject new on limit); `DiscardNewPerSubject` for per-subject rejection |
| `max_msgs`, `max_bytes`, `max_age`, `max_msg_size`, `max_msgs_per_subject` | Hard limits enforced via `discard` policy |
| `num_replicas` | 1, 3, or 5; R=3 is the recommended file-based production default |
| `duplicate_window` | Window during which `Nats-Msg-Id` headers are tracked for dedup (default 2 minutes) |
| `subjects` | Subject patterns the stream captures (e.g. `["redis.>"]`) |
| `no_ack` | If true, publisher does not get a stored-ack reply; default false |

Retention semantics (per docs):
- `limits`: keep until a hard limit is breached.
- `interest`: keep only while at least one consumer that has interest in the subject hasn't acked the message.
- `workqueue`: a message is removed on first successful consumer ack; *"this retention policy supports a set of consumers that have non-overlapping interest on subjects"* (consumers cannot have overlapping subject filters).

For the Redis-Streams-relay use case, **`retention: limits` with R=3, `storage: file`, `discard: old`, `max_age: 24h` (or your replay window), and `duplicate_window: 15m`** is the right starting point.

#### 2.3 Deduplication and "exactly-once" publish
JetStream tracks `Nats-Msg-Id` headers within `duplicate_window`. Per NATS docs: *"Streams support deduplication using a Nats-Msg-Id header and a sliding window within which to track duplicate messages."* The standard at-least-once becomes "effectively exactly-once for publishers" by:
1. Setting `Nats-Msg-Id` to a stable, content-derived ID (here: the Redis stream entry ID, `<ms>-<seq>`, which is globally unique within a stream).
2. Sizing `duplicate_window` ≥ the worst case time between original publish and a retry. Two minutes is fine for in-process retries; size up if your relay can be restarted hours later (e.g. 24h if you may replay a long PEL backlog).
3. Using JetStream-acked publish (the publisher's `PublishAsync` / `Publish` call waits for `PubAck`).

The trade-off NATS docs explicitly call out: *"we would caution against large windows"* — the dedup map grows with throughput × window. At 10K msg/s with a 15-minute window you are tracking 9M IDs, which costs memory on every replica.

#### 2.4 Replication and storage
- File storage with R=3 is the typical production posture; per NATS docs *"Replicas=3 - Can tolerate the loss of one server servicing the stream. An ideal balance between risk and performance."* R=5 only when you can lose two nodes simultaneously without violating consistency.
- File writes flush to the OS synchronously, with fsync controlled by `sync_interval` (default **2 minutes**). Tune down for stricter durability vs. lower throughput.
- Quorum is RAFT-based and *"the formal consistency model of NATS JetStream is Linearizable"* for writes within a stream.

#### 2.5 Throughput envelope
NATS docs' own `nats bench js pub` example reports *"NATS JetStream asynchronous publisher stats: 403,828 msgs/sec ~ 49 MiB/sec ~ 2.48us"* (128-byte messages, file storage, replicas=1, async, batch=500, on an Apple M4 MacBook Pro running nats-server 2.12.1, loopback). On real hardware with file storage R=3 over a real network and small messages, expect 50–200K msgs/s per stream; large messages (>4 KiB) become bandwidth-bound. A real-world user-reported number on cloud VMs (8c Intel Xeon, NVMe SSD, virtio_net) was ~134K msgs/sec for the same 128-byte async benchmark. Per-message overhead on disk is `length(4) + seq(8) + ts(8) + subj_len(2) + subj + hdr_len(4) + hdr + msg + hash(8)` — so a 5-byte payload with a 30-byte `Nats-Msg-Id` header costs ~75 bytes on disk.

#### 2.6 Headers
NATS messages support arbitrary headers (NATS protocol 2.0+). Reserved headers relevant here:
- `Nats-Msg-Id` — dedup ID (window-scoped)
- `Nats-Expected-Stream` — publish only if stream name matches
- `Nats-Expected-Last-Sequence` — optimistic concurrency control
- `Nats-Expected-Last-Msg-Id` — optimistic concurrency control on the previous Msg-Id

---

### Part 3 — Vector

#### 3.1 Architecture in 10 seconds
Vector is a Rust dataflow engine. A topology is **sources → transforms → sinks** wired by named `inputs`. Events flow through a typed pipeline (`log`/`metric`/`trace`). Every component has a bounded in-memory buffer between it and the next; sinks additionally support a disk buffer for durability. End-to-end acknowledgements propagate from sinks back to sources, so an "ack-aware" source (Kafka, S3, Datadog Agent, etc.) only acks upstream once the sink has confirmed delivery.

#### 3.2 The Vector `redis` source — **does NOT support Streams**
**Confirmed status as of Vector v0.55 (May 2026):** the `data_type` field is documented as *"The Redis data type (list or channel) to use."*. The Rust enum is:
```rust
#[serde(rename_all = "lowercase")]
pub enum DataTypeConfig { List, Channel }
```
History (issues #3319, #5696, #5697; PRs #7096, #7078) shows the original umbrella request explicitly included `stream` ("list、channel、pattern channel、stream"), but only `list` and `channel` shipped, and no follow-up PR adds the stream variant.

Minimal working `list` config (which is *not* what we want, but for context):
```yaml
sources:
  rlist:
    type: redis
    url: redis://127.0.0.1:6379/0
    key: vector
    data_type: list
    list:
      method: lpop
    redis_key: redis_key   # field on the event capturing the key
```

`list.method` accepts `lpop` or `rpop` (and historically `brpop` for blocking; this had a server-side bug pre-Redis 6 with float timeouts — see #22061). Note this is destructive — the Redis `list` is consumed.

**Workarounds — ranked.**

**Workaround A (recommended): tiny sidecar relay.** Run a small Go/Python program per Redis stream that performs `XREADGROUP > COUNT n BLOCK 5000`, emits NDJSON to stdout (or POSTs to Vector's `http_server` source), and only `XACK`s after the line has flushed (or after the 200 response). Vector ingests via `stdin`/`socket`/`http_server` (which support end-to-end acks) and sinks to NATS. This gives you full PEL semantics and clean back-pressure.

**Workaround B (quick & dirty): `exec` source running `redis-cli XREAD`.** Works for one-direction "tail" of a stream without consumer groups, but loses pending tracking, can't `XACK`, and has no native back-pressure into Redis. Acceptable only for fire-and-forget telemetry replication.

**Workaround C: dual write to Redis + Kafka, use Vector's `kafka` source.** Reasonable if you already operate Kafka and want consumer-group resilience. Adds infrastructure.

**Workaround D: use Redpanda Connect (Benthos) instead of Vector for this leg.** Native `redis_streams` input does exactly XREADGROUP+XACK; native NATS JetStream output supports `Nats-Msg-Id`. Trade: one more binary in your fleet, but ~zero glue code.

#### 3.3 The Vector `nats` sink (with JetStream support)
PR #20834 ("feat(new sink): Add possibility to use nats jetstream in nats sink" by whatcouldbepizza, July 2024) added basic `jetstream: true`; PR #23510 (merged via auto-merge on Aug 6, 2025) extended it to a structured block — *"This PR adds support in the nats sink for JetStream message headers. It introduces a configurable, templated Nats-Msg-Id header that ensures a unique ID for each message. This enables broker-level deduplication, resulting in stronger delivery guarantees and exactly-once semantics when combined with idempotent consumers."*

Documented shape (verbatim from the v0.50+ docs):

> `jetstream` (optional object) — *"Send messages using Jetstream. If set, the subject must belong to an existing JetStream stream."*
> `jetstream.enabled` (bool, default false) — *"Whether to enable Jetstream."*
> `jetstream.headers` — *"A map of NATS headers to be included in each message."*
> `jetstream.headers.message_id` — *"A unique identifier for the message. Useful for deduplication. Can be a template that references fields in the event, e.g., `{{ event_id }}`."*

Canonical example:
```yaml
sinks:
  my_jetstream_sink:
    type: nats
    inputs: ["my_source"]
    url: "nats://localhost:4222"
    subject: "redis.prod.{{ stream }}.{{ event_type }}"
    jetstream:
      enabled: true
      headers:
        message_id: "{{ redis_id }}"
    encoding:
      codec: json
    auth:
      strategy: credentials_file
      credentials_file:
        path: /etc/nats/relay.creds
    healthcheck:
      enabled: true
    acknowledgements:
      enabled: true
    buffer:
      type: disk
      max_size: 5368709120   # 5 GiB
      when_full: block
```

Authentication strategies on the sink: `user_password`, `token`, `nkey` (with `nkey` + `seed`), `credentials_file` (path to NATS `.creds` JWT bundle). TLS is configured via `tls.*` (`ca_file`, `crt_file`, `key_file`, `alpn_protocols`).

Templating: `subject` and `headers.*` honor Vector's template syntax (`{{ field_name }}`). Use it to route per-event to subject hierarchies.

Encoding: `json` is the right default for cross-system event payloads. `text` only carries the `message` field; `native_json` carries the full Vector event including metadata.

Batching & request tuning (inherited from the standard sink wrapper):
- `batch.max_bytes`, `batch.max_events`, `batch.timeout_secs`
- `request.concurrency` (adaptive, integer, or `none`), `request.rate_limit_num`, `request.timeout_secs`, `request.retry_attempts`, retry backoff (Fibonacci)
- **For ordering preservation set `request.concurrency = 1`** so events are published serially per sink instance.

#### 3.4 Data model and transforms
Events are dynamic structures. The `remap` transform (VRL) is the workhorse:
```yaml
transforms:
  parse:
    type: remap
    inputs: ["redis_relay"]
    source: |
      .stream = .stream || "unknown"
      .event_type = .data.type || "generic"
      .redis_id = .id
      del(.host)
```
`filter` drops events by VRL predicate; `route` fans into multiple outputs by predicate; `throttle` rate-limits. None are required here, but `remap` is essential for projecting Redis fields into NATS subject tokens.

#### 3.5 End-to-end acks and buffers
End-to-end acknowledgements (per the Vector docs): *"When end-to-end acknowledgements are enabled, the source will wait to 'ack' the data until it has been persisted to a disk buffer or has been sent by the sink to the downstream target."* Critical wording — **a disk buffer between source and sink counts as "ack'd at source"**, which is fine for survival of Vector restarts but breaks strict end-to-end-to-NATS semantics if the disk buffer is between source and the NATS sink. For our pipeline, **omit the disk buffer between source and `nats` sink** (or accept the durability semantics: events on disk are durable through Vector restarts but not yet in NATS).

Set:
```yaml
acknowledgements:
  enabled: true   # global
```
and on the source side run a relay that only XACKs Redis on a successful ack from Vector.

#### 3.6 Observability
- `--api` on, then `vector top` for a TUI view of throughput/buffer fill per component (note: moved to gRPC in v0.55 — any external tooling that talked to `/graphql` needs to be updated per the v0.55 upgrade guide).
- `internal_metrics` source → Prometheus exporter sink for `component_received_events_total`, `component_sent_events_total`, `component_errors_total`, `buffer_events`, `buffer_byte_size`, `component_latency_seconds` (new histogram in v0.54+), `source_send_latency_seconds`, `source_send_batch_latency_seconds` (new in v0.55).
- `vector validate` to dry-run config; `vector tap` to inspect events in flight.

---

### Part 4 — End-to-end production architecture

#### 4.1 Topology
```
+----------+   XADD   +-------+       +---------------------+      +--------+   PubAck   +-------------+
| Producer | -------> | Redis | <---- | XREADGROUP relay    | ---> | Vector | --------> | NATS JS R=3 |
| services |          | primary|      | (sidecar, 1 per     | NDJSON|        | jet-      | file storage|
+----------+          +-------+       | stream/consumer)    | tcp/  | nats   | stream    +-------------+
                          |           |  XACK on Vector ack |  http | sink   |
                          v           +---------------------+       +--------+
                       replica                                                              consumers
                       (PEL replicated)                                                     (pull/push)
```

Each relay handles one Redis stream key with one consumer-group consumer name (typically `pod-<hostname>-<N>`). Run N relays per stream for horizontal scale; PEL ownership is per consumer, so XAUTOCLAIM redistributes after failure.

#### 4.2 Delivery-semantics analysis

| Failure mode | What protects you | Result |
| --- | --- | --- |
| Producer dies mid-XADD | Producer's own retry logic; Redis 8.6 `IDMP` for stream-level idempotency | At-least-once into Redis |
| Redis primary fails | Replication of stream + PEL state; Sentinel/Cluster failover | Pending consumers resume with their PEL intact; possible duplicate read of in-flight entries |
| Relay crashes between XREADGROUP and Vector handoff | Entry remains in PEL; on restart relay re-reads with `id=0` first | Re-published; deduped by `Nats-Msg-Id` |
| Relay crashes after publish but before XACK | Entry remains in PEL; re-published on restart | Re-published; deduped by `Nats-Msg-Id` (within `duplicate_window`) |
| Vector crashes mid-batch | With `acknowledgements: enabled` and no disk buffer, source has not been acked, so relay has not XACKed | Re-published on restart; deduped |
| NATS server unavailable | Vector retries with Fibonacci backoff; back-pressure to relay; relay blocks on Vector's input | Buffered until restored; PEL grows in Redis |
| Long NATS outage past `duplicate_window` | Dedup window expired before retry | **Duplicate possible** — size `duplicate_window` ≥ worst tolerated NATS outage |

**Why true exactly-once is impossible:** the Two Generals problem applies to the relay↔NATS PubAck. The relay can publish-then-ack, with a window where the publish succeeded on the server but the PubAck was lost in transit. The relay will retry, and only the dedup window saves you. "Effectively-once" means *the system behaves as if exactly-once when the duplicate window is sized to cover all retry latencies you tolerate*.

**Ordering:** Redis Streams guarantee total order per stream key. JetStream guarantees total order per subject. To preserve order end-to-end:
- One relay per stream key (or use XREADGROUP with a single consumer name so processing is serial).
- `request.concurrency: 1` on the NATS sink.
- Subject template must include enough granularity that ordering matters within each subject only (which it always does for a single Redis stream → single subject mapping).

#### 4.3 JetStream stream definition (production starting point)
```bash
nats stream add REDIS_EVENTS \
  --subjects 'redis.prod.>' \
  --storage file \
  --retention limits \
  --discard old \
  --replicas 3 \
  --max-age 24h \
  --max-bytes 50GB \
  --max-msgs -1 \
  --max-msgs-per-subject -1 \
  --max-msg-size 1MB \
  --dupe-window 15m \
  --no-ack=false
```

`dupe-window=15m` covers in-process retries and short outages. Bump to 1h–24h if your relay can be paused (maintenance, deploy) for longer. Watch memory: the dedup map costs ~64 bytes/ID × (throughput × window).

#### 4.4 Sample Vector config (`/etc/vector/vector.yaml`)
```yaml
data_dir: /var/lib/vector

api:
  enabled: true
  address: 0.0.0.0:8686

acknowledgements:
  enabled: true

sources:
  redis_relay:
    type: http_server
    address: 127.0.0.1:9000
    encoding: ndjson
    acknowledgements:
      enabled: true     # 200 returned only after sink ack

transforms:
  shape:
    type: remap
    inputs: [redis_relay]
    source: |
      # Relay emits: {"stream":"orders","id":"1715800000000-0","event_type":"created","data":{...}}
      .stream      = string!(.stream)
      .event_type  = string!(.event_type)
      .redis_id    = string!(.id)
      del(.id)

  drop_bad:
    type: filter
    inputs: [shape]
    condition: 'exists(.redis_id) && exists(.stream) && exists(.event_type)'

sinks:
  nats_js:
    type: nats
    inputs: [drop_bad]
    url: "nats://nats-1.internal:4222,nats://nats-2.internal:4222,nats://nats-3.internal:4222"
    subject: "redis.prod.{{ stream }}.{{ event_type }}"
    encoding:
      codec: json
    jetstream:
      enabled: true
      headers:
        message_id: "{{ redis_id }}"
    auth:
      strategy: credentials_file
      credentials_file:
        path: /etc/nats/vector-relay.creds
    tls:
      ca_file: /etc/nats/ca.pem
    healthcheck:
      enabled: true
    acknowledgements:
      enabled: true
    request:
      concurrency: 1
      timeout_secs: 30
      retry_attempts: 18446744073709551615   # effectively infinite
    batch:
      max_events: 256
      timeout_secs: 1
    buffer:
      type: memory
      max_events: 10000
      when_full: block
```

Notes on this config:
- **No disk buffer between relay and NATS sink.** This is intentional: with `when_full: block` on a memory buffer, the HTTP server source back-pressures the relay, which back-pressures XREADGROUP COUNT, which is what we want. A disk buffer here would short-circuit end-to-end-acks (events would be "ack'd" at source as soon as they hit disk).
- **`request.concurrency: 1`** is critical for ordering. If you don't need per-subject ordering you can raise this.
- **Multiple NATS URLs** for HA — Vector's underlying `nats.rs` will reconnect-and-rotate.

#### 4.5 Sample Go sidecar relay
```go
package main

import (
    "bufio"
    "bytes"
    "context"
    "encoding/json"
    "log"
    "net/http"
    "os"
    "time"

    "github.com/redis/go-redis/v9"
)

type Event struct {
    Stream    string            `json:"stream"`
    ID        string            `json:"id"`
    EventType string            `json:"event_type"`
    Data      map[string]string `json:"data"`
}

func main() {
    stream     := os.Getenv("REDIS_STREAM")     // e.g. "orders"
    group      := os.Getenv("REDIS_GROUP")      // e.g. "vector-relay"
    consumer   := os.Getenv("REDIS_CONSUMER")   // unique per pod
    vectorURL  := os.Getenv("VECTOR_URL")       // e.g. "http://127.0.0.1:9000/"
    redisAddr  := os.Getenv("REDIS_ADDR")       // e.g. "redis:6379"

    rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
    ctx := context.Background()

    // Idempotent bootstrap
    _ = rdb.XGroupCreateMkStream(ctx, stream, group, "$").Err()

    http := &http.Client{Timeout: 30 * time.Second}

    // Phase 1: drain my own PEL
    drainPEL(ctx, rdb, http, vectorURL, stream, group, consumer)

    // Phase 2: live tail
    for {
        res, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
            Group: group, Consumer: consumer,
            Streams: []string{stream, ">"},
            Count: 256, Block: 5 * time.Second,
        }).Result()
        if err != nil && err != redis.Nil { log.Println(err); continue }

        for _, s := range res {
            for _, m := range s.Messages {
                if !publish(http, vectorURL, buildEvent(stream, m)) {
                    // Don't ACK; container retry / next loop re-reads via PEL
                    continue
                }
                if err := rdb.XAck(ctx, stream, group, m.ID).Err(); err != nil {
                    log.Println("xack:", err)
                }
            }
        }
    }
}

func publish(c *http.Client, url string, ev Event) bool {
    payload, _ := json.Marshal(ev)
    req, _ := http.NewRequest("POST", url, bytes.NewReader(append(payload, '\n')))
    req.Header.Set("Content-Type", "application/x-ndjson")
    resp, err := c.Do(req)
    if err != nil { log.Println("post:", err); return false }
    defer resp.Body.Close()
    return resp.StatusCode == 200    // Vector returned 200 only after sink ack
}

func buildEvent(stream string, m redis.XMessage) Event {
    et, _ := m.Values["event_type"].(string)
    if et == "" { et = "generic" }
    data := map[string]string{}
    for k, v := range m.Values {
        if s, ok := v.(string); ok { data[k] = s }
    }
    return Event{Stream: stream, ID: m.ID, EventType: et, Data: data}
}

func drainPEL(ctx context.Context, rdb *redis.Client, c *http.Client,
              url, stream, group, consumer string) {
    for {
        res, _ := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
            Group: group, Consumer: consumer,
            Streams: []string{stream, "0"}, Count: 256,
        }).Result()
        if len(res) == 0 || len(res[0].Messages) == 0 { return }
        for _, m := range res[0].Messages {
            if publish(c, url, buildEvent(stream, m)) {
                rdb.XAck(ctx, stream, group, m.ID)
            }
        }
    }
}

var _ = bufio.NewWriter // unused in HTTP path; kept for completeness
```

Why HTTP, not bare TCP: Vector's `http_server` source with `acknowledgements: enabled` only returns 200 *after* the event has been acked end-to-end (i.e., after `nats_js` got `PubAck` from JetStream). This is the strict, correct hand-off; TCP+newlines does not give you that signal.

#### 4.6 Failure-mode recovery

- **PEL growth** (alarm at >10K per consumer): the relay or its downstream is stalled. Drain via `XPENDING stream group` summary, then `XAUTOCLAIM stream group new-consumer 60000 0-0 COUNT 100` to redistribute.
- **Stuck consumer** (idle > 5×expected processing time): `XAUTOCLAIM` from a janitor consumer in another pod.
- **NATS down**: Vector's NATS sink retries with Fibonacci backoff (set `request.retry_attempts` high); the relay's HTTP POST blocks, applying back-pressure to XREADGROUP COUNT. Redis stream grows; trim via `XTRIM stream MAXLEN ~ <N>` with the default `KEEPREF` (do not `DELREF` — keep PEL refs intact for replay).
- **Redis primary failover**: PEL replicates, so the relay reconnects to the new primary, runs phase-1 drain, no message loss. Possible duplicates on in-flight messages → deduped by JetStream.

#### 4.7 Operational concerns

- **Sizing:** Vector's *Agent Architecture* doc recommends *"Limit the Vector agent to 2 vCPUs and 4 GiB of memory. If your Vector agent requires more than this, shift resource-intensive processing to your aggregators."* For this relay role, 2 vCPU / 4 GiB per Vector pod is the right starting point; one such Vector process easily sustains 50–100K events/s for this simple shape→sink topology.
- **Monitoring (Prometheus targets):**
  - Redis: `redis_stream_length{stream=...}`, `redis_stream_group_pending{group=...}`, `redis_connected_clients`, `instantaneous_ops_per_sec`.
  - Vector: `vector_component_sent_events_total{component_id="nats_js"}`, `vector_buffer_events{...}`, `vector_component_errors_total`, `vector_component_latency_seconds`, `vector_source_send_latency_seconds` (v0.55+).
  - NATS: `jetstream_server_streams_total`, `nats_jetstream_stream_messages`, `nats_jetstream_stream_first_seq`, `nats_jetstream_stream_last_seq`, `nats_jetstream_duplicate_message_count` (where exposed via nats_exporter).
- **Alerts:**
  - `redis_stream_group_pending > 10_000` for >5m (consumer stuck).
  - `rate(vector_component_errors_total{component_id="nats_js"}[5m]) > 0` (sink errors).
  - `vector_buffer_events / vector_buffer_events_max > 0.8` (back-pressure imminent).
  - JetStream `stream.bytes / stream.max_bytes > 0.9`.
- **Scaling out:** add more relay pods with unique consumer names; Redis distributes via XREADGROUP. Add NATS subject sharding only if a single subject is your bottleneck (rarely the case unless one Redis stream is hot >50K msg/s).

---

## Recommendations

1. **Default architecture:** one Go sidecar relay per Redis stream → Vector `http_server` source (with `acknowledgements: enabled` and 200-on-ack) → `remap` → `nats` sink (JetStream + `Nats-Msg-Id = {{ redis_id }}`). Vector ≥ v0.50 required (JetStream header support landed via PR #23510 on Aug 6, 2025).
2. **JetStream stream:** R=3 file storage, `retention: limits`, `max_age: 24h`, `dupe-window: 15m`. Move dupe-window to 1h+ only if your operational reality has multi-hour relay pauses.
3. **One sink instance per Redis stream, `request.concurrency: 1`** to preserve order. Run multiple Vector replicas only if you can shard your Redis streams across them (one stream per replica).
4. **If Vector is not strategically necessary for this leg**, use Redpanda Connect's `redis_streams` input + `nats_jetstream` output. You will write ~30 lines of YAML, no sidecar. Choose Vector when you need its broader source ecosystem (Kubernetes logs, metrics, traces) feeding the same NATS topology.
5. **Benchmarks to gate promotion:** verify in your environment that sustained relay throughput ≥ peak XADD rate × 1.5, p99 end-to-end latency Redis-XADD-to-JetStream-stored < 500 ms, and an induced NATS outage of `dupe-window/2` produces zero duplicate consumer-visible messages.
6. **Threshold for revisiting the design:**
   - If sustained per-stream throughput > 50K msg/s, evaluate Kafka or NATS-native publishing from producers (skip Redis Streams entirely for that leg).
   - If you need >24h retention with replay, JetStream `max_age` and Redis `max_bytes` need explicit alignment; consider mirroring the JetStream stream to a long-retention secondary.
   - If you observe dedup misses, the duplicate window is too small — bump it before adding application-level dedup.
7. **Track these upstream:** vectordotdev/vector for a native `data_type: stream` PR (would obsolete the sidecar); NATS for changes to dedup-window memory accounting; Redis 8.6 `IDMP`/`XCFGSET` if you want to push idempotency one layer further upstream into producers.

---

## Caveats

- **Vector's `redis` source remains list/channel-only as of v0.55 (May 2026).** This is the single biggest factor in choosing the architecture; if upstream lands a native stream source, the sidecar becomes redundant. Re-check at upgrade time.
- **End-to-end acks vs. disk buffers:** Vector's documented behavior is that *"the source will wait to 'ack' the data until it has been persisted to a disk buffer or has been sent by the sink to the downstream target."* If you put a disk buffer between source and NATS sink, you trade "event lost if Vector dies before NATS write" for "event lost if Redis dies before disk buffer reaches NATS — but Vector restart resumes". For Redis Streams the source-side recovery (PEL replay) is strong enough that a disk buffer adds little; we recommend memory buffer + back-pressure.
- **Dedup-window memory is shared across the JetStream stream.** A wide window at high throughput can be expensive; the NATS team explicitly warns *"we would caution against large windows"*. Validate with a load test.
- **`XDEL` does not remove PEL references.** If a producer XDELs an entry that is pending in your consumer group, the consumer will receive a null payload on PEL replay. Use `XACKDEL` (Redis 8.2+) or `XDELEX … DELREF` for correct cleanup.
- **Redis Cluster note:** the relay must connect to the primary that owns the stream's hash slot. For multi-stream consumers across slots, you need either `{tag}` hash tags to co-locate or one relay per slot.
- **Many of the performance numbers in this report are vendor-published.** NATS docs' 403,828 msgs/sec figure is single-node loopback on an Apple M4; the Redis 8.6 3.5M ops/sec is a pipelined SET:GET cache workload, not a streams workload; the 136K XADD ops/sec is the most directly relevant single-instance figure but is still Arm-on-Azure-Cobalt-specific. Treat all of these as upper bounds and benchmark your own hardware and payload sizes before sizing.
- **PR #23510 (JetStream headers in Vector's NATS sink) was merged Aug 6, 2025;** the boolean `jetstream: true` form added by PR #20834 still works for backwards compatibility but does not let you set headers. If you are on a Vector version older than v0.50 you cannot set `Nats-Msg-Id` through the sink, which breaks the deduplication design — upgrade before deploying this architecture.
- **Vector v0.55 moved the observability API from GraphQL to gRPC.** Tooling that talked to `/graphql` or `vector tap`/`vector top` against an older endpoint needs to be updated; the `/health` HTTP probe is unchanged.