# 50k Loss-Free Headroom Bump — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise JetStream `--max-bytes` from 2GB to 5GB as the new default of `labs/redis-redpanda-throughput-stress/`, then recalibrate so the 50k tier passes verdict loss-free in both write modes.

**Architecture:** Single config knob change (env-tunable, default 5GB), supporting docs updates (README knobs table, RESEARCH.md sizing rationale, .env.example), two matrix runs (first to verify loss-free + harvest p99, second to verify the calibrated gate passes), regenerate dashboard.

**Tech Stack:** docker-compose, NATS JetStream + nats CLI, bash, jq, Python 3 (dashboard generator).

**Spec:** [`docs/superpowers/specs/2026-05-27-throughput-stress-headroom-design.md`](../specs/2026-05-27-throughput-stress-headroom-design.md)

**Working directory for all tasks:** `/media/hp/secondary/projects/gam-redis-pubsub`

---

## File-touch map

| File | Touched in task |
|---|---|
| `labs/redis-redpanda-throughput-stress/docker-compose.yml` | Task 1 |
| `labs/redis-redpanda-throughput-stress/.env.example` | Task 2 |
| `labs/redis-redpanda-throughput-stress/README.md` | Task 3 |
| `labs/redis-redpanda-throughput-stress/RESEARCH.md` | Task 4 |
| `labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh` | Task 7 |
| `labs/redis-redpanda-throughput-stress/reports/*.json` | Tasks 6 and 8 (regenerated) |
| `labs/redis-redpanda-throughput-stress/reports/dashboard.html` | Task 8 (regenerated) |

---

## Task 1: Make `--max-bytes` env-tunable in docker-compose, default 5GB

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/docker-compose.yml:89`

- [ ] **Step 1: Edit the nats-init stream-add command**

Change line 89 from:

```yaml
            --max-bytes 2GB \
```

to:

```yaml
            --max-bytes ${NATS_MAX_BYTES:-5GB} \
```

- [ ] **Step 2: Verify docker-compose expands the env var correctly**

Run from `labs/redis-redpanda-throughput-stress/`:

```bash
cd labs/redis-redpanda-throughput-stress
docker compose config | grep -A1 max-bytes
```

Expected output contains the literal string `--max-bytes 5GB \` (compose-time env expansion already resolved the default).

- [ ] **Step 3: Verify env override works**

```bash
NATS_MAX_BYTES=8GB docker compose config | grep -A1 max-bytes
```

Expected output contains the literal string `--max-bytes 8GB \`.

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-throughput-stress/docker-compose.yml
git commit -m "redis-redpanda-throughput-stress: NATS_MAX_BYTES env-tunable, default 5GB

Raises the JetStream APP_EVENTS cap from 2GB to 5GB so the 50k tier
has buffer to drain loss-free. Env-tunable for future research without
docker-compose edits."
```

---

## Task 2: Document `NATS_MAX_BYTES` in .env.example

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/.env.example`

- [ ] **Step 1: Add the new row under "Host port overrides"**

Insert these two lines after line 23 (after `WRITER_PORT=18081`):

```
# JetStream APP_EVENTS stream size cap. 5GB holds the 50k tier peak
# buffer (~2.55GB for a 30s sustain) with comfortable headroom.
NATS_MAX_BYTES=5GB
```

The resulting block starting at line 16 must look like:

```
# Host port overrides (defaults shown)
REDIS_CENTRAL_PORT=18379
REDIS_REGION_PORT=18380
NATS_CLIENT_PORT=18222
NATS_MON_PORT=18322
CONNECT_SRC_PORT=18195
CONNECT_SINK_PORT=18196
WRITER_PORT=18081

# JetStream APP_EVENTS stream size cap. 5GB holds the 50k tier peak
# buffer (~2.55GB for a 30s sustain) with comfortable headroom.
NATS_MAX_BYTES=5GB

# These are fixed in docker-compose.yml (listed for visibility):
```

- [ ] **Step 2: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/.env.example
git commit -m "redis-redpanda-throughput-stress: document NATS_MAX_BYTES in .env.example"
```

---

## Task 3: Update README knobs table and calibration narrative

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/README.md:44-56` (knobs table)
- Modify: `labs/redis-redpanda-throughput-stress/README.md:76-87` (calibration mode section)

- [ ] **Step 1: Add `NATS_MAX_BYTES` row to the knobs table**

Insert a new row immediately before the `MAX_RATE` row (currently line 55). The full updated table (lines 44–57) must read:

```markdown
| Env var       | Default | Effect                                        |
|---------------|---------|-----------------------------------------------|
| `DURATION_S`  | `30`    | sustain window per tier                       |
| `WARMUP_S`    | `5`     | half-rate warmup window                       |
| `DRAIN_S`     | `10`    | post-sustain drain window                     |
| `WORKERS`     | `16`    | writer goroutines                             |
| `BATCH_MAX`   | `500`   | ceiling on adaptive batch depth (batch mode)  |
| `PATTERN_WEIGHTS`     | `33,33,34` | per-write pattern weighted picker       |
| `PATTERN_CARDINALITY` | `20000`    | unique IDs per pattern                  |
| `PAYLOAD_BYTES` | `1024`| JSON pad bytes per event                      |
| `STREAM_MAXLEN` | `2000000` | central + region stream MAXLEN ~ cap      |
| `NATS_MAX_BYTES` | `5GB` | JetStream APP_EVENTS byte cap (raise for higher tiers) |
| `MAX_RATE`    | `60000` | hard ceiling on `POST /rate`                   |
| `INITIAL_MODE`| `batch` | starting write mode                            |
```

- [ ] **Step 2: Update the calibration-mode narrative for the 50k tier**

The current calibration-mode section (lines 76–87) was written when the 50k tier was expected to fail. Replace lines 76–87 with:

```markdown
## Calibration mode (default)

Out of the box `scripts/lib/tier-defs.sh` ships with `TIER_P99_MS` calibrated from a full-matrix run on a 32-core / 122 GiB host. All six tiers gate rate floor, `missing==0`, and a p99 sync-latency ceiling. The 50k tier passes loss-free under the default `NATS_MAX_BYTES=5GB`; on smaller hosts you may need to lower the matrix's top tier or raise `NATS_MAX_BYTES` further.

To recalibrate on a different host:

1. Run the full matrix at least once on the target host.
2. Inspect `reports/*.json` for `sync_latency_ms.p99` across both modes.
3. Pick ceilings (suggested: `round_up_to_100ms(max(p99_batch, p99_single) * 1.25)`).
4. Edit `TIER_P99_MS` in `scripts/lib/tier-defs.sh`.

After calibration, the harness gates all three: rate, missing, p99.
```

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/README.md
git commit -m "redis-redpanda-throughput-stress: README knobs table + 50k narrative update"
```

---

## Task 4: Add JetStream sizing section to RESEARCH.md

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/RESEARCH.md`

- [ ] **Step 1: Insert new section between "Why STREAM_MAXLEN" and "Why calibration-mode verdict"**

Locate the line `## Why calibration-mode verdict` (currently line 44). Immediately before it, insert this new section:

```markdown
## Why NATS_MAX_BYTES = 5GB (was 2GB)

JetStream's `APP_EVENTS` stream is configured `--storage file --discard old --max-bytes ...`. When the stream hits the byte cap, every new publish discards the oldest unacked message — silent loss before the sink can pull. This is the dominant loss path at high throughput.

Sizing math at 50k:

- Writer commits 50 000 msg/s × 30 s sustain × ~1.7 KB JetStream envelope (1024 B payload + JSON wrapper + NATS headers) ≈ **2.55 GB peak buffer**.
- A 2 GB cap evicts ~0.55 GB before the sink can drain — observed as 40–50% loss on the original matrix run at 50k.
- A 5 GB cap gives ~2× headroom over the 50k peak buffer. Even if the sink briefly lags 3–5 s behind the writer, the buffer absorbs it without eviction.

The end-of-run `nats.bytes` from the failed 50k runs (1.26 GB) is itself evidence the sink can keep pace once the cap stops the eviction race — it's the steady-state retained-message footprint, not a backlog.

The knob is env-tunable (`NATS_MAX_BYTES`) so future tiers (60k, 80k) can raise it without docker-compose edits. nats container memory cap (2 GiB) still bounds index footprint comfortably at 5 GB stream size (~500 MB index for ~3 M messages tracked).

```

(Note the trailing blank line so the next `## Why calibration-mode verdict` is properly separated.)

- [ ] **Step 2: Verify the section count went from 8 to 9**

```bash
grep -c "^## " labs/redis-redpanda-throughput-stress/RESEARCH.md
```

Expected output: `9`.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/RESEARCH.md
git commit -m "redis-redpanda-throughput-stress: RESEARCH.md adds NATS_MAX_BYTES sizing rationale"
```

---

## Task 5: Bring stack up and verify the new 5GB cap is live

**Files:** none (verification only)

- [ ] **Step 1: Tear down any existing stack to ensure a clean nats-init run**

```bash
cd labs/redis-redpanda-throughput-stress
docker compose down -v
```

Expected: no error. (`down -v` deletes the named `nats-data` volume so the next `up` re-runs `nats-init` against an empty data dir, which is the only way `stream add` re-runs.)

- [ ] **Step 2: Boot the stack**

```bash
docker compose up --wait
```

Expected: all services report healthy within ~30s. `rrts-nats-init` exits 0.

- [ ] **Step 3: Verify the stream cap is 5GB**

```bash
docker exec rrts-nats nats stream info APP_EVENTS | grep -i 'max bytes'
```

Expected output line contains `5.00 GiB` or `5,000,000,000`. If it shows `2.00 GiB`, the nats-data volume was not wiped — repeat Step 1.

- [ ] **Step 4: Leave the stack running for Task 6**

No teardown here — Task 6's matrix run reuses this stack.

---

## Task 6: Run the first matrix and verify 50k loss-free

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/reports/*.json` (regenerated by the harness)

- [ ] **Step 1: Run the full default matrix**

```bash
cd labs/redis-redpanda-throughput-stress
bash scripts/stress-run.sh
```

Expected wall-clock: 10–15 min. The harness drives each of 6 tiers × 2 modes = 12 runs, writes `reports/{tier}-{mode}.json` after each, and prints a summary table at the end. Because the script was launched with no arguments, it will auto-teardown (`docker compose down -v`) at the end — that's expected.

- [ ] **Step 2: Verify both 50k reports are loss-free**

```bash
jq '{tier, mode, missing, trimmed, rate_achieved, verdict_detail: .verdict.detail}' \
   reports/50000-batch.json reports/50000-single.json
```

Expected for both reports:
- `missing == 0`
- `trimmed == 0`
- `rate_achieved >= 45000` (i.e., ≥ 0.90 × 50000)
- `verdict_detail.rate_floor_ok == true`
- `verdict_detail.missing_ok == true`
- `verdict_detail.p99_latency_ok == null` (p99 gate is still skipped because `TIER_P99_MS[50000]` is empty)

**If any 50k report shows `missing > 0`:** stop and investigate — `NATS_MAX_BYTES=5GB` is not enough headroom on this host. Re-check `nats stream info APP_EVENTS` to confirm the cap is live, then consider raising the env var via `NATS_MAX_BYTES=8GB bash scripts/stress-run.sh` and re-running. Do not proceed to Task 7 until 50k is loss-free.

**If any 50k report shows `quiescence_timeout == true`:** per the spec's risk note, raise `DRAIN_S` from 10 to 20 in `scripts/lib/tier-defs.sh`, re-run, then document the change in RESEARCH.md.

- [ ] **Step 3: Verify all other tiers also passed rate-floor + missing gates**

```bash
jq '{tier, mode, verdict_detail: .verdict.detail}' reports/*.json | \
  grep -E '"(rate_floor_ok|missing_ok)": false' || echo "ALL PASS"
```

Expected output: `ALL PASS`.

If any tier failed, do not proceed — surface the failures and stop.

- [ ] **Step 4: Capture the 50k p99 numbers for Task 7**

```bash
jq '{tier, mode, p99: .sync_latency_ms.p99}' reports/50000-batch.json reports/50000-single.json
```

Record both p99 values. They feed the ceiling computation in Task 7.

- [ ] **Step 5: Commit the first-matrix reports**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-throughput-stress/reports/
git commit -m "redis-redpanda-throughput-stress: first matrix at 5GB cap — 50k loss-free

50k both modes now PASS rate_floor + missing gates. p99 still skipped
pending tier-defs calibration in the next commit."
```

---

## Task 7: Calibrate `TIER_P99_MS[50000]` from the matrix data

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh`

- [ ] **Step 1: Compute the 50k p99 ceiling**

Using the two p99 values captured in Task 6 step 4, compute:

```
ceiling_ms = ceil_to_100ms(max(p99_batch, p99_single) × 1.25)
```

with a floor of 100 ms. Example: if `p99_batch=6200ms` and `p99_single=7100ms`, then `max=7100`, `×1.25=8875`, `ceil to next 100ms=8900`. So `ceiling_ms=8900`.

Record the computed value as `CEILING_MS`.

- [ ] **Step 2: Edit `tier-defs.sh` to set the 50k ceiling**

Current line 57 reads:

```bash
  [50000]=""
```

Change it to use the computed value (substitute `CEILING_MS`):

```bash
  [50000]=CEILING_MS
```

Also update the per-tier breakdown comment at lines 35–42. The current line 41 reads:

```bash
#   50k: BOTH modes fail with 40-50% loss; ceiling left null (skip gate) —
#        the lab's purpose at 50k is to demonstrate the ceiling, not gate on it.
```

Replace both lines (41–42) with (substitute `p99_batch`, `p99_single`, `CEILING_MS` from Task 6 step 4 and Task 7 step 1):

```bash
#   50k: batch=p99_batch, single=p99_single -> max*1.25 -> ceil=CEILING_MS
#        (passes loss-free under NATS_MAX_BYTES=5GB; recalibrated 2026-05-27)
```

- [ ] **Step 3: Decide whether to tighten 50k rate floor**

If both 50k modes in Task 6 step 4 reported `rate_achieved / 50000 >= 0.95`, tighten the floor:

```bash
  [50000]=0.95
```

(line 27 in the `TIER_RATE_MIN_PCT` array). Otherwise leave it at `0.90`.

- [ ] **Step 4: Verify the file still parses as bash**

```bash
bash -n labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh
```

Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh
git commit -m "redis-redpanda-throughput-stress: calibrate 50k p99 ceiling at 5GB cap

50k both modes now pass loss-free; ceiling computed from observed p99
using the standard ceil_100ms(max * 1.25) heuristic."
```

---

## Task 8: Verification matrix + dashboard regeneration

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/reports/*.json` (regenerated)
- Modify: `labs/redis-redpanda-throughput-stress/reports/dashboard.html` (regenerated)

- [ ] **Step 1: Run the verification matrix**

```bash
cd labs/redis-redpanda-throughput-stress
bash scripts/stress-run.sh
```

Wall-clock: 10–15 min. Auto-tears down at end (no-arg invocation).

- [ ] **Step 2: Verify all 12 reports show `verdict.pass == true`**

```bash
jq -r 'select(.verdict.pass == false) | "\(.tier)-\(.mode) FAILED: \(.verdict.detail)"' \
   reports/*.json || true
echo "---"
jq -r 'select(.verdict.pass == true) | "\(.tier)-\(.mode) PASS"' reports/*.json | wc -l
```

Expected: no `FAILED:` lines before `---`, and the count after `---` is `12`.

**If any tier failed `p99_latency_ok`:** the calibrated ceiling was too tight for this run. Inspect the failing tier's p99, recompute, edit `tier-defs.sh`, commit the tier-defs change, and re-run Task 8 step 1.

- [ ] **Step 3: Regenerate the dashboard**

```bash
python3 scripts/dashboard.py
```

Expected output ends with `Dashboard: 12 reports -> reports/dashboard.html` and a `file://` URL.

- [ ] **Step 4: Sanity-check dashboard contents**

```bash
grep -c '"missing_ok": true' reports/*.json | grep -vE ':12$' && echo "MISMATCH" || echo "OK"
```

Expected: `OK` (every report has exactly one `"missing_ok": true` line).

```bash
grep -o '"verdict":{"pass":true' reports/*.json | wc -l
```

Expected: `12`.

- [ ] **Step 5: Commit the calibrated reports and dashboard**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-throughput-stress/reports/
git commit -m "redis-redpanda-throughput-stress: verification matrix + dashboard at 5GB cap

All 12 tiers pass rate_floor + missing + p99 gates. 50k loss-free
both modes. Dashboard regenerated."
```

---

---

## Addendum 2026-05-27: tasks added after the first matrix failed

The first matrix run (Task 6 above) showed the 5GB cap alone did not produce loss-free 50k — the connect-sink, not the JetStream buffer, was the real bottleneck. See spec amendment for full analysis. The following tasks were added after the failure was diagnosed and the user authorized the corrected scope (sink CPU + max_in_flight + DRAIN_S).

### Task 9: Bump connect-sink CPU 6→12 in docker-compose.yml

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/docker-compose.yml` (the `connect-sink` service block, around line 132)

- [ ] **Step 1: Edit the connect-sink resource limit**

Locate the `connect-sink:` service block. Its `deploy.resources.limits` line currently reads:

```yaml
        limits: { cpus: "6.0", memory: "2g" }
```

Change to:

```yaml
        limits: { cpus: "12.0", memory: "2g" }
```

Do NOT touch the `connect-source` block (it stays at 6.0 CPU).

- [ ] **Step 2: Verify**

```bash
cd labs/redis-redpanda-throughput-stress
docker compose config | grep -B5 -A1 'rrts-connect-sink' | grep cpus
```

Expected output contains `cpus: '12.0'` (compose YAML normalization may quote the value).

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/docker-compose.yml
git commit -m "redis-redpanda-throughput-stress: bump connect-sink CPU 6->12

First matrix showed the sink (not the 5GB JetStream buffer) is the
50k bottleneck. Doubling CPU is the first knob the sink needs."
```

### Task 10: Raise max_in_flight 256→1024 on both fan-out outputs in reverse.yaml

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/connect/reverse.yaml:40,46`

- [ ] **Step 1: Edit both `max_in_flight` lines**

Locate the two `max_in_flight: 256` lines (one under the `redis` output for cache SET, one under `redis_streams` for region-events XADD). Change both to:

```yaml
          max_in_flight: 1024
```

- [ ] **Step 2: Verify**

```bash
grep -c 'max_in_flight: 1024' labs/redis-redpanda-throughput-stress/connect/reverse.yaml
```

Expected output: `2`.

```bash
grep -c 'max_in_flight: 256' labs/redis-redpanda-throughput-stress/connect/reverse.yaml
```

Expected output: `0`.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/connect/reverse.yaml
git commit -m "redis-redpanda-throughput-stress: raise sink max_in_flight 256->1024

Symmetric with the JetStream input's max_in_flight on the source side.
At 50k * ~1.7KB the fan-out per-output depth needs >256 to keep up."
```

### Task 11: Raise DRAIN_S default 10→30 in tier-defs.sh

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh:63`

- [ ] **Step 1: Edit the DRAIN_S default**

Locate the line:

```bash
DRAIN_S="${DRAIN_S:-10}"
```

Change to:

```bash
DRAIN_S="${DRAIN_S:-30}"
```

- [ ] **Step 2: Verify**

```bash
grep 'DRAIN_S=' labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh
```

Expected output contains `DRAIN_S="${DRAIN_S:-30}"`.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh
git commit -m "redis-redpanda-throughput-stress: raise DRAIN_S default 10->30

Per first-matrix data: 50k batch had ~755k in-flight at writer-stop;
sink steady-state delivery ~30k/s -> ~25s to drain. 30s gives margin."
```

### Task 12: Amend `## Why NATS_MAX_BYTES = 5GB (was 2GB)` in RESEARCH.md

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/RESEARCH.md` (the section added in Task 4)

- [ ] **Step 1: Append a corrected-analysis subsection inside the existing section**

After the final paragraph of `## Why NATS_MAX_BYTES = 5GB (was 2GB)` (the one ending "...if RSS approaches the cap"), insert a blank line then this subsection:

```markdown
### Corrected after first matrix: buffer alone wasn't enough

The first verification matrix (2026-05-27) showed the 5GB cap did NOT produce loss-free 50k by itself. Missing count stayed at ~750k, but the failure mode flipped: instead of JetStream evicting overflow mid-sustain, the stream filled with messages the connect-sink could not deliver in time, and `DRAIN_S=10s` expired with ~750k messages still in flight (`quiescence_timeout=true` in the report).

The `nats.bytes ≈ delivered × 1.7 KB` match cited above was misread — it was the steady-state product of continuous eviction holding the buffer bounded, not evidence the sink could keep pace at line rate.

The actual fix at 50k required three additional knobs:

- `connect-sink` CPU cap raised from 6 to 12 (it was saturating the 6 CPU at 50k).
- `max_in_flight` raised from 256 to 1024 on both `reverse.yaml` fan-out outputs.
- `DRAIN_S` default raised from 10 s to 30 s so the sink can finish draining the backlog before quiescence checks.

The 5GB cap is still load-bearing — it stops eviction-driven loss — but the sink-side knobs are what turn 50k into a loss-free tier on this host.
```

- [ ] **Step 2: Verify section count still 9**

```bash
grep -c "^## " labs/redis-redpanda-throughput-stress/RESEARCH.md
```

Expected output: `9` (no new `##` heading; the corrected analysis is a `###` subsection inside the existing one).

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/RESEARCH.md
git commit -m "redis-redpanda-throughput-stress: RESEARCH.md notes corrected sink-bottleneck finding"
```

### Task 13: Re-run matrix with new knobs (inline)

- [ ] Boot stack with new config: `cd labs/redis-redpanda-throughput-stress && docker compose down -v && docker compose up --wait`
- [ ] Verify sink CPU shows 12 in `docker compose config`
- [ ] Run full matrix: `bash scripts/stress-run.sh`
- [ ] Verify: 50k both modes show `missing == 0`, `trimmed == 0`, `quiescence_timeout == false`. 40k batch no longer trims.
- [ ] Capture all p99 values for ALL tiers (recalibration needed across the board, not just 50k)
- [ ] Commit reports

### Task 14: Recalibrate ALL tier p99 ceilings (inline)

- [ ] Compute new ceilings via `ceil_100ms(max(p99_batch, p99_single) * 1.25)`, floor 100 ms
- [ ] Edit `scripts/lib/tier-defs.sh` `TIER_P99_MS` for any tier whose ceiling drifted
- [ ] Update the per-tier-breakdown comment in tier-defs.sh
- [ ] Commit

### Task 15: Verification matrix + dashboard regen (inline, replaces original Task 8)

- [ ] Re-run matrix once more to verify all 12 reports show `verdict.pass == true`
- [ ] Regenerate dashboard via `python3 scripts/dashboard.py`
- [ ] Commit reports + dashboard

---

## Self-review check

**Spec coverage:**

| Spec section | Plan task |
|---|---|
| 1. Goal (loss-free 50k passing all three gates) | Tasks 5–8 collectively |
| 2. Root cause | Documented in Task 4 (RESEARCH.md) |
| 3. Single change (5GB env-tunable) | Tasks 1, 2 |
| 4. Files touched table | Mirrored in plan's "File-touch map" |
| 5. Verification & calibration flow (steps 1–6) | Tasks 5, 6, 7, 8 in order |
| 6. Verdict impact | Verified in Task 8 step 2 |
| 7. Risks (quiescence timeout, nats memory) | Task 6 step 2 contingency, ops note |
| 8. Non-goals (no new tiers, no storage swap) | Plan does none of them |
| 9. /research-lab compliance | Doc updates in Tasks 3, 4 keep RESEARCH/README aligned |

**No-placeholder check:** All `CEILING_MS`, `p99_batch`, `p99_single` substitutions in Task 7 are bound to concrete values captured in Task 6 step 4 — they are values to substitute, not placeholders for the engineer to invent.

**Type consistency:** Env var name `NATS_MAX_BYTES` used identically in docker-compose.yml (Task 1), .env.example (Task 2), README knobs table (Task 3), RESEARCH.md (Task 4). Tier-defs key `[50000]` used consistently in Task 7.
