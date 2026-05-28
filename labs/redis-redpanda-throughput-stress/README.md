# redis-redpanda-throughput-stress

Throughput-focused stress harness for the Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis pipeline. Forked from [`../redis-redpanda-connect-stress/`](../redis-redpanda-connect-stress/) (which itself forks `../redis-redpanda-qos-resilience/`); all three labs coexist on different host port ranges.

## What this demonstrates

Two writer modes (pipelined batch vs single-XADD) across six tiers (5k, 10k, 20k, 30k, 40k, 50k msg/s) on three hashtag-wrapped key patterns:

- `lb:company:active:{employee:<int>}`
- `lb:functions:active:{role:<sha1-hex>}`
- `lb:functions:active:{org:<int>}`

with 60 000 unique keys (20 000 per pattern) and a per-message sync-latency report (`applied_ms − t_send_ms`) covering writer → central Redis → Connect → JetStream → Connect → regional Redis.

ALO only. No chaos drill. No QoS profile comparison.

## Run it

```bash
cd labs/redis-redpanda-throughput-stress
cp .env.example .env             # optional
bash scripts/stress-run.sh       # default matrix: 6 tiers × 2 modes = 12 runs
```

Total wall-clock: ~10–15 min for the full default matrix. Each run writes `reports/{tier}-{mode}.json` and a summary table prints at the end.

### Subset runs

```bash
# Single tier + single mode (no auto-teardown)
bash scripts/stress-run.sh --tiers=50000 --modes=batch

# Multiple tiers, both modes
bash scripts/stress-run.sh --tiers=10000,20000

# All tiers, single mode only
bash scripts/stress-run.sh --modes=single
```

No-arg runs auto-teardown (`docker compose down -v`). Any explicit arg suppresses teardown.

### Knobs

| Env var       | Default | Effect                                        |
|---------------|---------|-----------------------------------------------|
| `DURATION_S`  | `30`    | sustain window per tier                       |
| `WARMUP_S`    | `5`     | half-rate warmup window                       |
| `DRAIN_S`     | `10`    | post-sustain drain window                     |
| `WORKERS`     | `16`    | writer goroutines                             |
| `BATCH_MAX`   | `500`   | ceiling on adaptive batch depth (batch mode)  |
| `PATTERN_WEIGHTS`     | `33,33,34` | per-write pattern weighted picker       |
| `PATTERN_CARDINALITY` | `20000`    | unique IDs per pattern                  |
| `PAYLOAD_BYTES` | `1024`| JSON pad bytes per event                      |
| `STREAM_MAXLEN` | `2000000` | central + region stream MAXLEN ~ cap      |
| `NATS_MAX_BYTES` | `5GB` | JetStream APP_EVENTS byte cap (raise for higher tiers) |
| `MAX_RATE`    | `60000` | hard ceiling on `POST /rate`                   |
| `INITIAL_MODE`| `batch` | starting write mode                            |

## Ports (host)

| Service           | Host port | Notes                                     |
|-------------------|-----------|-------------------------------------------|
| writer            | 18081     | `/healthz`, `/metrics`, `/rate`, `/reset` |
| redis-central     | 18379     | `redis-cli -p 18379`                      |
| redis-region      | 18380     | `redis-cli -p 18380`                      |
| nats (client)     | 18222     |                                           |
| nats (monitoring) | 18322     | `/jsz`, `/healthz`, `/varz`               |
| connect-source    | 18195     | `/ready`, `/metrics`                      |
| connect-sink      | 18196     | `/ready`, `/metrics`                      |

Coexists with `redis-multiregion-via-connect/` (15xxx), `redis-redpanda-qos-resilience/` (16xxx), and `redis-redpanda-connect-stress/` (17xxx).

## Resource caps

Per-container caps total ~29 CPU and ~9.25 GiB. On a 32-core / 122 GiB host that's <90% CPU and <8% RAM. See `docker-compose.yml` for per-service breakdown.

## Calibration mode (default)

`scripts/lib/tier-defs.sh` ships with `TIER_P99_MS` calibrated from a full-matrix run on a 32-core / 122 GiB host. All six tiers gate rate floor and `missing==0`; the p99 gate is enforced on tiers where the matrix produced a stable ceiling (5k, 10k, 20k, 30k, 40k) and skipped at 50k (ceiling tier — see below).

**Expected outcomes on the calibrated host:**

- Tiers 5k–30k: all `verdict.pass=true`.
- 40k single: PASS.
- 40k batch: `verdict.pass=false` is expected — the regional `region-events` stream (`MAXLEN=2M`) trims at this tier because the sink delivers more than the regional bound can hold. Documented research signal, not a regression.
- 50k both modes: `verdict.pass=false` is expected — the pipeline genuinely tops out around 40k single / 30k batch loss-free on this host. 50k records where the ceiling lives.

To recalibrate on a different host:

1. Run the full matrix at least once on the target host.
2. Inspect `reports/*.json` for `sync_latency_ms.p99` across both modes.
3. Pick ceilings (suggested: `round_up_to_100ms(max(p99_batch, p99_single) * 1.25)`).
4. Edit `TIER_P99_MS` in `scripts/lib/tier-defs.sh`.

After calibration, the harness gates all three: rate, missing, p99 (on tiers where p99 is gated).

## Live `/rate` endpoint

The writer's `POST /rate` accepts a JSON body `{ "rate": <int>, "mode": "batch"|"single" }`. Either field is optional — missing fields keep their current value.

```bash
curl -s -X POST -d '{"rate":35000,"mode":"single"}' \
  -H 'content-type: application/json' http://localhost:18081/rate
# -> {"rate":35000,"mode":"single"}
```

## Useful checks (between runs)

```bash
# Stream lengths
redis-cli -p 18379 XLEN app.events
redis-cli -p 18380 XLEN region-events

# JetStream
docker exec rrts-nats nats stream info APP_EVENTS

# Writer state
curl -s http://localhost:18081/metrics
curl -s -X POST -d '{"rate":0}' -H 'content-type: application/json' http://localhost:18081/rate

# Report fields
jq '.sync_latency_ms, .missing, .received_by_pattern, .verdict' reports/50000-batch.json
```

## Visual dashboard

After a matrix run, generate a self-contained HTML dashboard that compares batch vs single across all tiers — rate, packet loss, latency percentiles, and a full per-run table:

```bash
python3 scripts/dashboard.py
# Dashboard: 12 reports -> reports/dashboard.html
# Open:      file:///.../reports/dashboard.html
```

Open the printed `file://` URL in any browser. The HTML inlines all data (no server needed) and uses Chart.js from CDN. Regenerate after each matrix run; `reports/dashboard.html` is gitignored.

## Tear down

```bash
docker compose down -v
```

## Further reading

- [`RESEARCH.md`](RESEARCH.md) — design rationale.
- Parent: [`../redis-redpanda-connect-stress/`](../redis-redpanda-connect-stress/) — QoS-aware stress with 3 profiles and chaos drills.
- Design spec: `docs/superpowers/specs/2026-05-26-redis-redpanda-throughput-stress-design.md`.
- Implementation plan: `docs/superpowers/plans/2026-05-26-redis-redpanda-throughput-stress.md`.
