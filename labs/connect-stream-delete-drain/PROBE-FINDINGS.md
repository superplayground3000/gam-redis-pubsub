# Probe findings — hpdevelop/connect:v4.92.0-batch-nats

Empirical results from `probe/` (run 2026-07-02) that resolve the design's
"still to confirm in Stage 4" unknowns **before** building the full lab. Each
was measured, not assumed.

## Summary answer to the two requirements

- **"pull consumer mode 沒有 msg loss" — ✅ CONFIRMED.** The build never acks a
  message before its apply. Messages fetched-but-unprocessed at close are left
  **un-acked**, so they redeliver and eventually apply. No loss on any close path.
- **"stream 關閉時把手上的 msg 作完並且 ack" — ⚠️ QUALIFIED.** On stream close the
  build does **not** drain-and-ack the whole in-hand (prefetched) batch. Only the
  message(s) actively in the pipeline finish; the rest of the `fetch_batch_size`
  prefetch is **abandoned un-acked** and recovered by *redelivery*, not by drain.
  It is effectively drain-clean **only at `fetch_batch_size: 1`**. Still no loss
  either way — the recovery path is redelivery of un-acked messages.

## Confirmed facts

| # | Question | Result |
|---|---|---|
| P1 | Delivery-count metadata key | **`nats_num_delivered`** (string). Full set: `nats_consumer`, `nats_num_delivered`, `nats_num_pending`, `nats_sequence_consumer`, `nats_sequence_stream`, `nats_subject`, `nats_timestamp_unix_nano`. |
| P2 | `throw` under `reject_errored.drop` ⇒ nack or drop-ack? | **NACK ⇒ redelivery** (the causal hinge holds). Caveat: an explicit nack triggers **immediate** redelivery with *no* `ack_wait` backoff — an always-faulting msg spins a hot loop (~19k redeliveries/s). |
| P3/D1 | `DELETE /streams/{id}` drains? blocking? | **No drain, non-blocking.** Returns in ~0.3–0.4s; abandons the prefetched in-flight set un-acked (27/29 at fb=256). Re-POST ⇒ they redeliver and apply (`ack_floor` climbs to N) ⇒ **no loss**. |
| D2 | `SIGTERM` (shutdown_timeout=20s) drains? | **No** — `docker stop -t 30` exited in 0.6s, abandoning 17/19 un-acked. `shutdown_timeout` does not drain the input's prefetch buffer. No loss (redelivered on restart). |
| FB | Does `fetch_batch_size` govern the un-acked-on-close window? | **Yes, directly.** fb=1 ⇒ ~1 abandoned on DELETE (drain-clean); fb=256 ⇒ ~23 abandoned. This is the central knob. |
| Batch knob | Input batch config field | **`fetch_batch_size`** (default 10) on the `nats_jetstream` input — this *is* the "batch-nats" feature. |

## Mental model (why close doesn't drain a big batch)

The `nats_jetstream` input **prefetches** up to `fetch_batch_size` messages in one
pull — the server marks them delivered immediately (`num_ack_pending` jumps to the
batch size) — then the pipeline (`threads:1`) applies them one at a time. On close
(DELETE or SIGTERM) the input stops; only the message(s) already handed to the
pipeline finish and ack. The rest of the prefetch buffer is discarded **un-acked**
(correctly — they were never applied), and JetStream redelivers them to the next
bound consumer. So:

- **Safety (no loss):** guaranteed — un-acked, never acked-before-apply.
- **Drain-on-close:** only as small as `fetch_batch_size`. Large batch ⇒ large
  redelivery window on close; `fetch_batch_size:1` ⇒ at most one redelivered.

## Design impact (folded into RESEARCH.md)

1. **Scenario 1 (`DELETE`) expectation corrected.** The original "region reaches N
   with `applied:*==1`, zero redeliveries" is only true at `fetch_batch_size:1`.
   At larger batches the correct assertion is **no loss** (all N present with
   correct `event_id` after re-bind), with a **redelivery window ≈ prefetched
   in-flight** — and the lab should *demonstrate* redelivery scales with
   `fetch_batch_size` rather than treating any redelivery as failure.
2. **`fetch_batch_size` is a first-class lab parameter** (`.env`), swept to show
   the drain-window / redelivery tradeoff. `1` = drain-clean-on-close; large =
   throughput but a bigger redelivery blip on every close/failover.
3. **Fault gate uses `meta("nats_num_delivered")`** (confirmed key).
4. **Control A (always-fault) must be bounded** — it hot-loops; observe redelivery
   briefly then purge, or cap with a finite `max_deliver`, to avoid a CPU spin.
5. **Elector interaction (chart-level).** The elector's `DELETE` on leadership loss
   returns fast (~0.4s) and does **not** drain; the new leader redelivers the
   abandoned batch. No loss, but every failover replays up to `fetch_batch_size`
   messages — relevant to the chart's 5s DELETE HTTP timeout being ample (no drain
   to wait for) and to sizing `fetch_batch_size` in production.

## How to reproduce

```bash
cd probe
bash run-probes.sh        # P1 meta key, P2 throw⇒nack, P3 DELETE non-drain
bash run-drain-probe.sh   # D1 DELETE + redelivery recovery, D2 SIGTERM
bash run-fb1-probe.sh     # fetch_batch_size 1 vs 256 close window
```
