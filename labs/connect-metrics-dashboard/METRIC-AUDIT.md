# Metric-name audit — cdc-dashboard.json vs live :4195

Captured: `labs/connect-metrics-dashboard/captured/*.txt` (see git for the run).
Dashboard: `chart/files/grafana/cdc-dashboard.json` (12 panels / 16 targets).
Pipeline source (structural cross-check for metrics that didn't fire in this
capture): `labs/connect-metrics-dashboard/connect/source.yaml` (forward leg),
`labs/connect-metrics-dashboard/connect/sink.yaml` (reverse leg),
`internal/elector/main.go` (elector — can't run in the lab).

## Base metric names actually exposed

Source leg (`captured/source-metrics.txt`), deduped base names:
```
cdc_forward_others
input_connection_failed, input_connection_lost, input_connection_up, input_received
input_latency_ns_bucket, input_latency_ns_count, input_latency_ns_sum
output_batch_sent, output_connection_failed, output_connection_lost, output_connection_up, output_error, output_sent
output_latency_ns_bucket, output_latency_ns_count, output_latency_ns_sum
processor_batch_received, processor_batch_sent, processor_error, processor_received, processor_sent
processor_latency_ns_bucket, processor_latency_ns_count, processor_latency_ns_sum
```

Sink leg (`captured/sink-metrics.txt`), deduped base names:
```
cdc_apply
input_connection_failed, input_connection_lost, input_connection_up, input_received
input_latency_ns_bucket, input_latency_ns_count, input_latency_ns_sum
output_batch_sent, output_connection_failed, output_connection_lost, output_connection_up, output_error, output_sent
output_latency_ns_bucket, output_latency_ns_count, output_latency_ns_sum
processor_batch_received, processor_batch_sent, processor_error, processor_received, processor_sent
processor_latency_ns_bucket, processor_latency_ns_count, processor_latency_ns_sum
```

Writer (`captured/writer-metrics.txt`): `cdc_writer_sent_total`, `cdc_writer_errors_total`,
`cdc_writer_ops_total`, `cdc_writer_rate_target` (gauge), `cdc_writer_inflight` (gauge).

Latency-calculator (`captured/latency-metrics.txt`): `cdc_latency_seconds` (gauge),
`cdc_latency_samples` (gauge), `cdc_latency_dropped_negative_total`.

**Not present in either Connect capture, despite being wired in the pipeline configs:**
`cdc_unprocessable` (0 hits in `sink-metrics.txt`), `cdc_forward_publish_failed` and
`cdc_forward_unrouted` (0 hits in `source-metrics.txt`) — confirmed by
`grep -c cdc_unprocessable captured/sink-metrics.txt` → `0`, and
`grep -c cdc_forward_publish_failed|cdc_forward_unrouted captured/source-metrics.txt` → `0`
each. None of these error/miss branches fired during the capture run (no decode failures,
no unknown ops, no NATS publish failures, no empty-prefix/no-catchAll misses). Their real
names and label sets are taken from the `metric:` processor blocks in `sink.yaml` /
`source.yaml` — same exporter, same no-`_total` convention as `cdc_apply` /
`cdc_forward_others`, which DID fire — so the name is "structural", not scraped.

## Per-panel audit

| Panel | Dashboard expr uses | Real name on :4195 | Source | Verdict |
|---|---|---|---|---|
| 1 Apply throughput | `{__name__=~"cdc_apply(_total)?"}` by (op,type) | `cdc_apply` — `cdc_apply{label="",op="create",path="...",type="hash"} 481` (sink-metrics.txt:3) | sink | rename to bare `cdc_apply` (drop `(_total)?` regex); **known-limitation**: only create/update rows exist — see below |
| 2 Unprocessable stat | `{__name__=~"cdc_unprocessable(_total)?"}` | `cdc_unprocessable` (bare counter, label `reason`) — structural: `sink.yaml:109-113` (`name: cdc_unprocessable`, `labels: reason: decode_error`) and `sink.yaml:198-202` (`reason: unknown_op`); 0 occurrences in `sink-metrics.txt` (branch didn't fire) | sink | drop regex → bare `cdc_unprocessable`; verdict grounded structurally, not from a captured line |
| 3 Unprocessable by reason | `cdc_unprocessable(_total)?` by (reason) | same as Panel 2; `reason` label confirmed present in both `metric:` blocks (`sink.yaml:112`, `:201`) | sink | drop regex → bare name; `reason` label ok |
| 4 Processor errors | `{__name__=~"processor_error(_total)?"}` | `processor_error` (bare, Benthos built-in) — `processor_error{label="",path="root.pipeline.processors.0"} 0` (source-metrics.txt:96; also sink-metrics.txt:103) | both | drop regex → bare `processor_error` |
| 5 Forward publish failed | `cdc_forward_publish_failed(_total)?` | `cdc_forward_publish_failed` (bare counter, label `reason=publish_error`) — structural: `source.yaml:145-151`; 0 occurrences in `source-metrics.txt` (no publish failures in this run) | source | drop regex → bare name; structural, not captured |
| 6 Processing latency | `processor_latency_ns_bucket` | exact match already — `processor_latency_ns_bucket{label="",path="root.pipeline.processors.0",le="0.005"} 5805` (source-metrics.txt:100; sink-metrics.txt:119). No component-label prefix; base name is `processor_latency_ns` (Benthos built-in Timing metric), `le` label present as expected | both | ok — no change needed |
| 7 E2E latency | `cdc_latency_seconds{op="overall"}` | exact match — `cdc_latency_seconds{op="overall",quantile="0.50"} 0.001` (latency-metrics.txt:2); `quantile` label present, matches `legendFormat: {{quantile}}` | latency-calc | ok |
| 8 Writer throughput | `cdc_writer_ops_total`, `cdc_writer_errors_total` | exact match — `cdc_writer_ops_total{op="create"} 530` (writer-metrics.txt:6); `cdc_writer_errors_total 0` (writer-metrics.txt:4) | writer | ok |
| 9 Elector | `elector_leading`, `elector_post_total{result=...}`, `elector_delete_total{result=...}` | exact match — `internal/elector/main.go:79-83` (`writeMetric(w, "elector_leading", ...)`, `elector_post_total{result="ok"|"err"}`, `elector_delete_total{result="ok"|"err"}`) | elector | verified-from-source (can't run in this lab) — ok, no change |
| 10 Apply by group | `{__name__=~"cdc_apply(_total)?"}` by (job,op) | `cdc_apply` — same series as Panel 1 | sink | rename to bare `cdc_apply`; same known-limitation applies (delete/rename rows are absent from the exposition entirely, so `by (job,op)` still can't show them) |
| 11 Forward unrouted | `cdc_forward_unrouted(_total)?` by (reason) | `cdc_forward_unrouted` (bare counter, label `reason=empty_prefix`) — structural: `source.yaml:110-117`; 0 occurrences in `source-metrics.txt` (no empty-prefix events in this run) | source | drop regex → bare name; structural, not captured |
| 12 Forward others | `cdc_forward_others(_total)?` by (reason) | `cdc_forward_others` — `cdc_forward_others{label="",path="root.pipeline.processors.1.switch.1.processors.0",reason="no_match"} 5805` (source-metrics.txt:3); `reason="no_match"` label present | source | drop regex → bare name |

**Tally:** 12 panels / 16 targets audited (Panel 6 has 3 targets p50/p95/p99, Panel 8 has
2, Panel 9 has 2, all other panels have 1). 8 targets carry the unnecessary
`(_total)?` regex hedge and need the exact bare name substituted — Panels 1, 2, 3, 4, 5,
10, 11, 12 (one target each: `cdc_apply` ×2 panels, `cdc_unprocessable` ×2,
`processor_error` ×1, `cdc_forward_publish_failed` ×1, `cdc_forward_unrouted` ×1,
`cdc_forward_others` ×1). 8 targets are already correct as written and need no change —
Panel 6 (3× `processor_latency_ns_bucket`), Panel 7 (1× `cdc_latency_seconds`), Panel 8
(2× `cdc_writer_*`), Panel 9 (2× `elector_*`).

## Suffix convention

Confirmed from the two counters that actually fired: `cdc_apply` (sink-metrics.txt:1-6)
and `cdc_forward_others` (source-metrics.txt:1-3) are both exposed **without** a `_total`
suffix — Redpanda Connect's Prometheus exporter does not append `_total` to `metric:`
processor counters (unlike Go client-golang convention, and unlike the hand-rolled Go-app
counters `cdc_writer_ops_total` / `cdc_latency_dropped_negative_total`, which the app code
appends `_total` to itself). Built-in Benthos/Connect counters (`processor_error`,
`input_received`, etc.) are likewise bare, no `_total`. This is the same exporter used by
every `metric:` block in `sink.yaml` and `source.yaml`, so the rule applies identically to
the three counters that did not fire in this run (`cdc_unprocessable`,
`cdc_forward_publish_failed`, `cdc_forward_unrouted`) — their real names are bare, with
high confidence, even though no capture line proves it directly. The dashboard's
`{__name__=~"NAME(_total)?"}` regexes are therefore unnecessary hedges for all seven
custom-counter targets; replace each with the exact bare name.

## Label check

- `op`, `type` on `cdc_apply`: present on create/update rows only (`op="create"|"update"`,
  `type="hash"|"string"`) — confirmed in `sink-metrics.txt:3-6`. **Absent** on delete/rename
  — see known limitation below.
- `reason` on `cdc_unprocessable`, `cdc_forward_unrouted`, `cdc_forward_others`: confirmed
  present in the `metric:` label blocks (`sink.yaml:112,201`; `source.yaml:117,124`) and,
  for `cdc_forward_others`, directly on the live series (`reason="no_match"`,
  source-metrics.txt:3).
- `le` on `processor_latency_ns_bucket`: present as expected for a histogram
  (source-metrics.txt:100-111).
- `quantile` on `cdc_latency_seconds`: present (latency-metrics.txt:2-10), matches the
  panel's `legendFormat: {{quantile}}`.
- `result` on `elector_post_total` / `elector_delete_total`: present per
  `internal/elector/main.go:80-83`; dashboard filters `result="err"` — matches.
- No label the dashboard groups by is absent from a metric that actually emits — the one
  gap is entire *rows* missing (delete/rename), not a missing label name; see below.

## Known limitation: `cdc_apply` drops delete/rename rows entirely

`sink.yaml` emits `cdc_apply` with **4 labels** (`label,op,path,type`) on the create/update
branch (`sink.yaml:165-170`, inside the `create|update` switch case) but with only
**3 labels** (`label,op,path`, no `type`) on the delete branch (`sink.yaml:178-182`) and the
rename branch (`sink.yaml:192-196`). Because a Prometheus counter's label set must be
identical across every sample under one metric name, Connect's exporter cannot register a
second, differently-shaped `cdc_apply` series — it logs `"Metrics label mismatch 4 versus 3
[label path op] for name 'cdc_apply', skipping metric"` and **drops** the delete/rename
increments rather than emitting them with an empty `type=""`.

This is directly evidenced by the capture: `cdc_writer_ops_total` (writer-metrics.txt:8-9)
shows real delete/rename traffic was driven (`op="delete"` 240, `op="rename"` 80), yet
`sink-metrics.txt` has **zero** `cdc_apply{op="delete",...}` or `cdc_apply{op="rename",...}`
lines — only 4 create/update rows (sink-metrics.txt:3-6).

Consequence: Panel 1 (`by (op,type)`) and Panel 10 (`by (job,op)`) can **never** show
delete or rename activity, no matter how the query is written — the underlying time series
do not exist in the exposition. Root cause is a chart/pipeline change
(`chart/files/connect/cdc-reverse.yaml`, which `sink.yaml` is rendered from — add a
`type` label to the delete/rename `metric:` blocks, e.g. `type: "n/a"`) requiring a
failover test per `rules/05-invariants.md`; **out of scope for this task**. Task 6 should
only fix the dashboard `expr`s, not this pipeline gap.

## Counter magnitude note

Cross-service counters in these captures don't fully reconcile (e.g. writer ops vs. sink
applies) because the docker-compose stack was driven multiple times during debugging and
container restarts reset in-process Benthos/Go counters between captures. This is not
message loss — it's an artifact of how the capture was produced, not a data-path finding.
