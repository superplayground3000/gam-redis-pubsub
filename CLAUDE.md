# CLAUDE.md

Go CDC lab `redis-cdc-le-k8s`: central Redis Stream → Redpanda Connect (source leg) → NATS
JetStream → Connect (sink leg) → region Redis KV, with K8s-Lease leader election. Single Go
binary `app` (subcommands: writer, verifier, elector, latency-calculator, dashboard). Helm
chart in `chart/`, Go code in `internal/`, scripts in `scripts/`. CI runs only the fast
tiers (L0+L1); the docker/kind tiers are manual and mandatory —
`scripts/run-all-tests.sh` is the single entrypoint.

## Always follow

- Read `rules/00-diagnostic.md` once per session (what breaks here and why).
- Read `rules/05-invariants.md` **before any change to code, chart, or pipelines** — all four
  invariants are binding after every change; it defines the exact test each change requires.
- Read `rules/10-model-dispatch.md` before spawning subagents or choosing models.
- Read `rules/20-judgment-rubric.md` before declaring any work complete.
- Read `rules/30-delegation-prompts.md` when writing a subagent prompt.
- Read `rules/40-maintenance-protocol.md` before editing anything under `rules/` or this file.
- Record process lessons in `rules/50-lessons.md` (format defined there).

## Hard safety rules

1. Never edit the INV-1 load-bearing lines (`rules/05-invariants.md` table) without running the
   required kind-cluster test and reporting its output. These lines carry the at-least-once
   guarantee; one past violation lost 757 messages.
2. Back up any existing file under `rules/` or `CLAUDE.md` before modifying it:
   `cp <file> <file>.bak-$(date +%Y%m%d-%H%M%S)`.
3. Never claim tests pass without having run them in this session; paste command + exit status.
4. New chart components must ship with an `enabled:` values toggle in the same change.
5. New pipeline failure branches must increment `cdc_unprocessable{reason=...}` (or a new
   counter) and appear on the Grafana dashboard in the same change.

## Verification quick reference (details: `rules/05-invariants.md`)

- All levels: `scripts/run-all-tests.sh` (L0→L3; `SKIP_L2=1`/`SKIP_L3=1` to skip docker
  tiers, `RUN_FAILOVER=1` adds L4)
- Unit: `go test ./...` (<10 s)
- Chart render: `helm lint chart/ && helm template chart/ >/dev/null` (seconds)
- Lab alert proof (L2): `labs/redis-cdc-error-alerting/scripts/verify-alert.sh` (~7 min)
- Kind e2e: `scripts/build-images.sh --kind --kind-name=cdc` then
  `RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh` (~5 min)
- Failover chaos: `scripts/verify-failover.sh` (~12 min; required for consumer-id/group, lease,
  elector, ack/commit, or nats-init consumer changes — full list in `rules/05-invariants.md`)

## Routing

- Chart or values review → project skill `.claude/skills/helm-chart-review/`
- Delivery-semantics questions → `docs/failover-report/REPORT.md`,
  `docs/nats-jetstream-and-redis-kv-message-flow.md`
- `docs/superpowers/plans|specs/` are dated session artifacts, not current requirements —
  check dates before acting on them.
