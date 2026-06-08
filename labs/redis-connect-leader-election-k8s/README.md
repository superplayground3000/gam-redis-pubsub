# redis-connect-lww-k8s

## What this demonstrates

A stale change (lower version) can never overwrite a newer change at the Redis KV
sink, regardless of arrival order across a parallel pipeline — proven end-to-end on
Kubernetes, plus the single-instance sustained applied-write throughput.

Kubernetes/Helm fork of `../redis-redpanda-connect-stress-k8s`. The only data-path
change is at the sink: a blind `SET` becomes a version-gated **last-write-wins
compare-and-set** (a Redis Lua `EVAL`). The sink deliberately runs parallel
(`threads: 4`, source `max_in_flight: 256`) so same-key messages reorder — and the
fence makes the final per-key state correct anyway. Mechanism is from
`../../last-write-wins-lab/research.md`.

## Run it (kind)

```bash
# (NATS auth fixtures are committed under chart/files/nats-auth/; regenerate only
#  on a fresh checkout if missing: scripts/gen-nats-auth.sh)
kind create cluster --name lww
scripts/build-images.sh --kind --kind-name=lww     # build writer/verifier/dashboard, load into kind
scripts/verify-lww.sh                              # Proof A + Proof B; prints throughput + verdict
```

Tune the run with env vars: `RATE=20000 DURATION_S=30 scripts/verify-lww.sh`
(defaults: RATE=5000, DURATION_S=30, WARMUP_S=5, DRAIN_S=10 — see `scripts/lib/run-defaults.sh`).

Watch it live in a browser:

```bash
scripts/dashboard-forward.sh        # binds --address 0.0.0.0; prints LAN URLs
# open http://<host>:8080  → live key/version/value stream + applied/stale-fenced/duplicate counters
```

## Expected output

`verify-lww.sh` exits 0 only when both proofs pass:

```
[proofA] results (want: 1 0 0 -1 3 v3): 1 0 0 -1 3 v3
[proofA] PASS
[proofB] {"lww":{"keys_checked":32,"mismatches":0,"regressions":0,"applied":147296,
          "stale":2726,"duplicate":0,"writes_per_key_avg":5090.6,"rate_target":5000,
          "rate_achieved_avg":4999.96,"boot_ok":true,"store_empty_at_start":true,
          "quiescence_ok":true},"verdict":{"pass":true}}
[verify-lww] PASS — both proofs green
```

- **Proof A** is the deterministic mechanism test (apply versions 3,1,2 + replay 3 to
  one key, direct to redis-region): `1 0 0 -1`, final `ver=3 val=v3`.
- **Proof B** is end-to-end: `stale > 0` proves same-key reordering was actually
  exercised *and* fenced; `mismatches == 0` proves the final state is exactly correct
  despite it. Measured single instance: **~5,000 msg/s** at the default rate and
  **~20,000 msg/s** at the writer's cap — both with `mismatches=0` and thousands of
  stale writes correctly rejected. The sink kept up with no backlog, so the true
  ceiling is higher than 20k.

If a run prints `verdict.pass=false reason="inconclusive — no strictly-older arrival
observed"`, the keyspace was too large to force reordering for that rate/duration —
lower `KEY_SPACE_SIZE` or raise `RATE`/`DURATION_S` (the default keyspace of 32 is
tuned to reorder reliably; see the comment in `chart/values.yaml`).

## Validation note

This is a Kubernetes lab, so the research-lab skill's `validate_lab.sh` (docker-compose
only) does **not** apply. `scripts/verify-lww.sh` is the validation: it exits 0 only
when Proof A passes **and** Proof B's verdict is `pass:true` (which requires the
§3.4.1 precondition guards to hold and `stale > 0`).

## Teardown

```bash
helm uninstall lww -n lww-k8s
kind delete cluster --name lww
```

## Further reading

- `RESEARCH.md` — the mechanism, the unambiguous-proof precondition, validated numbers.
- `../../last-write-wins-lab/research.md` — upstream design (why NATS/source-timestamp don't work).
- `../../docs/superpowers/specs/2026-06-04-redis-connect-lww-k8s-design.md` — the spec.
- `../redis-redpanda-connect-stress-k8s/` — the parent stress lab.
