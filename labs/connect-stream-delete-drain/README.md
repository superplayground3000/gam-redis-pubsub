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

High-throughput run (DELETE mid-firehose, confirmed stably-parked cohort):

```bash
docker compose run --rm \
  -e PROFILE=throughput -e MSG_COUNT=20000 -e PUBLISH_RATE=5000 \
  -e SLEEP_MS=25 -e PIPELINE_THREADS=8 -e ARM_INFLIGHT=200 \
  -e MAX_ACK_PENDING=1000 -e MIN_INFLIGHT=4 \
  controller
```

`MIN_INFLIGHT=4` with `PIPELINE_THREADS=8` requires at least 4 messages to be
simultaneously in-flight inside Connect at both the first and confirm poll before
DELETE fires — proving the DELETE lands over a real multi-message cohort, not a
transient single message. The confirm-poll delay is `max(20ms, min(SLEEP_MS/4,
100ms))` = 20ms with `SLEEP_MS=25`, which stays inside the per-message sleep window.

## Knobs

See `.env.example`. Key ones: `PROFILE`, `MSG_COUNT`, `SLEEP_MS` (in-flight
window), `PIPELINE_THREADS`, `ACK_WAIT` (redelivery healing), `ARM_FRACTION` /
`ARM_INFLIGHT` (when DELETE fires), `MIN_INFLIGHT` (cohort size confirmed across
two polls; default 1 for deterministic, recommend 4 for throughput with threads=8).

## Ports

NATS 15422, Redis 16379, Connect 14195, controller health 18080.

## Verdict

`RESULT_JSON {profile, n, inflight_at_delete, lost[], dup_count, drained,
verdict:{pass}}`. PASS requires zero loss, a fully drained consumer, and a
non-zero in-flight cohort at DELETE time (else the run is inconclusive and FAILs).

See `RESEARCH.md` for the full design and the relationship to `redis-cdc-le-k8s`.
