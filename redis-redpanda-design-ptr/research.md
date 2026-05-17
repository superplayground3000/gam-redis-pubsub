# Production Architecture Research: Redis Streams → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis

## TL;DR
- **Exactly-once-effective end-to-end is achievable** for this pipeline only by (a) running Redis ≥ 6.2 with AOF `everysec`, (b) using JetStream `Nats-Msg-Id` deduplication on the middle hop, and (c) making the final Redis sink idempotent with an application-level idempotency key embedded in the payload — because Redpanda Connect's `redis_streams` input does **not** expose the Redis entry ID as metadata, so the entry ID alone cannot be used as the dedup key without a small workaround.
- **Every hop has well-defined failure semantics that compose to at-least-once with duplicates**: Redpanda Connect uses an in-process transaction model with no disk state, so it nacks back to its source on crash; duplicates are introduced at (i) Redpanda Connect crash between processing and ack, (ii) JetStream PubAck loss, (iii) JetStream redelivery on AckWait expiry, (iv) Redis XCLAIM/XAUTOCLAIM redelivery. Each of these is bounded if dedup windows and idempotency keys are configured.
- **Operational effort is moderate-to-high**: three stateful systems (Redis Sentinel/Cluster, NATS JetStream R=3, Redis again), two stateless Redpanda Connect tiers, and a supervisor pattern for stranded PEL entries. At ~500 req/s the workload is trivial for all of them; the real burden is monitoring (≈25 alerts across Redis lag/PEL, JetStream `num_ack_pending`, Connect `output_error`), not throughput.

---

## Key Findings

1. **Redis Streams gives at-least-once by default; exactly-once-effective requires idempotent sinks.** `XREADGROUP` with explicit `XACK`, plus `XAUTOCLAIM` (Redis 6.2+) for stranded entries, is the standard pattern. Redis 8.2 adds `XACKDEL`, `XDELEX`, and the `KEEPREF`/`DELREF`/`ACKED` trimming options, plus IDMP/IDMPAUTO publisher-side idempotency via `XCFGSET` — but per the JFrog Security Research disclosure (jfrog.com/blog/exploiting-remote-code-execution-in-redis/, published January 17, 2026), **CVE-2025-62507 ("a user can run the XACKDEL command with multiple IDs and trigger a stack buffer overflow, which may potentially lead to remote code execution"), CVSS v3 score 8.8 (High), affects Redis 8.2.0, 8.2.1, and 8.2.2 only, and is fixed in Redis 8.2.3 (with a further update in 8.3.2)**. The vulnerability was originally discovered by Google Big Sleep (Google DeepMind + Project Zero). Do not run 8.2.0–8.2.2 in production.
2. **Redpanda Connect's `redis_streams` input does NOT expose the Redis entry ID as metadata.** The official docs (docs.redpanda.com/redpanda-connect/components/inputs/redis_streams/) state only: *"Redis stream entries are key/value pairs, as such it is necessary to specify the key that contains the body of the message. All other keys/value pairs are saved as metadata fields,"* and for `body_key`: *"The field key to extract the raw message from. All other keys will be stored in the message as metadata."* No `redis_stream_id` or analogous field is added. **This is the single most important correction to the user's existing research document if it claims otherwise.** The producer must embed an application-level idempotency key (UUID, event ID) **inside the XADD payload** as a field.
3. **`nats_jetstream` input and output were both introduced in Redpanda Connect / Benthos 3.46.0** (verified verbatim on both docs.redpanda.com component pages: *"Reads messages from NATS JetStream subjects. Introduced in version 3.46.0."* / *"Write messages to a NATS JetStream subject. Introduced in version 3.46.0."*), and the `headers` field on the output requires version 4.1.0 or later (*"Explicit message headers to add to messages. This field supports interpolation functions. Requires version 4.1.0 or later."*). Run Redpanda Connect ≥ 4.38.0 to additionally get inline NKey-seed auth.
4. **JetStream exactly-once composes from two primitives**: server-side dedup keyed on `Nats-Msg-Id` (default 2 minutes window; configurable via `--dupe-window`), introduced with JetStream GA in NATS server 2.2 (per docs.nats.io/release-notes/whats_new/whats_new_22: *"NATS 2.2 is the largest feature release since version 2.0. The 2.2 release provides highly scalable, highly performant, secure and easy-to-use next generation streaming in the form of JetStream."*), plus double-ack (`AckSync`) on consume with `AckExplicit` + `MaxDeliver`. The `DiscardNewPerSubject` option, *"released in the v2.9.0 NATS server"* (nats.io/blog/new-per-subject-discard-policy/), combined with `MaxMsgsPerSubject=1` and subject-name carrying the id, enables truly **infinite** dedup beyond the window.
5. **End-to-end monitoring requires three exporters**: `oliver006/redis_exporter` with `--check-streams` for Redis stream/PEL/lag metrics; `prometheus-nats-exporter` or `nats-surveyor` for JetStream `num_pending` / `num_ack_pending` / redelivered; Redpanda Connect's built-in `metrics: prometheus: {}` on `:4195/metrics` for `input_received`, `output_sent`, `output_error`, `output_latency_ns`, `output_connection_up`.

---

## Details

### TOPIC 1 — Redis Streams

**Commands and minimum Redis versions (verified against redis.io/docs/latest/commands).**

| Command / feature | Min Redis version | Purpose |
|---|---|---|
| `XADD`, `XREAD`, `XREADGROUP`, `XACK`, `XCLAIM`, `XDEL`, `XGROUP CREATE/DESTROY/DELCONSUMER/SETID`, `XINFO STREAM/GROUPS/CONSUMERS`, `XLEN`, `XPENDING`, `XRANGE`, `XREVRANGE`, `XTRIM`, `XSETID` | **5.0.0** | Core Streams API (verified in Redis 8.2 commands reference) |
| `XAUTOCLAIM` | **6.2.0** | *"XAUTOCLAIM was introduced in Redis 6.2 to simplify the common pattern of scanning pending messages and claiming idle ones."* |
| `XGROUP CREATECONSUMER`, `NOMKSTREAM` on `XADD`, `MINID` trim | **6.2.0** | Verified in commands reference |
| `XINFO STREAM FULL` modifier | **6.0.0** | *"Added the FULL modifier"* |
| `entries-read`, `lag`, `entries-added`, `max-deleted-entry-id`, `recorded-first-entry-id` in XINFO | **7.0.0** | *"Starting with Redis version 7.0.0: Added the max-deleted-entry-id, entries-added, recorded-first-entry-id, entries-read and lag fields"* |
| `active-time` field in XINFO CONSUMERS | **7.2.0** | *"Starting with Redis version 7.2.0: Added the active-time field"* |
| `XACKDEL`, `XDELEX`, `KEEPREF`/`DELREF`/`ACKED` on `XADD`/`XTRIM` | **8.2.0** | *"Available since Redis 8.2. If no option is specified, KEEPREF is used by default."* |
| `XCFGSET`, `IDMP`, `IDMPAUTO` (publisher-side idempotency) | **8.6.0** (per `since` metadata in XADD docs) | *"XCFGSET v8.6.0 @write @stream @fast Sets the IDMP configuration parameters for a stream."* For a production pipeline today, **do not depend on XCFGSET/IDMP**; treat 7.2 as the practical baseline. |

**Delivery guarantees you can actually achieve.**

- **At-most-once**: pass `NOACK` to `XREADGROUP` — the entry is not added to the consumer's PEL and is effectively acked at delivery. Use only when occasional loss is acceptable.
- **At-least-once (default)**: `XREADGROUP GROUP g consumer COUNT n STREAMS key >` followed by processing and `XACK key g <id>`. On crash before ACK, the entry stays in the PEL and is redelivered to the same consumer when it returns (use ID `0` instead of `>` to drain its history first) or to a different consumer via XCLAIM/XAUTOCLAIM.
- **Exactly-once-effective**: only achievable by combining (1) at-least-once consumption with PEL-based recovery, AND (2) idempotent application-level write at the sink, keyed by an idempotency-id embedded in the message payload by the original producer. Redis Streams itself does not provide exactly-once.

**Disconnection / failover behavior.**

- In-flight entries already delivered to a consumer remain in the consumer-group PEL until acked, claimed, or trimmed.
- On consumer restart, the consumer must first read its own PEL with `XREADGROUP GROUP g consumer COUNT n STREAMS key 0` (ID `0`, not `>`) to drain pending entries before switching to `>` for new ones.
- **Primary failover (Sentinel / Cluster):** per the Redis Streams intro doc: *"A Stream, like any other Redis data structure, is asynchronously replicated to slaves and persisted into AOF and RDB files. However what may not be so obvious is that also consumer groups full state is propagated to AOF, RDB and slaves, so if a message is pending in the master, also the slave will have the same information."* Asynchronous replication implies a small window of recently-delivered/recently-acked entries can be lost on failover. AOF `appendfsync everysec` is the standard production setting; `appendfsync always` is safer but ~10× slower.
- A second consumer takes over stranded entries via `XCLAIM key group new_consumer min-idle-time-ms id [id …]` or, preferably, the cursor-based `XAUTOCLAIM key group new_consumer min-idle-time-ms 0-0 COUNT n` (6.2+). The atomic claim is safe — XCLAIM resets idle time, so two simultaneous claimers cannot both win.
- **Trimming caveat with PEL:** prior to Redis 8.2, `XTRIM`/`XADD MAXLEN` could delete entries still in some consumer's PEL — those become "ghost" PEL entries returned in the deleted-IDs slice of XAUTOCLAIM. From 8.2, `DELREF` and `ACKED` give clean semantics. Until then, size MAXLEN comfortably above the longest expected processing latency × throughput.

**Monitoring (what to scrape and alert on).**

- **`XINFO STREAM <key>`** — length, first/last/max-deleted entry IDs, entries-added; `FULL` shows groups+PEL inline.
- **`XINFO GROUPS <key>`** — per group: `consumers`, `pending` (PEL length), `last-delivered-id`, **`entries-read`** and **`lag`** (Redis 7+). `lag` is the canonical "unread messages" metric — replace any older code that scaled on `pending` alone (KEDA's older Redis-streams scaler had this bug; see kedacore/keda #3127). On Redis 7.0.x, `entries-read` could be NULL after replica promotion until activity resumes; see redis/redis #12898 (*"In XREADGROUP ACK, because streamPropagateXCLAIM does not propagate entries-read, entries-read will be inconsistent between master and replicas"*), fixed by always propagating `streamPropagateGroupID`. Reliable on Redis ≥ 7.2.
- **`XINFO CONSUMERS <key> <group>`** — `pending` per consumer, `idle`, `inactive`, `seen-time`, `active-time` (7.2+).
- **`XPENDING <key> <group> [IDLE ms] - + N [consumer]`** — list stale PEL entries, used by the XAUTOCLAIM supervisor.
- **`XLEN`** — total entries.
- **Prometheus exporters:**
  - `oliver006/redis_exporter` with `--check-streams=<pattern>` (or `REDIS_EXPORTER_CHECK_STREAMS`) emits `redis_stream_length`, `redis_stream_first_entry_id`, `redis_stream_last_entry_id`, `redis_stream_last_generated_id`, `redis_stream_max_deleted_entry_id`, `redis_stream_groups`, and per-group/consumer: `redis_stream_group_last_delivered_id`, `redis_stream_group_pending`, `redis_stream_group_consumers`, `redis_stream_group_entries_read`, `redis_stream_group_lag` (7+), `redis_stream_group_consumer_pending`, `redis_stream_group_consumer_idle_seconds`. Use `--streams-exclude-consumer-metrics` to control cardinality.
  - Alternative: `chrnola/redis-streams-exporter` (stream/group metrics only).
- **Alert thresholds for ~500 req/s**: `redis_stream_group_lag > 5000` for 1m (≈10s of backlog); `redis_stream_group_pending > 2000` for 5m; `redis_stream_group_consumer_idle_seconds > 60` (consumer hung); sustained rate of XAUTOCLAIM-claimed entries > 0 (Connect₁ unhealthy).

### TOPIC 2 — Redpanda Connect (Benthos) Configuration

All field lists below are verified against docs.redpanda.com. The current line is Redpanda Connect 4.x — **run ≥ 4.38.0** to get NKey-seed inline auth on NATS components, and ≥ 4.60.0 for `tls_handshake_first`. **Minimum useful baseline = 4.1.0** (header interpolation on `nats_jetstream` output).

#### `redis_streams` input — full configuration

```yaml
input:
  label: redis_source
  redis_streams:
    url: redis://:password@redis-primary:6379/0   # required; comma-separated for cluster
    kind: simple                                   # simple | cluster | failover
    master: ""                                     # required when kind=failover (Sentinel master name)
    body_key: body                                 # key that holds the message body; other XADD fields become metadata
    streams: [ events_in ]                         # required
    consumer_group: connect_ingest_group           # required for at-least-once semantics
    client_id: connect-instance-${HOSTNAME}        # unique per pod; becomes the XREADGROUP consumer name
    create_streams: true                           # XGROUP CREATE … MKSTREAM if absent
    start_from_oldest: true                        # XGROUP CREATE … 0 if true, else $
    commit_period: 1s                              # XACK batching interval
    timeout: 1s                                    # XREADGROUP BLOCK timeout
    limit: 10                                      # XREADGROUP COUNT
    auto_replay_nacks: true                        # nacked messages replayed indefinitely (back-pressures source); false = drop
    tls:
      enabled: false
      skip_cert_verify: false
      enable_renegotiation: false
      root_cas: ""
      root_cas_file: ""
      client_certs: []
```

**Metadata caveat (verified verbatim against docs.redpanda.com):** *"Redis stream entries are key/value pairs, as such it is necessary to specify the key that contains the body of the message. All other keys/value pairs are saved as metadata fields."* and for `body_key`: *"The field key to extract the raw message from. All other keys will be stored in the message as metadata."* — there is **no `redis_stream_id` metadata field**. The entry ID is consumed by the input for internal XACK bookkeeping but is not surfaced. If you need an idempotency key downstream, the producer **must include it as a field of the XADD entry**, e.g. `XADD events_in * id <uuid> body <payload>`, after which `meta("id")` is available.

#### `redis_streams` output — full configuration

```yaml
output:
  label: redis_sink
  redis_streams:
    url: redis://:password@redis-final:6379/0
    kind: simple
    master: ""
    stream: events_out                              # required; supports interpolation, e.g. ${! meta("target") }
    body_key: body                                  # key under which body is written in the XADD entry
    max_length: 0                                   # 0 = no MAXLEN; >0 enables MAXLEN ~ (approximate)
    max_in_flight: 64                               # batch parallelism
    metadata:
      exclude_prefixes: []                          # metadata keys NOT to copy onto the XADD entry
    batching:
      count: 0
      byte_size: 0
      period: ""
      check: ""
      processors: []
    tls: { … }
```

Note: *"All metadata fields of the message will also be set as key/value pairs, if there is a key collision between a metadata item and the body then the body takes precedence."* This is the mechanism by which an idempotency-id flowing through the pipeline as `meta("id")` is written back into the Redis sink stream — making the final hop idempotent if combined with an upstream lookup (`SET processed:<id> NX EX …`).

#### `nats_jetstream` input — full configuration (3.46.0+; prefer 4.38.0+)

```yaml
input:
  label: nats_source
  nats_jetstream:
    urls: [ nats://nats-1:4222, nats://nats-2:4222, nats://nats-3:4222 ]   # required
    max_reconnects: -1                              # negative = retry forever
    subject: ORDERS.>                               # optional if `stream` is set
    stream: ORDERS                                  # required when consuming a mirror in another JetStream domain
    durable: connect-consumer                       # persists offset across restarts
    queue: ""                                       # DO NOT set both `queue` AND `durable` — they correspond to push vs pull and conflict
    bind: ""                                        # bind to an existing consumer
    deliver: all                                    # all | last | new | last_per_subject
    ack_wait: 30s                                   # server-side redelivery timer
    max_ack_pending: 1024                           # in-flight cap; lower it for backpressure
    tls: { … }
    auth:
      nkey_file: ""
      nkey: ""                                      # requires Redpanda Connect 4.38.0 or later
      user_credentials_file: ""
      user_jwt: ""
      user_nkey_seed: ""
    tls_handshake_first: false                      # requires 4.60.0
    extract_tracing_map: ""                         # EXPERIMENTAL
```

Metadata fields added: `nats_subject`, `nats_sequence_stream`, `nats_sequence_consumer`, `nats_num_delivered`, `nats_num_pending`, `nats_domain`, `nats_timestamp_unix_nano` — verified verbatim. Use `meta("nats_num_delivered") > 3` in a `switch` to route to DLQ.

The pull-vs-push conflict is documented in redpanda-data/connect discussion #2695: when `queue` is set alongside `durable`, NATS returns *"cannot create a queue subscription for a consumer without a deliver group."* — pull consumers use `durable` only.

#### `nats_jetstream` output — full configuration (3.46.0+; header interpolation requires 4.1.0+)

```yaml
output:
  label: nats_sink
  nats_jetstream:
    urls: [ nats://nats-1:4222, nats://nats-2:4222, nats://nats-3:4222 ]
    max_reconnects: -1
    subject: ORDERS.created                         # supports interpolation: ${! meta("topic") }
    headers:
      Nats-Msg-Id: ${! meta("id") }                 # idempotency-id → JetStream dedup; REQUIRES Connect 4.1.0+
    metadata:
      include_prefixes: []                          # which message-metadata items to forward as NATS headers
      include_patterns: []
    max_in_flight: 1024
    tls: { … }
    auth: { … }
    inject_tracing_map: ""
```

The `Nats-Msg-Id` header is the single most important integration point — it enables JetStream server-side dedup during the configured `duplicate_window`.

#### Buffers, batching, processors, error handling

- **Buffers:** Default is no buffer, which is correct for at-least-once because Connect uses an in-process transaction model. The README states: *"Redpanda Connect processes and acknowledges messages using an in-process transaction model with no need for any disk persisted state, so when connecting to at-least-once sources and sinks it's able to guarantee at-least-once delivery even in the event of crashes, disk corruption, or other unexpected server faults."* Avoid the `memory` buffer here (breaks at-least-once on crash). A disk buffer is unnecessary at 500 req/s.
- **Batching:** Configure on the output (`batching: { count: 10, period: 100ms }`) for write efficiency; do not batch beyond what your idempotency handling can replay.
- **Error handling primitives:**
  - `try: [ … ]` — child processors are skipped after first failure.
  - `catch: [ … ]` — only runs on failed messages; clears the error flag at the end.
  - `retry: { backoff: { initial_interval, max_interval, max_elapsed_time }, processors: [ … ] }`
  - `mapping: 'root = if errored() { deleted() }'` — drop errored messages (propagates an ack upstream).
  - `switch` output with `check: errored()` — DLQ pattern.
  - `fallback: [ primary_output, dlq_output ]` — second output receives messages the first failed (the metadata key `fallback_error` carries the error).
  - `reject_errored: <inner_output>` — wraps an output and forwards errored messages to the parent fallback.
- **`auto_replay_nacks` semantics (verbatim):** *"Whether messages that are rejected (nacked) at the output level should be automatically replayed indefinitely, eventually resulting in back pressure if the cause of the rejections is persistent. If set to false these messages will instead be deleted."* Leave at `true` (default) on the source-side Connect — this guarantees that Redis Stream entries remain unacked until the entire downstream chain succeeds.

#### Redpanda Connect metrics

- HTTP endpoint default: `:4195` (configurable via `http.address`). Enable Prometheus via:
  ```yaml
  metrics:
    prometheus:
      use_histogram_timing: false
      add_process_metrics: false
      add_go_metrics: false
  ```
- Scrape paths: `/metrics` and `/stats`. Histogram timing requires Redpanda Connect ≥ 3.63.0.
- Health endpoints: `/ping` (liveness — always 200) and `/ready` (readiness — 200 only when all inputs and outputs are connected; 503 otherwise).
- **Standard metric series** (all labeled with `label`, `path`, and `stream` when in streams mode):
  - `input_received`, `input_latency_ns`, `input_connection_up`, `input_connection_failed`, `input_connection_lost`.
  - `output_sent`, `output_batch_sent`, `output_error`, `output_latency_ns`, `output_connection_up`, `output_connection_failed`, `output_connection_lost`, `batch_created{mechanism="count|size|period|check"}`.
  - `processor_received`, `processor_sent`, `processor_batch_received`, `processor_batch_sent`, `processor_error`, `processor_latency_ns` per processor.
  - `buffer_*` series if a buffer is configured.
- **Production alerts:** `rate(output_error[5m]) > 0`; `output_connection_up < 1` for 30s; `histogram_quantile(0.99, rate(output_latency_ns_bucket[5m])) > 1e9` (1s); `input_received == 0` for 5m outside maintenance.

### TOPIC 3 — NATS JetStream

**Minimum NATS server versions (verified verbatim where possible).**

| Feature | Min nats-server |
|---|---|
| JetStream GA — streams, consumers, PubAck, Nats-Msg-Id dedup, AckExplicit/All/None, MaxDeliver, AckWait | **2.2.0** — *"NATS 2.2 is the largest feature release since version 2.0. The 2.2 release provides highly scalable, highly performant, secure and easy-to-use next generation streaming in the form of JetStream."* (docs.nats.io/release-notes/whats_new/whats_new_22) |
| `DiscardNewPerSubject` (per-subject limit enforcement → infinite-dedup pattern) | **2.9.0** — *"One feature, released in the v2.9.0 NATS server, that flew under the radar was the new DiscardNewPerSubject option on a stream."* (nats.io/blog/new-per-subject-discard-policy/) |
| `BackOff` array on consumer (per-attempt redelivery delays) | 2.7.x |
| Nats-Expected-Last-Subject-Sequence (CAS) | 2.7.x |
| Sealed streams, source/mirror improvements | 2.10+ |
| Atomic batch publish | 2.12 |
| **Fast batch publish (ADR-50, "Fast Ingest Batch Publishing"), sourcing-with-dedup** | **2.14.0** (April 30, 2026) |

**Practical baseline as of May 2026: nats-server v2.14.0 is the current stable release** (released April 30, 2026, per nats.io/download/). The 2.14 release blog (nats.io/blog/nats-server-2.14-release/) describes *"first-class support for high-throughput publishing into JetStream"*. For this pipeline at 500 req/s, **2.10.x is more than sufficient**; upgrade to 2.14 if throughput grows past ~10k req/s or you specifically need fast batch publish.

**NATS CLI (`natscli`):** `nats stream info|add|ls|rm`, `nats consumer info|add|ls|rm`, `nats stream view`, `nats consumer next`, `nats bench` have been core subcommands since the earliest tagged `natscli` releases (these predate v0.0.20). **Current stable: v0.3.2 (March 25, 2026)** — release notes state verbatim: *"This release is identical to version 0.3.1 but updates all dependencies for recent CVE disclosures."* (github.com/nats-io/natscli/releases/tag/v0.3.2). Practical floor: any release ≥ v0.0.26 (Dec 2021).

**Streams.** Created via `nats stream add ORDERS --subjects 'ORDERS.>' --storage file --replicas 3 --retention limits --max-age 168h --max-bytes 10GB --discard old --dupe-window 5m`. Key knobs:
- **`Storage`**: `file` (default, durable, fsync per write group commit) or `memory` (faster, lost on restart).
- **`Replicas`**: **3 in production** — per docs.nats.io: *"Replicas=3 - Can tolerate the loss of one server servicing the stream. An ideal balance between risk and performance."* 1 and 2 are not recommended; 5 trades performance for tolerating 2 failures.
- **`Retention`**: `limits` (general-purpose, retains until limits hit), `interest` (retains while at least one consumer hasn't acked), `workqueue` (delete on ack — gives effectively-exactly-once consumption *across the cluster*, but only one consumer subscription per subject filter).
- **`Discard`**: `old` (default), `new` (reject when limit hit), `new` + `DiscardNewPerSubject` (the infinite-dedup pattern).
- **`Duplicates` / `--dupe-window`** — sliding window over `Nats-Msg-Id`. *"The default window to track duplicates in is 2 minutes, this can be set on the command line using `--dupe-window` when creating a stream, though we would caution against large windows."* Set ≥ the worst-case end-to-end retry interval of the upstream Connect (e.g. 10–15 minutes).

**Consumers.** Configured with `nats consumer add ORDERS connect-consumer --pull --filter 'ORDERS.>' --ack explicit --deliver all --max-deliver 5 --wait 30s --max-pending 1024 --replay instant`. Key knobs:
- **`AckPolicy`**: `none` (at-most-once), `all` (acking N implicitly acks ≤N), `explicit` (each must be acked — **required for pull consumers; required for at-least-once**).
- **`AckWait`**: server-side redelivery timer. Set ≥ 2× p99 processing latency; default 30s.
- **`MaxDeliver`**: cap on redelivery attempts. After this, an advisory is published on `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.<STREAM>.<CONSUMER>` — subscribe to this for DLQ routing.
- **`BackOff: [10s, 30s, 2m, 5m]`**: exponential per-attempt redelivery delay; overrides AckWait when set.
- **`MaxAckPending`**: server stops delivery when this many unacked are outstanding — your in-flight throttle.
- **`DeliverPolicy`**: `all`, `last`, `new`, `by_start_sequence`, `by_start_time`, `last_per_subject`.
- **Pull vs push** in Redpanda Connect: the `nats_jetstream` input creates a **pull** subscription when `durable` is set; **do not also set `queue`** (queue groups are for push consumers).

**Exactly-once.**
- Publisher side: `Nats-Msg-Id` header + `duplicate_window` — duplicate publishes within the window return `PubAck{Duplicate: true}` and are silently skipped.
- Consumer side: `AckSync` (double-ack) — sets a reply subject on the ack and waits for server confirmation, eliminating the "ack lost in flight" duplicate case.
- Together with `Discard: new` + `MaxMsgsPerSubject: 1` + subject = `events.<id>` (NATS ≥ 2.9.0), you get truly infinite dedup.

**Monitoring.**

- **Server HTTP endpoints (default `:8222`)**: `/varz`, `/connz`, `/routez`, `/jsz` (JetStream — supports `?streams=true&consumers=true&config=true`), `/accountz`, `/accstatz`, `/healthz` (200 when JetStream is ready; `?js-enabled-only=true` and `?js-server-only=true` filter the check).
- **`nats stream info <stream>`** — Messages, Bytes, FirstSeq, LastSeq, Active Consumers, Storage, Replicas, Cluster (leader, followers).
- **`nats consumer info <stream> <consumer>`** — Last Delivered (consumer seq, stream seq), Acknowledgment Floor, Outstanding Acks, Redelivered Messages, Unprocessed Messages, Waiting Pulls.
- **`prometheus-nats-exporter`** with flags `-varz -connz -healthz -jsz=all` (or `-jsz=streams` / `-jsz=consumers`) against each server. Key metrics:
  - Core: `nats_core_total_connections`, `nats_core_slow_consumers`, `nats_core_mem_bytes`, `nats_core_cpu`, `nats_varz_in_msgs`, `nats_varz_out_msgs`.
  - JetStream: `jetstream_stream_messages`, `jetstream_stream_bytes`, `jetstream_stream_first_seq`, `jetstream_stream_last_seq`, `jetstream_stream_consumer_count`, `jetstream_consumer_num_pending`, `jetstream_consumer_num_ack_pending`, `jetstream_consumer_num_waiting`, `jetstream_consumer_num_redelivered`, `jetstream_consumer_delivered_consumer_seq`, `jetstream_consumer_ack_floor_consumer_seq`, `jetstream_server_total_streams`, `jetstream_server_total_consumers`.
- **`nats-surveyor`** (≥ v0.9.1) polls Statz cluster-wide from a single deployment; recommended for multi-server NATS. Provides `nats_up` to distinguish exporter problems from NATS problems. Run `nats-surveyor --jsz=all --jsz-leaders-only --jsz-filter=consumer_num_pending,consumer_num_ack_pending,consumer_num_waiting` to control cardinality.
- **Critical alerts:** `jetstream_consumer_num_ack_pending` approaching `MaxAckPending` (delivery stalled); `rate(jetstream_consumer_num_redelivered[5m]) > 0` sustained (downstream failing); `jetstream_consumer_num_pending > N` (backlog); leader changes on the stream; `nats_up == 0`; messages arriving on `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.>` → DLQ.

### TOPIC 4 — End-to-end Robustness

**Where duplicates can enter the chain.**

| Hop | Failure mode | Result |
|---|---|---|
| Redis → Connect₁ | Connect₁ crash after processing, before XACK | Redis redelivers entry to another consumer when the XAUTOCLAIM supervisor runs; duplicate emitted to NATS, deduped server-side via `Nats-Msg-Id`. |
| Connect₁ → NATS | PubAck dropped in network | Connect₁ retries, JetStream returns `Duplicate: true`, no duplicate stored. ✓ |
| NATS → Connect₂ | AckWait expires before Connect₂'s ack reaches server | JetStream redelivers; Connect₂ writes to final Redis again → duplicate **unless** sink is idempotent on the id. |
| NATS → Connect₂ | Connect₂ crash after processing, before ack | Same as above — redelivery + idempotent sink absorbs. |
| Connect₂ → Redis | Final Redis is down | Connect₂ nacks; with `auto_replay_nacks: true` Connect₂ does not ack to NATS; on restart, NATS redelivers; no loss. |

**End-to-end exactly-once-effective recipe (recommended).**
1. **Producer into Redis**: include an application-level `id` field in every XADD (UUIDv4 or upstream event ID). At 500 req/s, ~43M ids/day; UUIDv7 (time-ordered) is preferable.
2. **Connect₁**: read with consumer group, `commit_period: 1s`. In a mapping processor: `meta id = json("id")`. Output to `nats_jetstream` with `headers: { Nats-Msg-Id: ${! meta("id") } }` — requires Connect 4.1.0+.
3. **JetStream**: `--dupe-window 15m` (≥ longest plausible Connect₁ retry interval), `Replicas: 3`, file storage, `Retention: limits` or `interest`. Optionally `Discard: new` + `MaxMsgsPerSubject: 1` + subject = `events.<id>` for infinite dedup (NATS ≥ 2.9.0), but this is overkill for a 15-minute drift.
4. **Connect₂**: pull subscription, `AckPolicy: explicit`, `AckWait: 30s`, `MaxDeliver: 5`, `BackOff: [10s, 30s, 2m]`. Use a `try` block; on terminal failure, route via `switch`+`output.reject` so the message lands on the `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.…` advisory and a dedicated DLQ Connect consumes it.
5. **Redis sink**: before XADD, `SET processed:<id> 1 NX EX 86400` — if the key existed, skip the XADD. This is the idempotency hop that compensates for the missing entry-ID metadata on the source side. Alternatively, embed `id` as a field of the XADD and rely on a periodic deduplication sweep.

**HA topology.**

- **Redis source and sink**: Redis Sentinel with 3 sentinels + 1 primary + 2 replicas across 3 AZs; `appendonly yes`, `appendfsync everysec`. Use `kind: failover` and `master:` in Connect's Redis client so it resolves the primary via Sentinel. For higher write availability, Redis Cluster with 3 primaries × 2 replicas, hash-tagged stream keys.
- **NATS**: `--replicas 3` per stream; 3 nats-server nodes minimum (5 for higher meta-layer fault tolerance). Use a single client URL list. JetStream consensus is Raft-based.
- **Redpanda Connect**: 2+ replicas per tier, sharing the same Redis consumer group (Connect₁) and the same NATS durable consumer name (Connect₂). Both tiers are stateless; schedule them as standard Kubernetes Deployments with `replicas: 2`, `podAntiAffinity` on node.
- **Supervisor pattern**: a third tiny Connect deployment (or a sidecar) running periodically (e.g. every 60s via `generate: { interval: 60s }`) issues `XAUTOCLAIM <stream> <group> supervisor-1 300000 0-0 COUNT 100` against the source Redis to reclaim PEL entries idle > 5 minutes, re-emitting them through the normal pipeline. Without this, a permanently dead Connect₁ pod leaves entries stranded in its consumer's PEL forever.

**End-to-end monitoring strategy.**

- **Three Prometheus jobs**: `redis_exporter` (source + sink Redis), `prometheus-nats-exporter` or `nats-surveyor` (NATS cluster), `redpanda-connect` (each Connect pod). One Grafana dashboard per hop.
- **The four golden signals for this pipeline:**
  1. **Backlog**: `redis_stream_group_lag` (Redis source) + `jetstream_consumer_num_pending` (NATS) — both near 0 at steady state.
  2. **In-flight**: `redis_stream_group_pending` + `jetstream_consumer_num_ack_pending` — both well below caps.
  3. **Errors**: Connect `rate(output_error[5m])`, NATS `rate(jetstream_consumer_num_redelivered[5m])`, Redis command-failed counters.
  4. **Latency**: Connect `histogram_quantile(0.99, rate(output_latency_ns_bucket[5m]))` per pod.
- **Alerts** (page on first three, ticket on the fourth): backlog growing for >5m, in-flight at >80% of cap for >2m, error rate >0 for >1m, p99 latency >2× SLO for >10m. Also: Sentinel/Raft leader churn, AOF rewrite stuck, JetStream `meta cluster down`.

**Operational effort assessment.**

This is **three stateful systems plus two stateless tiers and a supervisor**. For 500 req/s the resource footprint is trivial — Redis on a 4-vCPU box, NATS on three 2-vCPU boxes, Connect pods at 200m CPU each — but the **on-call burden is real**: ~25 alerts, three exporters, two failover runbooks (Redis Sentinel, NATS Raft), and a quarterly chaos drill to verify XAUTOCLAIM supervisor and JetStream leader-election. A 2–3 engineer team can run this comfortably; a one-person team should consider collapsing the architecture. Alternatives: drop the second Connect tier and have Connect₁ write directly to the final Redis (loses replay, halves the components); replace the middle hop with Redis Streams + longer retention (one fewer system, no cross-region replication story); or move the middle hop to Redpanda itself (Kafka semantics, fewer dedup contortions, heavier ops).

---

## Recommendations

**Stage 1 — Baseline (start here; validates the architecture).**
- Redis 7.2.x (source and sink), AOF `everysec`, Sentinel ×3 or managed Redis with multi-AZ failover.
- NATS server **2.10.x or 2.14.x** cluster ×3, JetStream `Replicas: 3`, file storage, `--dupe-window 15m`.
- Redpanda Connect 4.x (≥ 4.38.0), 2 replicas per tier, `redis_streams` ↔ `nats_jetstream` with `Nats-Msg-Id` header set from a payload-embedded id.
- Application sink uses `SET <id> NX EX` idempotency check before final XADD.
- Prometheus + Grafana + the three exporters above; basic alert rules.
- **Advance to Stage 2** when: pipeline stable at 500 req/s for 2 weeks, no manual reconciliation needed.

**Stage 2 — Harden (after ~1 month of stable operation).**
- Deploy the **XAUTOCLAIM supervisor** Connect pipeline for the source Redis (idle threshold 5m).
- Wire the `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.>` advisory into a DLQ Connect pipeline → S3 / object store with structured error envelopes.
- Add chaos tests: kill one Connect₁ pod mid-flight; fail over the source Redis primary; restart a NATS node; verify zero data loss and that duplicates are absorbed by sink idempotency (count `processed:<id>` keys vs. unique source ids).
- **Advance to Stage 3** when: chaos drills pass with zero loss and bounded duplicates.

**Stage 3 — Upgrade path (when you have spare cycles).**
- Move to Redis **8.2.3+** (or 8.3.2+) to use `XACKDEL` + `DELREF`/`ACKED` for cleaner PEL semantics — but **never run 8.2.0, 8.2.1, or 8.2.2** due to CVE-2025-62507 (CVSS 8.8). On 8.6+ you also get publisher-side IDMP via XCFGSET.
- Move to NATS **2.14.0+** for fast batch publish (ADR-50) if throughput grows past ~10k req/s.
- Consider `DiscardNewPerSubject` + `MaxMsgsPerSubject=1` + subject-as-id for infinite dedup if 15-minute window is ever insufficient.

**When NOT to use this architecture.**
- Single-region, single-team, <100 req/s, low durability tolerance → use Redis Streams end-to-end, drop NATS.
- Need ordered partition-level replay with infinite retention → use Redpanda/Kafka, not NATS.
- Need cross-cloud DR → JetStream stream mirroring or sourcing across leaf nodes is a viable add-on.

---

## Caveats

- **The user's existing research document's claim about `redis_streams` input metadata is correct**: the current docs.redpanda.com page lists no metadata fields containing the Redis entry ID — only that *"All other keys/value pairs are saved as metadata fields"* from the XADD entry. The architecture must place an idempotency id inside the payload at the producer.
- **`nats_jetstream` input and output introduced in 3.46.0**: verified verbatim. **`headers` interpolation requires Redpanda Connect 4.1.0+**: verified verbatim. Use Redpanda Connect 4.38.0+ to additionally benefit from inline NKey-seed auth.
- **Redis 7.0 had a replica-consistency bug** for `entries-read`/`lag` (redis/redis #12898). Production-grade lag-based scaling needs Redis ≥ 7.2.
- **Redis 8.2 `XACKDEL` had CVE-2025-62507** (CVSS v3 8.8, stack buffer overflow potentially leading to RCE, discovered by Google Big Sleep). **Affects 8.2.0, 8.2.1, and 8.2.2 only; fixed in 8.2.3, with a further update in 8.3.2.** If you upgrade to 8.2 for the new trimming options, ensure you are on 8.2.3+.
- **NATS workqueue retention with multiple consumers** is forbidden by the server (only one consumer subscription per subject filter). For fan-out with delete-on-ack, use `interest` retention.
- **JetStream `duplicate_window` is per-message-id, not per-payload**: a producer that retries with a *new* id after timeout will produce a duplicate. The id must be assigned at the *event* level, not the *publish-attempt* level.
- **Active-Active Redis** ("CRDB") replicates only group existence (`CREATE`/`DESTROY`) and selective `XACK` — not full PEL state — so this recipe assumes single-region active-passive Redis (Sentinel/Cluster), not Redis Enterprise Active-Active. Active-Active would require a different design with explicit ID-generation modes (Strict/Half-strict/None) and per-region read isolation.
- **NATS CLI release version with a verbatim "introduced in" for stream/consumer subcommands could not be pinned to a specific tag** — these commands predate the first tagged release of `nats-io/natscli`. Treat any release ≥ v0.0.26 (Dec 2021) as supporting the full management surface used in this report; current stable is **v0.3.2** (March 25, 2026), which *"is identical to version 0.3.1 but updates all dependencies for recent CVE disclosures"*.
- **Redpanda Connect `redis_streams` input/output do not carry an explicit "Introduced in version" banner** because they pre-date Benthos 1.0. They are available in all supported 3.x and 4.x releases.