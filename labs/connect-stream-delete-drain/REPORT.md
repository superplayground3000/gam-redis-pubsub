# connect-stream-delete-drain — Result Report

## The question

When a leader handover deletes Connect's streams-mode pipeline
(`DELETE /streams/<id>` — exactly what `redis-cdc-le-k8s/internal/elector` does on
`OnStoppedLeading`), are messages **already received into Connect** but not yet
applied to Redis lost? Two modes to distinguish:

- **applied-but-not-acked** ("處理完沒 ack") → JetStream redelivers after
  `ack_wait` → duplicate, absorbed by idempotent `SET` (safe).
- **acked-but-not-applied** ("ack 了但實際沒做完") → gone from JetStream, never
  reached Redis → **true loss**. The failure we hunt.

## Method

Isolated topology — NATS JetStream → one Redpanda Connect (streams mode) → Redis
— driven by the **real REST `DELETE`**. Each message `i` does `SET kv:<i>` **and**
`INCR applied:<i>` after a per-message `sleep` (the controllable in-flight
window). Loss is made *loud*: a lost message is a **missing index**
(`applied:<i> == 0`) with a fully-drained consumer — it cannot hide behind
idempotent `SET`. The DELETE fires only after a **confirm-poll** proves a cohort
of `>= MIN_INFLIGHT` messages is *stably parked* inside Connect, so the teardown
genuinely lands mid-flight (not on an already-drained pipeline).

## Results (both PASS, empirically validated)

| Profile | N | Publish | In-flight at DELETE | Lost | Duplicates | Verdict |
|---|---|---|---|---|---|---|
| deterministic | 60 | burst | 2 | `[]` | 0 | PASS (`validate_lab.sh` exit 0) |
| throughput | 20,000 | 5,000/s | 9 (≥ MIN_INFLIGHT=4) | `[]` | 0 | PASS |

```
RESULT_JSON {"profile":"deterministic","n":60,"inflight_at_delete":2,"lost":[],"dup_count":0,"drained":true,"verdict":{"pass":true}}
RESULT_JSON {"profile":"throughput","n":20000,"inflight_at_delete":9,"lost":[],"dup_count":0,"drained":true,"verdict":{"pass":true}}
```

## Answer

**No message loss.** Across both a quiet handover and a 20k-msg / 5k-per-sec
firehose handover, `lost:[]` every time — **Connect drains the messages it has
already fetched (finishes apply + ack) before the stream teardown completes**,
rather than dropping them. In these runs `dup_count:0` as well, meaning the
in-flight cohort drained cleanly *without* even needing redelivery. There was
**no acked-but-not-applied case** — the dangerous mode is not observed.

## Key empirical finding (load-bearing for interpretation)

The messages actually held *inside* Connect at any instant (`num_ack_pending`) ≈
**`pipeline.threads`** — the JetStream pull(bind) input fetches roughly one
message per thread; the rest of the firehose stays as undelivered **NATS
backlog**, never at risk during a DELETE. So "already received by Connect" is a
small per-pod cohort (~threads), which is exactly the handover-loss zone — and
that cohort is conserved.

## Caveats (honest scope)

- Isolates **Connect's graceful-shutdown on REST DELETE** — does *not* model a
  `SIGKILL` / pod-kill handover (deferred; would need a freezable Redis valve).
  The k8s elector uses REST DELETE, so this matches the real mechanism.
- `inflight_at_delete` is a pre-DELETE snapshot; the confirm-poll closes the
  drain race to confirm-poll granularity (residual is sub-RTT).
- Result is "no loss observed under these conditions" — strong evidence, not a
  formal proof. `pipeline.threads > 1` can also produce (idempotent) duplicates,
  which the harness counts rather than fails.

## Reproduce

```bash
cd labs/connect-stream-delete-drain
./scripts/smoke-test.sh                    # deterministic, asserts verdict.pass

# throughput (firehose handover):
docker compose up -d --build nats redis connect
docker compose run --rm \
  -e PROFILE=throughput -e MSG_COUNT=20000 -e PUBLISH_RATE=5000 \
  -e SLEEP_MS=25 -e PIPELINE_THREADS=8 -e ARM_INFLIGHT=200 \
  -e MAX_ACK_PENDING=1000 -e MIN_INFLIGHT=4 controller
docker compose down -v
```

Full design and the per-knob rationale: `RESEARCH.md`.
Next step (separate): phase-2 end-to-end handover verifier inside
`redis-cdc-le-k8s` during a real leader flip.
