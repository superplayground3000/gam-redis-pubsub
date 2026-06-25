# connect-stream-delete-drain

Does deleting a Redpanda Connect streams-mode pipeline mid-flight (the teardown
the leader elector runs on handover) lose messages? This lab answers it in
isolation: NATS JetStream -> one Connect (streams mode) -> Redis, with a controller
that fires `DELETE /streams` while a batch is in-flight and reconciles a per-key
ledger.

## Property

When `DELETE /streams/<id>` tears down the pipeline while messages are fetched
but not yet applied to Redis, **no message is acked-without-apply (lost)**. Each
in-flight message is either drained-and-applied or left un-acked and healed by
JetStream redelivery (a duplicate, absorbed by idempotent `SET`).

- `applied:<i> == 0` with a drained consumer -> **LOST** (the failure).
- `applied:<i> >= 2` -> redelivered duplicate (reported, not a failure).

## Run

```bash
cp .env.example .env
./scripts/smoke-test.sh          # deterministic profile, asserts verdict PASS
```

High-throughput run (DELETE mid-firehose):

```bash
# edit .env: PROFILE=throughput MSG_COUNT=20000 PUBLISH_RATE=5000 \
#            SLEEP_MS=25 PIPELINE_THREADS=8 ARM_INFLIGHT=200
docker compose run --rm controller
```

## Knobs

See `.env.example`. Key ones: `PROFILE`, `MSG_COUNT`, `SLEEP_MS` (in-flight
window), `PIPELINE_THREADS`, `ACK_WAIT` (redelivery healing), `ARM_FRACTION` /
`ARM_INFLIGHT` (when DELETE fires).

## Ports

NATS 15422, Redis 16379, Connect 14195, controller health 18080.

## Verdict

`RESULT_JSON {profile, n, inflight_at_delete, lost[], dup_count, drained,
verdict:{pass}}`. PASS requires zero loss, a fully drained consumer, and a
non-zero in-flight cohort at DELETE time (else the run is inconclusive and FAILs).

See `RESEARCH.md` for the full design and the relationship to `redis-cdc-le-k8s`.
