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
- Custom counters (`cdc_apply`, `cdc_unprocessable`) fire under normal traffic and
  establish the exporter's suffix convention, which applies identically to the
  forward-leg counters (`cdc_forward_unrouted/others/publish_failed`) — same exporter,
  same rule — so those names are confirmed structurally even when a branch doesn't fire.
- `elector_*` metrics need the K8s Lease API and can't run in compose. They are
  hand-written text in `internal/elector/main.go`
  (`elector_leading`, `elector_post_total{result=...}`, `elector_delete_total{result=...}`)
  and are verified from source, not from a scrape.
- `cdc_writer_*` and `cdc_latency_seconds` come from the `app` writer/latency binaries
  (plain-text `/metrics`, NOT the Connect exporter) and are captured live.

## Findings
_(populated in Task 5 — table of dashboard expr → real name → verdict)_

## How to run
See "Run" section below.
