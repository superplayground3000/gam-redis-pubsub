# 00-diagnostic.md — Harness Diagnostic

Written 2026-07-05 by a governance session (Fable 5) per `docs/harness/request.md`.
Environment findings below were verified by inspection on that date; re-verify paths before relying on them if the repo has been reorganized since.

## Verified environment (2026-07-05)

| Item | Finding |
|---|---|
| Repo | `redis-cdc-le-k8s` Go module at repo root; single binary `app` with subcommands `writer`, `verifier`, `elector`, `latency-calculator`, `dashboard` (`main.go:26-52`) |
| Helm chart | `chart/` (name `redis-cdc-le-k8s`); pipelines in `chart/files/connect/`; dashboard JSON in `chart/files/grafana/`; alerts in `chart/files/prometheus/` |
| CLAUDE.md | Did not exist before this session (no backup was needed; the current one was created new) |
| Makefile / CI | No Makefile. CI added 2026-07-05: `.github/workflows/ci.yaml` runs L0+L1 per PR / push to master. Single entrypoint: `scripts/run-all-tests.sh` |
| Tests | `go test ./...` (<10s); L2 lab `labs/redis-cdc-error-alerting/scripts/verify-alert.sh` (~7 min); kind e2e `scripts/verify-cdc.sh` (~5 min); chaos `scripts/verify-failover.sh` (~12 min) |
| Subagents | Claude Code `Agent` tool with agent types incl. read-only `Explore`; model override values verified in harness: `sonnet`, `opus`, `haiku`, `fable` |
| Model effort controls | Not exposed in this harness (model selection only). Not verified beyond that — do not invent effort parameters |
| External providers | Codex via `codex:rescue` skill; MiniMax via `minimax-subagent` skill. Governed by the user's global rule `~/.claude/rules/subagent-provider-routing.md` |
| Memory | Claude Code auto-memory directory exists per-project (managed by the harness; do not hand-edit paths) |
| Project skills | `.claude/skills/helm-chart-review/` exists and works; use it for any chart/values review |

## Top 3 problems this rule set exists to fix

### Problem 1 — Nothing is always-loaded: every session re-discovers the repo from scratch

- **Symptom:** Before this rule set, there was no CLAUDE.md, no rules/, no Makefile. Each session spent thousands of tokens re-scanning `chart/`, `internal/`, and `scripts/` to learn what exists, and sometimes guessed wrong paths (see git history: `fix: repoint doc references broken by the helm-release/ reorg`).
- **Why it matters:** Token waste on rediscovery, and errors from stale guesses (the chart moved from `helm-release/` to `chart/` at least once).
- **Fix:** `CLAUDE.md` is now a short always-loaded router. It names the real paths and test commands. Keep it short; details live in `rules/`.
- **Enforced by:** `CLAUDE.md` + `rules/40-maintenance-protocol.md` (which forbids letting CLAUDE.md grow or drift).

### Problem 2 — Delivery correctness is encoded in YAML lines that look editable

- **Symptom:** The at-least-once guarantee depends on specific lines in `chart/files/connect/cdc-forward.yaml`, `chart/files/connect/cdc-reverse.yaml`, `chart/files/connect/cdc_rename.lua`, and `chart/values.yaml`. To a future agent these look like ordinary config. One historical bug of exactly this shape (pod-scoped `client_id: __POD__`) lost 757 messages in the failover A/B test before being fixed (`docs/failover-report/REPORT.md`).
- **Why it matters:** A well-meaning small edit (rename a consumer, "clean up" `bind: true`, change the output error handling) silently destroys the core guarantee. Tests exist but nothing forced anyone to run them.
- **Fix:** `rules/05-invariants.md` lists the load-bearing lines and maps every change type to the exact verification command that must pass before the change may be declared done.
- **Enforced by:** `rules/05-invariants.md` (INV-1) + `rules/20-judgment-rubric.md` ("when is work complete").

### Problem 3 — No verification ladder: agents either skip testing or run the most expensive test for trivial changes

- **Symptom:** There is no single test entrypoint and no CI. `verify-failover.sh` takes ~12 minutes; `go test ./...` takes seconds. Without a rule, weak agents either declare success with no evidence, or burn 15+ minutes of kind-cluster time on a docs change.
- **Why it matters:** Both failure modes are costly: unverified changes cause regressions; over-testing wastes wall-clock and tokens on every iteration.
- **Fix:** The verification ladder in `rules/05-invariants.md` §Verification ladder maps change types to required test levels (L0 unit → L1 render → L2 docker lab → L3 kind e2e → L4 failover chaos); `scripts/run-all-tests.sh` is the single entrypoint.
- **Enforced by:** `rules/05-invariants.md` + the completion rubric in `rules/20-judgment-rubric.md`.

## Secondary observations (not top-3, still real)

- Subagent reports tend to return long prose; `rules/10-model-dispatch.md` §Return contract requires conclusion + evidence + paths, with long artifacts written to disk.
- `docs/superpowers/plans/` and `specs/` are dated session artifacts, not rules. Do not treat them as current requirements without checking dates.
- CI (since 2026-07-05) enforces only L0+L1 per PR / push to master; L2-L4 remain enforced solely by these rules.
