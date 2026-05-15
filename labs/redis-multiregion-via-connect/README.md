# Redis Multiregion via Redpanda Connect

End-to-end demo: KV writes on a "central" Redis are propagated to a "region"
Redis through a **Redpanda Connect → NATS JetStream → Redpanda Connect** bridge.
A Go writer drives the central side; a live web dashboard shows per-key state
on both sides and measures SET-to-SET propagation delay.

See [`RESEARCH.md`](RESEARCH.md) for design and references.

## Architecture

```
writer (Go) ──MULTI: SET+XADD──▶ redis-central
                                        │
                          redis_streams │  body_key=value, group=propagator
                                        ▼
                                 connect-forward ──nats_jetstream──▶ NATS APP_EVENTS
                                                                        │
                                                                  subject app.events.>
                                                                  Nats-Msg-Id dedup
                                                                        ▼
                                                                 connect-reverse
                                                                        │
                                                                redis: SET key value
                                                                        ▼
                                                                  redis-region
                                                                        │
        dashboard (Go) ◀── PSUBSCRIBE __keyspace@0__:lb:* on BOTH redises
                          (computes delta_ms = now() − t_send_ms)
```

## Run

```bash
cd labs/redis-multiregion-via-connect
docker compose up -d --build
```

Then open <http://127.0.0.1:15080/>.

The writer cycles through 9 keys (3 patterns × 3 keys each) at 1 Hz. You should
see central-side entries appear immediately and region-side entries follow a
few hundred ms later.

## Smoke test

```bash
bash scripts/smoke-test.sh
```

Asserts the *property*: all 9 keys propagate to region, plus three probe writes
land within `PROBE_BUDGET_MS` (default 3000 ms).

## Tear down

```bash
docker compose down -v
```

## Ports (host)

| Service           | Host port | Notes                              |
|-------------------|-----------|------------------------------------|
| dashboard (HTTP)  | 15080     | live UI + WebSocket `/ws`          |
| redis-central     | 15379     | `redis-cli -p 15379`               |
| redis-region      | 15380     | `redis-cli -p 15380`               |
| nats              | 15222     | NATS client                        |
| nats monitoring   | 18222     | `/healthz`, `/varz`                |
| connect-forward   | 15195     | `/ready`, `/metrics`               |
| connect-reverse   | 15196     | `/ready`, `/metrics`               |

## Useful checks

```bash
# Central stream + group state
redis-cli -p 15379 XLEN app.events
redis-cli -p 15379 XINFO GROUPS app.events

# JetStream
docker exec rmvc-nats nats stream info APP_EVENTS

# Connect health
curl -s http://localhost:15195/ready
curl -s http://localhost:15196/ready

# Compare central vs region for one key
redis-cli -p 15379 GET lb:company:employees:id:55688
redis-cli -p 15380 GET lb:company:employees:id:55688
```

## Configuration knobs

| Env / setting               | Where                           | Default | Effect                                  |
|-----------------------------|---------------------------------|---------|-----------------------------------------|
| `WRITE_INTERVAL_MS`         | `writer` env                    | 1000    | writer tick period                      |
| `WAIT_FOR_FILL_S`           | `scripts/smoke-test.sh` env     | 12      | wait before checking writer output      |
| `PROBE_BUDGET_MS`           | `scripts/smoke-test.sh` env     | 3000    | per-probe propagation budget            |
| `--dupe-window 5m`          | `nats-init` command             | 5m      | JetStream dedup horizon                 |
| `commit_period: 200ms`      | `connect/forward.yaml`          | 200ms   | XACK flush cadence on central stream    |
| `max_in_flight: 256`        | `connect/forward.yaml`          | 256     | async JetStream publish parallelism     |
