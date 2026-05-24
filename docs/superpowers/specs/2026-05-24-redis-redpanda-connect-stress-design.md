# redis-redpanda-connect-stress — design spec

**Date:** 2026-05-24
**Implementation skill:** `research-lab` (produces a self-contained `labs/{topic-slug}/` directory with `docker-compose.yml`, `README.md`, `RESEARCH.md`, and Go components).
**Parent lab:** [`labs/redis-redpanda-qos-resilience/`](../../../labs/redis-redpanda-qos-resilience/) — forked, not extended.

## 1. Goal

Build a runnable lab that demonstrates Redpanda Connect's capability and verifies pipeline stability under high message throughput at three tiers: **10 msg/s, 1,000 msg/s, 10,000 msg/s**. The lab must run on a developer host without stuttering the machine, produce machine-readable reports, and emit a clear PASS/FAIL verdict per (tier × mode).

A successful run proves three properties at every tier:

1. **Throughput** — the Redis Stream → Connect → JetStream → Connect → Redis Stream pipeline sustains the target rate end-to-end.
2. **Latency** — end-to-end p99 latency stays under a tier-specific SLO.
3. **Chaos resilience** — the pipeline survives a mid-run `connect-sink` kill without violating QoS guarantees (loss = 0 under ALO/EOE; bounded loss under AMO).

## 2. Non-goals

- Real-time visual dashboard. Stress runs are non-interactive; results are JSON files + a stdout summary table. (The parent lab keeps its WebSocket dashboard; this fork removes it.)
- Multi-host or cluster deployment. Single Docker Compose host only.
- Production-grade Redpanda Connect tuning. The lab uses the parent lab's `alo` Connect YAMLs verbatim where possible; QoS profile switching (`amo`, `eoe`) is supported but the default and golden path is `alo`.
- Per-key visibility. At 10 k msg/s the parent lab's 9-cycling-keys / last-value-per-key model is meaningless; verification is **count-based** plus **sampled e2e latency**.

## 3. Directory layout

New lab at `labs/redis-redpanda-connect-stress/`.

```
labs/redis-redpanda-connect-stress/
├── README.md
├── RESEARCH.md
├── docker-compose.yml
├── .env.example
├── .gitignore                         # ignores reports/*.json
├── connect/
│   ├── alo-forward.yaml               # copied verbatim from parent
│   ├── alo-reverse.yaml               # copied verbatim from parent
│   ├── amo-forward.yaml
│   ├── amo-reverse.yaml
│   ├── eoe-forward.yaml
│   └── eoe-reverse.yaml
├── writer/                            # rewritten (not copied)
│   ├── main.go
│   ├── Dockerfile
│   ├── go.mod
│   └── go.sum
├── collector/                         # NEW
│   ├── main.go
│   ├── Dockerfile
│   ├── go.mod
│   └── go.sum
├── scripts/
│   ├── stress-run.sh
│   ├── lib/
│   │   └── tier-defs.sh
│   └── chaos/
│       └── kill-connect-sink.sh
└── reports/
    └── .gitkeep
```

**Removed vs parent:** `dashboard/`, the parent's `writer/`, `scripts/smoke-test.sh`, `scripts/chaos/{kill-connect-source,kill-nats,kill-region-redis,compare-streams}.sh`. The stress lab only needs `kill-connect-sink.sh` for chaos mode.

**Ports** are in the **17xxx** range so this lab can coexist with `redis-multiregion-via-connect/` (15xxx) and the parent `redis-redpanda-qos-resilience/` (16xxx). See Section 9 for the full table.

## 4. Architecture

```
                              POST /rate {rate}
                                     │
                                     ▼
                       ┌─────────────────────────┐
stress-run.sh ───────▶│ writer (Go)              │──XADD(MAXLEN ~ 100000)──▶ redis-central
                       │  - N goroutines         │                              │
                       │  - per-worker pipelines │                              │
                       │  - token-bucket limiter │                              │
                       │  - embeds ts_ns in body │                              │
                       │  - /metrics, /rate,     │                              │
                       │    /reset, /healthz     │                              │
                       └─────────────────────────┘                              │
                                                                                 │
                                                                  redis_streams (consumer group)
                                                                                 │
                                                                                 ▼
                                                                         connect-source
                                                                                 │
                                                                            JetStream
                                                                          (file, R=1,
                                                                           max-bytes 256MB)
                                                                                 │
                                                                                 ▼
                                                                          connect-sink
                                                                                 │
                                                                                 ▼
                                                                          redis-region
                                                                       XADD region-events
                                                                       (MAXLEN ~ 100000)

  collector (Go, run once per tier × mode) reads:
    - writer /metrics                  → sent, errors, rate_achieved
    - redis-central XLEN app.events    → source backlog
    - redis-region XLEN region-events  → delivered count
    - redis-region XRANGE region-events → e2e latency sample (now - ts_ns)
    - nats /jsz                        → backlog, bytes, pending
    - connect-{source,sink} /metrics   → per-leg throughput
  → writes reports/{tier}-{mode}-{profile}.json
```

**Key differences from parent lab:**

| Aspect                  | Parent lab                | Stress lab                                  |
|-------------------------|---------------------------|---------------------------------------------|
| Throughput              | 1 msg/s                   | 10 / 1 000 / 10 000 msg/s                   |
| Visibility              | live WebSocket dashboard  | post-run JSON report + stdout table         |
| Keys                    | 9 cycling, last-value     | wide key space (`stress:{seq % 100000}`)    |
| Keyspace notifications  | on (`KEA`)                | **off** (`""`) — 10 k events/s of fanout is wasteful |
| Redis stream cap        | unbounded                 | `XADD ... MAXLEN ~ 100000`                  |
| Resource limits         | none                      | per-container CPU + mem caps (Section 8)    |
| Writer rate             | env, fixed at start       | live `POST /rate` HTTP endpoint             |
| Chaos drills            | 4 kill scripts, manual    | 1 kill script, harness-driven in chaos mode |

## 5. Writer component

New `writer/main.go`. Single container, internally concurrent.

### 5.1 Environment

| Var               | Default                | Meaning                                           |
|-------------------|------------------------|---------------------------------------------------|
| `REDIS_ADDR`      | `redis-central:6379`   | central stream target                             |
| `STREAM_KEY`      | `app.events`           | source stream                                     |
| `STREAM_MAXLEN`   | `100000`               | `XADD ... MAXLEN ~ N` cap                         |
| `WORKERS`         | `8`                    | goroutines doing pipelined XADDs                  |
| `PIPELINE_DEPTH`  | `50`                   | commands per pipeline flush                       |
| `INITIAL_RATE`    | `0`                    | starts paused; harness drives via `/rate`         |
| `KEY_SPACE_SIZE`  | `100000`               | distinct keys cycled by `seq % N`                 |
| `PAYLOAD_BYTES`   | `200`                  | filler so each message is a known size            |
| `MAX_RATE`        | `20000`                | refuse `/rate` requests above this (safety guard) |
| `HEALTH_ADDR`     | `:8081`                | HTTP listen                                       |

### 5.2 Internals

- One `*redis.Client` shared across workers (`go-redis/v9` is goroutine-safe and pools connections internally).
- A central `golang.org/x/time/rate.Limiter` sized to the current `rate_target`. Workers acquire `PIPELINE_DEPTH` tokens before issuing one pipelined batch of XADDs.
- Each message body is JSON:
  ```json
  {"event_id":"<uuid>","ts_ns":<int64>,"seq":<int64>,"pad":"<filler>"}
  ```
  `ts_ns` is captured at the moment the XADD command is queued (not at JSON-marshal time). Filler is sized so total JSON length ≈ `PAYLOAD_BYTES`.
- Key pattern: `stress:{seq % KEY_SPACE_SIZE}`. The Redis stream stores `{key, json}` pairs via `XADD`.
- Every XADD uses `MAXLEN ~ STREAM_MAXLEN` (approximate trimming — O(1), zero throughput cost).
- Per-worker cap of **4 in-flight pipelines**. Beyond that the limiter blocks on token acquisition, which naturally lowers `rate_achieved` below `rate_target` — that gap is the visible backpressure signal.

### 5.3 HTTP API

| Method + Path | Body / Behavior                                                              |
|---------------|------------------------------------------------------------------------------|
| `GET /healthz`| 200 if Redis `PING` succeeds                                                 |
| `GET /metrics`| Prometheus text: `stress_writer_sent_total`, `stress_writer_errors_total`, `stress_writer_rate_target`, `stress_writer_rate_achieved` (5 s rolling), `stress_writer_inflight_pipelines` |
| `POST /rate`  | `{"rate": <int>}` — sets limiter. `rate=0` pauses. Reject > `MAX_RATE` (400).|
| `POST /reset` | zeros counters and resets achieved-rate window                               |

### 5.4 Safety

- Writer refuses `rate > MAX_RATE` with HTTP 400.
- Writer drops in-flight pipelines and stops accepting new XADDs when it sees SIGTERM; harness uses this for graceful drain.

## 6. Collector component

New `collector/main.go`. Run **once per (tier, mode)** by the harness as a one-shot container.

### 6.1 Invocation

```bash
docker compose run --rm collector \
  --tier=1000 --mode=latency --profile=alo \
  --duration=30s --warmup=5s --drain=10s \
  --out=/reports/1000-latency-alo.json
```

The collector image is built once at compose build time. It shares the lab network and mounts `./reports:/reports`.

### 6.2 What it samples

Every **1 s** during the run window the collector hits:

| Source         | Endpoint / command                                       | Used for                              |
|----------------|----------------------------------------------------------|---------------------------------------|
| writer         | `GET /metrics`                                           | `sent_total`, `errors_total`, `rate_achieved` |
| redis-central  | `XLEN app.events`                                        | source backlog                        |
| redis-region   | `XLEN region-events`                                     | delivered count                       |
| redis-region   | `XRANGE region-events {last_id}+ + COUNT 200`            | e2e latency sample (parse `ts_ns`)    |
| nats           | `GET /jsz?streams=true&consumers=true`                   | `messages`, `bytes`, `num_pending`    |
| connect-source | `GET /metrics`                                           | `input_received`, `output_sent`, `output_error` |
| connect-sink   | `GET /metrics`                                           | same                                  |

### 6.3 Latency sampling

At every 1 s tick the collector `XRANGE`s the latest 200 entries from `region-events` (starting after the last ID it saw). It parses `ts_ns` out of each payload, computes `now_ns - ts_ns`, and feeds the delta into an `hdrhistogram` (range 1 µs..60 s, 3 significant figures). At end of run, p50/p95/p99/max come from the histogram. A 30 s run at any tier samples ~6 000 latencies — statistically solid without storing every message.

### 6.4 Run lifecycle

```
t=0           POST writer/rate {warmup_rate}      // 50% of target
t=warmup_end  POST writer/rate {target}           // sustain begins; snapshot_start
              (chaos mode: at sustain_mid → stop connect-sink, sleep 8s, start)
t=sustain_end POST writer/rate {0}                // drain begins
t=drain_end   final snapshot, compute report, exit
```

The collector returns exit 0 if the verdict is `pass`, exit 1 otherwise. The harness ignores the exit code for individual collector runs and aggregates verdicts itself.

### 6.5 Output JSON schema

```json
{
  "tier": 1000,
  "mode": "latency",
  "profile": "alo",
  "started_at": "2026-05-24T19:12:03Z",
  "duration_s": 30,
  "rate_target": 1000,
  "rate_achieved_avg": 998.2,
  "rate_achieved_min": 942.0,
  "sent": 30021,
  "errors": 0,
  "received": 30019,
  "missing": 2,
  "missing_pct": 0.0067,
  "latency_ms": {"p50": 18.4, "p95": 47.2, "p99": 89.1, "max": 211.3, "samples": 6044},
  "redis": {"central_xlen_max": 1247, "region_xlen_final": 30019},
  "nats": {"pending_max": 980, "bytes": 7320000},
  "connect": {"source_in": 30021, "source_out": 30021, "sink_in": 30021, "sink_out": 30019},
  "chaos": null,
  "slo": {"rate_min_pct": 0.95, "latency_p99_ms": 1000, "allow_missing": false},
  "verdict": {"pass": true, "checks": {"rate_ok": true, "missing_ok": true, "latency_p99_ok": true}}
}
```

When `mode == "chaos"`, `chaos` is populated:
```json
"chaos": {"action": "kill-connect-sink", "down_at_s": 15, "duration_s": 8, "recovery_lag_max": 8412}
```

`recovery_lag_max` is the maximum value of NATS `num_pending` (for the sink consumer) observed across all 1 s ticks after the sink restarts — i.e. the deepest backlog the pipeline had to drain before catching up.

### 6.6 Verdict logic

The collector computes `verdict.pass = all(checks)`:

- `rate_ok`: `rate_achieved_avg / rate_target ≥ slo.rate_min_pct`
- `missing_ok`: `missing == 0` unless `slo.allow_missing` (true only for `profile == "amo"`)
- `latency_p99_ok`: `latency_ms.p99 ≤ slo.latency_p99_ms` (checked only in `latency` and `chaos` modes; `throughput` mode skips this check)

## 7. Harness orchestration

`scripts/stress-run.sh` is the top-level entry point.

### 7.1 Usage

```bash
# Full default matrix (3 tiers × 3 modes, profile=alo)
bash scripts/stress-run.sh

# Subset: single tier and mode
bash scripts/stress-run.sh --tiers=10000 --modes=chaos

# Override duration
DURATION_S=60 bash scripts/stress-run.sh

# Run on a different QoS profile
PROFILE_QOS=eoe bash scripts/stress-run.sh
```

CLI flags accepted: `--tiers=`, `--modes=`, `--profile=`. Env overrides: `DURATION_S`, `WARMUP_S`, `DRAIN_S`, `PROFILE_QOS`.

### 7.2 Tier / SLO definitions

In `scripts/lib/tier-defs.sh`:

```bash
declare -A TIER_SLO=(
  ["10:p99_ms"]=200       ["10:rate_min_pct"]=95
  ["1000:p99_ms"]=1000    ["1000:rate_min_pct"]=95
  ["10000:p99_ms"]=5000   ["10000:rate_min_pct"]=90
)
DURATION_S="${DURATION_S:-30}"
WARMUP_S="${WARMUP_S:-5}"
DRAIN_S="${DRAIN_S:-10}"
```

The 90% rate floor at 10 k/s is intentional: it accommodates the documented backpressure case where Connect can't quite keep up but the pipeline doesn't break. The report shows the gap; the verdict still passes.

### 7.3 Per-(tier × mode) run sequence

```
 1. POST writer/reset                     # zero counters
 2. XTRIM app.events MAXLEN 0             # clear source stream
 3. XTRIM region-events MAXLEN 0          # clear region stream
 4. POST writer/rate {tier/2}             # warmup half-rate
 5. sleep $WARMUP_S
 6. POST writer/rate {tier}               # sustain begins
 7. mode-specific:
      throughput → (nothing)
      latency    → (nothing; collector samples latency every run)
      chaos      → at t+(DURATION_S/2): docker stop  rrcs-connect-sink
                                       sleep 8s
                                       docker start rrcs-connect-sink
 8. sleep $DURATION_S
 9. POST writer/rate {0}                  # drain begins
10. sleep $DRAIN_S
11. docker compose run --rm collector …   # writes reports/{tier}-{mode}-{profile}.json
12. parse verdict, append row to summary table
```

### 7.4 Top-level flow

```
parse args
→ docker compose up -d --wait
→ for tier in TIERS:
    for mode in MODES:
      run_one(tier, mode)                # the 12-step sequence above
→ render summary table from all JSON reports
→ exit 0 if every verdict.pass; else exit 1
```

### 7.5 Summary table (stdout)

```
tier      mode         rate_achieved   missing   p99 ms    verdict
─────────────────────────────────────────────────────────────────
10        throughput   10.0/10         0         12        PASS
10        latency      10.0/10         0         14        PASS
10        chaos        9.8/10          0         180       PASS
1000      throughput   998/1000        0         42        PASS
1000      latency      999/1000        0         91        PASS
1000      chaos        992/1000        0         812       PASS
10000     throughput   9420/10000      0         3120      PASS
10000     latency      9380/10000      0         3870      PASS
10000     chaos        9210/10000      14        7200      FAIL (latency_p99)
─────────────────────────────────────────────────────────────────
```

### 7.6 Chaos-mode safety

Before stopping `connect-sink` in chaos mode, the harness reads NATS `/jsz` and aborts the run with a clear message if stream `bytes` is already above 200 MB. This prevents a previous-run leftover from pushing the host into swap during the planned outage.

### 7.7 Teardown

Full-matrix runs end with `docker compose down -v`. Subset runs (`--tiers=`, `--modes=`) do not auto-teardown — that lets the operator inspect Redis / NATS / Connect state after a single failed run.

## 8. Resource governance

This is the largest divergence from the parent lab and addresses the explicit "beware of host loading" requirement. Every container gets a hard cap via `deploy.resources.limits` in `docker-compose.yml`. Docker Compose v2 honors these without Swarm mode.

| Service          | CPU limit | Mem limit | Rationale                                       |
|------------------|-----------|-----------|-------------------------------------------------|
| `redis-central`  | `2.0`     | `512m`    | XADD is single-threaded; 2 CPU is plenty        |
| `redis-region`   | `2.0`     | `512m`    | same                                            |
| `nats`           | `2.0`     | `1g`      | JetStream file storage; 1 GB ample for 10k×30s  |
| `connect-source` | `2.0`     | `1g`      | the hot path                                    |
| `connect-sink`   | `2.0`     | `1g`      | the hot path                                    |
| `writer`         | `2.0`     | `256m`    | 8 goroutines × pipeline 50 — CPU-bound          |
| `collector`      | `0.5`     | `128m`    | only active during measure phase                |

**Total ceiling: 12.5 CPU, 4.4 GiB RAM.** On a 32-core / 122 GiB host that is <40% CPU and <4% RAM in the worst case. The host stays interactive.

Additional safeguards:

- NATS JetStream `APP_EVENTS` stream (same name as parent lab, since `connect/*.yaml` are copied verbatim — the lab runs in its own NATS instance so the name does not collide) is created with `--max-bytes=256MB` (so a runaway can't fill disk).
- Redis streams trimmed via `MAXLEN ~ 100000` on every XADD.
- Writer refuses `rate > MAX_RATE` (default 20 000).
- `.env.example` documents how to *lower* caps further on weaker hosts (and mentions that doing so may invalidate the published SLOs).

## 9. Port allocation

All host ports in the **17xxx** range to coexist with `redis-multiregion-via-connect/` (15xxx) and `redis-redpanda-qos-resilience/` (16xxx).

| Service          | Host port | Notes                                |
|------------------|-----------|--------------------------------------|
| writer           | 17081     | `/healthz`, `/metrics`, `/rate`, `/reset` |
| redis-central    | 17379     | `redis-cli -p 17379`                 |
| redis-region     | 17380     | `redis-cli -p 17380`                 |
| nats (client)    | 17222     |                                      |
| nats (monitoring)| 17322     | `/healthz`, `/varz`, `/jsz`          |
| connect-source   | 17195     | `/ready`, `/metrics`                 |
| connect-sink     | 17196     | `/ready`, `/metrics`                 |

Container names use prefix `rrcs-` (redis-redpanda-connect-stress) to avoid colliding with `rrqr-*` from the parent lab.

## 10. Verifying the lab itself

Hand-run checks, documented in `README.md`. Not automated CI — this is a lab, not a service.

1. **Build + boot smoke:** `docker compose up -d --wait` succeeds; every healthcheck green; writer `/healthz` returns 200.
2. **Sanity tier:** `bash scripts/stress-run.sh --tiers=10 --modes=throughput` completes in ~50 s and produces a PASS verdict.
3. **Mid tier:** `bash scripts/stress-run.sh --tiers=1000 --modes=throughput,latency` completes; latency p99 < 1 s.
4. **Full matrix:** `bash scripts/stress-run.sh` completes in ≤10 min wall-clock; exit code reflects the summary table.
5. **Host stability check:** during the 10 k chaos run, `top -bn1` from another shell shows 1-min load average < 16 on a 32-core host — confirming the CPU caps are honored.

## 11. Implementation skill

Implementation is delegated to the **`research-lab`** skill, per user instruction. The skill is responsible for:

- Scaffolding `labs/redis-redpanda-connect-stress/` with the structure in Section 3.
- Generating Go source for the `writer/` and `collector/` components per Sections 5–6.
- Generating `docker-compose.yml` per Sections 4, 8, 9.
- Generating `scripts/stress-run.sh` and `scripts/lib/tier-defs.sh` per Section 7.
- Producing `README.md` (how to run, ports, SLOs, troubleshooting) and `RESEARCH.md` (design rationale, what stress proves, links to parent lab).

The writing-plans skill (invoked after this spec is approved) will produce a step-by-step plan that hands the actual scaffolding work to `research-lab`.

## 12. Out of scope (deferred)

These are recognized future work, **not** part of this spec:

- A "soak" mode (5+ min sustained per tier) — would require revisiting NATS max-bytes and Redis MAXLEN.
- Comparison report across multiple runs (regression tracking).
- Variable payload sizes within a single run (only fixed `PAYLOAD_BYTES` for now).
- Multi-writer / horizontally scaled load generation.
- AMO / EOE profile-specific SLO tables (default SLOs assume ALO).
