# Stable Redis Consumer Identity + SIGKILL No-Loss Proof — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the forward-leg Redis consumer identity follow the leadership role (stable name) instead of the pod, so an incoming leader replays the dead leader's un-acked PEL — then prove it on a kind cluster with an A/B (baseline-loses vs fixed-doesn't) failover test.

**Architecture:** One-line chart change routes `client_id` through a Helm value (`connect.source.consumerClientId`, default `cdc_propagator_active`). A new `scripts/verify-failover.sh` runs the same SIGKILL-failover test twice — baseline (`__POD__`) and fixed (`cdc_propagator_active`) — using a pure `redis-cli` oracle: forward-leg **PEL delta** (does the kill-time at-risk set `S` stay stuck or drain?) plus end-to-end **region-KV key membership**. No NATS CLI, no code change.

**Tech Stack:** Helm 3, kind, `kubectl exec … redis-cli`, bash. Deployed image `hpdevelop/connect:4.92.0-claudefix`. Target namespace `cdc-k8s`, release `cdc`, resource prefix `lab-`.

**Spec:** `docs/superpowers/specs/2026-07-03-redis-cdc-stable-consumer-failover-design.md`

---

## File Structure

- **Modify** `chart/files/connect/cdc-forward.yaml:35` — `client_id` becomes `{{ .Values.connect.source.consumerClientId }}`.
- **Modify** `chart/values.yaml` (under `connect.source:`, ~line 141) — add `consumerClientId: cdc_propagator_active`.
- **Create** `scripts/verify-failover.sh` — the A/B failover orchestrator + oracle (self-verifying; exits non-zero on any failed assertion).
- **Generated at run time** `reports/failover/<runid>-<mode>.json` + `reports/failover/<runid>-summary.txt` — evidence (not source).

Naming used across tasks (must stay consistent):
- Helm value: `connect.source.consumerClientId` (string).
- Stable name literal: `cdc_propagator_active`.
- Central stream/group: `app.events` / `cdc_propagator`.
- Region key pattern per run: `lb:failover:active:{run:<RUNID>:k<i>}` (`{`/`}` are literal in standalone Redis).
- Event id per run: `<RUNID>-<i>`.
- Exec targets: `deploy/lab-redis-central`, `deploy/lab-redis-region`; Lease `lab-connect-source-elector`; source Deployment `lab-connect-source` (pods `app=connect-source`).

---

## Task 1: Parameterize the forward-leg consumer name

**Files:**
- Modify: `chart/files/connect/cdc-forward.yaml:35`
- Modify: `chart/values.yaml` (under `connect.source:`)

- [ ] **Step 1: Write the failing render test**

Run (from `redis-cdc-le-k8s/`):

```bash
helm template cdc ./chart -n cdc-k8s -f chart/values-dev.yaml --set profile=cdc \
  | grep -c 'client_id: cdc_propagator_active'
```

Expected right now: `0` (still hard-coded `__POD__`). This is the red state.

- [ ] **Step 2: Add the Helm value**

In `chart/values.yaml`, inside the existing `connect:` → `source:` block (immediately after `streamID: forward_leg`), add:

```yaml
    # Stable logical Redis consumer name for the forward leg. It MUST NOT be
    # pod-scoped: on ungraceful (SIGKILL) failover the incoming leader reuses this
    # name and the redis_streams input replays the dead leader's un-acked PEL
    # (backlog read from "0"), deduped downstream by Nats-Msg-Id. Set to __POD__
    # only to reproduce the pre-fix message-loss baseline.
    consumerClientId: cdc_propagator_active
```

- [ ] **Step 3: Route the config through the value**

In `chart/files/connect/cdc-forward.yaml`, change line 35 from:

```yaml
    client_id: __POD__
```

to:

```yaml
    client_id: {{ .Values.connect.source.consumerClientId }}
```

Leave `output.label: __POD__` (line 99) unchanged — it is a Benthos component label, not the consumer identity, and the elector still rewrites it per-pod.

- [ ] **Step 4: Run the render tests to verify green**

```bash
helm template cdc ./chart -n cdc-k8s -f chart/values-dev.yaml --set profile=cdc \
  | grep -c 'client_id: cdc_propagator_active'
```
Expected: `1` (or more).

```bash
helm template cdc ./chart -n cdc-k8s -f chart/values-dev.yaml --set profile=cdc \
  --set connect.source.consumerClientId=__POD__ \
  | grep -c 'client_id: __POD__'
```
Expected: `1` (baseline override still renders the pod token for the elector to expand).

- [ ] **Step 5: Commit**

```bash
git add chart/files/connect/cdc-forward.yaml chart/values.yaml
git commit -m "fix(redis-cdc): route forward-leg client_id through connect.source.consumerClientId

Default cdc_propagator_active (stable logical consumer). On SIGKILL failover the
incoming leader reuses the name and the input replays the dead leader's un-acked
PEL, deduped by Nats-Msg-Id. Set __POD__ to reproduce the loss baseline. No Go
change (elector ReplaceAll on an absent token is a no-op).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Write the A/B failover verifier

**Files:**
- Create: `scripts/verify-failover.sh`

- [ ] **Step 1: Create the script**

Create `scripts/verify-failover.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# verify-failover.sh — prove the forward leg (Redis app.events -> NATS KV_CDC) loses
# messages on ungraceful (SIGKILL) failover with a pod-scoped consumer name, and does
# NOT with a stable consumer name. Runs the SAME test twice via
# connect.source.consumerClientId (baseline=__POD__, fixed=cdc_propagator_active).
#
# Oracle (pure redis-cli; spec 2026-07-03):
#   - forward-leg PEL delta: snapshot the at-risk pending set S under the run's consumer
#     name CID at kill; baseline => S stays stuck under the dead consumer; fixed => S drains.
#   - end-to-end region-KV membership: baseline => region missing the orphaned keys;
#     fixed => region has all N keys.
#
# Usage:
#   scripts/verify-failover.sh            # both legs; exit 0 iff baseline loses AND fixed doesn't
#   MODE=baseline scripts/verify-failover.sh
#   MODE=fixed    scripts/verify-failover.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-k8s}"
RELEASE="${RRCS_RELEASE:-cdc}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
N="${N:-1000}"
PENDING_THRESHOLD="${PENDING_THRESHOLD:-40}"
ARM_TIMEOUT_S="${ARM_TIMEOUT_S:-40}"
FAILOVER_TIMEOUT_S="${FAILOVER_TIMEOUT_S:-120}"
DRAIN_TIMEOUT_S="${DRAIN_TIMEOUT_S:-90}"
BASELINE_SETTLE_S="${BASELINE_SETTLE_S:-30}"
SINK_SETTLE_S="${SINK_SETTLE_S:-45}"
REPORT_DIR="${REPORT_DIR:-reports/failover}"

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
SRC_DEPLOY="deploy/${PREFIX}connect-source"
LEASE="${PREFIX}connect-source-elector"
GROUP="cdc_propagator"
STREAM="app.events"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
holder() { kubectl -n "$NS" get lease "$LEASE" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
now_ms() { date +%s%3N; }
pending_total() { rc XPENDING "$STREAM" "$GROUP" 2>/dev/null | head -n1 | tr -d '[:space:]'; }
# stream entry-ids pending for a given consumer (13-digit-ms-<seq>), one per line
pending_ids_for() { rc XPENDING "$STREAM" "$GROUP" - + 100000 "$1" 2>/dev/null | grep -oE '[0-9]{13}-[0-9]+' | sort -u; }

log() { echo "[failover] $*"; }
die() { echo "[failover] FAIL: $*" >&2; exit 1; }

run_one() {
  local mode="$1" client_val cid runid
  case "$mode" in
    baseline) client_val="__POD__" ;;
    fixed)    client_val="cdc_propagator_active" ;;
    *) die "unknown MODE=$mode (use baseline|fixed)";;
  esac
  runid="$(now_ms)"
  mkdir -p "$REPORT_DIR"
  log "=== MODE=$mode consumerClientId=$client_val runid=$runid ==="

  # 1) deploy the chosen config and force pods to re-read the pipeline
  helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
    --set profile=cdc -f "$VALUES_FILE" \
    --set "connect.source.consumerClientId=${client_val}" --wait --timeout 5m
  kubectl -n "$NS" rollout restart "$SRC_DEPLOY"
  kubectl -n "$NS" rollout status "$SRC_DEPLOY" --timeout=180s
  local deadline=$(( $(date +%s) + FAILOVER_TIMEOUT_S ))
  until [[ -n "$(holder)" ]]; do (( $(date +%s) < deadline )) || die "no lease holder after rollout"; sleep 2; done

  # 2) clean per-run state (fresh region; unique namespace makes central carryover irrelevant)
  rr FLUSHDB >/dev/null
  rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true

  # 3) burst N distinct-key create events (space-free tokens; body is opaque)
  local cmds; cmds="$(mktemp)"
  local i ts; ts="$(now_ms)"
  for (( i=1; i<=N; i++ )); do
    echo "XADD $STREAM * event_id ${runid}-${i} op create type string kv_key lb:failover:active:{run:${runid}:k${i}} ts ${ts} body v${i}"
  done > "$cmds"
  log "producing N=$N events"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"

  # 4) arm: wait for a non-trivial PEL, then snapshot the active holder + consumer name CID
  local armed=0 h
  deadline=$(( $(date +%s) + ARM_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    local p; p="$(pending_total)"; p="${p:-0}"
    if (( p >= PENDING_THRESHOLD )); then armed=1; break; fi
    sleep 0.3
  done
  (( armed == 1 )) || { echo "[failover] INCONCLUSIVE: PEL never reached $PENDING_THRESHOLD (raise N or lower throughput)"; return 3; }
  h="$(holder)"; [[ -n "$h" ]] || die "no holder at arm time"
  if [[ "$mode" == baseline ]]; then cid="$h"; else cid="cdc_propagator_active"; fi
  local s_ids; s_ids="$(pending_ids_for "$cid")"
  local s_count; s_count="$(echo -n "$s_ids" | grep -c . || true)"
  (( s_count > 0 )) || die "S empty under CID=$cid at kill (oracle would be vacuous)"
  # map S entry-ids -> kv_keys
  local s_keys="" id kk
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    kk="$(rc XRANGE "$STREAM" "$id" "$id" 2>/dev/null | grep -oE 'lb:failover:active:\{run:[0-9]+:k[0-9]+\}' | head -n1)"
    [[ -n "$kk" ]] && s_keys+="${kk}"$'\n'
  done <<< "$s_ids"
  log "armed: holder=$h CID=$cid |S|=$s_count"

  # 5) SIGKILL the active pod
  log "SIGKILL $h"
  kubectl -n "$NS" delete pod "$h" --grace-period=0 --force >/dev/null 2>&1 || true

  # 6) wait for failover
  deadline=$(( $(date +%s) + FAILOVER_TIMEOUT_S ))
  until [[ -n "$(holder)" && "$(holder)" != "$h" ]]; do
    (( $(date +%s) < deadline )) || die "no new lease holder after kill"
    sleep 2
  done
  log "new holder: $(holder)"

  # 7) settle
  if [[ "$mode" == fixed ]]; then
    deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S ))
    while (( $(date +%s) < deadline )); do
      local still; still="$(pending_ids_for "$cid" | comm -12 - <(echo "$s_ids") | grep -c . || true)"
      (( still == 0 )) && break
      sleep 2
    done
  else
    sleep "$BASELINE_SETTLE_S"
  fi
  sleep "$SINK_SETTLE_S"   # let the sink apply to region

  # 8) measure — PEL delta
  local remain; remain="$(pending_ids_for "$cid" | comm -12 - <(echo "$s_ids") | grep -c . || true)"
  # 8b) measure — region key membership
  local present; present="$(rr --scan --pattern "lb:failover:active:{run:${runid}:k*}" 2>/dev/null | grep -c . || true)"
  local loss=$(( N - present ))

  # 9) report
  local result
  result="$(printf '{"mode":"%s","runid":"%s","cid":"%s","n":%d,"s_count":%d,"pel_remaining":%d,"region_present":%d,"loss_keys":%d}' \
    "$mode" "$runid" "$cid" "$N" "$s_count" "$remain" "$present" "$loss")"
  echo "$result" > "${REPORT_DIR}/${runid}-${mode}.json"
  echo "RESULT_JSON:${result}"

  # 10) assert
  if [[ "$mode" == baseline ]]; then
    (( loss > 0 ))    || die "baseline expected loss but region has all keys (kill mistimed -> INCONCLUSIVE, retry)"
    (( remain > 0 ))  || die "baseline expected S stuck in PEL but it drained"
    log "baseline OK: loss_keys=$loss (S stranded, region missing $loss)"
  else
    (( loss == 0 ))   || die "fixed expected NO loss but region missing $loss keys (fix insufficient on this image)"
    (( remain == 0 )) || die "fixed expected S drained but $remain of S still pending (fix insufficient)"
    log "fixed OK: loss_keys=0, all $s_count stranded entries replayed"
  fi
}

MODE="${MODE:-both}"
if [[ "$MODE" == both ]]; then
  run_one baseline || { rc_code=$?; [[ $rc_code == 3 ]] && { echo "[failover] baseline inconclusive"; exit 3; }; exit $rc_code; }
  run_one fixed    || exit $?
  echo "[failover] PASS — baseline LOSES on SIGKILL failover, fixed DOES NOT"
else
  run_one "$MODE"
fi
```

- [ ] **Step 2: Syntax + lint check (the script's unit test)**

```bash
bash -n scripts/verify-failover.sh && echo "SYNTAX OK"
command -v shellcheck >/dev/null && shellcheck -S warning scripts/verify-failover.sh || echo "(shellcheck not installed; skipped)"
chmod +x scripts/verify-failover.sh
```
Expected: `SYNTAX OK`, no shellcheck errors (warnings about `comm`/process-substitution are acceptable).

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-failover.sh
git commit -m "test(redis-cdc): add SIGKILL-failover A/B no-loss verifier

Pure redis-cli oracle: forward-leg PEL delta (S stuck vs drained under the run's
consumer name) + end-to-end region-KV key membership. Runs baseline (__POD__) and
fixed (cdc_propagator_active) via connect.source.consumerClientId; passes iff
baseline loses and fixed does not.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Execute the A/B proof on the kind cluster and record evidence

**Files:**
- Generated: `reports/failover/<runid>-baseline.json`, `reports/failover/<runid>-fixed.json`, `reports/failover/summary.md`

**Pre-req:** the `cdc` kind cluster is up with namespace `cdc-k8s` deployed (verified: `lab-connect-source` 3/3, lease holder present). If not, boot per README (`kind create cluster --name cdc`, `scripts/build-images.sh --kind --kind-name=cdc`, then a `helm upgrade`).

- [ ] **Step 1: Sanity-check connectivity**

```bash
kubectl -n cdc-k8s exec -i deploy/lab-redis-central -- redis-cli PING
kubectl -n cdc-k8s get lease lab-connect-source-elector -o jsonpath='{.spec.holderIdentity}'; echo
```
Expected: `PONG`, and a `lab-connect-source-...` pod name.

- [ ] **Step 2: Run the baseline leg alone first (must demonstrate loss)**

```bash
MODE=baseline scripts/verify-failover.sh
```
Expected: a `RESULT_JSON:` line with `loss_keys > 0` and `pel_remaining > 0`, ending `baseline OK`. Exit 0.
If it prints `INCONCLUSIVE` (exit 3): re-run with a bigger burst / tighter window, e.g. `N=3000 PENDING_THRESHOLD=60 MODE=baseline scripts/verify-failover.sh`. Do not proceed until baseline reproducibly loses.

- [ ] **Step 3: Run the fixed leg alone (must show no loss)**

```bash
MODE=fixed scripts/verify-failover.sh
```
Expected: `RESULT_JSON:` with `loss_keys == 0` and `pel_remaining == 0`, ending `fixed OK`. Exit 0.
If `fixed` still loses: this is the falsification path in the spec — the stable name is insufficient on `4.92.0-claudefix` and recovery needs an `XAUTOCLAIM`/startup-replay code change. STOP and report the `RESULT_JSON` rather than forcing a pass.

- [ ] **Step 4: Run the combined gate**

```bash
scripts/verify-failover.sh; echo "exit=$?"
```
Expected: both legs run, final line `PASS — baseline LOSES on SIGKILL failover, fixed DOES NOT`, `exit=0`.

- [ ] **Step 5: Write the evidence summary**

Create `reports/failover/summary.md` capturing: the date, image tag (`hpdevelop/connect:4.92.0-claudefix`), the two `RESULT_JSON` lines, and a one-paragraph verdict tying `loss_keys`/`pel_remaining` to the diagnosis. Use the actual numbers emitted (fill from the two `reports/failover/<runid>-*.json` files — do not invent values).

- [ ] **Step 6: Commit the evidence**

```bash
git add reports/failover/
git commit -m "test(redis-cdc): record SIGKILL-failover A/B evidence (baseline loses, fixed no-loss)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Fix (route `client_id` through `connect.source.consumerClientId`, default `cdc_propagator_active`, `output.label` untouched) → Task 1. ✓
- A/B baseline-vs-fixed via the value → Task 2 `run_one`, Task 3 combined gate. ✓
- Arm in the vulnerable window (`pending>=THRESHOLD`), snapshot `S` **under CID** (not the holder), holder only picks the kill target → Task 2 step 4. ✓ (this is the stop-gate correction)
- Forward-leg PEL delta (stuck vs drained on the same `S`) → Task 2 measure/assert. ✓
- End-to-end region-KV membership, fresh prefix + `FLUSHDB` per run → Task 2 steps 2/8b. ✓
- No "drain-to-0" wait on baseline (bounded settle instead) → Task 2 step 7. ✓
- Falsifiability (fixed still loses ⇒ report, don't force pass) → Task 3 step 3. ✓
- Evidence report under `reports/` → Task 3 steps 5-6. ✓

**Placeholder scan:** none — full script, exact commands, exact expected outputs.

**Type/name consistency:** `connect.source.consumerClientId`, `cdc_propagator_active`, `app.events`/`cdc_propagator`, `lb:failover:active:{run:<RUNID>:k<i>}`, `lab-` prefix, and function names (`pending_ids_for`, `run_one`) are used identically across Task 1/2/3. ✓

**Known robustness notes (intentional, not gaps):**
- `run_one` asserts on **this run's `S` entry-ids** (via `comm -12`), not total group pending, so orphans left by a prior baseline run don't corrupt the fixed run's `pel_remaining`.
- `rollout restart` after `helm upgrade` guarantees pods re-read the pipeline (the elector renders `client_id` once at boot).
- Baseline deliberately leaves orphaned PEL + missing region keys; the unique per-run namespace + `FLUSHDB` isolate runs.
