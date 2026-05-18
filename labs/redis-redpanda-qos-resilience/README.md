# redis-redpanda-qos-resilience

End-to-end Redis-stream → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis pipeline with **switchable QoS profiles** and **scripted chaos drills**. Builds on (and runs alongside) [`../redis-multiregion-via-connect/`](../redis-multiregion-via-connect/).

## What this demonstrates

Under the default `PROFILE_QOS=alo` profile, every `event_id` written to `app.events` on central Redis reaches `region-events` on region Redis within a bounded window — even when `connect-sink` is killed mid-flight for ~8 seconds. Switching profiles (`amo` / `eoe`) and re-running the same chaos drill makes loss (AMO) and exact dedup (EOE) directly observable in the same `region-events` ledger.

See [`RESEARCH.md`](RESEARCH.md) for the wire contract, QoS specifics, and design decisions.

## Architecture

```
writer (Go) ──MULTI: SET+XADD──▶ redis-central ──redis_streams──▶ connect-source
                                                                       │
                                                            nats_jetstream
                                                              Nats-Msg-Id
                                                                       ▼
                                                              NATS APP_EVENTS
                                                              (file, R=1, dedup 5m)
                                                                       │
                                                                       ▼
                                            connect-sink (durable: region-writer)
                                                  │
                                  EOE only: cache_add event:<id> (SET NX EX)
                                                  │
                                                  ▼
                                       broker fan_out → redis-region
                                                  ├── SET <key> <value>
                                                  └── XADD region-events ...
                                                  │
       dashboard (Go) ◀── PSUBSCRIBE __keyspace@0__:lb:* on BOTH redises
                          + XLEN poll of app.events / region-events
                          (Prometheus /metrics + WebSocket UI)
```

## Run it

```bash
cd labs/redis-redpanda-qos-resilience
cp .env.example .env              # optional; defaults work
docker compose up -d --wait
open http://127.0.0.1:16080/      # live dashboard
```

The writer cycles through 9 keys (3 patterns × 3 keys each) at 1 Hz by default. The dashboard shows per-pattern propagation p50/p95, last-value-per-key central vs region, and `XLEN(app.events)` vs `XLEN(region-events)` so loss/duplicates are visible at a glance.

## Switch QoS profile

Edit `.env` (or set the env var inline) and recreate the two Connect containers — Redis and NATS state survive the flip:

```bash
PROFILE_QOS=eoe docker compose up -d --force-recreate connect-source connect-sink
```

| Profile | Forward | Reverse | After 10s `connect-sink` outage |
|---|---|---|---|
| `alo` (default) | consumer group + `Nats-Msg-Id` | **durable** `region-writer`, ack-explicit, `deliver: all` | missing = 0, duplicates ≥ 0 (usually 0 — JS dedup absorbs) |
| `amo` | no `Nats-Msg-Id`, `auto_replay_nacks: false` | **ephemeral**, `deliver: new`, `ack_wait: 2s` | missing > 0 (~outage_s × 1/s), duplicates = 0 |
| `eoe` | same as ALO | ALO + `cache add event:<id>` gate (SET NX EX) | missing = 0, duplicates = 0 |

## Smoke test (the property)

```bash
bash scripts/smoke-test.sh
```

Boots, waits for steady state, kills `connect-sink` for `CHAOS_DOWN_S` (default 8s), waits `CHAOS_CATCHUP_S` (default 15s), then runs `scripts/chaos/compare-streams.sh` and asserts `missing in region = 0`. Exit 0 means the property held.

To also assert "zero duplicates" (the stronger EOE property), recreate with EOE and rerun:
```bash
PROFILE_QOS=eoe docker compose up -d --force-recreate connect-source connect-sink
sleep 5
bash scripts/chaos/compare-streams.sh
# Expect:  duplicate event_ids region : 0
```

## Chaos drills

All scripts take a single optional `DOWNTIME_S` arg (default 10s); the named container is stopped, slept, and started.

```bash
bash scripts/chaos/kill-connect-source.sh 8
bash scripts/chaos/kill-connect-sink.sh   8
bash scripts/chaos/kill-nats.sh           8
bash scripts/chaos/kill-region-redis.sh   8
bash scripts/chaos/compare-streams.sh        # audit after any drill
```

## Tear down

```bash
docker compose down -v
```

## Ports (host)

| Service           | Host port | Notes                              |
|-------------------|-----------|------------------------------------|
| dashboard (HTTP)  | 16080     | UI + `/ws` + `/metrics`            |
| writer            | 16081     | `/healthz` + `/metrics`            |
| redis-central     | 16379     | `redis-cli -p 16379`               |
| redis-region      | 16380     | `redis-cli -p 16380`               |
| nats (client)     | 16222     |                                    |
| nats (monitoring) | 18322     | `/healthz`, `/varz`, `/jsz`        |
| connect-source    | 16195     | `/ready`, `/metrics`               |
| connect-sink      | 16196     | `/ready`, `/metrics`               |

These do not collide with `labs/redis-multiregion-via-connect/` (15xxx), so both labs can run side-by-side.

## Metrics quick reference

```bash
# Writer counters
curl -s http://127.0.0.1:16081/metrics | grep rrqr_writer_

# Dashboard histograms + stream-length gauges
curl -s http://127.0.0.1:16080/metrics | grep rrqr_

# Connect (per leg)
curl -s http://127.0.0.1:16195/metrics | head
curl -s http://127.0.0.1:16196/metrics | head

# NATS / JetStream
curl -s http://127.0.0.1:18322/jsz
```

## Useful checks

```bash
# Stream lengths
redis-cli -p 16379 XLEN app.events
redis-cli -p 16380 XLEN region-events

# JetStream
docker exec rrqr-nats nats stream info APP_EVENTS

# Connect readiness
curl -s http://localhost:16195/ready
curl -s http://localhost:16196/ready

# EOE-only: how many event_ids have been gated
redis-cli -p 16380 KEYS 'event:*' | wc -l
```

## Configuration knobs

| Env / setting               | Where                    | Default | Effect                                       |
|-----------------------------|--------------------------|---------|----------------------------------------------|
| `PROFILE_QOS`               | `.env` / compose env     | `alo`   | which YAML pair Connect mounts                |
| `WRITE_INTERVAL_MS`         | `.env` / writer env      | 1000    | writer tick                                   |
| `CHAOS_DOWN_S`              | `.env` / smoke-test env  | 8       | how long to stop connect-sink in the drill    |
| `CHAOS_CATCHUP_S`           | `.env` / smoke-test env  | 15      | how long to wait for catch-up                 |
| `--dupe-window 5m`          | `nats-init` command      | 5m      | JetStream dedup horizon                       |
| `commit_period`             | `connect/*-forward.yaml` | 200ms / 50ms | XACK flush cadence                       |

## Further reading

- [`RESEARCH.md`](RESEARCH.md) — design + wire contract.
- [Redpanda Connect docs](https://docs.redpanda.com/redpanda-connect/about/) — input/output/processor/cache reference.
- [NATS JetStream concepts](https://docs.nats.io/nats-concepts/jetstream) — streams, consumers, deduplication.
- [`../redis-multiregion-via-connect/`](../redis-multiregion-via-connect/) — the simpler baseline this lab extends.
- [`../../redis-redpanda-design-ptr/research.md`](../../redis-redpanda-design-ptr/research.md) — production-architecture deep dive that informed the design.
