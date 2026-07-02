# connect-stream-delete-drain

## What this demonstrates

`hpdevelop/connect:v4.92.0-batch-nats` in JetStream pull-consumer bind mode loses no
messages across stream close (Streams `DELETE`, `SIGTERM`, `SIGKILL`); drain-on-close is
bounded by `fetch_batch_size` (fb=1 is drain-clean; larger fb replays more on close but
never loses). The build never acks a message before its Redis apply, so anything
fetched-but-unapplied at close is left un-acked and redelivered.

## Run it

```bash
cp .env.example .env
bash scripts/smoke-test.sh          # KEEP=1 leaves the stack up; override any .env var inline
```

`smoke-test.sh` first runs preflight **Controls A/B** that abort loud if the build's
`throw`⇒nack semantics or the `nats_num_delivered` gate don't hold — so no experiment is
trusted without validating the build in the same run. It then runs four experiments
(apply-fault / `DELETE` / `SIGTERM` / `SIGKILL`) across a `fetch_batch_size` sweep, driving
closes from the host and verifying every key is present carrying its own `event_id`.

## Expected output

```
PREFLIGHT PASSED — controls validate the build+harness
### fetch_batch_size=1
  exp1 ... abandoned un-acked=0        <- drain-clean
  VERIFY keys=120 missing=0 mismatch=0 ... RESULT: NO-LOSS
### fetch_batch_size=16
  exp1 ... abandoned un-acked=15
### fetch_batch_size=256
  exp1 ... abandoned un-acked=117      <- redelivery window ≈ fetch_batch_size
SMOKE-PASS: no message loss across DELETE/SIGTERM/SIGKILL for all fetch_batch_size in {1,16,256}.
```

Every experiment prints `RESULT: NO-LOSS` with `missing=0 mismatch=0`; `abandoned un-acked`
grows with `fetch_batch_size` while the region set stays complete and identity-correct.

## Teardown

```bash
docker compose down -v
```

## Further reading

- `RESEARCH.md` — design + the seven-round Codex review that shaped the causal oracle.
- `PROBE-FINDINGS.md` — measured build behavior (why `DELETE`/`SIGTERM` don't drain the batch).
- `probe/` — the throwaway probe scripts that established those facts.
