# labs/robustness-test — image robustness validation in kind

Proves `hpdevelop/connect:v4.92.0-batch-nats` (override: `CONNECT_IMAGE=...`)
against the two requirements in `docs/labs/robustness-test/request.md`:
zero message loss under pod force-kill (3 replicas/leg + Lease leader election,
Redis & NATS healthy), and unprocessable-message counting in metrics.

## Prerequisites
- kind cluster (default name `cdc`): `kind get clusters | grep -qx cdc || kind create cluster --name cdc`
- The target image present in the local docker store: `docker image inspect "$CONNECT_IMAGE"`
- `helm`, `kubectl`, `jq`, `docker` on PATH. Everything runs in containers/the
  kind cluster; no host changes.

## Run

    labs/robustness-test/scripts/verify-robustness.sh

Phases (~6-40 min total, depending on inconclusive-retry count and hardware;
measured 5m57s on a warm kind cluster):
0. Load images into kind; deploy with `connect.image=$CONNECT_IMAGE`; e2e
   correctness via `scripts/verify-cdc.sh` (verifier verdict.pass).
1. A/B failover canary via `scripts/verify-failover.sh`: baseline (pod-scoped
   consumer id) MUST lose on source-leader SIGKILL — proves the harness detects
   loss — then the real config MUST NOT. Retried up to 2× on INCONCLUSIVE (rc 3).
2. Sink-leader SIGKILL mid-flight → new Lease holder + region has all N keys.
3. Standby SIGKILL (one per leg) during traffic → leadership unchanged + all N keys.
4. Poison: 5× unknown_op (XADD) + 5× decode_error (direct NATS publish) →
   `cdc_unprocessable{reason=...}` ≥ +5 per reason on the sink leader's
   `:4195/metrics`; then `nats stream purge KV_CDC` and a 100-key good-traffic
   sanity proves recovery. (≥, not ==: poison redelivers forever by design.)

Exit 0 iff all phases pass. Per-run artifacts: `labs/robustness-test/reports/<ts>/`
(`report.json`, `report.md`, per-phase logs) — gitignored.

## Env knobs
`CONNECT_IMAGE`, `KIND_NAME`, `RRCS_NS`, `RRCS_RELEASE`, `RRCS_PREFIX`,
`N_SINKKILL` (default 5000), `N_STANDBY` (2000), `N_POISON` (5),
`SINK_TIMEOUT_S` (300), `FAILOVER_TIMEOUT_S` (120).

## Interpreting failures
- Phase 1 baseline "expected loss but region has all keys" → INCONCLUSIVE
  (mistimed kill), rerun; NOT an image defect.
- Phase 2/4 assertion failures with healthy Redis/NATS → image fails the
  requirement; capture `reports/<ts>/` and the pod logs it saves.
