# RESEARCH — redis-cdc-error-alerting validation lab

This lab proves that the `redis-cdc-le-k8s` chart's Grafana dashboard and the
`CDCUnprocessableMessages` Prometheus alert behave correctly against a real (distilled)
Redpanda Connect sink pipeline. It consumes the chart's **single-source** artifacts —
`chart/files/prometheus/cdc-alerts.yaml` and `chart/files/grafana/cdc-dashboard.json` —
by **bind-mounting** them (never copying), so the lab validates exactly what ships.

## Topology

```
                         kv.cdc.<op>  (Nats-Msg-Id = event_id)
  generator ──publish──▶  NATS JetStream (stream LAB_CDC)
   (Go)                        │  durable pull consumer  cdc_sink  (bind:true, maxDeliver=-1, ackWait=30s)
                               ▼
                          connect (distilled sink, :4195 /metrics)
                            │ op-switch: create/update → redis SET
                            │            delete        → redis DEL
                            │            rename        → redis RENAME
                            │            decode fail   → cdc_unprocessable{reason=decode_error} + throw
                            │            unknown op    → cdc_unprocessable{reason=unknown_op}   + throw
                            ▼
                          redis        (applied state)

  connect:/metrics ◀─scrape── prometheus (loads chart cdc-alerts.yaml)
                                   │ evaluates CDCUnprocessableMessages
                                   ▼
                              alertmanager ──webhook──▶ alert-sink (Go, records fired alerts, GET /alerts)

  prometheus ◀─datasource── grafana (provisioned with chart cdc-dashboard.json, uid=cdc-sink-observability)
```

Prometheus stamps `namespace=lab-cdc` and `job=cdc-connect-sink` on the scrape so the
shared alert/dashboard queries — which `group by (namespace, job, reason)` — scope the
same way they do in-cluster.

## Metric taxonomy

The distilled pipeline emits the **same metric names** as the chart's `cdc-reverse.yaml`:

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `cdc_apply` | counter | `op`, `type` | A CDC event was successfully applied to Redis (create/update/delete/rename). |
| `cdc_unprocessable` | counter | `reason` | A message the sink cannot apply. `reason=unknown_op` (op outside the known set) or `reason=decode_error` (a create/update claiming `enc: gzip:base64` whose body is not valid base64/gzip). |
| `processor_error` | counter (built-in) | `path` | Redpanda Connect's own per-processor error counter. Dashboard **context** only — NOT what drives the alert. |

Depending on exposition, the Connect `metric` counter scrapes as `cdc_unprocessable` or
`cdc_unprocessable_total` (this pinned image, `hpdevelop/connect:4.92.0-claudefix`,
exposes it **without** `_total`). Every query in the alert, the dashboard, and
`verify-alert.sh` therefore uses a `{__name__=~"cdc_..._?(_total)?"}` full-string regex so
they are suffix-agnostic and (being a full-string match) exclude the OpenMetrics
`_created` series.

### Why a dedicated counter drives the alert (not `processor_error`)

`processor_error` increments for *any* processor failure and is noisy/ambiguous — it
cannot tell "poison message" from a transient Redis hiccup, and it has no `reason`. The
pipeline instead emits an **explicit** `cdc_unprocessable{reason=...}` counter right before
it `throw()`s, so the alert keys off a signal that means exactly "a message the sink
structurally cannot apply." `processor_error` is kept on the dashboard purely as context.

## The decode-error `else { null }` fix

The mapping binds `let decoded = if create/update { ... } else { null }`. The explicit
`else { null }` is **required**: a `let` bound to an if-without-else leaves the variable
undefined for delete/rename ops, and the subsequent `meta body = $decoded` would then
throw for perfectly healthy deletes/renames. `decode_failed` is set to `"yes"` only when
the message claimed `gzip:base64` **and** decoding returned null — that is the
`reason=decode_error` path.

## How the alert maps to "unprocessable" (nack + redeliver-forever)

The rule (from the chart's `cdc-alerts.yaml`, mounted verbatim):

```
sum by (namespace, job, reason) ( increase({__name__=~"cdc_unprocessable(_total)?"}[2m]) ) > 0
for: 0m
```

The durable pull consumer runs with `maxDeliver=-1` and `ackWait=30s`. When the sink hits
a poison message it `throw()`s; the `reject_errored` output drops the batch **without
acking**, so JetStream redelivers the same message after `ackWait` — forever, once per
`ackWait`. Each redelivery re-runs the pipeline and re-increments
`cdc_unprocessable{reason}`. So as long as poison sits in the stream, the counter keeps
climbing at ~1/ackWait, and `increase(...[2m]) > 0` holds the alert **firing continuously**.

**Cadence coupling (do not break):** the `[2m]` window must stay ≥ 2× `ackWait` (30s) so
the counter re-increments at least twice per window — otherwise the alert flaps in the
gaps between redeliveries. There is intentionally **no** `keep_firing_for`: a window
larger than the redelivery cadence already holds the alert firing, and stacking both would
delay clearing. Once the poison is removed, the counter stops incrementing and the alert
clears **~one window (≈2m, ± one evaluation interval) after the last redelivery.**

## Single-source design (bind-mounts, not copies)

Two host paths (relative to the lab dir) are mounted read-only into the containers:

- `../../redis-cdc-le-k8s/chart/files/prometheus/cdc-alerts.yaml`
  → `/etc/prometheus/rules/cdc-alerts.yaml` (Prometheus rule file)
- `../../redis-cdc-le-k8s/chart/files/grafana` (dir)
  → `/var/lib/grafana/dashboards` (Grafana file-provider path)

The chart embeds those SAME files into a `PrometheusRule` CRD and a Grafana dashboard
ConfigMap via `.Files.Get`. Because the lab mounts them raw, any drift between "what the
lab validates" and "what the chart deploys" is impossible — there is one source of truth.
(The alert file is deliberately Helm-free — the `{{ $labels.x }}` in it are *Prometheus*
alert templates, not Helm, and `.Files.Get` returns raw bytes so Helm never touches them.)

## Reading the dashboard (uid `cdc-sink-observability`)

- **Apply throughput (ops/s) by op/type** — `rate(cdc_apply[...])` split by `op`/`type`.
  Healthy traffic makes this climb; it is the "things are working" panel.
- **Unprocessable (5m) — activity** — a stat/activity view of `cdc_unprocessable`
  increase; lights up the moment poison is being redelivered.
- **Unprocessable rate by reason** — `rate(cdc_unprocessable[...])` split by `reason`;
  shows `unknown_op` vs `decode_error` separately, mirroring the alert's `by (reason)`.
- **Connect processor errors (context)** — built-in `processor_error` by `path`; context
  only, to correlate raw Connect failures with the dedicated unprocessable counter.

All panels use the provisioned Prometheus datasource (the dashboard's `${datasource}`
template variable resolves to it automatically under Grafana file provisioning).

## `verify-alert.sh` phases (what each asserts)

1. **Bring up + resolve metric names.** Starts the stack, waits for the `cdc-connect-sink`
   Prometheus target to be `up`, and reads `/metrics` directly to avoid any `_total`
   assumption.
2. **PHASE 1 — healthy.** Runs the generator in `healthy` mode. Asserts
   `sum(increase(cdc_apply[2m])) > 0` (the sink applied events) **and** that the
   `CDCUnprocessableMessages` alert is NOT firing. Proves clean traffic stays green.
3. **PHASE 2 — poison.** Runs the generator in `poison` mode (both `unknown_op` and a
   corrupt-body `decode_error`). Polls until the alert is firing with **both** reasons and
   asserts the `alert-sink` webhook received the firing alert. Proves the alert detects
   poison and the notification path works end-to-end.
4. **PHASE 3 — recovery.** Purges the `LAB_CDC` stream (`nats ... stream purge LAB_CDC -f`)
   so redelivery stops, then polls up to ~3min for the alert to clear. Proves the alert
   self-clears ~one 2m window after the poison is gone — no manual reset needed.

Exit 0 + `PASS:` means all four held. PHASE 3 is intentionally the slow part (~2-3 min):
it waits out the real 2m alert window from the single-source rule file, which the lab does
**not** shorten.
