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

**Statement:** Every *valid* message XADDed to the central Redis stream is applied to the region
Redis at least once, provided the Redis stream and NATS JetStream themselves are not corrupted.
Duplicates are allowed (absorbed by idempotency); loss is not. **Malformed (unprocessable)
messages are exempt:** when `connect.deadLetter.enabled`, a malformed message is parked on the
dead-letter subject with a confirmed PubAck instead of being applied (owner-approved 2026-07-20,
docs/superpowers/plans/2026-07-20-all-in-one-sink-group.md). **This exemption applies identically
to the sharded sink** (`chart/files/connect/cdc-reverse-sharded.yaml`) when
`connect.sharding.families` is configured — both pipelines park via `reject_errored` +
switch-output(`dlq_out`), write-then-ack (rows 8/14/15). In a multi-env topology each env parks
its OWN copy under `<dlqRoot>.<envId>.<reason>` with `Nats-Msg-Id: dlq.<envId>.<event_id>`; the
env-scoping of BOTH the subject and the msg-id is load-bearing — a bare `dlq.<event_id>` would let
one env's park dedupe against another's (stream-wide, subject-independent msg-id dedup) → a silent
per-env hole (design.md §5.4/E2). Proven by `scripts/verify-sharded-dlq-e2e.sh` PASS 2026-07-21
(3 classes parked env-scoped, +9 PubAck, O-6 held) and `scripts/verify-multi-env.sh` PASS
2026-07-21 (cross-park: two env-scoped copies, no dedup-swallow).

### Load-bearing lines (do not change without running L3, and L4 where marked)

| # | File | What must stay true | Why |
|---|---|---|---|
| 1 | `chart/files/connect/cdc-forward.yaml` | Source XACKs Redis only after NATS PubAck (Connect `redis_streams` input + `commit_period`; write-then-ack) | Entry never acked before it is durably in JetStream |
| 2 | `chart/files/connect/cdc-forward.yaml` + `chart/values.yaml` (`connect.source.consumerClientId`) | Consumer client id is **stable and role-scoped** (`cdc_propagator_active`), never pod-scoped (`__POD__`) — **L4 required if touched** | Pod-scoped id orphans the PEL on SIGKILL; historical bug lost 757 msgs (`docs/failover-report/REPORT.md`) |
| 3 | `chart/files/connect/cdc-forward.yaml` | `auto_replay_nacks: true`; consumer group `cdc_propagator` unchanged | Unacked entries must be re-read |
| 4 | `chart/files/connect/cdc-forward.yaml` | JetStream publish sets header `Nats-Msg-Id: meta("event_id")` (inside the `fallback` first child) | Server-side dedup absorbs replays after crash-between-publish-and-ack |
| 5 | `chart/values.yaml` (`nats.stream.dupeWindow: 5m`) | Dedup window stays ≥ the realistic replay window | Same as #4 |
| 6 | `chart/files/connect/cdc-reverse.yaml` | Sink binds to a pre-created durable pull consumer, `bind: true`. The durable base is **env-parameterized** via `connect.envId` — `cdc_sink_<envId>` (shards `cdc_sink_<envId>_<fam>_s<K>`), defaulting to the bare `cdc_sink` when `envId` is empty (byte-identical legacy render). Two releases MUST NOT share a durable base — they would collide on one ack floor → split delivery, not a full copy (design.md §4/E1, VF-2). `envId` is IMMUTABLE for a release's life (see operational invariant below). Bind semantics unchanged | Ad-hoc consumers reset delivery state; a shared base splits one env's stream between two |
| 7 | `chart/values.yaml` (`nats.stream.consumer`) | `maxDeliver: -1` (redeliver forever), `ackWait` finite (30s default) | Poison messages must redeliver, not vanish |
| 8 | `chart/files/connect/cdc-reverse.yaml` + `chart/files/connect/cdc-reverse-sharded.yaml` | Output wraps in `reject_errored`: Redis apply runs **before** ack; processor failure nacks. The inner output is `drop` in the non-DLQ render; under `connect.deadLetter.enabled` it becomes `switch{dlq_out, drop}` (park-then-ack) in **both** pipelines — the `reject_errored` wrapper is unchanged, and the non-DLQ render stays `reject_errored`+`drop` (E4). Touching the sharded variant → L3 `RUN_SHARDING=1` + L4 sharding | Message acked to JetStream only after the region write (or a PubAck-confirmed park) succeeded |
| 9 | `chart/files/connect/cdc_rename.lua` | Rename guarded by `EXISTS` (idempotent no-op on redelivery) | Redelivered rename must not error-loop or corrupt |
| 10 | `internal/elector/` + `chart/values.yaml` lease settings | Leader election keeps exactly one active leg; standby takes over on lease expiry | Recovery path for #2 |
| 11 | `chart/files/connect/cdc-forward.yaml` | The output `fallback`'s failure child stays `reject` (nack → replay). Never `drop` or any child that succeeds without a JetStream PubAck. **Sharded render exception (subject-sharding v2, owner-approved 2026-07-15):** when `connect.sharding.families` is configured the fallback is REMOVED BY DESIGN — the output is a bare `nats_jetstream` with `max_in_flight: 1` that blocks and retries in place (a forward nack would PEL-replay an older event after newer ones already published → silent reorder, which v2 cannot detect without a fence). Write-then-XACK is unchanged: no PubAck ⇒ no ack. Do NOT re-add a reject path to the sharded variant, and do NOT remove the fallback from the non-sharded render | The fallback child runs when the publish failed; anything that "succeeds" there would XACK entries that never reached JetStream — silent loss. It exists only to count (`cdc_forward_publish_failed`) and nack |
| 13 | `chart/files/connect/cdc-forward.yaml`, `chart/files/connect/cdc-reverse-sharded.yaml`, `chart/templates/_helpers.tpl` | Sharded render (v2 ordering chain O-3..O-7): forward `pipeline.threads: 1` + `max_in_flight: 1`; sink broker `copies: 1` + `pipeline.threads: 1`; every shard durable `max_ack_pending: 1` (hard-coded in the helper's consumers list, never the values inheritance chain). **Loosening ANY of these silently reintroduces old-overwrites-new and no metric can detect it** (`docs/design/subject-sharding/design.md` §3) — L3 `RUN_SHARDING=1` + L4 sharding scripts required if touched. **Under `connect.deadLetter.enabled` these numbers are UNCHANGED** (`copies:1`/`threads:1`/MAP:1): the DLQ `switch` output (row 8) does not loosen O-6/O-7 — park-then-ack occupies the SAME single-in-flight slot as a normal apply (the ack is emitted by the output transaction only after the DLQ PubAck, and the broker routes it back to the originating shard child), and a parked message is poison carrying no valid change, so occupying the slot cannot reorder any key (design.md §5.3). Verified `scripts/verify-sharding-failover.sh` + `scripts/verify-sharding-replay.sh` PASS 2026-07-21 (O-6 held) | v2 removed the LWW fence; per-key apply order IS the correctness mechanism |
| 12 | `chart/templates/connect-source.yaml`, `chart/templates/connect-sink.yaml` | Pod template keeps the `checksum/connect-config` annotation over the connect ConfigMaps | The elector POSTs the pipeline only when it wins the Lease; without the checksum-triggered rollout, a helm upgrade that edits a pipeline never reaches the running leg — you verify stale config (bit this repo on 2026-07-05, `rules/50-lessons.md`) |
| 14 | `chart/files/connect/cdc-reverse.yaml` | DLQ path (when `connect.deadLetter.enabled`) stays publish-to-DLQ-then-ack: under `reject_errored`, permanent poison (`meta("dlq")=="yes"`) is published to the computed DLQ root suffixed with `.<reason>` — the root is the legacy out-of-prefix subject `<deadLetter.subject>`, or, under the owner-approved shared-prefix layout, the in-prefix `<nats.stream.subjectPrefix>.<connect.deadLetter.segment>` (`docs/superpowers/plans/2026-07-20-shared-prefix-subject-layout.md`) — with header `Nats-Msg-Id: dlq.${event_id}`, and only then acked; a DLQ send failure surfaces as an output error → `reject_errored` nacks → redelivery (`cdc-reverse.yaml:418-444`) | Parking must never ack a message whose park was not durably confirmed; the `dlq.` msg-id prefix keeps a redelivered poison deduping against its own earlier DLQ publish, never against the original publish subject space (which would PubAck{duplicate} → ack → nothing parked — a silent INV-1 hole) |
| 15 | `chart/files/connect/cdc-reverse-sharded.yaml` | **Sharded DLQ path (mirrors row 14 for the sharded pipeline; multi-env mixed-sink, 2026-07-21).** When `connect.deadLetter.enabled` AND `connect.sharding.families` are set, the sharded output stays publish-to-DLQ-then-ack: under `reject_errored`, permanent poison (`meta("dlq")=="yes"`, classes `decode_error`/`hash_decode_error`/`unknown_op`) is published to `<dlqRoot>.<envId>.<reason>` with header `Nats-Msg-Id: dlq.<envId>.<event_id>` (via `rrcs.nats.dlqMsgIdPrefix`), PubAck-confirmed, then acked; a send failure → `output_error{label=dlq_out}` → `reject_errored` nacks → redelivery on the SAME shard durable (safe under MAP=1). BOTH the subject and the msg-id are env-scoped (E2) so two envs never dedupe-swallow each other's park. **Also load-bearing: the sharded pipeline MUST carry the `hash_decode_failed` guard** — the `cdc_unprocessable{shard,reason=hash_decode_error}` counter renders UNCONDITIONALLY (only the PARK action gates on `deadLetter.enabled`), closing the pre-existing INV-2 hole (E3). Touching this → L3 `RUN_SHARDING=1` + L4 sharding. Proven `scripts/verify-sharded-dlq-e2e.sh` PASS 2026-07-21 (3 classes parked env-scoped, +9 PubAck, shard unblocked) | Same contract as row 14: a park must never ack before it is durably confirmed, and the `dlq.<envId>.` msg-id prefix keeps a redelivered poison deduping against its OWN earlier park, never the original publish or another env's park — either would PubAck{duplicate} → ack → nothing parked, a silent per-env INV-1 hole |

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

### Operational invariants (multi-env mixed-sink, 2026-07-21 — owner-approved E1/E9)

These are release-topology rules, not single load-bearing lines; a violation is a silent INV-1
loss the render cannot catch (each helm release renders independently — no cross-release guard).

- **Exactly ONE publisher release per shared stream (E9).** The forward leg's identity is GLOBAL:
  Redis consumer group `cdc_propagator` + client id `cdc_propagator_active` (INV-1 rows 2-3, VF-17).
  A second publisher release collides on that group and SPLITS the `app.events` read → each gets
  a partial copy → silent loss. Multi-env fan-out is native JetStream multi-consumer (N durables,
  N ack floors) off the ONE published copy — never N publishers. Sink-only releases add durables,
  never a second forward.
- **`connect.envId` is IMMUTABLE for a release's life (E1).** It feeds the durable base
  (`cdc_sink_<envId>`), the DLQ subject + msg-id, `resourcePrefix`, and the `env` metric label.
  Renaming it mints a NEW durable (a `--deliver all` replay burst, VF-16), orphans the old one
  (accruing `num_pending`), AND moves the DLQ lane (stranding parked poison) — same hazard class as
  the row-2 consumer-id rename. To re-home an env, plan a bootstrap/handoff (runbooks in
  `docs/design/multi-env-mixed-sink/`), never an in-place `envId` edit. Verified disjoint by
  `scripts/verify-multi-env.sh` PASS 2026-07-21 (two envs, disjoint durables, independent floors).

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
| `chart/files/connect/cdc-reverse-sharded.yaml` | Same contract as cdc-reverse.yaml (`cdc_unprocessable{shard,reason}`, `cdc_apply{shard,op,type}` after successful apply, `cdc_sync_latency_seconds{op,shard}` post-apply with clamp + int-ns, `cdc_sync_skew_negative{shard}`) — the shard label comes from the broker child, never `kv_key` (INV-S8). **`hash_decode_error` is a `cdc_unprocessable{shard,reason}` value** whose counter renders UNCONDITIONALLY (independent of `deadLetter.enabled`) — closes the pre-existing sharded hash-guard hole (E3, VF-8). **Under `connect.deadLetter.enabled` the DLQ park path also emits `cdc_dlq_forwarded{shard,reason}`** in-pipeline (routed, one of the three classifier branches — a switch-output case cannot count post-write on this build), mirroring cdc-reverse.yaml; `output_sent{label=dlq_out}` is the PubAck-confirmed-parked signal |
| `chart/files/connect/cdc-reverse.yaml` | `cdc_apply{op,type}` increments only after a successful apply |
| `chart/files/connect/cdc-reverse.yaml` | `cdc_sync_latency_seconds{op}` timing records only after a successful apply (`!errored()` + `sync_has_ts` guard); its value stays clamped ≥ 0 and `.int64().string()`-formatted — a negative or float value makes the metric processor error AFTER the apply and nack an already-applied message. Negative deltas increment `cdc_sync_skew_negative` instead |
| `chart/files/connect/observability.yaml` | `use_histogram_timing: true`. Quirk of the pinned build: the timing metrics keep `_ns` names (`processor_latency_ns` etc.) but the histogram **buckets record seconds** — dashboards must treat values as seconds |
| `internal/latency/metrics.go` + `chart/templates/latency-calculator.yaml` | latency-calculator serves `cdc_latency_seconds{op,quantile}` gauges (+ samples, dropped-negative) on `:8082`, and its Service exposes port `http` for the ServiceMonitor |
| `chart/templates/observability/servicemonitor.yaml` | Selects connect legs + writer + latency-calculator (`http` endpoint) and the elector sidecars (`elector` endpoint, port 8090 on the connect Services) |
| `chart/files/grafana/cdc-dashboard.json` | Panels exist for: apply throughput, unprocessable activity, unprocessable-by-reason, processor errors, forward-leg publish failures, Connect latency p50/p95/p99, end-to-end latency percentiles, sync latency p50/p95/p99 by group, sync clock-skew negatives, writer throughput/errors, elector leadership, and **panel 18 "DLQ: routed vs confirmed parked"** — its `routed` series is `sum by (reason, shard)` so it covers the sharded pipeline's `cdc_dlq_forwarded{shard,reason}` with a per-shard breakdown, and `confirmed parked`/`publish failures` read `output_{sent,error}{label=dlq_out}` across `job=~".*connect-sink.*"` (sharded per-group jobs included). **If you add a metric, add/extend a panel in the same change.** |
| `chart/files/prometheus/cdc-alerts.yaml` | `CDCUnprocessableMessages` alert; its `increase[...]` window must stay ≥ 2× `nats.stream.consumer.ackWait` (redelivery cadence coupling — documented in the rule file header) |
| `chart/files/prometheus/cdc-alerts.yaml` | `CDCDeadLetterPublishFailing` alert fires on `output_error{label="dlq_out"} > 0` (DLQ publish failing → poison nack-loops instead of parking; the same failed-attempt series behind dashboard panel 18). Sink-leg scoped (`job=~".*connect-sink.*"`) — the substring selector ALSO matches sharded per-group sink jobs (`connect-sink-<group>`, and the env-prefixed `<envId>-connect-sink-<group>`), so a sharded env's DLQ publish failures page too; `sum by (namespace, job)` preserves per-namespace/per-env scoping so it never pages across envs (E4/E10). Shares the same `increase[...]` window ≥ 2× `ackWait` coupling as `CDCUnprocessableMessages` |
| `chart/files/prometheus/cdc-alerts.yaml` (sharding group) | `CDCShardStuck` (A1) and `CDCShardAckPendingViolation` (A6) recover the per-env `env` label from the durable name via `label_replace` on `cdc_sink_<envId>_<fam>_s<K>` (envId is DNS-1123, dash-only, no underscores — so the leading-token capture is unambiguous), for multi-env Alertmanager routing off the NATS-exporter series which carry only `durable` (E10, design §9). Best-effort on a legacy `cdc_sink_<fam>_s<K>` durable (no envId token) — harmless in single-env. Validated by promtool (`check rules`, 9 rules SUCCESS) 2026-07-21 |
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
