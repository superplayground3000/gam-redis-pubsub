# Design: `labs/robustness-test/` — image robustness validation for `hpdevelop/connect:v4.92.0-batch-nats`

Date: 2026-07-06
Status: approved by owner (this session)
Source request: `docs/labs/robustness-test/request.md`

## Problem

The owner wants kind-cluster proof that image `hpdevelop/connect:v4.92.0-batch-nats`
(present in the local docker image store; the chart currently pins
`hpdevelop/connect:4.92.0-claudefix`) satisfies two robustness requirements:

1. With Redis and NATS healthy throughout, ≥3 Connect pods per leg, and Lease leader
   election, **no message is lost under pod force-kill** (SIGKILL / `--grace-period=0`).
2. **Every message the pipeline cannot process is counted in metrics.**

The repo already proves both properties for the *pinned* image via `scripts/verify-cdc.sh`
(L3), `scripts/verify-failover.sh` (L4), and the INV-2 machinery. This lab re-proves them
against a *different image tag*, and extends kill coverage to the sink leg and standby pods.

## Property demonstrated (one sentence)

In a kind cluster running this repo's chart with 3 replicas per Connect leg and K8s-Lease
leader election, `hpdevelop/connect:v4.92.0-batch-nats` loses zero messages under force-kill
of the source-leg leader, the sink-leg leader, and standby pods (Redis & NATS healthy
throughout), and every unprocessable message increments `cdc_unprocessable{reason}`.

## Decisions made during clarification

| Question | Decision |
|---|---|
| Kill scope | Both leg leaders + a standby pod per leg (not just the source leader) |
| Loss-detection canary | Keep the A/B baseline (pod-scoped consumer id MUST lose) to prove the harness detects loss with this image |
| Metrics proof | Inject poison messages in-cluster and assert exact `cdc_unprocessable{reason}` increments; existence-only check rejected as too weak |
| Language | Bash orchestration reusing existing scripts (repo convention); Go/Python harness rejected as duplication |
| Structure | Thin orchestrator lab under `labs/robustness-test/`; standalone rebuild and in-place extension of `verify-failover.sh` rejected |

## Design

### Layout

```
labs/robustness-test/
├── RESEARCH.md              # research-lab skill artifact (essentials + design decisions)
├── README.md                # how to run, what passes mean, runtime
├── scripts/
│   ├── verify-robustness.sh # single entrypoint, runs phases 0-4, writes report
│   ├── kill-sink-leader.sh  # phase 2
│   ├── kill-standby.sh      # phase 3
│   └── poison-metrics.sh    # phase 4
└── reports/                 # gitignored run artifacts (report.json, report.md, logs)
```

### Phases (all against the batch-nats image in kind cluster `cdc`, ns `cdc-k8s`)

| # | Phase | Reuses | Pass criterion |
|---|---|---|---|
| 0 | Load app image (`scripts/build-images.sh --kind`) + `kind load docker-image` of the connect tag; deploy with image override; end-to-end correctness | `scripts/verify-cdc.sh` | verifier `verdict.pass=true` |
| 1 | A/B canary + source-leader SIGKILL | `scripts/verify-failover.sh` (baseline + fixed) | baseline loses messages AND fixed loses zero |
| 2 | Sink-leader SIGKILL under live traffic | new; oracle modeled on verify-failover's pure-redis-cli membership check | new lease holder appears; region KV contains all N injected keys |
| 3 | Standby SIGKILL (one non-holder pod per leg) under traffic | new | leadership unchanged; region KV contains all N keys |
| 4 | Poison injection: XADD messages triggering `decode_error` and `unknown_op` (reasons per `chart/files/connect/cdc-reverse.yaml`) mixed with good ones | new | `cdc_unprocessable{reason=...}` on the sink leader's `:4195/metrics` increments by exactly the injected counts; good messages still applied to region KV |

Exit 0 iff all five phases pass. Estimated runtime ~30 min (5+12+5+5+3).

### Image override mechanism

`scripts/verify-cdc.sh` and `scripts/verify-failover.sh` gain an optional `RRCS_SET` env:
space-separated `key=value` pairs appended as repeated `--set` to their helm invocations.
Default empty → behavior unchanged. The lab exports
`RRCS_SET="connect.image=${CONNECT_IMAGE}"` with `CONNECT_IMAGE` defaulting to
`hpdevelop/connect:v4.92.0-batch-nats`, so the lab is reusable for future tags.
Rejected alternative: a lab-local full values file (drifts from `chart/values-dev.yaml`;
naive YAML concat would clobber the `connect:` block).

### Traffic + oracles for the new phases

Same style as `verify-failover.sh`: `redis-cli XADD` a known key set into `app.events`
during the kill window; after takeover/settle, assert region-KV membership of all N keys
via `redis-cli` (`EXISTS`/scan). No new Go code. Phase 2 reuses the arm→confirm-leader→kill
→retry-on-inconclusive discipline from `verify-failover.sh` to avoid mistimed kills.

### Reporting

`reports/<timestamp>/report.json` (per-phase verdict, image tag + digest, counts, commands)
plus a human `report.md`. The reporting rule of `rules/05-invariants.md` applies: the final
summary pastes exact commands + exit statuses.

## Invariant compliance

- No chart, pipeline, or Lua changes → INV-1/INV-2 load-bearing lines untouched.
- New lab ships no chart components → INV-3 unaffected.
- The `RRCS_SET` patch touches two verification scripts; it is exercised end-to-end by the
  lab run itself (L3+L4 equivalent), satisfying INV-4 for that change.
- Backup rule: only new files plus additive edits to two scripts under `scripts/`
  (not `rules/` or `CLAUDE.md`), so no rule-file backups needed.

## Deliberately excluded

- **Redis/NATS outage or restart tolerance** — the request explicitly conditions on both
  staying healthy.
- **Cross-key reordering** — accepted non-guarantee per INV-1 (`rules/05-invariants.md`);
  not a loss bug, not tested here.
- **Performance/latency of the batch-nats image** — out of scope; only delivery + metrics.
- **Grafana/alert visual verification** — metric-level assertion only; the L2 lab already
  covers alert wiring for the pipeline files, which this image consumes unchanged.

## Risks

- The batch-nats image's batching semantics may legitimately fail phases 1/2 (e.g. batched
  publishes acked before PubAck). That is a *finding*, not a lab defect — the report must
  distinguish "image fails requirement" from "harness inconclusive".
- Kill timing races → mitigated by reusing the existing inconclusive-retry pattern.
- `hpdevelop/connect:v4.92.0-batch-nats` exists only locally; the lab must `kind load` it
  and fail fast with a clear message if the tag is absent.
