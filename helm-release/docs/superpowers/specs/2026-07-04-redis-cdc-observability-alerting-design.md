# redis-cdc-le-k8s Observability: Grafana Dashboard + Unprocessable-Message Alert + Validation Lab

**Date:** 2026-07-04
**Status:** Approved design, ready for planning
**Scope:** `redis-cdc-le-k8s/chart/` + new `labs/redis-cdc-error-alerting/`

## Problem

The CDC chart ships a Redpanda Connect source/sink relay whose sink leg
(`cdc-reverse.yaml`) can receive messages it fundamentally cannot apply — an
unknown `op`, or a body whose `enc="gzip:base64"` decode fails. Today these
`throw()` → nack → redeliver forever (poison) and surface only as Redpanda
Connect's generic built-in `processor_error`. There is:

- no Grafana dashboard (the chart's `dashboard` Deployment is an unrelated custom
  Go app, not Grafana),
- no alert for unprocessable messages,
- no purpose-built metric that means "this message will never apply,"
- no harness that proves an alert fires and the dashboard reflects reality.

## Goal

Add, to the chart, a **Grafana dashboard** and a **Prometheus alert** that fires
whenever an unprocessable message occurs — plus a self-contained docker-compose
**lab** that generates traffic and automatically proves both work. The chart must
**not** bundle Prometheus, Grafana, or Alertmanager; it ships only the dashboard
and alert artifacts for an existing cluster observability stack to consume.

## Decisions (locked)

1. **Alert signal — both.** A dedicated counter (pipeline `metric` name
   `cdc_unprocessable`, exposed as `cdc_unprocessable_total{reason}`) is the precise
   alert trigger; the built-in `processor_error` is shown on the dashboard for
   broader context (it also catches transient apply failures).
2. **Chart delivery — kube-prometheus-stack conventions.** Grafana dashboard as a
   ConfigMap with the `grafana_dashboard: "1"` sidecar label; alert as a
   `PrometheusRule` CRD; scrape via a `ServiceMonitor`. All gated behind
   `.Values.observability.enabled` (default **false** — the CRDs require the
   prometheus-operator CRDs to exist, so enabling is opt-in).
3. **Metrics port — keep 4195.** Redpanda Connect serves `/metrics` on the same
   HTTP listener as the streams REST API; there is no native second port. Rather
   than move the whole listener (elector POST, probes, Service, writer-wait,
   dashboard app all target 4195), we keep 4195 and scrape `4195/metrics`.
4. **Lab — distilled single-Connect sink pipeline** + Go traffic generator
   (Go per team preference), not the full k8s CDC stack and not a metric stub.

## Metric design

**Exposed series names are NOT frozen — pin them from `/metrics` first.** Redpanda
Connect's docs show built-ins as **unsuffixed** (`input_received`, `processor_error`,
`output_sent`), yet the sibling `lww` lab matches **both** `lww_apply{` and
`lww_apply_total{` — so whether a `_total` suffix (and a companion `_created`
series) appears is exposition/build-dependent and **must not be assumed**. The
series names in the queries below are **illustrative placeholders**; the ground
truth is the actual `/metrics` output of the pinned image
`hpdevelop/connect:4.92.0-claudefix` (`values.yaml:113`).

> **Implementation task (do this before writing any query).** Scrape
> `:4195/metrics` on a running Connect of the pinned image **once** in the lab and
> capture the **exact** emitted names and labels. Then pin every dashboard/alert/
> lab-scraper reference to those observed names. Skip `_created` series. Define the
> pipeline `metric` processor `name:` as the **base** `cdc_unprocessable` — **never**
> `cdc_unprocessable_total` (that would expose as `cdc_unprocessable_total_total`).
> If unsure across builds, match `{__name__=~"cdc_unprocessable(_total)?"}` rather
> than hardcoding one form.

| Pipeline `metric` name | Exposed series (illustrative — pin from `/metrics`) | Type | Labels | Role |
|---|---|---|---|---|
| `cdc_unprocessable` (new) | `cdc_unprocessable[_total]` | counter | `reason` = `unknown_op` \| `decode_error` | **Alert trigger** |
| `cdc_apply` (existing) | `cdc_apply[_total]` | counter | `op`, `type` | Success throughput |
| — (Connect built-in) | `processor_error`, `output_error` | counter | `path`, `label` | Dashboard context |
| — (Connect built-in) | `input_received`, `output_sent` | counter | `path`, `label`, `endpoint` | Throughput sanity |

`cdc_unprocessable` is incremented in the sink pipeline's two permanent-poison
paths (the `metric` processor commits the increment **before** the message errors,
so the counter still moves even though `output.reject_errored{drop{}}` ultimately
nacks/drops the message):

- **`unknown_op`** — the `switch` default branch that currently does
  `throw("unknown op: …")`. Add a `metric` counter processor before the throw.
- **`decode_error`** — the `create`/`update` body decode
  (`this.body.decode("base64").decompress("gzip")`). Restructure so the decode
  runs inside a `try`; the `catch` increments the counter with `reason=decode_error`
  and re-throws to preserve nack/redelivery semantics. **This is a structural
  refactor, not a drop-in:** today the decode lives in the top-level `mapping`
  (`cdc-reverse.yaml:61,79`) before the op `switch`. Implementing it means moving the
  body decode into a processor-level `try`/`catch` *inside* the create/update branch
  (a `mapping` that sets `meta("body")`), while leaving the op-gating and the
  existing latency/apply logic intact — the plan must treat it as an edit to the
  existing mapping structure.

Both are messages that will not succeed on redelivery, so counting them is the
correct "unprocessable" signal. Transient region-Redis apply failures deliberately
do **not** hit this counter — they self-heal on redelivery and appear only via
`processor_error` on the dashboard.

**Attempt-based, not distinct-message (by design).** The consumer is
`ackWait: 30s`, `maxDeliver: -1` (`values.yaml:85,87`) — a poison message is
redelivered **forever** (~every 30s) until acked, and the `metric` processor
increments on **every** attempt. So `cdc_unprocessable` counts *delivery attempts*,
not distinct poison messages, and once the alert fires it **stays firing** while the
poison keeps being retried — provided the alert lookback window is ≥ the redelivery
cadence (see Alert → Cadence coupling), and it clears ~one window after the poison
is gone. That is the intended "a human must remove/fix the poison" behavior — the
alert should not self-clear while an unprocessable message is stuck, but should
resolve promptly once it is.
The dashboard "Unprocessable" panels are therefore read as *activity present*, not
as a distinct-message count. (Distinct-message semantics would need a dedup key on
message id and are out of scope.)

## Single source of truth (anti-drift)

To guarantee the lab validates the exact artifacts the chart ships:

- `chart/files/grafana/cdc-dashboard.json` — the only dashboard file. The chart's
  dashboard ConfigMap embeds it via `.Files.Get`; the lab's Grafana provisioning
  points at the same file.
- `chart/files/prometheus/cdc-alerts.yaml` — the only Prometheus rule file (a plain
  `groups:` document). The chart's `PrometheusRule` template embeds its `groups:`
  into the CRD `spec` via `.Files.Get` (+ `fromYaml`/`toYaml`); the lab's
  Prometheus mounts the same file directly as a rules file.

One dashboard, one alert expression, consumed by both Helm and compose.

### Portability: the shared JSON must not pin a datasource

A single dashboard JSON only works in both Grafana instances if it does **not**
hardcode a Prometheus datasource UID/name — the cluster's datasource and the lab's
are different objects with different UIDs, so a pinned `"datasource"` resolves in
one and breaks in the other. Therefore the JSON references its datasource through a
Grafana **`datasource`-type template variable** (`name: datasource`,
`query: prometheus`); every panel and target uses
`"datasource": {"type": "prometheus", "uid": "${datasource}"}`. The variable
auto-selects whatever Prometheus datasource each environment exposes. The JSON
carries **no** `__inputs` block (the sidecar does not resolve `__inputs`).

The two loaders are **environment adapters, not drift** — they wrap the same
identical JSON without editing it:

- **Chart:** ConfigMap with `grafana_dashboard: "1"`; the kube-prometheus-stack
  Grafana sidecar imports it. The datasource variable resolves against the
  cluster's provisioned Prometheus datasource.
- **Lab:** a Grafana **datasource** provisioning file (Prometheus → the lab's
  `prometheus` service) plus a **dashboard provider** provisioning file pointing at
  the mounted `cdc-dashboard.json`. The variable resolves against that datasource.

The alert file needs no such treatment: a plain `groups:` document is a valid
Prometheus rule file verbatim in both the CRD `spec` and the lab's rules mount.

## Multi-install scoping (no cross-scrape / cross-alert)

**Isolation boundary = the namespace. One release per namespace (as the verify
scripts assume).** Within that boundary two facts do the work — and, importantly,
a release/instance label on the ServiceMonitor would **not** add isolation, so the
spec does not claim it does (see the "why not instance-scope" note below).

1. **Namespace-scoped scrape (built in, not added by us).** Kubernetes Services are
   namespace-scoped, so a Service's Endpoints only ever include pods in **its own
   namespace**; a ServiceMonitor's default `namespaceSelector` is its own namespace
   too. So for installs in **different namespaces there is no cross-scrape** — each
   ServiceMonitor sees only its namespace's Connect Services, whose Endpoints are
   only that namespace's pods. The ServiceMonitor simply selects
   `app In (connect-source, connect-sink)` on port name `http`, path `/metrics`, in
   the release namespace.

2. **Install-scoped queries.** prometheus-operator stamps `namespace` and `job`
   (= the `rrcs.name`-prefixed Service name, release-unique) onto every scraped
   series. All dashboard panels filter `{namespace=~"$namespace", job=~"$job"}`,
   and the alert aggregates **`by (namespace, job, reason)`** — so even when **one**
   Prometheus scrapes **many** namespaces, each install is a distinct series,
   labelled with the namespace/job that identifies it. This is what actually
   separates dashboards and alerts across installs.

> **Why not "instance-scope" the ServiceMonitor?** An
> `app.kubernetes.io/instance` matcher on the ServiceMonitor would be **cosmetic,
> not isolating**: the real pod→metrics binding is the headless Service's
> `spec.selector: {app: connect-sink}`, which is **not** release-scoped. So two
> installs sharing **one** namespace already cross-wire at the Service Endpoints
> level, and no ServiceMonitor label can undo that. Genuine same-namespace
> co-tenancy would require release-scoping the base chart's **pod labels and
> Service `spec.selector`** (an immutable-selector change → reinstall), which is a
> base-chart concern **out of scope** for this observability feature. We therefore
> support isolation **only across namespaces** and state that plainly rather than
> implying a defense the mechanism can't provide.

Lab parity: the lab's Prometheus scrapes the single `connect` via `static_configs`
and **stamps matching `namespace` and `job` labels** (via `static_configs.labels`),
so the same dashboard variables resolve and the same alert expression fires and
attributes correctly there too.

## Chart additions

```
chart/files/grafana/cdc-dashboard.json                   # new — dashboard (single source)
chart/files/prometheus/cdc-alerts.yaml                   # new — rule groups (single source)
chart/templates/observability/servicemonitor.yaml        # new
chart/templates/observability/prometheusrule.yaml        # new (embeds cdc-alerts.yaml)
chart/templates/observability/dashboard-configmap.yaml   # new (embeds cdc-dashboard.json)
chart/files/connect/cdc-reverse.yaml                     # edit — add metric name: cdc_unprocessable (base; exposed as _total)
chart/values.yaml                                        # add observability.* block
```

`values.observability`:

```yaml
observability:
  enabled: false                     # opt-in; CRDs require prometheus-operator
  serviceMonitor:
    interval: 15s
    labels: {}                       # e.g. { release: kube-prometheus-stack }
  prometheusRule:
    labels: {}                       # operator ruleSelector match (CRD metadata only)
  dashboard:
    folder: ""                       # optional Grafana folder annotation
    labels: {}                       # extra ConfigMap labels beyond grafana_dashboard: "1"
```

- **ServiceMonitor** (namespace-scoped; see Multi-install scoping): selects
  `app In (connect-source, connect-sink)` on port name `http`, path `/metrics`, in
  the release namespace (default `namespaceSelector` = own namespace). Isolation is
  the namespace boundary + the `namespace`/`job` query scoping — **not** an instance
  label. Standby pods expose `/metrics` with no `cdc_apply[_total]` series — fine;
  dashboard aggregates with `sum(...) by (namespace, job, …)`.
- **PrometheusRule** carries `.Values.observability.prometheusRule.labels` so the
  operator's `ruleSelector` picks it up.
- **dashboard-configmap** carries `grafana_dashboard: "1"` for the Grafana sidecar.

No changes to ports, leader election, RBAC, or the existing custom `dashboard`
Go app.

## Dashboard panels

Every query is scoped `{namespace=~"$namespace", job=~"$job"}` (Multi-install
scoping) and aggregated with `sum(...) by (…)` across this install's leader +
standby pods. **Built-in metrics carry Connect-native labels (`path`, `label`,
`endpoint`); every panel must `sum` those away** (keep only the dimensions the
legend needs) or it fragments into one series per component path. (Metric names
below are illustrative — pin the real `[_total]` form from `/metrics`; see Metric
design.)

- **Throughput** — `sum by (op,type) (rate(cdc_apply[_total]{...}[$__rate_interval]))`;
  `sum(rate(input_received{...}[…]))` vs `sum(rate(output_sent{...}[…]))` (native
  labels summed away).
- **Errors (focus)** — these are **windowed activity** panels, so they must use
  `increase(...[window])`, **not** the raw monotonic counter (a raw counter stat
  shows an ever-growing cumulative total, which contradicts the "activity present"
  reading in Metric design):
  `sum by (reason) (increase(cdc_unprocessable[_total]{...}[$__rate_interval]))`
  (timeseries) and a big stat `sum(increase(cdc_unprocessable[_total]{...}[5m]))`
  "Unprocessable (5m)"; `sum(rate(processor_error{...}[$__rate_interval]))` (drops
  `path`/`label`). If a lifetime total is wanted, add a **separate, clearly labelled**
  "cumulative" panel using the raw counter — never mix the two framings in one panel.
- **Latency** — if `use_histogram_timing` produces histograms, p50/p99 processing
  latency; otherwise omit.
- **JetStream health** — redelivered / pending if exposed by the input metric set.
- **Template variables** — `datasource` (type `datasource`, `query: prometheus`;
  makes the JSON portable across both Grafana instances — see anti-drift section),
  `namespace`, `job` (both `label_values(...)`; scope panels to one install),
  `instance`/`pod`.

## Alert (`cdc-alerts.yaml`)

- **`CDCUnprocessableMessages`** (primary):
  `sum by (namespace, job, reason) (increase(cdc_unprocessable_total[2m])) > 0`
  (the `cdc_unprocessable_total` name is the **illustrative** `_total` form — pin to
  the actual `/metrics` name before shipping; see Metric design). Grouped so each
  install alerts independently and is attributed — see Multi-install scoping.
  `for: 0m`, **no `keep_firing_for`**.

  **One mechanism, not two (avoid a long false-positive tail).** The counter only
  re-increments once per redelivery, and redelivery cadence is the consumer's
  `ackWait` (`values.yaml:85`, default `30s`). A single lookback **window > that
  cadence** is sufficient: with `[2m]` over a `30s` cadence, every window contains
  ≥1 increment while poison is stuck, so the alert stays firing continuously with
  **no flapping and no `keep_firing_for`**. Stacking a large window *and* a large
  `keep_firing_for` was wrong — their latencies add, leaving the alert firing for
  ~(window + keep_firing_for) after the poison is gone. With this design the alert
  **clears ~one window (roughly 2m) after the last redelivery** — approximate, not
  crisp: Prometheus `increase()` extrapolates over the range, and the eval/scrape
  interval (15s) adds up to ~one interval of boundary jitter, so treat it as "≈2m,
  ±~15s", not an exact 120s. That approximation is the intended prompt resolution
  (the lab's Recovery phase asserts a bound, not an exact time).

  **Cadence coupling (documented, since the rule file is Helm-free).** The `2m`
  window must stay **≥ 2×`ackWait`**. Because `cdc-alerts.yaml` is single-source and
  can't read `.Values`, a header comment in the rule file **and** a comment beside
  `ackWait` in `values.yaml` must state: *if you raise `ackWait`, raise this window
  to ≥ 2×`ackWait`.* `severity` is baked into
  `cdc-alerts.yaml` as a static label (default `warning`) — **not** sourced from
  values — because that file is the single source the lab's Prometheus mounts
  verbatim (no Helm rendering), so the rule content must be Helm-free. Annotations
  carry `reason` + a runbook hint. (Chart-only CRD metadata such as
  `prometheusRule.labels` is applied by the template around the embedded groups,
  where Helm rendering is available.)
- **`CDCProcessorErrorsHigh`** (optional, info-level, default off): a
  `processor_error` rate threshold, to avoid transient-blip false positives on the
  primary alert.

## Validation lab: `labs/redis-cdc-error-alerting/`

Self-contained docker-compose (produced via the research-lab convention, with a
`RESEARCH.md`).

**Services**

- `redis` — region KV target.
- `nats` (JetStream) + `nats-init` — creates the stream and durable pull consumer.
- `connect` — Redpanda Connect running a distilled `cdc-reverse` pipeline using the
  **same metric names** as the chart; metrics on `:4195/metrics`.
- `prometheus` — scrapes `connect` via `static_configs` that **stamp `namespace`
  and `job` labels** (so the shared dashboard variables resolve and the shared
  alert stays install-attributed); loads the chart's `cdc-alerts.yaml`.
- `alertmanager` — receives alerts, routes to a webhook.
- `alert-sink` — tiny Go service that records fired alerts and exposes `/alerts`
  for the test script to assert against.
- `grafana` — provisioning: a Prometheus **datasource** file (→ the `prometheus`
  service) + a **dashboard provider** file pointing at the mounted, unedited
  `chart/files/grafana/cdc-dashboard.json`. The dashboard's `${datasource}`
  variable resolves against the provisioned datasource.
- `generator` — Go; publishes CDC envelopes to NATS in modes `healthy` / `poison` /
  `mixed` at a configurable rate. The `poison` mode must exercise **both** counter
  reasons:
  - `unknown_op` — an envelope with an `op` outside `create/update/delete/rename`.
  - `decode_error` — this must be a **`create`/`update`** envelope carrying
    `enc: "gzip:base64"` with a **corrupt base64 / bad gzip** body. (A message with
    an *unrecognized* `enc` value would **not** work: `cdc-reverse.yaml:79` only
    enters the decode branch when `enc == "gzip:base64"`, so a bad `enc` skips decode
    entirely and never hits `reason=decode_error`.)

**Scripts**

- `run-lab.sh` — `docker compose up`.
- `verify-alert.sh` — automated proof. It **first scrapes `:4195/metrics` to resolve
  the actual series names** (the `[_total]` form is not assumed — same pin-from-
  `/metrics` rule as the chart; see Metric design) into shell vars, or matches with
  the `{__name__=~"cdc_(apply|unprocessable)(_total)?"}` regex fallback. Then:
  1. **Healthy phase** → assert the resolved apply counter is increasing and the
     alert `inactive`.
  2. **Poison phase** (injects both `unknown_op` and `decode_error`) → assert the
     resolved unprocessable counter increases **for both reasons** and the alert
     transitions to `firing` within a timeout (poll Prometheus `/api/v1/alerts` and
     `alert-sink`).
  3. **Recovery phase** → stop poison, purge the stuck messages, assert the alert
     `clears within ~one window` (validates the no-`keep_firing_for` resolution).
  4. Print PASS/FAIL and return an exit code.
- `RESEARCH.md` — metric taxonomy; why dedicated counter + `processor_error`; how
  the alert maps to "unprocessable"; how to read the dashboard.

## Testing

- `labs/redis-cdc-error-alerting/verify-alert.sh` is the integration test — it runs
  real Connect + Prometheus + Alertmanager and asserts the shipped alert fires.
- `helm template --set observability.enabled=true` and `=false` must both render
  cleanly (CRDs present only when enabled).

## Out of scope (YAGNI)

- No dead-letter queue — unprocessable messages are counted and alerted, not
  quarantined (future extension).
- No port change, no leader-election change.
- The chart deploys no Prometheus/Grafana/Alertmanager — only the dashboard and
  alert artifacts.
