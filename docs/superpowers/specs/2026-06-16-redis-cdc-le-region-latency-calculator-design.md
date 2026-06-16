# Region-side CDC latency calculator — design

**Date:** 2026-06-16
**Lab:** `redis-cdc-le-k8s`
**Status:** approved (brainstorm), pending implementation plan

## Problem

In the target topology, **redis central** and **redis region** live in
**different Kubernetes clusters**. We want to measure the end-to-end CDC
propagation latency — central write → region apply — and periodically emit a
JSON report with p50/p95/p99, saved to a local file.

Hard constraint: the calculator runs in the **region** cluster and may access
**only region Redis**. It must NOT depend on central Redis or NATS JetStream
(they are in a different cluster and unreachable).

## Measurement model

The writer already stamps `body.ts` (central write time, unix-millis) inside
each create/update value. We add a second stamp at apply time on the **sink**
leg, so:

```
latency_ms = sink_ts - writer_ts
```

Both timestamps are captured at the real event moments and travel with the
event, so the calculator's read cadence never inflates the measured latency
(unlike observe-on-poll). `latency` is computed purely from data in region
Redis.

Only **create** and **update** are measurable — delete carries no body and
rename is body-less by design (value-preserving), so neither has a `writer_ts`.

### Why not stamp "in the value"

The verifier asserts **byte-exact** central↔region convergence
(`checks.go` `regionEquals` and `RenameParity` `cv == rv`). Injecting `sink_ts`
into the stored value would make region values diverge from central and break
PerOp + RenameParity. SCANning KV would also only see the *latest* value per
key, undercounting rapid same-key updates. Therefore the timestamps are carried
in a **separate sidecar stream**, leaving the stored value byte-identical.

## Architecture & data flow

```
[central cluster]  writer -> central Redis stream -> source connect -> NATS JetStream
                                                                          |
[region cluster]   sink connect --SET value (unchanged)--> region Redis KV
                       |
                       +--XADD {op,kv_key,writer_ts,sink_ts}--> region Redis stream  cdc:latency
                                                                          |  (polled via XRANGE)
                   latency-calculator (Deployment) --- writes ---> /reports/latency-report.json
```

The calculator touches **only region Redis** — never central, never NATS.

## Component 1 — sink change (`chart/files/connect/cdc-reverse.yaml`)

In the existing `create`/`update` switch branch, **after** the `SET` (value
unchanged) and the existing `cdc_apply` metric, append a **best-effort** latency
emit. Exact processor shape (all expressions below are empirically verified
against the chart's `connect:4.92.0` image — see "External review & verification"):

- `writer_ts` = `meta("body").parse_json().ts.or(0)`. The sink stashes the body
  as a raw JSON **string** in `meta body`, so it MUST be `parse_json()`-ed before
  field access — dot-navigation on the raw metadata string does not work. The
  payload's `ts` is a top-level field of that JSON (`payload.go snapshot()`).
- **Guard:** a nested `switch` with `check: meta("body").parse_json().ts.or(0) > 0`.
  Verifier-injected events (bodies like `{"v":1}` with no `ts`) yield `0` and are
  skipped — no XADD. The guard fires on a missing/zero `ts`, not on an empty body
  (empty bodies never reach the create/update branch).
- `sink_ts` = `now().ts_unix_milli()` (returns unix **milliseconds** — verified;
  do NOT use bare `now()` arithmetic).
- Emit via the `redis` processor with `command: xadd` (verified working with the
  `MAXLEN ~ N` modifier in a positional `args_mapping` — no Lua needed), against
  region Redis (reuses `rrcs.redis.region.url`):
  ```yaml
  args_mapping: |
    root = [ "{{ .Values.latencyCalculator.stream }}",
             "MAXLEN", "~", "{{ .Values.latencyCalculator.streamMaxLen }}", "*",
             "op", meta("op"),
             "kv_key", meta("kv_key"),
             "writer_ts", meta("body").parse_json().ts.string(),
             "sink_ts", now().ts_unix_milli().string() ]
  ```
- **Best-effort isolation:** wrap *only* the guarded XADD in a `try:` processor,
  followed by a sibling `catch:` that `log`s a WARN and clears the error. `try`
  and `catch` are real Redpanda Connect processors (Codex mislabeled `catch` as
  fictional; it exists and is the correct mechanism). Because `catch` clears the
  error flag, a failed telemetry XADD leaves the message un-errored, so the
  sink's `output.reject_errored` does NOT nack it → no redelivery, no double
  SET. The earlier `SET` is OUTSIDE this try/catch, so a real apply failure still
  nacks and redelivers as today. Ordering in the branch: `set` → `metric` →
  `try:[ switch → redis xadd ]` → `catch:[ log ]`.

delete and rename branches are unchanged (unmeasured).

Constraints this must preserve:
- The stored KV value stays byte-identical to central (verifier stays green).
- `pipeline.threads` concurrency and the no-LWW semantics are unaffected.
- Stream name and `MAXLEN` come from values (`latencyCalculator.stream` /
  `.streamMaxLen`) — single source of truth shared with the calculator.

## Component 2 — calculator (`latency-calculator/`, Go)

Long-running process, structured like the existing Go components
(`writer`/`verifier`/`elector`): small files, table-driven `_test.go`,
env-var config with defaults.

Loop:
1. **Consume** `cdc:latency` via `XRANGE (cursor, +]` from an in-memory
   last-seen ID cursor. On startup the cursor begins at the current stream tail
   (only new entries; cold start).
2. Each entry → sample `{op, latency_ms = sink_ts - writer_ts, sink_ts}`.
   **Drop negatives** (clock-skew artifacts) into a `dropped_negative` counter
   so they cannot corrupt percentiles.
3. Keep samples in a **rolling time window** (default 60s), evicting any whose
   `sink_ts` is older than `now - windowSec`.
4. Every **report interval** (default 10s): compute nearest-rank
   p50/p95/p99 plus count/min/max/mean, **overall** and **per-op**
   (create, update), and write the JSON report atomically (temp file + rename)
   to `reportPath`, overwriting the previous report.

Restart is cold — the in-memory window/cursor are lost (acceptable; telemetry is
best-effort). No central/NATS access anywhere. The first report after a cold
restart reflects only samples accumulated since restart (up to `windowSec` of
history may be missing) — acceptable for best-effort telemetry.

Eviction keys on the record's `sink_ts` (true apply time), not the XRANGE
arrival time, so a delayed XADD is still windowed by when the apply actually
happened.

**Report write is atomic:** write to `reportPath + ".tmp"` in the **same
directory** (same volume) as `reportPath`, then `os.Rename` over it. A reader
(`kubectl exec cat`) therefore never sees a partial file. The temp file must NOT
be in `/tmp` (cross-filesystem rename is not atomic).

### Report schema (`latency-report.json`)

```json
{
  "generated_at": "2026-06-16T07:30:00Z",
  "window":  { "start": "...", "end": "...", "duration_sec": 60 },
  "config":  { "interval_sec": 10, "window_sec": 60, "stream": "cdc:latency" },
  "overall": { "count": 1240, "dropped_negative": 0, "min_ms": 3, "max_ms": 210,
               "mean_ms": 41.2, "p50_ms": 38, "p95_ms": 95, "p99_ms": 160 },
  "by_op": {
    "create": { "count": 300, "min_ms": 4, "max_ms": 180, "mean_ms": 39.0,
                "p50_ms": 36, "p95_ms": 90, "p99_ms": 150 },
    "update": { "count": 940, "min_ms": 3, "max_ms": 210, "mean_ms": 41.9,
                "p50_ms": 39, "p95_ms": 96, "p99_ms": 162 }
  }
}
```

Empty window → counts of 0 and null/0 percentiles (report still written so the
file is always current). All latencies in **milliseconds**. A persistently rising
`dropped_negative` in production signals central/region clock drift (NTP), not a
CDC bug — documented in the README section.

## Component 3 — chart wiring

- `latency-calculator/Dockerfile` (multi-stage Go build, matches the other
  components' Dockerfiles).
- `chart/templates/latency-calculator.yaml` — a Deployment (1 replica), gated
  behind `latencyCalculator.enabled` (default **off**, like other optional
  components). The template **always mounts a volume at `/reports`** — an
  `emptyDir` when `persistence.enabled=false`, a PVC claim when `true`. There
  must be no template path where `/reports` is unmounted (the process writes
  there at every interval), so default-off persistence still has a writable
  `/reports`. Standard `rrcs.podLabels` / `rrcs.scheduling` / image helpers.
- `chart/values.yaml` — new `latencyCalculator` block:
  `enabled`, `stream: cdc:latency`, `streamMaxLen: 50000`, `windowSec: 60`,
  `intervalSec: 10`, `reportPath: /reports/latency-report.json`,
  `persistence: { enabled: false, size, storageClass }`, `resources`, `image`.
  Region Redis URL reuses `rrcs.redis.region.url`. The `streamMaxLen` comment
  notes it is rate-dependent: set it to at least ~2× the peak XADD rate per
  `intervalSec` so approximate `MAXLEN ~` trimming cannot evict entries before
  the calculator's XRANGE cursor reads them (lost samples only, never lost CDC).
- The sink's `cdc:latency` XADD `MAXLEN` is templated from
  `latencyCalculator.streamMaxLen` (single source of truth) so the sink emits
  the sidecar stream even when the calculator Deployment is disabled — enabling
  the calculator later still finds data.
- `scripts/build-images.sh` builds/loads the new image alongside the others.
- README + `docs/nats-jetstream-and-redis-kv-message-flow.md` get a short
  "latency calculator" section.

## Testing

Go unit tests (no live Redis required):
- nearest-rank percentile incl. empty, single-sample, **N=2 (assert p99 == max)**,
  and small-N edge cases;
- rolling-window eviction by `sink_ts`;
- negative-latency drop + counter;
- per-op bucketing (create vs update vs ignored ops);
- report JSON serialization (golden shape);
- stream-entry parsing (well-formed, missing field, non-numeric ts).

Manual / lab:
- enable `latencyCalculator.enabled=true` in the kind lab, run the writer,
  `kubectl exec` into the calculator pod and `cat /reports/latency-report.json`;
- confirm the verifier still passes (value bytes unchanged).

## Assumptions & caveats

- **Clock skew:** in the kind lab every pod shares one node clock, so skew ≈ 0.
  In the production target the sink (region) and writer (central) clocks differ,
  so `sink_ts - writer_ts` is only as accurate as NTP sync between clusters. The
  negative-drop guard handles gross skew; the absolute numbers assume reasonable
  NTP discipline. Documented, not engineered around (no cross-cluster probe is
  possible under the access constraint).
- **delete / rename** are unmeasured (no `writer_ts`).
- Telemetry is **best-effort**: a sidecar XADD failure is swallowed and never
  affects CDC correctness or the verifier.

## External review & verification

Codex ran an early cross-model design review (2026-06-16). Resolutions, with the
feasibility-critical Bloblang/Redis claims **empirically verified** against the
chart's `hpdevelop/connect:4.92.0-claudefix` image:

- **C1 — `meta("body")` is a string, needs `parse_json()`** (valid). Verified:
  `this.body.parse_json().ts` → the embedded ts; `.or(0)` → `0` for a body with
  no `ts`. Folded into Component 1.
- **C2 — `command: xadd` with `MAXLEN ~ N` might not serialize** (not reproduced).
  Verified: a positional `args_mapping` with `"MAXLEN","~","50000","*",…` XADDs
  correctly via `command: xadd` on 4.92 — kept the simple form, no Lua eval.
- **C3 — best-effort wrapper** (valid intent). Adopted real `try:`/`catch:`
  processors wrapping only the XADD (`catch` is a real processor; clears the
  error so `reject_errored` does not nack). Ordering pinned: set → metric →
  try → catch.
- **S1 — millis expression** (valid). Verified `now().ts_unix_milli()` returns
  unix-millis; chosen explicitly.
- **S2/S3/S5, N1/N2/N4** — folded in as the cold-start undercount note,
  `streamMaxLen` rate-sizing note, the always-mount-`/reports` rule, the
  `dropped_negative` skew hint, the atomic same-dir `os.Rename`, and the N=2
  percentile test case.

## Out of scope (YAGNI)

- Historical/timestamped report retention (single overwritten file only).
- Prometheus export / dashboards (the report file is the deliverable).
- Measuring delete/rename latency.
- Cross-cluster clock-skew correction.
