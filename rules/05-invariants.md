# 05-invariants.md — Repo Invariants That Must Hold After Every Change

These four invariants are the owner's standing requirements (2026-07-05). Every change to this
repo must leave all four true. Each invariant lists: what must be true, the load-bearing
code/config that makes it true, and the exact command that proves it.

If a change makes any "load-bearing" item false, either restore it or get explicit user
approval — do not silently redesign a guarantee.

File paths and quoted keys below were correct on 2026-07-05. If a cited key is not where the
table says, search the repo for the quoted key before concluding the table is wrong.

---

## INV-1 — At-least-once delivery, source and sink, in Kubernetes

**Statement:** Every message XADDed to the central Redis stream is applied to the region Redis
at least once, provided the Redis stream and NATS JetStream themselves are not corrupted.
Duplicates are allowed (absorbed by idempotency); loss is not.

### Load-bearing lines (do not change without running L3, and L4 where marked)

| # | File | What must stay true | Why |
|---|---|---|---|
| 1 | `chart/files/connect/cdc-forward.yaml` | Source XACKs Redis only after NATS PubAck (Connect `redis_streams` input + `commit_period`; write-then-ack) | Entry never acked before it is durably in JetStream |
| 2 | `chart/files/connect/cdc-forward.yaml` + `chart/values.yaml` (`connect.source.consumerClientId`) | Consumer client id is **stable and role-scoped** (`cdc_propagator_active`), never pod-scoped (`__POD__`) — **L4 required if touched** | Pod-scoped id orphans the PEL on SIGKILL; historical bug lost 757 msgs (`docs/failover-report/REPORT.md`) |
| 3 | `chart/files/connect/cdc-forward.yaml` | `auto_replay_nacks: true`; consumer group `cdc_propagator` unchanged | Unacked entries must be re-read |
| 4 | `chart/files/connect/cdc-forward.yaml` | JetStream publish sets header `Nats-Msg-Id: meta("event_id")` | Server-side dedup absorbs replays after crash-between-publish-and-ack |
| 5 | `chart/values.yaml` (`nats.stream.dupeWindow: 5m`) | Dedup window stays ≥ the realistic replay window | Same as #4 |
| 6 | `chart/files/connect/cdc-reverse.yaml` | Sink binds to pre-created durable pull consumer: `cdc_sink`, `bind: true` | Ad-hoc consumers reset delivery state |
| 7 | `chart/values.yaml` (`nats.stream.consumer`) | `maxDeliver: -1` (redeliver forever), `ackWait` finite (30s default) | Poison messages must redeliver, not vanish |
| 8 | `chart/files/connect/cdc-reverse.yaml` | Output is `reject_errored` + `drop`: Redis apply runs **before** ack; processor failure nacks | Message acked to JetStream only after region write succeeded |
| 9 | `chart/files/connect/cdc_rename.lua` | Rename guarded by `EXISTS` (idempotent no-op on redelivery) | Redelivered rename must not error-loop or corrupt |
| 10 | `internal/elector/` + `chart/values.yaml` lease settings | Leader election keeps exactly one active leg; standby takes over on lease expiry | Recovery path for #2 |

### How to verify

- **Functional proof (L3, ~5 min):**
  `scripts/build-images.sh --kind --kind-name=cdc && RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh`
  Exit 0 = dedup + per-op + replay + rename-parity + hash-ops all pass (`internal/verifier/checks.go`).
  Note: the script's header comment understates coverage — `verdict.pass` also gates
  rename-parity and hash-ops (`internal/verifier/report_test.go`).
- **Crash-safety proof (L4, ~12 min):** `scripts/verify-failover.sh`
  Exit 0 = baseline (pod-scoped id) loses messages AND fixed (stable id) loses zero.
- L4 is **required** for any change to: consumer client id, consumer group, lease settings,
  elector code, ack/commit settings, or the nats-init consumer creation.

**Known accepted non-guarantee:** cross-key reordering (e.g. delete-before-rename) is by design
in this fence-free/no-LWW lab (`docs/nats-jetstream-and-redis-kv-message-flow.md`). Do not
"fix" it as if it were a loss bug; it is not covered by INV-1.

---

## INV-2 — Problem-message metrics, seconds histograms, and Grafana visualization

**Statement:** (a) every message the pipeline cannot process is visible in a metric;
(b) performance histograms are exposed in **seconds**; (c) the Grafana dashboard shipped in the
chart visualizes both.

### Load-bearing items

| File | What must stay true |
|---|---|
| `chart/files/connect/cdc-reverse.yaml` | `cdc_unprocessable{reason=...}` counter fires on every permanent-failure branch (today: `decode_error`, `unknown_op`). **Any new failure branch added to a pipeline must add a `reason` label value.** |
| `chart/files/connect/cdc-reverse.yaml` | `cdc_apply{op,type}` increments only after a successful apply |
| `chart/files/connect/observability.yaml` | `use_histogram_timing: true` (Connect timing histograms, in seconds) |
| `chart/files/grafana/cdc-dashboard.json` | Panels exist for: apply throughput, unprocessable activity, unprocessable-by-reason, processor errors. **If you add a metric, add/extend a panel in the same change.** |
| `chart/files/prometheus/cdc-alerts.yaml` | `CDCUnprocessableMessages` alert; its `increase[...]` window must stay ≥ 2× `nats.stream.consumer.ackWait` (redelivery cadence coupling — documented in the rule file header) |
| `chart/templates/observability/*` | ServiceMonitor/PrometheusRule/dashboard ConfigMap render when `observability.enabled=true` |
| `internal/writer/http.go`, `internal/elector/main.go` | Writer counters (`cdc_writer_errors_total` etc., exposed in `http.go`) and elector counters (`elector_leading`, `elector_post_total`, `elector_delete_total`) keep existing names — dashboards/reports reference them by name |

### How to verify

- Render check (L1): `helm template chart/ --set observability.enabled=true` — confirm
  ServiceMonitor, PrometheusRule, and dashboard ConfigMap appear; `helm template chart/`
  (default) — confirm they do not.
- Metric name check after editing a pipeline: grep the dashboard + alert files for every metric
  name you touched: `grep -n "cdc_unprocessable\|cdc_apply" chart/files/grafana/cdc-dashboard.json chart/files/prometheus/cdc-alerts.yaml`
- Behavior check (L3): run `verify-cdc.sh`, then curl `:4195/metrics` on the sink pod and
  confirm `cdc_apply` moved and any newly added failure counter exists.

### Known gaps in INV-2 (pre-existing, 2026-07-05 — highest-priority follow-up work)

1. Dashboard has **no latency/histogram panels** even though seconds histograms are exposed. → Add p50/p95/p99 panels querying Connect timing histograms.
2. **No dedicated counter for failed JetStream publish** on the source leg (only generic Connect `output_error`). → Add a forward-leg failure metric + panel.
3. Writer/elector metrics are exposed but not scraped (ServiceMonitor selects only connect legs) and not on the dashboard.
4. Latency percentiles exist only as file JSON (`latencyCalculator`), not as Prometheus metrics.

An agent asked to "improve observability" should work this list top-down.

---

## INV-3 — Every helm chart component individually enable/disable-able

**Statement:** each deployable component in `chart/` can be turned off via values, and
`helm template` with a component disabled emits none of its resources.

### Current state (2026-07-05)

Toggles exist: bundled NATS (`nats.external.enabled` inverts), nats-init jobs (selected by
`nats.external.enabled`; one variant always renders — no full disable), bundled Redis
central/region (`redis.<side>.external.enabled` inverts), `latencyCalculator.enabled`,
`verifier.run`, `observability.enabled`, persistence toggles.

**Missing toggles (gap — follow-up work):** connect-source, connect-sink, writer, dashboard,
RBAC, connect ConfigMaps are always rendered. Target values shape when adding them:
`connect.source.enabled`, `connect.sink.enabled`, `writer.enabled`, `dashboard.enabled`,
`rbac.enabled` (default all `true`), guarding the whole template file with
`{{- if .Values.<component>.enabled }}`.

### Rules for chart changes

1. **Any new component template must ship with an `enabled:` toggle (default chosen deliberately) in the same change.** No exceptions.
2. When adding a toggle, also guard dependent resources (Service, ConfigMap, RBAC of that component).
3. Use the existing project skill `.claude/skills/helm-chart-review/` for any chart/values review.

### How to verify (L1, seconds)

For each toggle touched:
```bash
helm template chart/ --set <component>.enabled=false | grep -i "<component resource name>"   # expect: no hits
helm template chart/ | grep -i "<component resource name>"                                    # expect: hits
helm lint chart/
```
Then L3 (`verify-cdc.sh`) if the disabled-by-default set changed, to prove the default install still passes.

---

## INV-4 — A test suite runs after every change

**Statement:** every change is verified before being declared done, at the level the change
warrants. Full e2e runs on a kind cluster; fast verification uses containers.

### Verification ladder

| Level | Command | Time | Proves |
|---|---|---|---|
| **L0** | `go test ./...` | <10 s | Go unit/integration logic |
| **L1** | `helm lint chart/ && helm template chart/ >/dev/null` (+ targeted `--set` render checks) | seconds | Chart renders; toggles behave |
| **L2** | docker-compose fast verification — **does not exist yet** (planned: `labs/redis-cdc-error-alerting/`, spec `docs/superpowers/plans/2026-07-05-redis-cdc-observability-lab.md`). Until built, substitute L0+L1 and go straight to L3 | ~1 min (target) | Sink pipeline + metrics/alerts without k8s |
| **L3** | `scripts/build-images.sh --kind --kind-name=cdc` then `RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh` | ~5 min | End-to-end delivery: dedup, per-op, replay, rename-parity, hash-ops |
| **L4** | `scripts/verify-failover.sh` | ~12 min | At-least-once survives SIGKILL of the active leader |

### Change type → required level (minimum; more is fine)

| You changed… | Required |
|---|---|
| Docs, comments, reports | none (read-back only) |
| Go code in `internal/` or `main.go` | L0; + L3 if it touches writer/verifier/elector behavior |
| Chart templates or `values*.yaml` | L1; + L3 if it affects any deployed-by-default component |
| Connect pipeline YAML (`chart/files/connect/*`) or Lua | L1 + L3 |
| Anything in the INV-1 load-bearing table | L1 + L3, **+ L4 where the table says so** |
| Metrics, dashboard JSON, alert rules | L1 + the INV-2 grep check; L3 if metric emission changed |
| Build scripts / Dockerfile | Build image + L3 |

If a change matches more than one row, the **strictest** matching row applies.

### Reporting rule (weak-model-safe)

Before saying a change is done, paste: the exact command(s) run, exit status, and the relevant
result line (verifier: the `verdict.pass=true` field of RESULT_JSON, or the script's final
`[verify-cdc] PASS` line). If a required level was skipped, say so
explicitly and why. Never claim "tests pass" without having run them in this session.
(See `rules/20-judgment-rubric.md` §Completion.)

### Known gaps in INV-4 (follow-up work, in priority order)

1. **L2 docker-compose lab not built** (spec exists — see above).
2. **No single entrypoint** — a `scripts/run-all-tests.sh` (L0→L1→L3, L4 behind an env flag) or Makefile would remove per-session judgment.
3. **No CI** — nothing runs automatically on push/PR; a workflow running L0+L1 per PR and L3 nightly would enforce this invariant mechanically.

---

## Change checklist (copy into your working notes for any non-doc change)

1. Which invariants does this change touch? (INV-1/2/3/4 tables above)
2. Did I keep every load-bearing line true, or get user approval to change it?
3. Which ladder level is required? Did I run it? Paste command + result.
4. If I added a metric → dashboard panel updated? If a component → `enabled:` toggle present?
5. Anything discovered that belongs in `rules/50-lessons.md`?
