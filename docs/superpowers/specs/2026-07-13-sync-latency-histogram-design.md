# Sync-latency histogram — design (2026-07-13)

Source request: `docs/requests/sync-latency-histogram/requirements.md`
Research reference (source-verified against connect v4.92.0 / benthos v4.73.0):
`docs/requests/sync-latency-histogram/sync-latency-histogram.md`

## Requirements disposition

| # | Requirement | Decision |
|---|---|---|
| 1 | Histogram metric for msg sync latency | Implement — `cdc_sync_latency_seconds` timing metric in the sink pipeline (Approach A below) |
| 2 | p50/p95/p99 sync-latency Grafana panel | Implement — new dashboard panel + skew-counter panel |
| 3 | Default connect pod replicas → 2 | **Dropped by owner decision (2026-07-13)**: the "minimum 3 for HA" rationale in `chart/values.yaml` (one active leader + two standbys) wins; replicas stay at 3 for both legs |

## Semantics

`cdc_sync_latency_seconds` measures **writer mint → sink applied**: the time from the
writer stamping `ts` (epoch milliseconds, present in the envelope for all four ops —
`internal/writer/payload.go` `StreamValues`) to the sink successfully applying the op to
region Redis. It includes the forward leg, JetStream, cross-leg transport, and any
redelivery/replay time — full sync latency, not a single hop.

- Covered ops: create, update, delete, rename (label `op`). Envelope `ts` is used, NOT the
  body-JSON `ts` (which only create/update carry) — this is deliberately broader than the
  existing latency-calculator path.
- Per-sink-group breakdown comes free from the Prometheus `job` label (one Deployment per
  group); no key-derived labels (cardinality).
- Messages with missing/zero/unparseable `ts` are skipped (guarded), never recorded as
  garbage deltas.
- Only **successfully applied** messages record: decode_error / unknown_op throws and
  failed Redis applies are excluded by an `!errored()` guard. A message that fails and is
  redelivered records once, on its successful apply, with the (correctly larger) total delta.
- Clock skew: the delta is **clamped to ≥ 0** before feeding the metric processor — the
  pinned build hard-errors on negative timing values (`processor_metric.go` L381-382), and
  an unclamped NTP step would error-flag messages into the nack/redelivery path. Negative
  deltas increment `cdc_sync_skew_negative` instead (non-zero ⇒ writer/sink NTP drift).
- Precision note: the delta is computed at decode time, just before the apply (the pattern
  the research doc validated). It under-counts by one local Redis call (sub-ms) — noise at
  the seconds scale this metric watches.

## Chosen approach

**A — `metric: timing` processor in the sink pipeline** (`chart/files/connect/cdc-reverse.yaml`),
exported as a seconds-bucket Prometheus histogram by the already-configured
`use_histogram_timing: true` (`chart/files/connect/observability.yaml`), scraped by the
existing ServiceMonitor. Zero new components; no INV-1 load-bearing line is touched.

Rejected: **B — extend the Go latency-calculator** with a native histogram: off by default,
create/update-only, samples are best-effort (try/catch XADD + approximate MAXLEN trim),
and it adds Go + scrape surface for a weaker guarantee. The existing `cdc:latency` stream /
latency-calculator path is left untouched.

## Changes

### 1. `chart/files/connect/cdc-reverse.yaml`

a. In the existing first stash mapping, add (all `.catch`-guarded so a malformed `ts` can
never nack a message):

```coffee
let ts_ms  = this.ts.number().catch(0)
let sync_delta_ns = if $ts_ms > 0 { timestamp_unix_nano() - ($ts_ms * 1000000).round() } else { 0 }
meta sync_has_ts     = if $ts_ms > 0 { "yes" } else { "no" }
meta sync_latency_ns = [ $sync_delta_ns, 0 ].max().string()   # clamp; metric processor rejects negatives
meta sync_skew_neg   = if $sync_delta_ns < 0 { "yes" } else { "no" }
```

b. Append ONE guarded block after the op switch (single recording point for all three
success branches):

```yaml
- switch:
    - check: '!errored() && meta("sync_has_ts") == "yes"'
      processors:
        - metric:
            type: timing
            name: cdc_sync_latency_seconds   # value fed in ns; histogram EXPORTS seconds (exporter divides by 1e9)
            labels:
              op: '${! meta("op") }'
            value: '${! meta("sync_latency_ns") }'
        - switch:
            - check: meta("sync_skew_neg") == "yes"
              processors:
                - metric:
                    type: counter
                    name: cdc_sync_skew_negative
```

The `!errored()` guard is correct under either possible errored-message-propagation
behavior of the pinned build (if errored messages traverse later processors, the guard
excludes them; if they are skipped, the guard is vacuously true). L3 verifies empirically
that error paths do not record.

### 2. `chart/files/connect/observability.yaml`

Add under `metrics.prometheus`:

```yaml
histogram_buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]
```

30/60/120 keep outage/PEL-replay tails out of +Inf (DefBuckets top out at 10 s). This
setting is global to the Connect process: the built-in timing metrics
(`processor_latency_ns` etc.) get the same seconds buckets — accepted (owner-approved),
still seconds, better tail resolution, slight cardinality increase.

### 3. `chart/files/grafana/cdc-dashboard.json`

- New timeseries panel **"Sync latency p50/p95/p99 (s)"** (unit: seconds; style of the
  existing "Connect processing latency" panel):
  `histogram_quantile(0.50|0.95|0.99, sum by (le) (rate(cdc_sync_latency_seconds_bucket{namespace=~"$namespace",job=~"$job"}[$__rate_interval])))`
- New timeseries panel **"Sync clock-skew negatives"**:
  `sum(increase({__name__=~"cdc_sync_skew_negative(_total)?",namespace=~"$namespace",job=~"$job"}[$__rate_interval]))`
  (INV-2: every added metric gets a panel).
- No new alert rules (a p99 SLA alert is a noted possible follow-up, out of scope).

## Error handling summary

| Failure | Behavior |
|---|---|
| `ts` missing / 0 / non-numeric | `sync_has_ts=no` → no sample; message flow unchanged |
| Negative delta (clock skew) | recorded as a clamped 0-second sample (never fed negative — the processor would error); `cdc_sync_skew_negative` increments; message flow unchanged |
| decode_error / unknown_op | excluded by `!errored()`; existing `cdc_unprocessable` + nack behavior unchanged |
| Redis apply failure | excluded; records later on successful redelivery |

## Verification plan (INV-4 ladder; strictest matching rows: pipeline YAML + metrics/dashboard)

1. **L0 + L1**: `scripts/run-all-tests.sh` fast tiers (`SKIP_L2=1 SKIP_L3=1`) — unit + lint +
   template + toggle render loop.
2. **INV-2 grep**: metric-name grep over dashboard + alerts files must hit
   `cdc_sync_latency_seconds` and `cdc_sync_skew_negative` in the dashboard JSON.
3. **L2** (~7 min): `labs/redis-cdc-error-alerting/scripts/verify-alert.sh` — sink pipeline +
   dashboard against a real Connect binary.
4. **L3** (~5 min): `scripts/build-images.sh --kind --kind-name=cdc` +
   `RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh`; then curl `:4195/metrics` on the
   sink pod and confirm: `cdc_sync_latency_seconds_bucket` present with seconds-scale values
   across ops; `cdc_sync_skew_negative` absent or 0; error-path messages did not record.
5. **L4 not required**: no consumer-id/group, lease, elector, ack/commit, or nats-init change.

## Invariant impact

- INV-1: no load-bearing line touched (input/bind, output `reject_errored`+`drop`, fallback,
  Lua all unchanged; added processors never throw by construction).
- INV-2: satisfied in-change (new metric + skew counter both on the dashboard; histogram in
  seconds).
- INV-3: no new component; no toggle needed (processors are not components).
- INV-4: plan above.
