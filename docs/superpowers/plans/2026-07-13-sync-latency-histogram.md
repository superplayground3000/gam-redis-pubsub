# Sync-Latency Histogram Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose a Prometheus histogram `cdc_sync_latency_seconds` (writer mint → sink successful apply, all ops) from the sink pipeline, with p50/p95/p99 Grafana panels and a clock-skew counter.

**Architecture:** A Bloblang stash in the sink pipeline's existing first mapping computes `now_ns − envelope.ts·1e6` (clamped ≥ 0, int64-string), and ONE guarded `switch` after the op switch feeds it to a `metric: timing` processor only for successfully-applied messages (`!errored()`). The already-configured `use_histogram_timing: true` exports it as a seconds-bucket histogram; custom buckets up to 120 s keep replay tails out of +Inf. Two new dashboard panels visualize it.

**Tech Stack:** Redpanda Connect v4.92.0 (benthos v4.73.0) Bloblang + metric processor, Helm chart, Grafana dashboard JSON.

**Spec:** `docs/superpowers/specs/2026-07-13-sync-latency-histogram-design.md` (approved 2026-07-13, includes Codex review fixes). Requirement 3 (replicas → 2) was **dropped by owner decision** — do NOT touch any `replicas:` value.

## Global Constraints

- NEVER touch any INV-1 load-bearing line (`rules/05-invariants.md` table): input `bind: true`, output `reject_errored`+`drop`, the forward fallback, consumer ids/groups, lease settings, `cdc_rename.lua`. This change only ADDS processors/mappings.
- The timing metric value MUST be an integer string ≥ 0: `.max()` clamp then `.int64().string()`. A float (scientific notation) or negative value makes the metric processor error AFTER the apply → `reject_errored` nacks an already-applied message.
- Metric names use only `[a-zA-Z0-9_]` (`cdc_sync_latency_seconds`, `cdc_sync_skew_negative`) — invalid names silently degrade to noop.
- Timing value is fed in NANOSECONDS; the Prometheus exporter divides by 1e9 — exported buckets are SECONDS. Never name anything `_ns`.
- Every added metric must appear on the Grafana dashboard in the same change (INV-2).
- Back up `rules/05-invariants.md` before editing it (`cp <file> <file>.bak-$(date +%Y%m%d-%H%M%S)`), per CLAUDE.md hard safety rule 2. The edit is ADDITIVE ONLY.
- Verification ladder for this change (INV-4, strictest rows): L0+L1 + INV-2 grep + L2 + L3. L4 NOT required. Paste command + exit status for every level you run.
- Working directory is the repo root. All paths below are repo-relative.

---

### Task 1: Sink pipeline stash + recording block + histogram buckets

**Files:**
- Modify: `chart/files/connect/cdc-reverse.yaml` (two insertions: end of first mapping ~line 98; after the op switch ~line 218)
- Modify: `chart/files/connect/observability.yaml` (add `histogram_buckets` under `metrics.prometheus`)

**Interfaces:**
- Consumes: envelope field `ts` (epoch-ms string, stamped for every op by `internal/writer/payload.go` `StreamValues`, forwarded by `cdc-forward.yaml` as `"ts": meta("ts").or("0")`).
- Produces: Prometheus series `cdc_sync_latency_seconds_bucket/_sum/_count{op=...}` and counter `cdc_sync_skew_negative` on the sink's `:4195/metrics` (Tasks 2, 3, 6 reference these exact names). Internal meta keys: `sync_has_ts` ("yes"/"no"), `sync_latency_ns` (int string), `sync_skew_neg` ("yes"/"no").

- [ ] **Step 1: Verify the render baseline (the "failing test")**

Run: `helm template chart/ | grep -c cdc_sync_latency_seconds`
Expected: `0` (exit status 1 from grep -c is fine — the metric must not exist yet).

- [ ] **Step 2: Add the stash lines to the first mapping**

In `chart/files/connect/cdc-reverse.yaml`, the first `- mapping: |` block currently ends with:

```yaml
        meta body = $decoded
        meta decode_failed = if $is_encoded && $decoded == null { "yes" } else { "no" }
```

Append DIRECTLY AFTER the `meta decode_failed` line, inside the same mapping block, at the same 8-space indentation:

```yaml
        # ── Sync-latency stash (spec 2026-07-13-sync-latency-histogram) ──
        # Envelope ts = writer mint time (epoch ms, stamped for EVERY op).
        # Delta is computed HERE (decode time), just before the apply — it
        # under-counts by one local Redis call (sub-ms), noise at the seconds
        # scale this metric watches. .catch(0) => a missing/garbled ts can
        # never throw and nack; it just skips the sample (sync_has_ts=no).
        let ts_ms = this.ts.number().catch(0)
        let sync_delta_ns = if $ts_ms > 0 { timestamp_unix_nano() - ($ts_ms * 1000000).round() } else { 0 }
        meta sync_has_ts = if $ts_ms > 0 { "yes" } else { "no" }
        # Clamp to >=0 (the timing metric processor hard-errors on negatives —
        # an NTP step must not error-flag messages into the nack path), and
        # .int64() BEFORE .string(): float arithmetic stringifies large values
        # in scientific notation, which the metric processor's strconv.ParseInt
        # rejects — and that error would fire AFTER the apply, nacking an
        # already-applied message (same trap as writer_ts below). Negative
        # deltas are counted separately via sync_skew_neg.
        meta sync_latency_ns = [ $sync_delta_ns, 0 ].max().int64().string()
        meta sync_skew_neg = if $sync_delta_ns < 0 { "yes" } else { "no" }
```

- [ ] **Step 3: Add the recording block after the op switch**

In the same file, the big op `switch` ends with the unknown-op default case:

```yaml
        - processors:
            - metric:
                type: counter
                name: cdc_unprocessable
                labels:
                  reason: unknown_op
            - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'
```

Insert DIRECTLY AFTER that block (before `output:`), at 4-space indentation (same level as the existing `- switch:` processors):

```yaml
    # ── Sync-latency recording (INV-2; spec 2026-07-13) ──────────────────
    # ONE recording point for all three success branches. !errored() excludes
    # decode_error/unknown_op throws AND failed Redis applies — only
    # successfully-applied messages record; a nacked message records on its
    # successful redelivery with the (correctly larger) total delta. The guard
    # is safe under either errored-propagation behavior: if errored messages
    # traverse later processors the guard skips them; if they don't, it is
    # vacuously true. Value is ns; with use_histogram_timing the Prometheus
    # exporter divides by 1e9 — the EXPORTED histogram is SECONDS (hence the
    # name; never suffix _ns).
    - switch:
        - check: '!errored() && meta("sync_has_ts") == "yes"'
          processors:
            - metric:
                type: timing
                name: cdc_sync_latency_seconds
                labels:
                  op: '${! meta("op") }'
                value: '${! meta("sync_latency_ns") }'
            - switch:
                - check: meta("sync_skew_neg") == "yes"
                  processors:
                    # Writer clock ahead of sink (NTP drift): the sample was
                    # clamped to 0 above; count it so the drift is visible.
                    - metric:
                        type: counter
                        name: cdc_sync_skew_negative
```

- [ ] **Step 4: Add the histogram buckets**

In `chart/files/connect/observability.yaml`, change:

```yaml
metrics:
  prometheus:
    use_histogram_timing: true
```

to:

```yaml
metrics:
  prometheus:
    use_histogram_timing: true
    # Buckets are SECONDS (exporter divides timing ns by 1e9). 30/60/120 keep
    # outage/PEL-replay tails out of +Inf (DefBuckets top out at 10s). GLOBAL:
    # the built-in timing metrics (processor_latency_ns etc.) get the same
    # seconds buckets — owner-approved 2026-07-13.
    histogram_buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]
```

- [ ] **Step 5: Verify the render**

Run:
```bash
helm lint chart/ && helm template chart/ >/dev/null && echo RENDER_OK
helm template chart/ | grep -c cdc_sync_latency_seconds
helm template chart/ | grep -c histogram_buckets
```
Expected: `RENDER_OK`; first grep ≥ 1 (metric appears in the sink pipeline ConfigMap); second grep ≥ 1 (buckets in the observability ConfigMap). Also confirm the toggle render still works:
```bash
helm template chart/ --set connect.sink.enabled=false | grep -c cdc_sync_latency_seconds
```
Expected: `0` (grep exits 1) — the block lives only in the sink pipeline.

- [ ] **Step 6: Commit**

```bash
git add chart/files/connect/cdc-reverse.yaml chart/files/connect/observability.yaml
git commit -m "chart: cdc_sync_latency_seconds timing histogram in sink pipeline"
```

---

### Task 2: Grafana dashboard panels

**Files:**
- Modify: `chart/files/grafana/cdc-dashboard.json` (append two panels to the `panels` array, after the last panel `"id": 12`)

**Interfaces:**
- Consumes: series `cdc_sync_latency_seconds_bucket` and `cdc_sync_skew_negative` (Task 1).
- Produces: panels id 13 and 14 (Task 3's rules grep and Task 6's L3 check reference the metric names inside this JSON).

- [ ] **Step 1: Confirm the metric names are absent (the "failing test")**

Run: `grep -c "cdc_sync_latency_seconds\|cdc_sync_skew_negative" chart/files/grafana/cdc-dashboard.json`
Expected: `0` (grep exits 1).

- [ ] **Step 2: Append the two panels**

The `panels` array currently ends with the panel `"id": 12` (gridPos `{h:8,w:12,x:0,y:40}`). Add a comma after that panel's closing `}` and append these two objects before the array's closing `]`:

```json
  {
   "id": 13,
   "title": "Sync latency p50/p95/p99 (s) by group",
   "type": "timeseries",
   "datasource": {
    "type": "prometheus",
    "uid": "${datasource}"
   },
   "gridPos": {
    "h": 8,
    "w": 12,
    "x": 12,
    "y": 40
   },
   "description": "cdc_sync_latency_seconds: writer mint (envelope ts) → sink successful apply, ALL ops — includes forward leg, JetStream, and redelivery/replay time. Timing is fed in ns; the exporter divides by 1e9, so values are SECONDS. sum by (le, job): each sink group keeps its own distribution — merging jobs would produce a bogus blended quantile.",
   "fieldConfig": {
    "defaults": {
     "unit": "s"
    }
   },
   "targets": [
    {
     "expr": "histogram_quantile(0.50, sum by (le, job) (rate(cdc_sync_latency_seconds_bucket{namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval])))",
     "legendFormat": "{{job}} p50"
    },
    {
     "expr": "histogram_quantile(0.95, sum by (le, job) (rate(cdc_sync_latency_seconds_bucket{namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval])))",
     "legendFormat": "{{job}} p95"
    },
    {
     "expr": "histogram_quantile(0.99, sum by (le, job) (rate(cdc_sync_latency_seconds_bucket{namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval])))",
     "legendFormat": "{{job}} p99"
    }
   ]
  },
  {
   "id": 14,
   "title": "Sync clock-skew negatives",
   "type": "timeseries",
   "datasource": {
    "type": "prometheus",
    "uid": "${datasource}"
   },
   "gridPos": {
    "h": 8,
    "w": 12,
    "x": 0,
    "y": 48
   },
   "description": "cdc_sync_skew_negative: messages whose writer ts was AHEAD of the sink clock (delta < 0). The latency sample is clamped to 0 (the metric processor rejects negatives), and counted here instead. Non-zero ⇒ writer/sink NTP drift or a corrupt ts field — investigate.",
   "fieldConfig": {
    "defaults": {
     "unit": "short"
    }
   },
   "targets": [
    {
     "expr": "sum(increase({__name__=~\"cdc_sync_skew_negative(_total)?\",namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval]))",
     "legendFormat": "negative deltas (clamped to 0)"
    }
   ]
  }
```

Note: the skew counter query uses the `{__name__=~"...(_total)?"}` form because the exporter may suffix counters with `_total` — this matches every existing counter panel in this dashboard. Histogram `_bucket` series get no such suffix, so panel 13 uses the plain name.

- [ ] **Step 3: Validate JSON + INV-2 grep**

Run:
```bash
python3 -m json.tool chart/files/grafana/cdc-dashboard.json >/dev/null && echo JSON_OK
grep -n "cdc_unprocessable\|cdc_apply\|cdc_forward_publish_failed\|cdc_latency_seconds\|cdc_writer\|elector_\|cdc_sync_latency_seconds\|cdc_sync_skew_negative" chart/files/grafana/cdc-dashboard.json chart/files/prometheus/cdc-alerts.yaml | grep -c "cdc_sync"
helm lint chart/ && helm template chart/ >/dev/null && echo RENDER_OK
```
Expected: `JSON_OK`; the `cdc_sync` grep count ≥ 4 (both names present in the dashboard JSON); `RENDER_OK`.

- [ ] **Step 4: Commit**

```bash
git add chart/files/grafana/cdc-dashboard.json
git commit -m "chart: sync-latency p50/p95/p99 + clock-skew dashboard panels"
```

---

### Task 3: Extend INV-2 bookkeeping in rules/05-invariants.md (additive only)

**Files:**
- Modify: `rules/05-invariants.md` (INV-2 table row + panel list + metric-grep command)

This edit is ADDITIVE ONLY (new metric row, extended panel list, extended grep pattern). It does not change or remove any existing invariant, so it is within the autonomous-maintenance scope of `rules/40-maintenance-protocol.md`; if anything in the file conflicts with these instructions, STOP and report instead of improvising.

- [ ] **Step 1: Back up the rule file (hard safety rule 2)**

```bash
cp rules/05-invariants.md rules/05-invariants.md.bak-$(date +%Y%m%d-%H%M%S)
ls rules/05-invariants.md.bak-* | tail -1
```
Expected: the new backup file is listed.

- [ ] **Step 2: Add a load-bearing row to the INV-2 table**

In the INV-2 "Load-bearing items" table, after the row for `cdc_apply` (`| chart/files/connect/cdc-reverse.yaml | cdc_apply{op,type} increments only after a successful apply |`), add:

```markdown
| `chart/files/connect/cdc-reverse.yaml` | `cdc_sync_latency_seconds{op}` timing records only after a successful apply (`!errored()` + `sync_has_ts` guard); its value stays clamped ≥ 0 and `.int64().string()`-formatted — a negative or float value makes the metric processor error AFTER the apply and nack an already-applied message. Negative deltas increment `cdc_sync_skew_negative` instead |
```

- [ ] **Step 3: Extend the dashboard panel list**

In the same table, the `chart/files/grafana/cdc-dashboard.json` row lists the required panels. Extend the list `..., Connect latency p50/p95/p99, end-to-end latency percentiles, ...` to include the new panels, e.g.:

`..., Connect latency p50/p95/p99, end-to-end latency percentiles, sync latency p50/p95/p99 by group, sync clock-skew negatives, writer throughput/errors, elector leadership.`

- [ ] **Step 4: Extend the metric-name grep**

In INV-2 "How to verify", change the grep command's pattern from:

```
cdc_unprocessable\|cdc_apply\|cdc_forward_publish_failed\|cdc_latency_seconds\|cdc_writer\|elector_
```

to:

```
cdc_unprocessable\|cdc_apply\|cdc_forward_publish_failed\|cdc_latency_seconds\|cdc_sync_latency_seconds\|cdc_sync_skew_negative\|cdc_writer\|elector_
```

- [ ] **Step 5: Read back the edited file and commit**

Read `rules/05-invariants.md` in full; confirm only the three additive edits above changed and every pre-existing row is intact (compare with `git diff rules/05-invariants.md`). Then:

```bash
git add rules/05-invariants.md
git commit -m "rules: INV-2 covers cdc_sync_latency_seconds + skew counter"
```
(The `.bak-*` file stays uncommitted — working-tree safety net per the maintenance protocol.)

---

### Task 4: Fast-tier verification (L0 + L1)

**Files:** none (verification only)

- [ ] **Step 1: Run the fast tiers via the single entrypoint**

```bash
SKIP_L2=1 SKIP_L3=1 scripts/run-all-tests.sh; echo "exit=$?"
```
Expected: `exit=0` — L0 `go test ./...` passes and the L1 render/toggle loop passes for every toggle. Paste the command, exit status, and the script's final summary line into your report.

- [ ] **Step 2: If anything fails**

Use superpowers:systematic-debugging — do NOT weaken a toggle check or an invariant to make it pass. Fix, re-run, and only then continue.

---

### Task 5: L2 — dashboard + alert lab against a real Connect

**Files:** none (verification only; ~7 min, requires docker)

- [ ] **Step 1: Run the lab**

```bash
labs/redis-cdc-error-alerting/scripts/verify-alert.sh; echo "exit=$?"
```
Expected: `exit=0` and the script's final PASS line. This proves the chart's dashboard JSON (bind-mounted single-source into the lab's Grafana) provisions cleanly with the two new panels, alongside the existing alert behavior. Note: the lab runs its OWN connect config, so it does not exercise the new pipeline block — that is Task 6's job. Paste command + exit status + final line.

---

### Task 6: L3 — kind e2e + live metric assertions

**Files:** none (verification only; ~5 min + image build, requires kind cluster `cdc`)

- [ ] **Step 1: Build images into kind and run the e2e verifier**

```bash
scripts/build-images.sh --kind --kind-name=cdc; echo "build_exit=$?"
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh; echo "verify_exit=$?"
```
Expected: both exit 0; the verifier's `verdict.pass=true` / final `[verify-cdc] PASS` line. Paste them.

- [ ] **Step 2: Assert the new metric on the sink's metrics endpoint**

Only the Lease-holding sink pod runs the pipeline, so sweep ALL sink pods and concatenate:

```bash
NS=cdc-k8s
M=$(mktemp)
for p in $(kubectl -n "$NS" get pod -l app=connect-sink -o name); do
  kubectl -n "$NS" port-forward "$p" 14195:4195 >/dev/null 2>&1 &
  PF=$!
  sleep 2
  curl -s http://127.0.0.1:14195/metrics >> "$M" || true
  kill "$PF" 2>/dev/null; wait "$PF" 2>/dev/null
done
echo "--- bucket series (expect >0):"; grep -c 'cdc_sync_latency_seconds_bucket' "$M"
echo "--- ops observed (expect create/update/delete/rename):"; grep -o 'cdc_sync_latency_seconds_count{[^}]*}' "$M" | sort -u
echo "--- 120s bucket present (expect >0):"; grep -c 'le="120"' "$M"
echo "--- skew counter (expect 0 hits or value 0):"; grep 'cdc_sync_skew_negative' "$M" || echo "absent (ok)"
echo "--- processor errors (expect 0 / absent):"; grep 'processor_error' "$M" | grep -v ' 0$' || echo "none non-zero (ok)"
```

Expected:
- `cdc_sync_latency_seconds_bucket` count > 0, with `le="120"` buckets present (custom buckets active).
- `_count` series exist for `op="create"`, `op="update"`, `op="delete"`, `op="rename"`.
- `cdc_sync_skew_negative` absent or 0 (same-node kind cluster ⇒ no skew).
- No non-zero `processor_error` for the sink stream — a non-zero value here is the Codex-flagged parse-failure trap (timing value not an integer string) and means applied messages were nacked: treat as a FAILURE, debug before proceeding.

- [ ] **Step 3: Sanity-bound the sample count against applies**

```bash
APPLY=$(grep -o 'cdc_apply[^ ]* [0-9.e+]*$' "$M" | awk '{s+=$2} END {print s}')
SYNC=$(grep -o 'cdc_sync_latency_seconds_count[^ ]* [0-9.e+]*$' "$M" | awk '{s+=$2} END {print s}')
echo "apply=$APPLY sync=$SYNC"
```
Expected: `sync > 0`, and PER-OP equality for create and update: the `cdc_sync_latency_seconds_count{op="create"}` sum equals the `cdc_apply{op="create"}` sum, likewise for update. A create/update sync count EXCEEDING its apply count means error-path messages recorded — FAILURE.
NOTE (found during execution 2026-07-13): do NOT compare whole-metric totals. `cdc_apply` has NO delete/rename series — pre-existing label-set inconsistency (`cdc_apply{op,type}` in the create/update branch vs `cdc_apply{op}` in delete/rename branches; the registry silently rejects the second shape), recorded in the 2026-07-07 SDD ledger. The sync histogram DOES cover delete/rename, so `sync total > apply total` is expected and correct.

- [ ] **Step 4: Report**

Paste every command + exit status + the assertion outputs. If all pass, the ladder for this change (L0, L1, INV-2 grep, L2, L3) is complete — state that L4 was not required (no consumer-id/group, lease, elector, ack/commit, or nats-init change).

---

## Self-review notes (done at plan-writing time)

- Spec coverage: spec §1 (pipeline) → Task 1; §2 (buckets) → Task 1; §3 (dashboard) → Task 2; INV-2 bookkeeping → Task 3; verification plan → Tasks 4–6. Requirement 3 dropped — no task touches replicas.
- Type consistency: meta keys `sync_has_ts`/`sync_latency_ns`/`sync_skew_neg` and metric names `cdc_sync_latency_seconds`/`cdc_sync_skew_negative` are identical across Tasks 1, 2, 3, 6.
- The dashboard JSON in Task 2 matches the file's existing 1-space indent style and panel-6 structure; ids 13/14 and gridPos slots verified free (panels end at id 12, y=40, x:12 slot empty).
