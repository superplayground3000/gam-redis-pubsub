# redis-redpanda-throughput-stress — design

**Status:** Approved 2026-05-26.
**Lineage:** Fork of `labs/redis-redpanda-connect-stress/` (see `docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md`).
**Goal:** A dedicated, throughput-focused stress lab over the Redis → Connect → JetStream → Connect → Redis pipeline. Exercises 5k–50k msg/s with two writer modes (pipelined batch vs single-XADD), Cluster-style hashtag-wrapped keys across three patterns, and reports per-message sync latency between central and regional Redis.

---

## 1. Scope

### What this lab proves

1. **Pipeline ceiling.** Where in the 5k–50k msg/s range does the parent's ALO pipeline (writer → central Redis → Redpanda Connect → JetStream → Connect → regional Redis) stop sustaining target rate?
2. **Batching contribution.** How much of the achievable ceiling comes from writer-side pipelining? Direct A/B at every tier: pipelined batch XADDs vs one XADD per round-trip.
3. **Sync-latency profile under sustained throughput.** How does end-to-end propagation (writer wall-clock → Connect-sink wall-clock just before regional SET) distribute (p50/p95/p99/p999/max) at each tier, for each mode, across three realistic key-shape patterns with hashtag-pinned slots.

### Non-goals

- QoS profile comparison — only ALO is implemented (AMO/EOE stripped).
- Chaos resilience — no `connect-sink` kill drill.
- Per-key visibility / dashboards.
- Redis Cluster topology — hashtags are present in keys for forward-compatibility and slot-routing realism, but the deployed Redis is a single primary on each side.

### Coexistence

Uses host port range `18xxx`. Coexists with:
- `redis-multiregion-via-connect/` (15xxx)
- `redis-redpanda-qos-resilience/` (16xxx)
- `redis-redpanda-connect-stress/` (17xxx)

Container name prefix: `rrts-`. Compose project name: `redis-redpanda-throughput-stress`.

---

## 2. Architecture

```
                                                                ┌────────────────────────────┐
                                                                │ regional Redis             │
                                                                │ (rrts-redis-region)        │
                                                                │  cache: SET <key> <value>  │
                                                                │  XADD region-events ...    │
                                                                └────────────▲───────────────┘
                                                                             │
┌──────────┐    XADD app.events    ┌──────────┐         ┌─────────────┐     │
│  writer  ├──────────────────────▶│  redis-  ├────────▶│   connect-  │     │
│ (Go,     │  fields: key, value,  │ central  │ stream  │   source    │     │
│  rrts-   │  event_id, pattern,   │ (rrts-   │ pull    │ (forward    │     │
│  writer) │  t_send_ms            │  redis-  │         │  .yaml)     │     │
│          │                       │ central) │         │             │     │
│ /healthz │                       └──────────┘         └──────┬──────┘     │
│ /metrics │                                                   │            │
│ /rate    │                                                   ▼            │
│ /reset   │                                              ┌────────┐        │
└──────────┘                                              │  NATS  │        │
                                                          │  JS    │        │
                                                          │ APP_   │        │
                                                          │ EVENTS │        │
                                                          └────┬───┘        │
                                                               │            │
                                                               ▼            │
                                                       ┌───────────────┐    │
                                                       │   connect-    │    │
                                                       │   sink        │    │
                                                       │ (reverse      │    │
                                                       │  .yaml)       │    │
                                                       │ stamps        │    │
                                                       │ applied_ms    ├────┘
                                                       └───────────────┘
                                                                ▲
                                                                │ XREAD BLOCK
                                                       ┌────────┴───────┐
                                                       │   collector    │
                                                       │ (Go, profile:  │
                                                       │  tools)        │
                                                       │  writes JSON   │
                                                       │  report        │
                                                       └────────────────┘
```

### Services

| Service          | Image                                  | CPU | RAM     | Host port            |
|------------------|----------------------------------------|----:|--------:|----------------------|
| `redis-central`  | `redis:7.4-alpine`                     |   4 |   1 GiB | 18379                |
| `redis-region`   | `redis:7.4-alpine`                     |   4 |   1 GiB | 18380                |
| `nats`           | `nats:2.10-alpine`                     |   4 |   2 GiB | 18222 (cli) / 18322 (mon) |
| `nats-init`      | `natsio/nats-box:0.14.5` (one-shot)    |   — |       — | —                    |
| `connect-source` | `hpdevelop/connect:4.92.0-claudefix`   |   6 |   2 GiB | 18195                |
| `connect-sink`   | `hpdevelop/connect:4.92.0-claudefix`   |   6 |   2 GiB | 18196                |
| `writer`         | local build `./writer`                 |   4 |   1 GiB | 18081                |
| `collector`      | local build `./collector` (profile: `tools`) | 1 | 256 MiB | —              |
| **Total**        |                                        | **29** | **9.25 GiB** |               |

Within the 32-core / 122 GiB host budget. The 31-CPU figure quoted during brainstorming included a 2-CPU rounding margin; actual sum is 29.

### Network

Single bridge network `rrts-net`. Container hostnames mirror parent (`redis-central`, `redis-region`, `nats`, etc.) so the YAMLs are minimally edited.

### Volumes

- `nats-data` (named) — JetStream file storage. Redis runs with `--appendonly no --save ""` (RDB off, AOF off) like parent.

### Data flow

Byte-identical to parent's ALO leg. Pipeline carries `t_send_ms` (writer-stamped) through to `applied_ms` (Connect-sink-stamped); collector reads both from regional `region-events` entries to compute per-message sync latency.

---

## 3. Writer redesign

### Key generation — 3 patterns with hashtag-wrapped tail

| Pattern    | Template                                       | ID kind                    | ID space     |
|------------|------------------------------------------------|----------------------------|-------------:|
| `employee` | `lb:company:active:{employee:<int>}`           | `int` 0..19999             | 20 000       |
| `role`     | `lb:functions:active:{role:<hexhash>}`         | 40-hex-char SHA-1 string   | 20 000 (pre-gen) |
| `org`      | `lb:functions:active:{org:<int>}`              | `int` 0..19999             | 20 000       |

- Braced tail = Redis Cluster hashtag (same content → same slot in a future cluster topology).
- `role` IDs are **pre-generated at writer startup**: 20 000 SHA-1 hashes drawn from a deterministic seed and held in memory, then sampled uniformly per write. (Generating fresh UUIDs per write would inflate the keyspace beyond 20k and lose the LWW-churn target.)
- Per-write pattern selection follows env `PATTERN_WEIGHTS` (default `33,33,34`), implemented as a weighted picker; total weights need not sum to 100.
- Per-pattern ID sampling: uniform random within `[0, PATTERN_CARDINALITY)` (integer patterns) or uniform pick from the pre-generated slice (`role`).

### Write modes

| Mode     | Behavior                                                                                  |
|----------|-------------------------------------------------------------------------------------------|
| `batch`  | N XADDs in a single `pipe.Exec`. Depth = `min(rate/10, BATCH_MAX)`, `BATCH_MAX=500` (env). Same adaptive logic as parent, ceiling raised from 50→500. Pipeline fires every ~100 ms regardless of rate. |
| `single` | One XADD per `pipe.Exec` (depth=1). Limiter still throttles to target rate. Tests round-trip-amortization effect directly. |

Both modes share the same Redis client (`go-redis/v9`); only the per-iteration depth differs.

### Live `/rate` endpoint extension

Parent body: `{"rate": <int>}`. New body:

```json
{"rate": 35000, "mode": "batch"}     // either field optional
```

Handler semantics:

- Missing `rate` → keep current rate.
- Missing `mode` → keep current mode.
- `mode` ∈ `{"batch", "single"}`; anything else → `400`.
- Mode swap is atomic via `atomic.Pointer[string]` (or equivalent); workers re-read mode at the top of every iteration (same pass where they re-read rate).
- `200 OK` response echoes effective state: `{"rate": 35000, "mode": "batch"}`.

### XADD payload

Unchanged field set (`event_id`, `key`, `value`, `pattern`, `t_send_ms`). What changes:

- `value` JSON pad grows from ~200 B to ~1 KiB (`PAYLOAD_BYTES` default `1024`).
- `key` carries the new hashtag-wrapped shape per pattern.
- `pattern` field becomes one of `employee` / `role` / `org` (was `stress`). Flows through to JetStream subject (`app.events.employee` etc.) and gives per-pattern visibility in `nats stream view`.

### Counters

Existing `Sent`, `Errors`, `Inflight` kept. Add:

- `SentByPattern` (3-element atomic counters, one per pattern) — for the JSON report's `received_by_pattern` cross-check.

### Env vars (new / changed on writer)

| Var                    | Default       | Effect                                          |
|------------------------|---------------|-------------------------------------------------|
| `BATCH_MAX`            | `500`         | ceiling for adaptive batch depth                |
| `PATTERN_WEIGHTS`      | `33,33,34`    | weighted picker for employee/role/org           |
| `PATTERN_CARDINALITY`  | `20000`       | per-pattern unique-ID count                     |
| `INITIAL_MODE`         | `batch`       | starting write mode                             |
| `PAYLOAD_BYTES`        | `1024`        | JSON pad bytes (parent default was 200)         |
| `MAX_RATE`             | `60000`       | hard ceiling on `POST /rate` (was 20000)        |
| `WORKERS`              | `16`          | writer goroutines (was 8) — needed for 50k/s    |

### Counterpart removals

`PIPELINE_DEPTH` env var is removed — replaced by `BATCH_MAX` for batch mode and is meaningless for single mode.

---

## 4. Connect pipeline & sync-latency measurement

### YAMLs (ALO only)

| File                     | Purpose                                                                 |
|--------------------------|-------------------------------------------------------------------------|
| `connect/forward.yaml`   | Was `alo-forward.yaml`. Central Redis Stream → JetStream.               |
| `connect/reverse.yaml`   | Was `alo-reverse.yaml`. JetStream → regional Redis (cache + ledger).    |

`docker-compose.yml` mounts these directly (no `${PROFILE_QOS}` interpolation).

### Forward leg (central → JetStream)

- `redis_streams` input on `app.events`, `body_key: value`, `limit: 50` (Connect's internal batch — untouched from parent).
- Mapping re-wraps to JSON envelope (`key`, `value`, `event_id`, `pattern`, `t_send_ms`) — unchanged.
- Publishes to JetStream subject `app.events.${! meta("pattern") }` → subjects become `app.events.employee`, `app.events.role`, `app.events.org`.
- JetStream stream `APP_EVENTS` still subscribes to `app.events.>` — no subject-config change needed.
- `max_in_flight: 256` → **`1024`**, to keep the JetStream output from throttling at 50k/s.

### Reverse leg (JetStream → regional)

- Durable consumer `region-writer`, `deliver: all`, `ack_wait: 30s` (unchanged).
- Mapping step keeps parent's `meta applied_ms = (timestamp_unix_nano() / 1000000).string()` — **load-bearing for sync-latency measurement**. Stamps Connect-sink wall-clock immediately before broker fan-out.
- Broker fan-out (`pattern: fan_out`):
  - `cache` output → `SET <key> <value>` on `redis-region` (the KV state replica).
  - `redis_streams` output → `XADD region-events ... max_length: 2000000`, `metadata.exclude_prefixes: ["nats_"]` (measurement ledger).
- `max_in_flight: 64` → **`256`** on both fan-out outputs.

### Measurement entry shape on `region-events`

Each XADD entry carries:

- `value` (the original 1 KiB JSON envelope, body)
- `key` (hashtag-wrapped key, from metadata passthrough)
- `event_id`
- `pattern`
- `t_send_ms` (writer wall-clock at central XADD)
- `applied_ms` (Connect-sink wall-clock just before SET)

### Sync-latency definition

```
sync_latency_ms = applied_ms - t_send_ms
```

Covers: writer → central XADD ack → Connect-source pull → JetStream publish/ack → Connect-sink consume → `applied_ms` stamp.

**Does NOT include** the final `SET` round-trip to regional. On a single host that overhead is sub-millisecond and dominated by pipeline cost; the metric closely approximates "how stale is regional vs central?". This caveat is documented in `RESEARCH.md`.

### Collector behavior

- Streaming `XREAD BLOCK 100 STREAMS region-events $` for full run duration.
- Per entry: parse fields → compute `sync_latency_ms` → feed into HDR histogram (existing dep `hdrhistogram-go`).
- Accumulate `received` count and per-pattern breakdown.
- Quiescence wait uses `GroupLag("app.events", "propagator")` (source) AND `ScrapeJSZ(natsURL, "APP_EVENTS").MaxPending` (sink) — see Section 5 step 9 for the rationale (XLEN is the wrong signal; we inherit parent's `bdf31a9` fix and `1e9e7b2` tail-flush).
- End-of-run: write JSON report with sync-latency distribution, counts, verdict (Section 5).

### Stream / JetStream sizing

| Stream                    | Cap                 | Reason                                                 |
|---------------------------|---------------------|--------------------------------------------------------|
| `app.events` (central)    | `MAXLEN ~ 2000000`  | 50k × 30 s = 1.5 M peak; ~33% headroom; ~600 MB max    |
| `region-events` (region)  | `MAXLEN ~ 2000000`  | same                                                   |
| JetStream `APP_EVENTS`    | `--max-bytes 2GB`   | ~1.5 M × 1.2 KiB ≈ 1.8 GB peak; headroom for trim lag  |
| JetStream `--max-msg-size`| `4KiB`              | 1 KiB payload + envelope overhead well under 4 KiB     |

---

## 5. Harness, matrix, report shape & verdict

### Harness — `scripts/stress-run.sh`

```bash
# Default full matrix (no args → auto-teardown at end)
bash scripts/stress-run.sh
  # Runs: 5k, 10k, 20k, 30k, 40k, 50k × {batch, single} = 12 runs

# Subset (any arg suppresses teardown so you can inspect state)
bash scripts/stress-run.sh --tiers=50000 --modes=batch
bash scripts/stress-run.sh --tiers=10000,20000 --modes=batch,single
```

### Per-run flow

1. **Harness**: `nats stream purge APP_EVENTS`; `redis-cli XTRIM app.events MAXLEN 0`; same for `region-events`.
2. **Harness**: `POST /rate {"rate": 0, "mode": "<mode>"}` to writer (pause + arm mode).
3. **Harness**: spawn collector with `--tier`, `--mode`, `--warmup`, `--duration`, `--drain`, `--out`.
4. **Collector**: `POST /rate {"rate": <tier/2>}` (warmup half-rate; mode already armed).
5. Sleep `WARMUP_S` (5 s).
6. **Collector**: `POST /rate {"rate": <tier>}` (sustain).
7. **Collector**: streaming `XREAD BLOCK` on `region-events`, counters running, for `DURATION_S` (30 s).
8. **Collector**: `POST /rate {"rate": 0}` (stop sending).
9. **Collector**: pipeline-quiescence wait, 10 s deadline. Polls every 250 ms; quiesced when **both** conditions hold for one poll:
   - **Source-side:** `GroupLag("app.events", "propagator") == 0` (consumer group has read every entry).
     - **NOT** `XLEN("app.events") == 0` — Redis streams don't shrink on ack, so XLEN never drops back to zero during a run. The parent lab regressed on this exact mistake (commit `bdf31a9`); we inherit the fixed signal.
     - `GroupLag` returns 0 trivially if the consumer group doesn't exist yet (first-ever run before Connect registers `propagator`); any other error propagates so the poll retries.
   - **Sink-side:** `ScrapeJSZ(natsURL, "APP_EVENTS").MaxPending == 0` (no JetStream deliveries pending ack from `connect-sink`'s durable consumer `region-writer`). Since this lab is ALO-only, sink-side check is always required (parent's AMO branch is dropped here).
10. **Collector**: tail-flush sleep of **1500 ms** after quiescence is observed, before cancelling the streaming receiver. The receiver's `XREAD BLOCK 100` can miss the final entry or two if cancelled too aggressively at the moment `MaxPending` flips to 0; parent lab calibrated this at 1500 ms (commit `1e9e7b2`).
11. Sleep `DRAIN_S` (10 s) for any in-flight to land. (Belt-and-braces; with healthy quiescence this is mostly idle.)
12. **Collector**: write JSON report; exit.
13. **Harness**: loop to next `(tier, mode)`.

### Per-tier SLO matrix — calibration mode

Ships with **p99 ceiling = `null`** for every tier. Rate floor and `missing==0` are enforced; p99 is reported but not gated until a calibration run fills in real numbers.

| Tier (msg/s) | `rate_min_pct` | `p99_ceiling_ms` |
|--------------|---------------:|------------------:|
| 5 000        | 0.95           | `null`            |
| 10 000       | 0.95           | `null`            |
| 20 000       | 0.90           | `null`            |
| 30 000       | 0.90           | `null`            |
| 40 000       | 0.90           | `null`            |
| 50 000       | 0.90           | `null`            |

**Calibration procedure** (one-time, documented in README):

1. Run the full matrix at least once on the target host.
2. Inspect `reports/*.json` for `sync_latency_ms.p99` across both modes.
3. Pick per-tier ceilings that are realistic but tight enough to catch regressions (suggested heuristic: `ceiling = round_up_to_100ms(max(p99_batch, p99_single) * 1.25)`).
4. Edit `scripts/lib/tier-defs.sh` to commit the numbers.
5. Future runs gate on the calibrated ceilings.

### Verdict logic

A run passes iff:

```
rate_achieved      >= tier.rate_min_pct * tier.target          (required)
missing            == 0                                         (required)
sync_latency_p99   <= tier.p99_ceiling_ms                      (skipped if null)
```

`verdict_detail.p99_latency_ok` is `null` (not `true`) when the ceiling is `null` — explicit "not yet gated" marker.

### Report JSON shape — `reports/{tier}-{mode}.json`

```json
{
  "tier": 50000,
  "mode": "batch",
  "duration_s": 30,
  "rate_target": 50000,
  "rate_achieved": 49850.2,
  "sent": 1495506,
  "received": 1492841,
  "received_by_pattern": { "employee": 497612, "role": 497615, "org": 497614 },
  "trimmed": 0,
  "missing": 2665,
  "sync_latency_ms": {
    "p50": 142.3, "p95": 612.1, "p99": 1180.4, "p999": 1843.2, "max": 2010.7,
    "count": 1492841
  },
  "received_errors": 0,
  "quiescence_timeout": false,
  "verdict": "PASS",
  "verdict_detail": {
    "rate_floor_ok": true,
    "missing_ok": true,
    "p99_latency_ok": null
  }
}
```

### Summary table printed at end of matrix

```
tier      mode       rate_achieved    missing   p99 ms    verdict
5000      batch      4992.1/5000      0         118.4     PASS
5000      single     4988.7/5000      0         142.0     PASS
10000     batch      9981.3/10000     0         234.1     PASS
10000     single     9215.4/10000     0         512.8     FAIL(rate)
...
50000     batch      49850.2/50000    0         1180.4    PASS
50000     single     12410.7/50000    0         8230.2    FAIL(rate)
```

The single-mode wall at high tiers is the visible "batching matters" story this lab is built to tell.

---

## 6. Configuration (`.env.example`)

```bash
# Stress run knobs
DURATION_S=30
WARMUP_S=5
DRAIN_S=10

# Writer tuning
WORKERS=16
BATCH_MAX=500
PATTERN_WEIGHTS=33,33,34
PATTERN_CARDINALITY=20000
PAYLOAD_BYTES=1024
STREAM_MAXLEN=2000000
MAX_RATE=60000
INITIAL_MODE=batch

# Host port overrides
REDIS_CENTRAL_PORT=18379
REDIS_REGION_PORT=18380
NATS_CLIENT_PORT=18222
NATS_MON_PORT=18322
CONNECT_SRC_PORT=18195
CONNECT_SINK_PORT=18196
WRITER_PORT=18081
```

---

## 7. Open items deferred to implementation plan

- Exact wire shape of the `MAXLEN` value at the writer's XADD call (`MAXLEN ~ 2000000` Approx=true to match Connect's `max_length: 2000000` on the reverse leg).
- Whether the collector spawns the warmup/sustain `POST /rate` calls itself or the harness does (parent puts it in the collector; that's preserved here).
- Test plan: unit tests for `limiter.Set` mode swap, `payload.NewPayload` size, key-generator pattern picker; integration smoke = single 5k batch run with `verdict=PASS`.

These belong in the implementation plan (`docs/superpowers/plans/2026-05-26-redis-redpanda-throughput-stress.md`), not this design doc.

---

## 8. References

- Parent lab: `labs/redis-redpanda-connect-stress/`
- Parent design: `docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md`
- Parent v2 measurement model: `docs/superpowers/specs/2026-05-25-redis-redpanda-connect-stress-v2-design.md`
- Production architecture deep-dive that informed both labs: `labs/redis-redpanda-design-ptr/research.md`
- Redpanda Connect docs: <https://docs.redpanda.com/redpanda-connect/about/>
- Redis Cluster hashtags spec: <https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/#hash-tags>
- NATS JetStream concepts: <https://docs.nats.io/nats-concepts/jetstream>
- HDR Histogram: <https://github.com/HdrHistogram/hdrhistogram-go>
