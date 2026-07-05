# RESEARCH — redis-cdc-error-alerting lab

Validation lab for the `redis-cdc-le-k8s` chart's observability surface: proves the
`CDCUnprocessableMessages` alert (`chart/files/prometheus/cdc-alerts.yaml`) and the
Grafana dashboard (`chart/files/grafana/cdc-dashboard.json`) behave correctly against a
real Connect sink pipeline, without a Kubernetes cluster. This is the L2 tier of the
verification ladder in `rules/05-invariants.md`.

## Topology

```
generator (Go) ──publish kv.cdc.<op>──▶ NATS JetStream (stream LAB_CDC)
                                              │  durable pull consumer cdc_sink (nats-init)
                                              ▼
                                    Connect (distilled sink, :4195/metrics)
                                       │ apply                │ poison → nack
                                       ▼                      ▼
                                    Redis KV          redelivery forever (maxDeliver=-1)
                                              ▲
prometheus (scrapes connect; loads the CHART's cdc-alerts.yaml via bind mount)
    │ alert firing
    ▼
alertmanager ──webhook──▶ alert-sink (Go, records alerts; GET /alerts)
grafana (provisions the CHART's dashboard dir via bind mount)
```

## Single-source design

The lab does **not** copy the alert or dashboard files. It bind-mounts them from the
chart:

- `../../chart/files/prometheus/cdc-alerts.yaml` → Prometheus `rule_files`
- `../../chart/files/grafana/` → Grafana dashboards directory

So the lab always validates exactly what the chart ships. Prometheus stamps
`namespace: lab-cdc` and `job: cdc-connect-sink` scrape labels because the shared
alert/dashboard queries group by `namespace`/`job` (in-cluster those come from the
ServiceMonitor).

## Metric taxonomy

| Metric | Source | Meaning |
|---|---|---|
| `cdc_apply{op,type}` | pipeline `metric` processor | incremented only after a successful Redis apply |
| `cdc_unprocessable{reason=decode_error}` | pipeline | message claimed `enc: gzip:base64` but the body failed base64/gzip decode |
| `cdc_unprocessable{reason=unknown_op}` | pipeline | op outside create/update/delete/rename |
| `processor_error`, `input_received`, `output_*` | Connect built-ins | dashboard context only |

The dedicated `cdc_unprocessable` counter drives the alert (stable name + `reason`
label, one increment per poisoned delivery). Built-in `processor_error` is kept as
dashboard context because its semantics (which processor, retries included) are
implementation-dependent — alerting on it would couple the alert to pipeline layout.

Metric name suffixing: the pinned Connect image exports the counters without a
`_total` suffix; shared queries use the `{__name__=~"cdc_...(_total)?"}` regex form so
both spellings work. `verify-alert.sh` resolves the names from `/metrics` first.

## How the alert maps to "unprocessable"

Poison messages are **nacked** (`reject_errored` output → nack) and the durable
consumer has `maxDeliver=-1` + `ackWait=30s`, so each poisoned message redelivers
forever, incrementing `cdc_unprocessable` on every delivery. The alert's
`increase[2m] > 0` window is therefore re-armed at least every ~30s while poison sits
in the stream (this is the alert-window/ackWait coupling documented in
`cdc-alerts.yaml`). After `nats stream purge LAB_CDC` removes the poison, no further
increments happen and the alert clears once the 2m window slides past — which is why
`verify-alert.sh` Phase 3 allows ~3 minutes.

## verify-alert.sh phases

1. **healthy** — 15s of create/update/delete traffic. Asserts `cdc_apply` increased
   and the alert stayed inactive.
2. **poison** — 20s of `unknown_op` + `decode_error` traffic. Asserts the alert fires
   with **both** `reason` label values and that Alertmanager delivered it to the
   `alert-sink` webhook.
3. **recovery** — purges the stream. Asserts the alert clears within ~3 minutes.

Exit 0 = all three phases held (the lab's PASS criterion).

## Reading the dashboard panels

- **Apply throughput** — rate of `cdc_apply` by op/type; should track generator rate
  during healthy traffic.
- **Unprocessable activity** — any nonzero = poison being (re)delivered right now.
- **Unprocessable by reason** — which failure class (`decode_error` vs `unknown_op`).
- **Processor errors** — Connect built-in, corroborates the dedicated counter.

## Differences from the in-cluster sink (deliberate distillation)

String-type SET only, plain Redis `RENAME` instead of the `cdc_rename.lua` guard, no
latency XADD, no content-log. Metric names, the op-switch shape, the decode
`else { null }` fix, and the ack-after-apply (`reject_errored` + nack) semantics are
identical to `chart/files/connect/cdc-reverse.yaml` — those are what the alert and
dashboard depend on.
