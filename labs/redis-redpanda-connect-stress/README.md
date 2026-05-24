# redis-redpanda-connect-stress

Stress-test harness for the Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis pipeline. Forked from [`../redis-redpanda-qos-resilience/`](../redis-redpanda-qos-resilience/); both labs can run side by side.

## What this demonstrates

Three QoS-aware behaviors at three throughput tiers (10, 1 000, 10 000 msg/s):

1. **Throughput** — pipeline sustains target rate end-to-end.
2. **Latency** — e2e p99 stays within a tier-specific SLO (200 ms / 1 s / 5 s).
3. **Chaos resilience** — a mid-run `connect-sink` kill does not violate QoS (zero loss under ALO/EOE; bounded loss under AMO).

See [`RESEARCH.md`](RESEARCH.md) for design rationale.

## Run it

```bash
cd labs/redis-redpanda-connect-stress
cp .env.example .env              # optional; defaults work
bash scripts/stress-run.sh        # full default matrix (3 tiers × 3 modes, alo)
```

Total time: ~7–10 min wall-clock for the full default matrix. Each per-tier run writes a JSON report to `reports/{tier}-{mode}-{profile}.json` and the harness prints a summary table at the end.

### Subset runs

```bash
# Single tier + single mode (no auto-teardown)
bash scripts/stress-run.sh --tiers=10000 --modes=chaos

# Multiple modes at one tier
bash scripts/stress-run.sh --tiers=1000 --modes=throughput,latency

# Different QoS profile
bash scripts/stress-run.sh --profile=eoe
```

A no-arg run is treated as a full matrix and auto-tears down at the end (`docker compose down -v`). Any argument (including just `--profile=`) suppresses teardown so you can inspect state.

### Knobs

| Env var       | Default | Effect                                        |
|---------------|---------|-----------------------------------------------|
| `DURATION_S`  | `30`    | sustain window per tier                       |
| `WARMUP_S`    | `5`     | half-rate warmup window                       |
| `DRAIN_S`     | `10`    | post-sustain drain window                     |
| `CHAOS_DOWN_S`| `8`     | how long `connect-sink` is stopped for chaos  |
| `PROFILE_QOS` | `alo`   | which Connect YAMLs are mounted               |
| `WORKERS`     | `8`     | writer goroutines                             |

## Ports (host)

| Service           | Host port | Notes                              |
|-------------------|-----------|------------------------------------|
| writer            | 17081     | `/healthz`, `/metrics`, `/rate`, `/reset` |
| redis-central     | 17379     | `redis-cli -p 17379`               |
| redis-region      | 17380     | `redis-cli -p 17380`               |
| nats (client)     | 17222     |                                    |
| nats (monitoring) | 17322     | `/jsz`, `/healthz`, `/varz`        |
| connect-source    | 17195     | `/ready`, `/metrics`               |
| connect-sink      | 17196     | `/ready`, `/metrics`               |

Coexists with `redis-multiregion-via-connect/` (15xxx) and `redis-redpanda-qos-resilience/` (16xxx).

## Resource caps

Every container has a hard CPU+memory limit; total ceiling is ~12.5 CPU and ~4.4 GiB RAM. On a 32-core / 122 GiB host this is <40% CPU and <4% RAM. Lower the caps in `docker-compose.yml` if running on a weaker host — but doing so may invalidate the published SLOs.

## Verifying the lab

```bash
# 1. Boot smoke
docker compose up -d --wait

# 2. Sanity tier
bash scripts/stress-run.sh --tiers=10 --modes=throughput

# 3. Mid tier with latency check
bash scripts/stress-run.sh --tiers=1000 --modes=throughput,latency

# 4. Full matrix
bash scripts/stress-run.sh
```

During the 10 k chaos run, in another shell, `uptime` should show 1-min load average < 16 on a 32-core host — confirming CPU caps are honored.

## Known limitations

- **Chaos timing is anchored to harness wall-clock, not collector sustain start**. There is up to ~3 s of drift due to `docker compose run` container startup. For DURATION_S=30 this is acceptable. If you tighten DURATION_S below 15 s, chaos timing accuracy degrades.
- **`region-events` stream is now capped at MAXLEN ~ 100000**: messages older than ~30 seconds at 10 k/s get trimmed. This matters only if a chaos outage exceeds ~30 s at 10 k/s — then the region tail can be lost. For DURATION_S=30 + CHAOS_DOWN_S=8 it's never a problem.
- **`CHAOS_DOWN_S` is the scripted sleep, not the true outage**: actual `connect-sink` unavailability also includes `docker stop` shutdown time (~1 s) + `docker start` + healthcheck readiness (~3-5 s). The chaos script now waits for the healthy status before returning, so the harness's chaos-window measurement is consistent — but the *reported* `down_at_s` in the JSON report reflects the harness wall-clock decision point, not the precise outage span.
- **JetStream stream config is sticky**: `nats-init` skips `stream add` if `APP_EVENTS` already exists. If you change `--max-bytes` in the compose file, run `docker compose down -v` to clear the named volume before restarting.
- **Connect Prometheus metrics**: the collector sums across all label variants of a given metric. If Redpanda Connect adds new labeled dimensions in a future version, totals stay correct.

## Useful checks (between runs)

```bash
# Stream lengths
redis-cli -p 17379 XLEN app.events
redis-cli -p 17380 XLEN region-events

# JetStream
docker exec rrcs-nats nats stream info APP_EVENTS

# Writer live state
curl -s http://localhost:17081/metrics
curl -s -X POST -d '{"rate":0}' -H 'content-type: application/json' http://localhost:17081/rate
```

## Tear down

```bash
docker compose down -v
```

## Further reading

- [`RESEARCH.md`](RESEARCH.md) — design rationale, what stress proves, links to the design spec.
- [`../redis-redpanda-qos-resilience/`](../redis-redpanda-qos-resilience/) — the parent lab (per-key visibility, no stress).
- Design spec: `docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md`.
- Implementation plan: `docs/superpowers/plans/2026-05-24-redis-redpanda-connect-stress.md`.
