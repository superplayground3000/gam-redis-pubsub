# Connect-metrics Grafana dashboard lab — design

**Date:** 2026-07-09
**Status:** Approved (brainstorming)
**Worktree:** `worktree-connect-metrics-dashboard`

## Problem

`chart/files/grafana/cdc-dashboard.json` references Connect metrics by *guessed*
names. The `{__name__=~"cdc_apply(_total)?"}` regex tricks are a tell that the
author was unsure whether Connect's Prometheus exporter emits `cdc_apply` or
`cdc_apply_total`, and the same doubt applies to built-in metrics
(`processor_error`, `processor_latency_ns_bucket`) and their label sets. The
metric *name* in `/metrics` is decided by Connect's Prometheus exporter + the
literal `metric:` processor names + the metrics mapping — **not** by Helm
templating. The only authority is a live `:4195/metrics` scrape from each leg.

**Goal:** stand up a docker-compose environment that runs both Connect legs,
capture the real metric names, align every dashboard `expr` to them, and commit
the corrected canonical `chart/files/grafana/cdc-dashboard.json`.

## Scope decisions (from brainstorming)

- **Lab scope:** full end-to-end CDC path (real traffic → real metrics).
- **Deliverable:** fix the canonical chart JSON (the lab is the proving ground).
- **Isolation:** dedicated git worktree.

## Architecture

Self-contained compose lab at `labs/connect-metrics-dashboard/`:

```
writer(app) ──XADD──▶ redis-central ──▶ connect-source(:4195) ──▶ nats(JetStream)
                                                                      │
redis-region ◀── connect-sink(:4195) ◀────────────────────────────────┘
     ▲
     └── latency-calculator(app) reads region XADD ts ──▶ cdc_latency_seconds

prometheus ──scrapes :4195 on both legs + writer + latency-calc──▶ grafana(provisioned)
```

### Components

| Service | Image / source | Role |
|---|---|---|
| redis-central | `redis:7.4-alpine` | source stream `app.events` |
| connect-source | `hpdevelop/connect:4.92.0-claudefix` | forward leg, run-mode, `:4195` |
| nats + nats-init | `nats:2.10-alpine` / `natsio/nats-box` | JetStream stream `LAB_CDC` (`kv.cdc.>`) + durable pull consumer |
| connect-sink | `hpdevelop/connect:4.92.0-claudefix` | reverse leg, run-mode, `:4195` |
| redis-region | `redis:7.4-alpine` | region KV target |
| writer | repo `app` binary | traffic generator (XADD to central) |
| latency-calculator | repo `app` binary | emits `cdc_latency_seconds` |
| prometheus | `prom/prometheus:v2.54.1` | scrapes both legs + app metrics |
| grafana | `grafana/grafana:11.2.0` | provisioned, editable dashboard |

### Pipeline fidelity

Connect configs are the chart's `cdc-forward.yaml` / `cdc-reverse.yaml`, rendered
via `helm template` with lab values and assembled into a **run-mode** config by
prepending the `http/logger/metrics` block from `observability.yaml`. Rendering
(not hand-writing) guarantees the `metric:` processors stay byte-identical to
production — only connection URLs/subjects/labels take lab values. Metric names
are never touched by templating, so run-mode fidelity is exact.

### Known gap: elector metrics

`elector_leading`, `elector_post_total`, `elector_delete_total` require the K8s
Lease API and cannot run in pure docker-compose. Their names are Go-defined in
`internal/elector/` (deterministic — no exporter ambiguity), so they are verified
by reading the source, not by running an elector. Every *ambiguous* (Connect-
emitted) name is covered by the two live legs. This gap is documented in the
lab RESEARCH.md and does not block the dashboard fix.

## Dashboard editing workflow

- Grafana provisions the Prometheus datasource and bind-mounts
  `chart/files/grafana/` as an **editable** dashboard directory.
- `scripts/scrape-metrics.sh` dumps both legs' raw `:4195/metrics` to files — the
  ground-truth name list every `expr` is checked against.
- `scripts/export-dashboard.sh` pulls the current dashboard JSON from the Grafana
  API back to the canonical chart file, stripping runtime `id`/`version` so the
  diff is clean.

## Deliverables

1. `labs/connect-metrics-dashboard/` — compose lab + `RESEARCH.md`.
2. Metric-name audit: raw `:4195` names vs. every dashboard `expr`, each mismatch
   called out.
3. Corrected `chart/files/grafana/cdc-dashboard.json`.
4. All work in the isolated worktree.

## Verification

- `docker compose up` → all services healthy; both `:4195/metrics` return the
  expected custom counters (proves every pipeline branch was exercised).
- Every dashboard panel renders non-empty in Grafana, or is documented as
  elector-only / not-reproducible.
- `helm lint chart/ && helm template chart/ >/dev/null` still pass after the JSON
  edit (chart-render invariant).
