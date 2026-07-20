# NATS JetStream message structure & how Redpanda Connect forms it (source) and applies it to Redis KV (sink)

> Lab: `labs/no-lww-simple-cdc`. This is the *no-LWW simple CDC* lab: a writer dual-writes
> to a central Redis (authoritative KV **+** an `app.events` stream); Redpanda Connect
> propagates each change event over NATS JetStream into a regional Redis as plain KV.
> Every config snippet below is the **real** config from this lab, not a sketch.

---

## 0. The end-to-end topology

```
                writer (Go)                 connect-source              JetStream stream KV_CDC          connect-sink                 region
   ┌───────────────────────────┐        (cdc-forward.yaml)        subjects: kv.cdc.>                (cdc-reverse.yaml)          ┌──────────┐
   │ pipeline:                 │   redis_streams      nats_jetstream          │            nats_jetstream      redis           │ Redis KV │
   │  SET/DEL  (central KV)     │   ─────────────►  ──────────────►  ┌─────────────────┐  ─────────────►  ──────────────►       │ (region) │
   │  XADD app.events  ────────┼──►  input          output           │ durable pull    │   input           SET / DEL / EVAL    │          │
   └───────────────────────────┘   (consumer_grp)  (publish subject) │ consumer        │  (cdc_sink)       per-op switch       └──────────┘
                                                                     │ cdc_sink        │
                                                                     └─────────────────┘
        central Redis                                              NATS JetStream                                  region Redis
   (redis-central, authoritative)                               (KV_CDC, durable log)                          (redis-region, replica)
```

Two Redpanda Connect processes, each a single self-contained YAML:

| Process | File | input → output | Role |
|---|---|---|---|
| **connect-source** | `chart/files/connect/cdc-forward.yaml` | `redis_streams` → `nats_jetstream` | Reads CDC events off the central Redis stream, **forms** one JetStream message per event |
| **connect-sink** | `chart/files/connect/cdc-reverse.yaml` | `nats_jetstream` → `redis` | Consumes JetStream messages, **forms** Redis KV writes (SET/DEL/Lua rename) |

The unit that travels between them is one **CDC event**. Its canonical shape is the Go
`Event` struct in `writer/payload.go`:

```go
type Event struct {
    EventID string // uuid; becomes Nats-Msg-Id for dedup
    Op      string // create | update | delete | rename
    KvKey   string // create/update/delete target key
    OldKey  string // rename source key
    NewKey  string // rename destination key
    TsMs    int64  // event time (ms)
    Body    string // opaque JSON value (no key embedded); "" for delete AND rename
}
```

---

## 1. Where the event is born: the writer's `XADD`

The writer (`writer/worker.go`) does a **dual write** inside one Redis pipeline — it mutates
the authoritative central KV *and* appends the change description to the `app.events` stream:

```go
applyCentral(pipe, ctx, e)                 // SET/DEL on central KV (authoritative intent)
pipe.XAdd(ctx, &redis.XAddArgs{
    Stream: w.StreamKey,                   // "app.events"
    MaxLen: w.StreamMaxLen, Approx: true,
    Values: e.StreamValues(),              // ordered field list ↓
})
```

`StreamValues()` (`writer/payload.go`) emits the XADD **field/value pairs in a fixed order**
(a slice, not a map — go-redis loses order with a map, and the source pipeline reads these
fields positionally-by-name as metadata):

```go
func (e Event) StreamValues() []any {
    return []any{
        "event_id", e.EventID,
        "op",       e.Op,
        "kv_key",   e.KvKey,
        "old_key",  e.OldKey,
        "new_key",  e.NewKey,
        "ts",       e.TsMs,
        "body",     e.Body,
    }
}
```

So a single stream entry looks like (Redis `XRANGE` view):

```
1718000000000-0
  event_id  9f1c…-uuid
  op        update
  kv_key    lb:general:active:{items:42}
  old_key   (empty)
  new_key   (empty)
  ts        1718000000000
  body      {"vid":"a3f…-uuid","ts":1718000000000,"pad":"xxxx…"}   # opaque; does NOT embed the key
```

That is the **input** to connect-source.

---

## 2. Anatomy of a NATS JetStream message

Before tracing the config, fix the four parts of a JetStream message — the source writes
the first three; the server stamps the fourth.

| Part | What it is | In this lab |
|---|---|---|
| **Subject** | The routing token. The stream `KV_CDC` is bound to the wildcard `kv.cdc.>`, so any subject under `kv.cdc.` is captured and persisted. | `kv.cdc.create`, `kv.cdc.update`, `kv.cdc.delete`, `kv.cdc.rename` — the op is the last token. |
| **Headers** | A multi-map of string→[]string, like HTTP headers. Some are **special** to JetStream. | `Nats-Msg-Id: <event_id>` (special: drives server-side dedup), `Content-Type: application/json` (informational). |
| **Payload (data)** | Opaque bytes — the server never parses it. | A **self-contained JSON envelope** (see §3.2). |
| **Server-side metadata** | Stamped by the JetStream server on persist/delivery, *not* by the publisher: stream sequence, consumer sequence, delivery timestamp, redelivery count, stream name. Carried in the message's reply subject and surfaced to consumers. | Used implicitly: `ack_wait`, redelivery on nack, dedup window. |

Two of these are load-bearing in this lab:

- **`Nats-Msg-Id`** — JetStream's idempotent-publish header. Within the stream's
  `dupe-window` (`5m`, see `values.yaml → nats.stream.dupeWindow`), a second message with
  the same `Nats-Msg-Id` is **silently discarded by the server**. Setting it to the event's
  UUID means a connect-source retry (e.g. it published, then crashed before acking the Redis
  stream, then re-read the same entry) cannot create a duplicate JetStream record.
- **Subject `…​.<op>`** — encodes the operation in the routing layer. The stream captures all
  ops via `kv.cdc.>`; the op is *also* inside the payload, so the sink never has to parse the
  subject (it reads the envelope), but the subject keeps ops separable for monitoring/replay.

### How the stream is provisioned

`chart/templates/nats-init-job.yaml` creates `KV_CDC` once (idempotent reconcile on upgrade):

```sh
nats stream add "KV_CDC" \
  --subjects "kv.cdc.>" \           # DESIRED_SUBJECTS, derived from subjectPrefix
  --storage file --replicas 1 \
  --retention limits --discard old \
  --max-age 1h --max-bytes 256MB \
  --max-msgs=-1 --max-msg-size=1MB \
  --dupe-window 5m                   # ← Nats-Msg-Id dedup horizon
```

The subject pattern is *derived in one place* from `nats.stream.subjectPrefix: "kv.cdc"`
(Helm helper `rrcs.nats.stream.subjects` → `printf "%s.>"`), so the bound subjects, the
publish subject, and the publisher's grant can't drift apart.

### Segment mode — an optional extra subject segment (default OFF)

Everything above describes the **default layout**, which is what ships unless you opt in:
normal ops land directly under the prefix as `kv.cdc.<op>`, and the DLQ (when enabled)
lives *outside* the prefix at `dlq.cdc.<reason>`. This is the layout every example and lab
in this repo exercises, and it is byte-identical to the pre-change chart.

An opt-in **segment mode** inserts a second, fixed subject segment under the prefix so that
normal and DLQ traffic can share one externally-fixed prefix (e.g. a PROD stream whose
binding is pinned at `kv.cdc.>`). It is enabled with `nats.stream.normalSegment` (and, for
the DLQ, `connect.deadLetter.segment`); leaving both empty keeps the default layout. When
set, the subject grammar shifts by one segment:

| | Default layout (unchanged) | Segment mode (`normalSegment: aio`, `deadLetter.segment: dlq`) |
|---|---|---|
| Normal publish | `kv.cdc.<op>` | `kv.cdc.aio.<op>` |
| DLQ publish | `dlq.cdc.<reason>` (outside the prefix) | `kv.cdc.dlq.<reason>` (inside the prefix) |
| Stream binding | `kv.cdc.>` (+ `dlq.cdc.>` when DLQ on) | `kv.cdc.>` alone — the segments are already under it |
| Sink filter | `kv.cdc.>` | `kv.cdc.aio.>` |

The two segments must differ (`aio ≠ dlq`), which is what keeps the whole-stream sink filter
from re-consuming its own dead letters — in the default layout that disjointness is
structural (the DLQ is physically outside the filter's universe); in segment mode it is a
render-time guard. The full opt-in schema, render guards, and the two-phase migration
runbook are documented in `docs/dlq.md` and
`docs/superpowers/plans/2026-07-20-shared-prefix-subject-layout.md`. The rest of this
document traces the **default** layout; read `kv.cdc.<op>` as `kv.cdc.<normalSegment>.<op>`
wherever segment mode is in effect.

---

## 3. SOURCE: how `cdc-forward.yaml` forms the JetStream message

Three stages: **input** turns stream fields into metadata; **pipeline** rebuilds a clean
envelope and re-derives the two routing values; **output** stamps subject + headers + payload.

### 3.1 Input — Redis stream fields become Connect metadata

```yaml
input:
  label: redis_source
  redis_streams:
    url: redis://lab-redis-central:6379
    kind: simple
    streams: [app.events]
    consumer_group: cdc_propagator       # durable group → at-least-once, resumable
    client_id: ${HOSTNAME:rpconnect-cdc-forward}
    body_key: body                       # the "body" field becomes the message CONTENT
    create_streams: true
    start_from_oldest: false
    commit_period: 200ms
    timeout: 500ms
    limit: 50
    auto_replay_nacks: true              # nacked messages are re-read (at-least-once)
```

The `redis_streams` input splits each XADD entry into two surfaces:

- **`body_key: body`** → the value of the `body` field becomes the Connect message **content**
  (the raw bytes flowing through the pipeline). For this lab that's the JSON snapshot.
- **Every other field** (`event_id`, `op`, `kv_key`, `old_key`, `new_key`, `ts`) → Connect
  **metadata** entries, readable with `meta("…")`.

So immediately after the input, one Connect message =
`content = {"vid":…,"ts":…,"pad":…}` and
`metadata = {event_id, op, kv_key, old_key, new_key, ts}`.

### 3.2 Pipeline — rebuild a self-contained envelope, re-derive routing keys

```yaml
pipeline:
  threads: 2
  processors:
    - mapping: |
        let body = content().string()
        let eid  = meta("event_id").or($body.hash("sha256").encode("hex"))
        root = {
          "event_id": $eid,
          "op":       meta("op").or("update"),
          "kv_key":   meta("kv_key").or(""),
          "old_key":  meta("old_key").or(""),
          "new_key":  meta("new_key").or(""),
          "ts":       meta("ts").or("0"),
          "body":     $body
        }
        meta op       = meta("op").or("update")   # used for the subject interpolation
        meta event_id = $eid                       # used for the Nats-Msg-Id header
```

What this stage does and **why**:

1. **Snapshots the content** (`$body`) before `root = {…}` overwrites it. The new `root`
   *embeds* `body` as a string field, so the payload becomes a single JSON object that
   contains everything — op, all keys, ts, and the body.
2. **Builds a self-contained envelope.** This is the central design decision: the sink will
   read *only the payload*, never NATS headers→metadata. The header path is fragile (header
   casing, multi-value semantics, broker mapping), so the op/keys are duplicated **into the
   payload** rather than relied upon from headers. (See the file's own header comment:
   *"so the sink never depends on NATS header→metadata mapping."*)
3. **Re-derives the two routing values into metadata**: `meta op` (used to interpolate the
   subject) and `meta event_id` (used to set `Nats-Msg-Id`). `.or(...)` defaults make the
   stage total — a malformed upstream entry still produces a valid envelope (op defaults to
   `update`, event_id falls back to a content hash so dedup still works).

After this stage the message is:

```jsonc
// CONTENT (this becomes the JetStream payload, verbatim bytes):
{
  "event_id": "9f1c…-uuid",
  "op": "update",
  "kv_key": "lb:general:active:{items:42}",
  "old_key": "",
  "new_key": "",
  "ts": "1718000000000",
  "body": "{\"id\":\"lb:general:active:{items:42}\",\"ts\":1718000000000,\"pad\":\"xxxx…\"}"
}
// METADATA: op=update, event_id=9f1c…-uuid  (plus the originals still present)
```

### 3.3 Output — stamp subject, headers, payload

```yaml
output:
  label: jetstream_sink
  nats_jetstream:
    urls: ["nats://lab-nats:4222"]
    auth: { user_credentials_file: "/etc/nats-creds/publisher/user.creds" }
    subject: "kv.cdc.${! meta(\"op\") }"   # ← rrcs.nats.stream.publishSubject
    headers:
      Nats-Msg-Id: ${! meta("event_id") }
      Content-Type: application/json
    max_in_flight: 256
```

This is the moment the **NATS JetStream message is formed**:

- **Subject** = `kv.cdc.` + the runtime value of `meta("op")`. The `${! … }` is a Redpanda
  Connect *interpolation* evaluated per-message at publish time (it is **not** Helm
  templating — the Helm helper deliberately emits the literal `${! meta("op") }` string).
  An `update` event publishes to `kv.cdc.update`; a `rename` to `kv.cdc.rename`. All land in
  `KV_CDC` because the stream binds `kv.cdc.>`.
- **Headers**: `Nats-Msg-Id` ← the event UUID (server-side dedup, §2); `Content-Type`
  informational.
- **Payload**: the current message content — i.e. the JSON envelope from §3.2, sent as raw
  bytes. The server persists it untouched.
- **Publish auth**: the publisher NATS user-credentials (an NSC-minted JWT/creds file),
  scoped so it may only publish under `kv.cdc.>`.
- **`max_in_flight: 256`**: up to 256 unacked publishes concurrently, for throughput.

A persisted record in `KV_CDC` is therefore:

```
subject : kv.cdc.update
headers : Nats-Msg-Id: 9f1c…-uuid
          Content-Type: application/json
data    : {"event_id":"9f1c…","op":"update","kv_key":"lb:general:active:{items:42}",
           "old_key":"","new_key":"","ts":"1718000000000","body":"{\"id\":…}"}
+ server stamps: stream seq, ts, etc.
```

---

## 4. SINK: how `cdc-reverse.yaml` forms the Redis KV write

Three stages again: **input** pulls from the durable consumer; **pipeline** lifts envelope
fields back into metadata then switches on `op` to run the right Redis command; **output**
turns processor success/failure into JetStream ack/nack.

### 4.1 Input — one durable pull consumer

```yaml
input:
  label: jetstream_source
  nats_jetstream:
    urls: ["nats://lab-nats:4222"]
    auth: { user_credentials_file: "/etc/nats-creds/subscriber/user.creds" }
    subject: "kv.cdc.>"          # rrcs.nats.stream.subjects (all ops)
    stream: "KV_CDC"
    durable: "cdc_sink"          # durable name → JetStream tracks ack state server-side
    deliver: all
    ack_wait: 30s                # unacked after 30s ⇒ JetStream redelivers
    max_ack_pending: 1024        # flow control: ≤1024 in-flight unacked
```

It binds the **durable** consumer `cdc_sink` and subscribes to the whole `kv.cdc.>` subject
space, so it receives every op in one stream. `durable` + `ack_wait` give at-least-once with
server-tracked progress: a message stays pending until the pipeline acks it, and is
redelivered if 30s pass without an ack.

Each delivered Connect message has `content =` the JSON envelope bytes (the payload from
§3.3); the op/keys live **inside** that content, not in metadata yet.

### 4.2 Pipeline — stash envelope into metadata, then switch on op

**Step 1 — stash, before any Redis call mutates the content:**

```yaml
- mapping: |
    meta op      = this.op
    meta kv_key  = this.kv_key
    meta old_key = this.old_key
    meta new_key = this.new_key
    meta body    = this.body
```

`this.op` etc. read fields out of the parsed JSON payload and copy them to metadata. **Why
metadata and why first:** the `redis` processor below **replaces the message content with the
Redis reply**. Any field needed *after* the Redis call (the metric label, and the
`args_mapping` of subsequent commands) must therefore already live in metadata — content is
about to be destroyed. (This is the comment in the file: *"the `redis` processor REPLACES
message content with the Redis reply."*)

**Step 2 — switch on `op`, run the matching Redis command:**

```yaml
- switch:
    - check: meta("op") == "create" || meta("op") == "update"
      processors:
        - redis:
            url: redis://lab-redis-region:6379
            kind: simple
            command: set
            args_mapping: 'root = [ meta("kv_key"), meta("body") ]'      # SET kv_key body
        - metric: { type: counter, name: cdc_apply, labels: { op: "${! meta(\"op\") }" } }

    - check: meta("op") == "delete"
      processors:
        - redis:
            url: redis://lab-redis-region:6379
            kind: simple
            command: del
            args_mapping: 'root = [ meta("kv_key") ]'                    # DEL kv_key
        - metric: { type: counter, name: cdc_apply, labels: { op: "delete" } }

    - check: meta("op") == "rename"
      processors:
        - redis:
            url: redis://lab-redis-region:6379
            kind: simple
            command: eval
            args_mapping: |
              let script = "<contents of cdc_rename.lua>"
              root = [ $script, 2, meta("old_key"), meta("new_key") ]   # EVAL guarded RENAME (no body)
        - metric: { type: counter, name: cdc_apply, labels: { op: "rename" } }

    - processors:                                                         # default: unknown op
        - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'
```

The `args_mapping` builds the **argument array** for a Redis command. `command: set` +
`root = [ meta("kv_key"), meta("body") ]` issues `SET <kv_key> <body>`. So the JSON envelope
is *destructured* back into a native Redis write:

| `op` | Redis command formed | Effect on region KV |
|---|---|---|
| `create` / `update` | `SET kv_key body` | key now holds the opaque JSON value |
| `delete` | `DEL kv_key` | key removed |
| `rename` | `EVAL cdc_rename.lua 2 old_key new_key` | **value-preserving** `RENAME old→new` (no body) |
| anything else | `throw(...)` | processor error → nack (see §4.3) |

The rename is a Lua script (`chart/files/connect/cdc_rename.lua`) embedded into the config at
Helm-render time (`{{ .Files.Get … | toJson }}`). It uses native Redis `RENAME` so the new key
**inherits old_key's existing value verbatim** — no body is carried in a rename event:

```lua
-- KEYS[1]=old_key  KEYS[2]=new_key   (no ARGV: value is NOT carried)
if redis.call('EXISTS', KEYS[1]) == 1 then
  redis.call('RENAME', KEYS[1], KEYS[2])
end
return 1
```

The `EXISTS` guard makes it **replay-idempotent**: bare `RENAME` raises `ERR no such key` when
`old_key` is already gone (a second JetStream delivery, or a reordered delete/rename that ran
first) — which would nack and redeliver forever. Guarded, that second delivery is a clean
no-op. The `2` is the Redis EVAL `numkeys`; `old_key`/`new_key` share a `{…}` hash tag (set by
the writer's key patterns) so both land in one slot on Redis Cluster, keeping the EVAL atomic.

> **Value-preserving rename works because the value is opaque to the key.** The writer's
> payload (`snapshot()`) deliberately does NOT embed the Redis key — it carries a random `vid`,
> matching production where a value never contains its own key. So moving the value to a new
> key with `RENAME` changes nothing inside it, and `new_key` is correct without re-sending a
> body. The authoritative central store applies the *same* guarded `RENAME` (writer
> `applyCentral`), so central and region converge — the verifier's `rename_parity` check
> asserts `central[new] == region[new]` after a rename.

### 4.3 Output — ack/nack is the whole contract

```yaml
output:
  reject_errored:
    drop: {}
```

There is **no real output sink** — the Redis writes happened in the pipeline. `reject_errored`
inspects the per-message error flag:

- **Pipeline succeeded** → message is **acked** to JetStream → the durable consumer advances;
  the record won't be redelivered.
- **Pipeline errored** (Redis unreachable, or the default `throw("unknown op")` branch fired)
  → message is **rejected/dropped here, which nacks it** to JetStream → after `ack_wait`
  (30s) JetStream **redelivers**. Redelivery is safe because SET/DEL/Lua are all idempotent.

This is the "no-LWW" part: there is **no version fence**. If a later, reordered same-key
event is redelivered or arrives late, it simply overwrites — last *delivered* wins, not last
*written*. The lab's whole point is to study that looseness.

### 4.4 Sidecar `cdc:latency` stream (best-effort telemetry)

On each create/update the sink also XADDs a best-effort `cdc:latency` record to
**region** Redis, carrying `op`/`kv_key`/`writer_ts` (the event's `ts`) and
`sink_ts` (the apply wall-clock). It is emitted *before* the authoritative `SET`
and wrapped in `try`/`catch`, so a telemetry failure is logged and ignored —
it never affects the applied KV value, and the `set` that follows is unwrapped so
a real apply error still nacks/redelivers. The stream is consumed only by the
optional region-side latency-calculator (`latency_ms = sink_ts - writer_ts`);
nothing in the apply path reads it, so the convergence verifier is unaffected.

---

## 5. Worked end-to-end examples (one per op)

Following the bytes from writer → central stream → JetStream → region Redis.

### create / update
```
writer XADD app.events:  event_id=U1 op=update kv_key=lb:general:active:{items:42}
                         old_key= new_key= ts=T body={"vid":"…","ts":T,"pad":"xx…"}
  └─ source pipeline ─► envelope {op:update, kv_key:…:42, body:"{…}", …}
  └─ source output  ─► SUBJECT kv.cdc.update   HEADER Nats-Msg-Id=U1   DATA <envelope>
JetStream KV_CDC: persisted (dedup-keyed on U1)
  └─ sink input    ─► content=<envelope>;  stash op/kv_key/body to meta
  └─ sink switch   ─► SET lb:general:active:{items:42} "{…opaque value…}"  on redis-region
  └─ sink output   ─► ack U1
RESULT: region key lb:general:active:{items:42} = the opaque JSON value (no key embedded)
```

### delete
```
writer XADD: op=delete kv_key=lb:general:active:{items:42} body=""   (empty body)
  source ─► SUBJECT kv.cdc.delete  HEADER Nats-Msg-Id=U2  DATA {op:delete, kv_key:…, body:""}
  sink   ─► DEL lb:general:active:{items:42}  ; ack
RESULT: region key removed
```

### rename
```
writer XADD: op=rename old_key=lb:company:standby:{employees:7}
                      new_key=lb:company:active:{employees:7} body=""   (no body carried)
  source ─► SUBJECT kv.cdc.rename  HEADER Nats-Msg-Id=U3  DATA {op:rename, old_key:…, new_key:…, body:""}
  sink   ─► EVAL cdc_rename.lua 2 <old> <new>  ⇒ if EXISTS old then RENAME old→new
  sink   ─► ack
RESULT: standby key gone, active key holds standby's ORIGINAL opaque value — atomically, same slot
```

### unknown op (failure path)
```
JetStream delivers a message whose op is, say, "patch"
  sink default branch ─► throw("unknown op: patch")  ⇒ processor error
  sink output reject_errored ─► nack ⇒ JetStream redelivers after ack_wait (30s)
(here it loops; in practice "unknown op" means a producer/consumer version skew to fix)
```

---

## 6. Field-by-field crosswalk (one table to keep)

| Stage | Where the field lives | `event_id` | `op` | `kv_key` | `old_key` | `new_key` | `ts` | `body` |
|---|---|---|---|---|---|---|---|---|
| Writer | `Event` struct | field | field | field | field | field | `TsMs` | field |
| Central stream | XADD field | `event_id` | `op` | `kv_key` | `old_key` | `new_key` | `ts` | `body` |
| Source input | Connect surface | meta | meta | meta | meta | meta | meta | **content** (`body_key`) |
| Source pipeline | rebuilt | envelope + meta | envelope + meta | envelope | envelope | envelope | envelope | envelope (embeds content) |
| **JetStream msg** | — | **Nats-Msg-Id header** + payload | **subject suffix** + payload | payload | payload | payload | payload | payload |
| Sink input | content | in JSON | in JSON | in JSON | in JSON | in JSON | in JSON | in JSON |
| Sink pipeline | stashed | (unused) | meta (switch) | meta (SET/DEL arg) | meta (Lua KEYS[1]) | meta (Lua KEYS[2]) | (unused) | meta (SET value; **unused by rename**) |
| Region Redis | KV | (dropped) | (drives command) | the key | DEL'd key | new key | (dropped) | the value |

Two fields cross into the JetStream **envelope of control** (subject + header) rather than
just the payload: `op` (→ subject) and `event_id` (→ `Nats-Msg-Id`). Everything else rides in
the payload and is reconstructed by the sink.

---

## 7. Why this shape — design rationale recap

- **Self-contained JSON payload, not header-dependent.** The source duplicates op/keys into
  the payload so the sink reads only the body — avoiding fragile NATS header→metadata mapping.
- **`Nats-Msg-Id = event_id` for server-side dedup.** Source retries can't create duplicate
  JetStream records within the 5-minute dupe window.
- **Op in the subject (`kv.cdc.<op>`) *and* in the payload.** Subject keeps ops separable for
  monitoring/replay; payload keeps the sink self-sufficient.
- **Durable pull consumer + ack/nack via `reject_errored`.** Success acks and advances;
  failure nacks and redelivers. Idempotent SET/DEL/Lua make redelivery harmless.
- **No version fence (no-LWW).** Reordered/late same-key arrivals overwrite. This is the
  behavior the lab exists to study — the cost of *not* doing last-write-wins.
- **Value-preserving rename, opaque value.** `rename` carries no body: both the sink and the
  authoritative central store apply a guarded native `RENAME`, so `new_key` inherits
  `old_key`'s value verbatim. This is correct precisely because the value is **opaque to the
  key** — the writer's payload never embeds the Redis key (it carries a random `vid`), matching
  production. The `rename_parity` verifier check asserts `central[new] == region[new]`.
- **Single hash slot per multi-key op.** Writer key patterns embed `{entity:id}` hash tags so
  the rename Lua's two keys stay in one Redis Cluster slot, keeping the `RENAME` EVAL atomic.
```
