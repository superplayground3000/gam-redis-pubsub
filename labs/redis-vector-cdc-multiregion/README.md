# redis-vector-cdc-multiregion

## What this demonstrates

KV updates written to a *central* Redis appear on a *region* Redis through the path **central-redis → Redis Stream → Go sidecar → Vector → NATS JetStream → Go consumer → region-redis**, with each key's end-to-end propagation delay observable live in a browser dashboard.

## Run it

```bash
cp .env.example .env       # only if you want to override defaults
docker compose up -d --wait

# Open the dashboard
xdg-open http://localhost:15500    # Linux
open      http://localhost:15500   # macOS
```

The dashboard shows the 9 tracked KVs side-by-side (central vs region), a rolling count of propagated events, and per-event propagation delay in milliseconds. Rows that have not yet caught up are highlighted in red; in-sync rows are green.

```bash
# Follow the bridge in real time
docker compose logs -f relay-publish relay-consume

# Peek at JetStream
docker compose exec nats sh -c 'wget -qO- http://localhost:8222/jsz?streams=true' | head -c 400

# Manually mutate central, watch region catch up
docker compose exec central-redis redis-cli SET "lb:company:employees:id:55688" '{"counter":999,"updated_at_ns":0}'
docker compose exec region-redis  redis-cli GET "lb:company:employees:id:55688"
```

> Note: the dashboard's match column reports `lagging` immediately after a manual `SET` until the producer's next tick puts a fresh entry into the stream (which then propagates to region). The producer is the only thing that XADDs to `cdc:events`; raw `SET`s bypass the CDC pipeline by design.

## Expected output

`docker compose ps` after `up --wait` shows every service healthy:

```
NAME                                              STATUS
lab-redis-vector-cdc-multiregion-central-redis-1  Up (healthy)
lab-redis-vector-cdc-multiregion-dashboard-1      Up (healthy)
lab-redis-vector-cdc-multiregion-nats-1           Up (healthy)
lab-redis-vector-cdc-multiregion-producer-1       Up (healthy)
lab-redis-vector-cdc-multiregion-region-redis-1   Up (healthy)
lab-redis-vector-cdc-multiregion-relay-consume-1  Up (healthy)
lab-redis-vector-cdc-multiregion-relay-publish-1  Up (healthy)
lab-redis-vector-cdc-multiregion-vector-1         Up (healthy)
```

`docker compose logs relay-consume` shows applies with per-event delay:

```
time=... level=INFO msg=applied n=1  subject=cdc.employees.55688 delay_ms=18
time=... level=INFO msg=applied n=2  subject=cdc.employees.55689 delay_ms=22
time=... level=INFO msg=applied n=3  subject=cdc.employees.55690 delay_ms=19
...
```

Smoke output ends with a single sentence summarizing what was observed:

```
PASS: 9/9 tracked keys propagated from central-redis through Vector + JetStream to region-redis,
      JetStream stream contains 27 messages, dashboard reports all-in-sync,
      max observed propagation delay = 41 ms.
```

## Teardown

```bash
docker compose down -v
```

## Validating

```bash
bash /home/hp/.claude/skills/research-lab/scripts/validate_lab.sh \
  labs/redis-vector-cdc-multiregion
```

Exit 0 ⇒ the property is demonstrated end-to-end.

## Further reading

- `RESEARCH.md` — design decisions, wire contract, and what was deliberately excluded.
- `../../redis-vector-js/redis-vector-js-research.md` — the reference deep-dive that motivated the architecture (Vector's lack of a Redis Streams source, the sidecar approach, JetStream subject design).
- Vector NATS sink — <https://vector.dev/docs/reference/configuration/sinks/nats/>
- Redis Streams + consumer groups — <https://redis.io/docs/latest/develop/data-types/streams/>
- NATS JetStream concepts — <https://docs.nats.io/nats-concepts/jetstream>
- Sibling lab `labs/redis-cdc-via-jetstream/` — same family without Vector or the dashboard.
