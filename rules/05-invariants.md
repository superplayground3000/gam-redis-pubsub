# 05-invariants.md — Repo Invariants That Must Hold After Every Change

These four invariants are the owner's standing requirements (2026-07-05). All of them are
**binding**: each must hold after every change, and violating one blocks completion.

History note (2026-07-05): between commits 19480d2 and this file's strict restore, the file
ran a temporary owner-approved "ratchet" regime (binding-now vs target-state with Known-gaps
carve-outs, approval memo in commit 59dcf6d). Every gap was closed on 2026-07-05 (chart
toggles, INV-2 observability items, L2 lab, run-all-tests entrypoint, CI), so the strict
version was restored the same day under the pre-approval recorded in that header and in
`rules/90-letter-to-future-sessions.md` §4 item 7. No fresh approval was needed or sought.

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
| 4 | `chart/files/connect/cdc-forward.yaml` | JetStream publish sets header `Nats-Msg-Id: meta("event_id")` (inside the `fallback` first child) | Server-side dedup absorbs replays after crash-between-publish-and-ack |
| 5 | `chart/values.yaml` (`nats.stream.dupeWindow: 5m`) | Dedup window stays ≥ the realistic replay window | Same as #4 |
| 6 | `chart/files/connect/cdc-reverse.yaml` | Sink binds to pre-created durable pull consumer: `cdc_sink`, `bind: true` | Ad-hoc consumers reset delivery state |
| 7 | `chart/values.yaml` (`nats.stream.consumer`) | `maxDeliver: -1` (redeliver forever), `ackWait` finite (30s default) | Poison messages must redeliver, not vanish |
| 8 | `chart/files/connect/cdc-reverse.yaml` + `chart/files/connect/cdc-reverse-sharded.yaml` | Output is `reject_errored` + `drop`: Redis apply runs **before** ack; processor failure nacks | Message acked to JetStream only after region write succeeded |
| 9 | `chart/files/connect/cdc_rename.lua` | Rename guarded by `EXISTS` (idempotent no-op on redelivery) | Redelivered rename must not error-loop or corrupt |
| 10 | `internal/elector/` + `chart/values.yaml` lease settings | Leader election keeps exactly one active leg; standby takes over on lease expiry | Recovery path for #2 |
| 11 | `chart/files/connect/cdc-forward.yaml` | The output `fallback`'s failure child stays `reject` (nack → replay). Never `drop` or any child that succeeds without a JetStream PubAck. **Sharded render exception (subject-sharding v2, owner-approved 2026-07-15):** when `connect.sharding.families` is configured the fallback is REMOVED BY DESIGN — the output is a bare `nats_jetstream` with `max_in_flight: 1` that blocks and retries in place (a forward nack would PEL-replay an older event after newer ones already published → silent reorder, which v2 cannot detect without a fence). Write-then-XACK is unchanged: no PubAck ⇒ no ack. Do NOT re-add a reject path to the sharded variant, and do NOT remove the fallback from the non-sharded render | The fallback child runs when the publish failed; anything that "succeeds" there would XACK entries that never reached JetStream — silent loss. It exists only to count (`cdc_forward_publish_failed`) and nack |
| 13 | `chart/files/connect/cdc-forward.yaml`, `chart/files/connect/cdc-reverse-sharded.yaml`, `chart/templates/_helpers.tpl` | Sharded render (v2 ordering chain O-3..O-7): forward `pipeline.threads: 1` + `max_in_flight: 1`; sink broker `copies: 1` + `pipeline.threads: 1`; every shard durable `max_ack_pending: 1` (hard-coded in the helper's consumers list, never the values inheritance chain). **Loosening ANY of these silently reintroduces old-overwrites-new and no metric can detect it** (`docs/design/subject-sharding/design.md` §3) — L3 `RUN_SHARDING=1` + L4 sharding scripts required if touched | v2 removed the LWW fence; per-key apply order IS the correctness mechanism |
| 12 | `chart/templates/connect-source.yaml`, `chart/templates/connect-sink.yaml` | Pod template keeps the `checksum/connect-config` annotation over the connect ConfigMaps | The elector POSTs the pipeline only when it wins the Lease; without the checksum-triggered rollout, a helm upgrade that edits a pipeline never reaches the running leg — you verify stale config (bit this repo on 2026-07-05, `rules/50-lessons.md`) |

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
(b) performance histograms are exposed in **seconds**; (c) the Grafana dashboard shipped in
the chart visualizes the failure metrics, the latency histograms/percentiles, and the
writer/elector health metrics. Any metric or failure path you ADD must appear on the
dashboard in the same change.

### Load-bearing items

| File | What must stay true |
|---|---|
| `chart/files/connect/cdc-reverse.yaml` | `cdc_unprocessable{reason=...}` counter fires on every permanent-failure branch (today: `decode_error`, `unknown_op`). **Any new failure branch added to a pipeline must add a `reason` label value.** |
| `chart/files/connect/cdc-forward.yaml` | `cdc_forward_publish_failed{reason}` increments in the output `fallback` failure child (fires per failed JetStream publish; the message is then nacked — INV-1 row 11). **Sharded render:** the fallback (and this counter) does not exist — the replacement signal is `output_error` on the connect-source job (dashboard panel 5 second series + `CDCForwardPublishBlocked` alert) |
| `chart/files/connect/cdc-forward.yaml` (sharded render) | `cdc_forward_unrouted{reason="unparseable_shard"}` and `cdc_forward_cross_shard_rename` fire on the sx isolation lane (dashboard panel 16 + `CDCShardIsolationLane`); `cdc_forward_cross_shard_rename` must stay 0 (INV-S7) |
| `chart/files/connect/cdc-reverse-sharded.yaml` | Same contract as cdc-reverse.yaml (`cdc_unprocessable{shard,reason}`, `cdc_apply{shard,op,type}` after successful apply, `cdc_sync_latency_seconds{op,shard}` post-apply with clamp + int-ns, `cdc_sync_skew_negative{shard}`) — the shard label comes from the broker child, never `kv_key` (INV-S8) |
| `chart/files/connect/cdc-reverse.yaml` | `cdc_apply{op,type}` increments only after a successful apply |
| `chart/files/connect/cdc-reverse.yaml` | `cdc_sync_latency_seconds{op}` timing records only after a successful apply (`!errored()` + `sync_has_ts` guard); its value stays clamped ≥ 0 and `.int64().string()`-formatted — a negative or float value makes the metric processor error AFTER the apply and nack an already-applied message. Negative deltas increment `cdc_sync_skew_negative` instead |
| `chart/files/connect/observability.yaml` | `use_histogram_timing: true`. Quirk of the pinned build: the timing metrics keep `_ns` names (`processor_latency_ns` etc.) but the histogram **buckets record seconds** — dashboards must treat values as seconds |
| `internal/latency/metrics.go` + `chart/templates/latency-calculator.yaml` | latency-calculator serves `cdc_latency_seconds{op,quantile}` gauges (+ samples, dropped-negative) on `:8082`, and its Service exposes port `http` for the ServiceMonitor |
| `chart/templates/observability/servicemonitor.yaml` | Selects connect legs + writer + latency-calculator (`http` endpoint) and the elector sidecars (`elector` endpoint, port 8090 on the connect Services) |
| `chart/files/grafana/cdc-dashboard.json` | Panels exist for: apply throughput, unprocessable activity, unprocessable-by-reason, processor errors, forward-leg publish failures, Connect latency p50/p95/p99, end-to-end latency percentiles, sync latency p50/p95/p99 by group, sync clock-skew negatives, writer throughput/errors, elector leadership. **If you add a metric, add/extend a panel in the same change.** |
| `chart/files/prometheus/cdc-alerts.yaml` | `CDCUnprocessableMessages` alert; its `increase[...]` window must stay ≥ 2× `nats.stream.consumer.ackWait` (redelivery cadence coupling — documented in the rule file header) |
| `chart/templates/observability/*` | ServiceMonitor/PrometheusRule/dashboard ConfigMap render when `observability.enabled=true` |
| `internal/writer/http.go`, `internal/elector/main.go` | Writer counters (`cdc_writer_errors_total` etc., exposed in `http.go`) and elector counters (`elector_leading`, `elector_post_total`, `elector_delete_total`) keep existing names — dashboards/reports reference them by name |

### How to verify

- Render check (L1): `helm template chart/ --set observability.enabled=true --set latencyCalculator.enabled=true`
  — confirm ServiceMonitor (both endpoints), PrometheusRule, dashboard ConfigMap, and the
  latency-calculator Service appear; `helm template chart/` (default) — confirm the
  observability objects do not.
- Metric name check after editing a pipeline: grep the dashboard + alert files for every metric
  name you touched: `grep -n "cdc_unprocessable\|cdc_apply\|cdc_forward_publish_failed\|cdc_forward_unrouted\|cdc_forward_cross_shard_rename\|cdc_latency_seconds\|cdc_sync_latency_seconds\|cdc_sync_skew_negative\|cdc_writer\|elector_\|output_error" chart/files/grafana/cdc-dashboard.json chart/files/prometheus/cdc-alerts.yaml`
- Behavior check (L2, ~7 min): `labs/redis-cdc-error-alerting/scripts/verify-alert.sh` proves
  the alert + dashboard against a real Connect sink (single-source bind mounts).
- Behavior check (L3): run `verify-cdc.sh`, then curl `:4195/metrics` on the sink pod and
  confirm `cdc_apply` moved and any newly added failure counter exists.

---

## INV-3 — Every helm chart component individually enable/disable-able

**Statement:** each deployable component in `chart/` can be turned off via values, and
`helm template` with a component disabled emits none of its resources.

Toggles (all verified by the L1 loop in `scripts/run-all-tests.sh`):
`connect.source.enabled`, `connect.sink.enabled` (each also gates its pipeline ConfigMap;
the shared observability ConfigMap renders if either leg is on), `writer.enabled`,
`dashboard.enabled`, `rbac.enabled`, `latencyCalculator.enabled`, `observability.enabled`,
`verifier.run`, and the external/bundled inversions `nats.external.enabled`,
`redis.central.external.enabled`, `redis.region.external.enabled`.

**Deliberate exception (not a gap):** the nats-init Job pair is selected by
`nats.external.enabled` and one variant always renders — it provisions the stream + durable
consumer that INV-1 rows 6-7 depend on, so it stays coupled to the NATS mode rather than
independently disable-able.

**Binding on every chart change:**
1. Any NEW component template ships with an `enabled:` toggle (default chosen deliberately,
   dependent Service/ConfigMap/RBAC guarded too) in the same change. No exceptions.
2. Never remove or break an existing toggle (prove with the L1 renders below).

Use the existing project skill `.claude/skills/helm-chart-review/` for any chart/values review.

### How to verify (L1, seconds)

For each toggle touched:
```bash
helm template chart/ --set <component>.enabled=false | grep -i "<component resource name>"   # expect: no hits
helm template chart/ | grep -i "<component resource name>"                                    # expect: hits
helm lint chart/
```
(`scripts/run-all-tests.sh` L1 runs this loop for every toggle.)
Then L3 (`verify-cdc.sh`) if the disabled-by-default set changed, to prove the default install still passes.

---

## INV-4 — A test suite runs after every change

**Statement:** every change is verified before being declared done, at the level the change
warrants, using the ladder below. `scripts/run-all-tests.sh` is the single entrypoint
(L0→L1→L2→L3; `SKIP_L2=1`/`SKIP_L3=1` to skip the docker tiers, `RUN_FAILOVER=1` adds L4).
CI (`.github/workflows/ci.yaml`) enforces L0+L1 on every PR and push to master; L2-L4 are run manually —
deliberate scope for now, an L3 nightly would strengthen it further.

### Verification ladder

| Level | Command | Time | Proves |
|---|---|---|---|
| **L0** | `go test ./...` | <10 s | Go unit/integration logic |
| **L1** | `helm lint chart/ && helm template chart/ >/dev/null` (+ targeted `--set` render checks) | seconds | Chart renders; toggles behave |
| **L2** | `labs/redis-cdc-error-alerting/scripts/verify-alert.sh` | ~7 min | Sink pipeline + `CDCUnprocessableMessages` alert + dashboard against a real Connect, no k8s (single-source bind mounts of the chart's alert/dashboard files) |
| **L3** | `scripts/build-images.sh --kind --kind-name=cdc` then `RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh` | ~5 min | End-to-end delivery: dedup, per-op, replay, rename-parity, hash-ops |
| **L4** | `scripts/verify-failover.sh` | ~12 min | At-least-once survives SIGKILL of the active leader |

### Change type → required level (minimum; more is fine)

| You changed… | Required |
|---|---|
| Docs, comments, reports | none (read-back only) |
| Go code in `internal/` or `main.go` | L0; + L3 if it touches writer/verifier/elector behavior |
| Chart templates or `values*.yaml` | L1; + L3 if it affects any deployed-by-default component |
| Connect pipeline YAML (`chart/files/connect/*`) or Lua | L1 + L3 |
| Sharding machinery (`cdc-reverse-sharded.yaml`, the forward shard mapping/output variant, shard helpers in `_helpers.tpl`, shard consumer creation in nats-init) | L1 + L2 (`test-shard-mapping.sh`) + L3 with `RUN_SHARDING=1`; + the L4 sharding scripts (`verify-sharding-failover.sh`, `verify-sharding-replay.sh`) if it touches INV-1 row 13 |
| Anything in the INV-1 load-bearing table | L1 + L3, **+ L4 where the table says so** |
| Metrics, dashboard JSON, alert rules | L1 + the INV-2 grep check + L2; L3 if metric emission changed |
| The lab itself (`labs/redis-cdc-error-alerting/**`) | L2 |
| Build scripts / Dockerfile | Build image + L3 |
| `scripts/run-all-tests.sh` / CI workflow | run the entrypoint itself (fast tiers at minimum) |

If a change matches more than one row, the **strictest** matching row applies.

### Reporting rule (weak-model-safe)

Before saying a change is done, paste: the exact command(s) run, exit status, and the relevant
result line (verifier: the `verdict.pass=true` field of RESULT_JSON, or the script's final
`[verify-cdc] PASS` line). If a required level was skipped, say so
explicitly and why. Never claim "tests pass" without having run them in this session.
(See `rules/20-judgment-rubric.md` §Completion.)

---

## Change checklist (copy into your working notes for any non-doc change)

1. Which invariants does this change touch? (INV-1/2/3/4 tables above)
2. Did I keep every load-bearing line true, or get user approval to change it?
3. Which ladder level is required? Did I run it? Paste command + result.
4. If I added a metric → dashboard panel updated? If a component → `enabled:` toggle present?
5. Anything discovered that belongs in `rules/50-lessons.md`?
