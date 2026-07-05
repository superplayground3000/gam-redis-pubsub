# CDC Observability — Chart Additions Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Grafana dashboard, a Prometheus unprocessable-message alert, and a ServiceMonitor to the `redis-cdc-le-k8s` chart (opt-in, kube-prometheus-stack conventions), plus a `cdc_unprocessable` counter in the sink pipeline — the chart ships the dashboard/alert artifacts but no Prometheus/Grafana/Alertmanager.

**Architecture:** Two single-source artifacts (`chart/files/grafana/cdc-dashboard.json`, `chart/files/prometheus/cdc-alerts.yaml`) are embedded into Helm objects via `.Files.Get` and (in Plan 2) mounted verbatim by the lab, so the lab validates exactly what ships. The sink pipeline (`cdc-reverse.yaml`) gains a `cdc_unprocessable{reason}` counter on its two permanent-poison paths. All observability objects are gated by `.Values.observability.enabled` (default false).

**Tech Stack:** Helm (Go templates), Redpanda Connect (Bloblang / `metric` processor), Prometheus (`increase()` alert, `promtool`), Grafana dashboard JSON, `hpdevelop/connect:4.92.0-claudefix`.

**Spec:** `docs/superpowers/specs/2026-07-04-redis-cdc-observability-alerting-design.md`

**Prerequisites:** `helm` v3, `promtool` (from `prometheus`), `jq`, `yq`, and Docker (for the metric name-pin task). Run all commands from `redis-cdc-le-k8s/`.

---

## File Structure

- `chart/files/connect/cdc-reverse.yaml` — **modify**: add `cdc_unprocessable` counter (unknown_op + decode_error).
- `chart/files/prometheus/cdc-alerts.yaml` — **create**: Helm-free Prometheus rule groups (single source).
- `chart/files/grafana/cdc-dashboard.json` — **create**: portable dashboard (single source; `${datasource}` variable).
- `chart/templates/observability/servicemonitor.yaml` — **create**.
- `chart/templates/observability/prometheusrule.yaml` — **create** (embeds `cdc-alerts.yaml`).
- `chart/templates/observability/dashboard-configmap.yaml` — **create** (embeds `cdc-dashboard.json`).
- `chart/values.yaml` — **modify**: add `observability.*` block; add ackWait cadence-coupling comment.

---

## Task 1: Add `cdc_unprocessable` counter to the sink pipeline

**Files:**
- Modify: `chart/files/connect/cdc-reverse.yaml` (top-level mapping ~lines 61-85; op `switch` ~lines 102-186)

Two poison paths get the counter. `unknown_op` is a `metric` processor before the existing `throw`. `decode_error` uses a Bloblang `.catch(null)` in the top-level mapping to set a `decode_failed` flag, then a **new first branch** in the op `switch` that increments the counter and throws (nack). This keeps `decode_error` isolated from transient region-Redis apply failures (which must NOT hit this counter), and the exclusive `switch` guarantees a decode-failed message never reaches the apply logic.

- [ ] **Step 1: Modify the top-level mapping to detect decode failure**

In `chart/files/connect/cdc-reverse.yaml`, replace the existing `meta body = if ...` block inside the first `- mapping:` (the one that stashes `meta op`/`type`/`kv_key`/`old_key`/`new_key`) with a `.catch(null)`-based decode plus a `decode_failed` flag. The stash lines for op/type/keys stay unchanged; only the body-decode line changes:

```yaml
        # OP-GATE the body decode; on failure set decode_failed so the switch's
        # first branch counts it as unprocessable (reason=decode_error) and nacks —
        # WITHOUT ever reaching the apply logic. .catch(null) turns a bad
        # base64/gzip body into null instead of throwing mid-mapping.
        let decoded = if this.op == "create" || this.op == "update" {
          if this.enc.or("") == "gzip:base64" {
            this.body.decode("base64").decompress("gzip").catch(null)
          } else { this.body }
        }
        meta body = $decoded
        meta decode_failed = if (this.op == "create" || this.op == "update") && this.enc.or("") == "gzip:base64" && $decoded == null { "yes" } else { "no" }
```

- [ ] **Step 2: Add the decode_error branch as the FIRST case in the op `switch`**

Immediately after `- switch:` and before the existing `- check: meta("op") == "create" || meta("op") == "update"` case, insert:

```yaml
        - check: meta("decode_failed") == "yes"
          processors:
            # Permanent poison: the gzip:base64 body could not be decoded. Count it,
            # then throw to nack (redelivered under maxDeliver=-1 until removed).
            - metric:
                type: counter
                name: cdc_unprocessable
                labels:
                  reason: decode_error
            - mapping: 'root = throw("decode_error: undecodable gzip:base64 body for kv_key %s".format(meta("kv_key").or("?")))'
```

- [ ] **Step 3: Add the counter to the unknown-op (default) branch**

Replace the existing default branch:

```yaml
        - processors:
            - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'
```

with:

```yaml
        - processors:
            - metric:
                type: counter
                name: cdc_unprocessable
                labels:
                  reason: unknown_op
            - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'
```

- [ ] **Step 4: Verify the chart still renders**

Run: `helm template t chart --set observability.enabled=false >/dev/null && echo OK`
Expected: `OK` (no template errors).

- [ ] **Step 5: Verify the pipeline config is valid Bloblang/YAML against the pinned image**

Render the sink stream config and lint it with the pinned Connect image (Connect validates streams configs with `lint`):

Run:
```bash
helm template t chart | yq 'select(.metadata.name|test("cdc-reverse|connect-sink-cfg|connect-configmaps"))' >/dev/null 2>&1 || true
docker run --rm -i hpdevelop/connect:4.92.0-claudefix lint /dev/stdin < <(helm template t chart --show-only templates/connect-configmaps.yaml | yq -r 'select(.data["cdc-reverse.yaml"]) | .data["cdc-reverse.yaml"]')
```
Expected: no lint errors printed (exit 0). If `--show-only` path differs, run `helm template t chart | yq -r 'select(.kind=="ConfigMap") | .data["cdc-reverse.yaml"] // empty'` to locate the rendered file and pipe that into `lint`.

- [ ] **Step 6: Commit**

```bash
git add chart/files/connect/cdc-reverse.yaml
git commit -m "feat(cdc): add cdc_unprocessable counter (unknown_op + decode_error) to sink pipeline"
```

---

## Task 2: Pin the exposed metric names from `/metrics`

The dashboard/alert must reference the ACTUAL series names emitted by the pinned image. This task records them so later tasks are not guessing. The shipped artifacts use a `{__name__=~"cdc_unprocessable(_total)?"}` regex (robust to the suffix), and this task confirms the regex matches exactly the counter series and never the OpenMetrics `_created` series.

**Files:** none modified (investigation task; record findings in the commit message / plan notes).

- [ ] **Step 1: Boot a throwaway Connect with the two metric processors and scrape it**

Create a scratch streams config that emits both counters, then curl `/metrics`:

```bash
cat > /tmp/pin.yaml <<'EOF'
http: { address: 0.0.0.0:4195, enabled: true }
metrics: { prometheus: {} }
input:
  generate:
    count: 1
    interval: ""
    mapping: 'root = {}'
pipeline:
  processors:
    - metric: { type: counter, name: cdc_unprocessable, labels: { reason: unknown_op } }
    - metric: { type: counter, name: cdc_apply, labels: { op: create, type: string } }
output:
  drop: {}
EOF
docker run --rm -d --name pin -p 4195:4195 -v /tmp/pin.yaml:/pin.yaml hpdevelop/connect:4.92.0-claudefix -c /pin.yaml
sleep 3
curl -s localhost:4195/metrics | grep -E '^cdc_(unprocessable|apply)' | sort -u
docker rm -f pin
```

- [ ] **Step 2: Record the observed names**

Expected: one of `cdc_unprocessable` or `cdc_unprocessable_total` (and same for `cdc_apply`), plus possibly a `cdc_unprocessable_created` gauge. Confirm the regex `cdc_unprocessable(_total)?` matches the counter line(s) and NOT `_created` (PromQL `=~` is a full-string match, so `_created` is excluded). Note the exact form in the commit message of Task 3 so reviewers know which suffix the pinned image uses.

- [ ] **Step 3: Commit (notes only — no file change; skip if nothing to record)**

No commit needed; carry the observed suffix into Task 3/4.

---

## Task 3: Create the single-source Prometheus alert file

**Files:**
- Create: `chart/files/prometheus/cdc-alerts.yaml`

- [ ] **Step 1: Write the rule file (Helm-free; regex metric name; cadence coupling documented)**

```yaml
# cdc-alerts.yaml — Prometheus rule groups for the CDC sink's unprocessable-message
# alert. SINGLE SOURCE: this exact file is (a) embedded into a PrometheusRule CRD
# spec by chart/templates/observability/prometheusrule.yaml via .Files.Get, and
# (b) mounted VERBATIM as a rules file by the validation lab's Prometheus (Plan 2).
# It MUST stay Helm-free (no {{ .Values ... }}) because the lab does not render it.
# The {{ $labels.x }} below are PROMETHEUS alert templates, not Helm — .Files.Get
# returns raw bytes so Helm never touches them.
#
# CADENCE COUPLING — DO NOT BREAK: the [2m] window must stay >= 2x the sink
# consumer's ackWait (values.yaml: nats.stream.consumer.ackWait, default 30s). The
# counter re-increments once per redelivery (cadence == ackWait); a window smaller
# than the cadence makes the alert flap in the gaps. If you raise ackWait, raise
# this window to >= 2x ackWait. There is intentionally NO keep_firing_for: a window
# larger than the cadence already holds the alert firing continuously, and stacking
# both would leave the alert firing ~(window + keep_firing_for) after the poison is
# gone. As written the alert clears ~one window (≈2m, ±one scrape interval) after
# the last redelivery.
#
# METRIC NAME: cdc_unprocessable is a Redpanda Connect `metric` counter (base name
# cdc_unprocessable); depending on exposition it scrapes as cdc_unprocessable or
# cdc_unprocessable_total. The __name__ regex matches both and (being a full-string
# match) EXCLUDES the OpenMetrics cdc_unprocessable_created series.
groups:
  - name: cdc-sink
    rules:
      - alert: CDCUnprocessableMessages
        expr: |
          sum by (namespace, job, reason) (
            increase({__name__=~"cdc_unprocessable(_total)?"}[2m])
          ) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "CDC sink has unprocessable messages (reason={{ $labels.reason }})"
          description: >-
            The CDC sink in namespace {{ $labels.namespace }} (job {{ $labels.job }})
            is receiving messages it cannot apply (reason={{ $labels.reason }}). Under
            maxDeliver=-1 these redeliver until removed. Inspect the JetStream durable
            consumer and the poison message. The alert clears ~2m after the last
            redelivery once the poison is cleared.
```

- [ ] **Step 2: Validate with promtool**

Run: `promtool check rules chart/files/prometheus/cdc-alerts.yaml`
Expected: `SUCCESS: 1 rules found`.

- [ ] **Step 3: Commit**

```bash
git add chart/files/prometheus/cdc-alerts.yaml
git commit -m "feat(cdc): add single-source Prometheus unprocessable-message alert rule"
```

---

## Task 4: Create the single-source Grafana dashboard

**Files:**
- Create: `chart/files/grafana/cdc-dashboard.json`

Portable across the cluster's Grafana (sidecar) and the lab's Grafana: no pinned datasource UID, no `__inputs`; a `${datasource}` template variable resolves per environment. Every query scoped by `namespace`/`job`; error panels use `increase()` (activity), not the raw counter; built-in `processor_error` summed to drop native labels.

- [ ] **Step 1: Write the dashboard JSON**

```json
{
  "title": "CDC Sink — Throughput & Unprocessable",
  "uid": "cdc-sink-observability",
  "schemaVersion": 39,
  "editable": true,
  "time": { "from": "now-1h", "to": "now" },
  "templating": {
    "list": [
      {
        "name": "datasource",
        "type": "datasource",
        "query": "prometheus",
        "current": {},
        "hide": 0
      },
      {
        "name": "namespace",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "${datasource}" },
        "query": "label_values(cdc_apply_total, namespace)",
        "refresh": 2,
        "includeAll": true,
        "multi": true
      },
      {
        "name": "job",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "${datasource}" },
        "query": "label_values(cdc_apply_total{namespace=~\"$namespace\"}, job)",
        "refresh": 2,
        "includeAll": true,
        "multi": true
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "Apply throughput (ops/s) by op/type",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "sum by (op,type) (rate({__name__=~\"cdc_apply(_total)?\",namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval]))",
          "legendFormat": "{{op}}/{{type}}"
        }
      ]
    },
    {
      "id": 2,
      "title": "Unprocessable (5m) — activity",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "gridPos": { "h": 8, "w": 6, "x": 12, "y": 0 },
      "fieldConfig": { "defaults": { "thresholds": { "steps": [ { "color": "green", "value": null }, { "color": "red", "value": 1 } ] } } },
      "targets": [
        {
          "expr": "sum(increase({__name__=~\"cdc_unprocessable(_total)?\",namespace=~\"$namespace\",job=~\"$job\"}[5m]))",
          "legendFormat": "unprocessable"
        }
      ]
    },
    {
      "id": 3,
      "title": "Unprocessable rate by reason",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "gridPos": { "h": 8, "w": 6, "x": 18, "y": 0 },
      "targets": [
        {
          "expr": "sum by (reason) (increase({__name__=~\"cdc_unprocessable(_total)?\",namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval]))",
          "legendFormat": "{{reason}}"
        }
      ]
    },
    {
      "id": 4,
      "title": "Connect processor errors (context)",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [
        {
          "expr": "sum(rate(processor_error{namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval]))",
          "legendFormat": "processor_error/s"
        }
      ]
    }
  ]
}
```

> Note: the `label_values(cdc_apply_total, ...)` variable queries assume the `_total` suffix; if Task 2 showed the unsuffixed form, change those two `query` strings to `cdc_apply`. The panel `expr`s already use the `(_total)?` regex and need no change.

- [ ] **Step 2: Validate JSON**

Run: `jq -e '.uid and .templating.list and (.panels|length>=4)' chart/files/grafana/cdc-dashboard.json`
Expected: prints `true`, exit 0.

- [ ] **Step 3: Confirm no pinned datasource UID and no `__inputs`**

Run: `jq -e '(.. | objects | select(has("datasource")) | .datasource | .uid? // "${datasource}") as $u | true' chart/files/grafana/cdc-dashboard.json && ! grep -q '__inputs' chart/files/grafana/cdc-dashboard.json && echo OK`
Expected: `OK` (no `__inputs`; all datasources reference `${datasource}`).

- [ ] **Step 4: Commit**

```bash
git add chart/files/grafana/cdc-dashboard.json
git commit -m "feat(cdc): add portable single-source Grafana dashboard"
```

---

## Task 5: Add the `observability` values block + ackWait coupling comment

**Files:**
- Modify: `chart/values.yaml` (append `observability` block near the end; add comment beside `nats.stream.consumer.ackWait`)

- [ ] **Step 1: Add the observability block**

Append to `chart/values.yaml` (top-level, keep existing indentation style):

```yaml
# Observability artifacts for an EXISTING cluster monitoring stack. The chart ships
# a Grafana dashboard, a PrometheusRule alert, and a ServiceMonitor — but NOT
# Prometheus/Grafana/Alertmanager. Opt-in: the ServiceMonitor/PrometheusRule need
# the prometheus-operator CRDs to exist, so this defaults to false.
observability:
  enabled: false
  serviceMonitor:
    interval: 15s
    labels: {}          # match the operator's serviceMonitorSelector, e.g. { release: kube-prometheus-stack }
  prometheusRule:
    labels: {}          # match the operator's ruleSelector (CRD metadata only)
  dashboard:
    folder: ""          # optional Grafana sidecar target folder
    labels: {}          # extra ConfigMap labels beyond grafana_dashboard: "1"
```

- [ ] **Step 2: Add the cadence-coupling comment beside ackWait**

In `chart/values.yaml`, on the `ackWait: "30s"` line under `nats.stream.consumer`, append the coupling note so a future editor sees it:

```yaml
      ackWait: "30s"        # redelivery timeout if the sink hasn't acked. COUPLING:
                            # the CDCUnprocessableMessages alert window in
                            # files/prometheus/cdc-alerts.yaml must stay >= 2x this.
                            # If you raise ackWait, raise that window too.
```

- [ ] **Step 3: Verify render with the new values**

Run: `helm template t chart --set observability.enabled=false >/dev/null && helm lint chart`
Expected: no errors; `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 4: Commit**

```bash
git add chart/values.yaml
git commit -m "feat(cdc): add observability.* values + ackWait/alert-window coupling note"
```

---

## Task 6: ServiceMonitor template

**Files:**
- Create: `chart/templates/observability/servicemonitor.yaml`

- [ ] **Step 1: Write the template**

```yaml
{{- if .Values.observability.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect") }}
  labels:
    app: cdc-observability
    {{- with .Values.observability.serviceMonitor.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  # Namespace-scoped isolation: only this release's namespace. Selects BOTH Connect
  # legs by their app label; queries are further scoped by namespace/job in PromQL.
  namespaceSelector:
    matchNames:
      - {{ .Release.Namespace }}
  selector:
    matchExpressions:
      - key: app
        operator: In
        values: [connect-source, connect-sink]
  endpoints:
    - port: http
      path: /metrics
      interval: {{ .Values.observability.serviceMonitor.interval }}
{{- end }}
```

- [ ] **Step 2: Verify it renders only when enabled**

Run:
```bash
test -z "$(helm template t chart --set observability.enabled=false --show-only templates/observability/servicemonitor.yaml 2>/dev/null)" && \
helm template t chart --set observability.enabled=true --show-only templates/observability/servicemonitor.yaml | yq -e '.kind=="ServiceMonitor" and (.spec.selector.matchExpressions[0].values | contains(["connect-sink"]))' && echo OK
```
Expected: `true` then `OK` (empty when disabled; valid ServiceMonitor selecting both legs when enabled).

- [ ] **Step 3: Commit**

```bash
git add chart/templates/observability/servicemonitor.yaml
git commit -m "feat(cdc): add opt-in ServiceMonitor for Connect /metrics"
```

---

## Task 7: PrometheusRule template (embeds the single-source alert)

**Files:**
- Create: `chart/templates/observability/prometheusrule.yaml`

- [ ] **Step 1: Write the template**

```yaml
{{- if .Values.observability.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "cdc-alerts") }}
  labels:
    app: cdc-observability
    {{- with .Values.observability.prometheusRule.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- /* cdc-alerts.yaml is a `groups:` document; .Files.Get returns it raw (Helm
         does NOT render {{ $labels }} inside files/). Indent it under spec. */}}
  {{- .Files.Get "files/prometheus/cdc-alerts.yaml" | nindent 2 }}
{{- end }}
```

- [ ] **Step 2: Verify the embedded groups render into a valid PrometheusRule**

Run:
```bash
helm template t chart --set observability.enabled=true --show-only templates/observability/prometheusrule.yaml \
  | yq -e '.kind=="PrometheusRule" and (.spec.groups[0].rules[0].alert=="CDCUnprocessableMessages")' && echo OK
```
Expected: `true` then `OK`.

- [ ] **Step 3: Extract the rendered spec and re-validate with promtool**

Run:
```bash
helm template t chart --set observability.enabled=true --show-only templates/observability/prometheusrule.yaml \
  | yq '.spec' | promtool check rules /dev/stdin
```
Expected: `SUCCESS: 1 rules found`.

- [ ] **Step 4: Commit**

```bash
git add chart/templates/observability/prometheusrule.yaml
git commit -m "feat(cdc): add opt-in PrometheusRule embedding the single-source alert"
```

---

## Task 8: Dashboard ConfigMap template (embeds the single-source dashboard)

**Files:**
- Create: `chart/templates/observability/dashboard-configmap.yaml`

- [ ] **Step 1: Write the template**

```yaml
{{- if .Values.observability.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "cdc-dashboard") }}
  labels:
    grafana_dashboard: "1"
    {{- with .Values.observability.dashboard.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.observability.dashboard.folder }}
  annotations:
    k8s-sidecar-target-directory: {{ . | quote }}
  {{- end }}
data:
  cdc-dashboard.json: |
{{ .Files.Get "files/grafana/cdc-dashboard.json" | indent 4 }}
{{- end }}
```

- [ ] **Step 2: Verify the ConfigMap renders with valid embedded JSON and the sidecar label**

Run:
```bash
helm template t chart --set observability.enabled=true --show-only templates/observability/dashboard-configmap.yaml \
  | yq -e '.metadata.labels["grafana_dashboard"]=="1"' && \
helm template t chart --set observability.enabled=true --show-only templates/observability/dashboard-configmap.yaml \
  | yq -r '.data["cdc-dashboard.json"]' | jq -e '.uid=="cdc-sink-observability"' && echo OK
```
Expected: `true`, `true`, `OK` (label present; embedded JSON parses and round-trips).

- [ ] **Step 3: Commit**

```bash
git add chart/templates/observability/dashboard-configmap.yaml
git commit -m "feat(cdc): add opt-in Grafana dashboard ConfigMap (sidecar-loaded)"
```

---

## Task 9: Whole-chart render gate (enabled + disabled)

**Files:** none (verification task).

- [ ] **Step 1: Disabled path emits zero observability objects**

Run:
```bash
helm template t chart --set observability.enabled=false \
  | yq -e 'select(.kind=="ServiceMonitor" or .kind=="PrometheusRule" or (.kind=="ConfigMap" and .metadata.labels["grafana_dashboard"]=="1")) | .kind' \
  | wc -l
```
Expected: `0`.

- [ ] **Step 2: Enabled path emits exactly the three objects**

Run:
```bash
helm template t chart --set observability.enabled=true \
  | yq -e 'select(.kind=="ServiceMonitor" or .kind=="PrometheusRule" or (.kind=="ConfigMap" and .metadata.labels["grafana_dashboard"]=="1")) | .kind' \
  | sort | uniq -c
```
Expected: one each of `ConfigMap`, `PrometheusRule`, `ServiceMonitor`.

- [ ] **Step 3: Full lint**

Run: `helm lint chart && helm template t chart --set observability.enabled=true >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit (docs/marker only if anything changed; otherwise skip)**

No file change expected — this task is the render gate.

---

## Self-Review Notes (author)

- **Spec coverage:** metric design (Task 1), single-source alert (Task 3) + dashboard (Task 4), kube-prometheus-stack delivery via ServiceMonitor/PrometheusRule/ConfigMap (Tasks 6-8), opt-in `observability.enabled` default false (Task 5), name-pin from `/metrics` (Task 2), ackWait cadence coupling in both the rule file header and beside `ackWait` (Tasks 3 + 5), namespace-boundary isolation + namespace/job query scoping (Tasks 4, 6). The lab (spec §"Validation lab") is **Plan 2**.
- **Deferred to Plan 2:** the docker-compose lab, Go `generator` + `alert-sink`, `verify-alert.sh` (healthy/poison/recovery), `RESEARCH.md` — all consume `chart/files/prometheus/cdc-alerts.yaml` and `chart/files/grafana/cdc-dashboard.json` produced here.
- **Name-suffix caveat:** dashboard variable `label_values(...)` queries hardcode `cdc_apply_total`; Task 2 confirms the suffix and Step-1 note in Task 4 says exactly what to change if the pinned image emits the unsuffixed form. Panel exprs use the `(_total)?` regex and are suffix-agnostic.
