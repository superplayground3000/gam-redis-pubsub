# Lab: Connect metrics → Grafana dashboard alignment

## Question
What are the real Prometheus metric names Redpanda Connect exposes on `:4195/metrics`
for each CDC leg, and does `chart/files/grafana/cdc-dashboard.json` reference them
correctly?

## Why it's uncertain
The dashboard uses `{__name__=~"cdc_apply(_total)?"}` regexes — the author hedged on
whether Connect's Prometheus exporter appends `_total` to `metric:`-processor counters,
and on the exact names/labels of built-ins (`processor_error`, `processor_latency_ns_*`).
Only a live scrape settles it.

## Setup
Full CDC path in docker-compose (see `docker-compose.yml`). Connect configs are rendered
from the chart (`scripts/render-configs.sh`) so `metric:` blocks match production exactly.
Traffic is driven by the `app writer` (`scripts/drive.sh`). Both legs' raw `/metrics` are
captured by `scripts/scrape-metrics.sh` into `captured/`.

## Coverage & known gaps
- `cdc_apply` fires under normal traffic and establishes the exporter's suffix
  convention. `cdc_unprocessable` did **not** fire in this capture (0 occurrences,
  see Findings) — its name/labels are confirmed structurally from
  `connect/sink.yaml:109-113,198-202`, not observed live. The same suffix
  convention applies identically to the forward-leg counters
  (`cdc_forward_unrouted/others/publish_failed`) — same exporter, same rule — so
  those names are also confirmed structurally even where a branch doesn't fire.
- `elector_*` metrics need the K8s Lease API and can't run in compose. They are
  hand-written text in `internal/elector/main.go`
  (`elector_leading`, `elector_post_total{result=...}`, `elector_delete_total{result=...}`)
  and are verified from source, not from a scrape.
- `cdc_writer_*` and `cdc_latency_seconds` come from the `app` writer/latency binaries
  (plain-text `/metrics`, NOT the Connect exporter) and are captured live.

## Findings

Full per-panel table, evidence lines, and the delete/rename limitation writeup live in
`METRIC-AUDIT.md`. Summary:

- **Suffix rule (confirmed):** Redpanda Connect's Prometheus exporter does not append
  `_total` to `metric:`-processor counters or to built-in Benthos counters — `cdc_apply`
  and `cdc_forward_others` are both bare in the live scrape (`captured/sink-metrics.txt:1`,
  `captured/source-metrics.txt:1`). Only the hand-rolled Go-app counters
  (`cdc_writer_ops_total`, `cdc_latency_dropped_negative_total`) carry `_total`; Go gauges
  (`cdc_writer_rate_target`, `cdc_latency_seconds`) do not. The dashboard's
  `{__name__=~"NAME(_total)?"}` regexes are therefore unnecessary hedges for every
  custom-counter target (8 of 16 targets) — Task 6 should replace each with the exact bare
  name.
- **Correction to the "Coverage & known gaps" note above:** contrary to what it states,
  `cdc_unprocessable` did **not** fire in this capture (`grep -c cdc_unprocessable
  captured/sink-metrics.txt` → `0`) — no decode failures or unknown ops occurred during the
  drive. Its real name/labels are established structurally from `connect/sink.yaml:109-113,
  198-202`, not from a scrape line, same as the two forward-leg miss counters.
- **`elector_*`:** verified from `internal/elector/main.go:79-83` (can't run in this
  compose lab — no K8s Lease API). Dashboard names already match exactly; no fix needed.
- **Known limitation (not fixed here):** `cdc_apply` on the sink only carries a `type`
  label on create/update (`sink.yaml:165-170`); delete (`:178-182`) and rename
  (`:192-196`) emit just `op`, so Connect's exporter rejects the mismatched-cardinality
  series ("Metrics label mismatch 4 versus 3 ... skipping metric") and **drops delete/rename
  `cdc_apply` entirely** — confirmed by `cdc_writer_ops_total` showing 240 deletes / 80
  renames driven (writer-metrics.txt:8-9) against zero `cdc_apply{op="delete"|"rename"}`
  lines in `sink-metrics.txt`. Panels 1 and 10 (`by (op,type)` / `by (job,op)`) can never
  show delete/rename as a result. Root cause is in `chart/files/connect/cdc-reverse.yaml`
  (needs a `type` label added to the delete/rename `metric:` blocks) — a chart change
  requiring a failover test, out of scope for this lab.
- Counter magnitudes don't fully reconcile across services because the compose stack was
  driven multiple times during debugging, resetting in-process counters on restart — not
  message loss.

## How to run
See "Run" section below.

## Run
```bash
cd labs/connect-metrics-dashboard
./scripts/render-configs.sh              # regenerate Connect configs from the chart
docker compose up -d --build             # bring up the full CDC path
./scripts/drive.sh 45                     # generate traffic
./scripts/scrape-metrics.sh              # capture raw :4195 + app /metrics into captured/
# edit dashboards live at http://localhost:13000 (anonymous admin), then:
./scripts/export-dashboard.sh            # write edits back to chart/files/grafana/cdc-dashboard.json
docker compose down -v
```

## Status
Dashboard aligned to live metric names on 2026-07-09. See METRIC-AUDIT.md for the mapping.
