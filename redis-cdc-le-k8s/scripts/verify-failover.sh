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
# stream entry-ids pending for a given consumer (raw output => bare IDs), one per line, sorted
pending_ids_for() { rc --raw XPENDING "$STREAM" "$GROUP" - + 100000 "$1" 2>/dev/null | grep -oE '[0-9]{13,}-[0-9]+' | sort -u; }
# count of pending entries for a given consumer — arm on THIS consumer, not the group total
pending_count_for() { pending_ids_for "$1" | grep -c . || true; }

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

  # 4) name the consumer for THIS run, then arm on ITS pending (NOT the group total —
  #    a prior baseline run leaves orphaned dead-pod PELs in the same group).
  local h cid
  h="$(holder)"; [[ -n "$h" ]] || die "no lease holder before arm"
  if [[ "$mode" == baseline ]]; then cid="$h"; else cid="cdc_propagator_active"; fi
  local armed=0
  deadline=$(( $(date +%s) + ARM_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    local p; p="$(pending_count_for "$cid")"; p="${p:-0}"
    if (( p >= PENDING_THRESHOLD )); then armed=1; break; fi
    sleep 0.3
  done
  (( armed == 1 )) || { echo "[failover] INCONCLUSIVE: PEL for $cid never reached $PENDING_THRESHOLD (raise N or lower throughput)"; return 3; }
  # guard: leadership must not have moved between naming and arming (baseline cid tracks the holder)
  if [[ "$mode" == baseline && "$(holder)" != "$h" ]]; then die "leadership moved during arm (holder=$(holder), expected $h) -> inconclusive"; fi
  local s_ids; s_ids="$(pending_ids_for "$cid")"
  local s_count; s_count="$(printf '%s\n' "$s_ids" | grep -c . || true)"
  (( s_count > 0 )) || die "S empty under CID=$cid at kill (oracle would be vacuous)"
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
      local still; still="$(pending_ids_for "$cid" | comm -12 - <(printf '%s\n' "$s_ids") | grep -c . || true)"
      (( still == 0 )) && break
      sleep 2
    done
  else
    sleep "$BASELINE_SETTLE_S"
  fi
  sleep "$SINK_SETTLE_S"   # let the sink apply to region

  # 8) measure — PEL delta
  local remain; remain="$(pending_ids_for "$cid" | comm -12 - <(printf '%s\n' "$s_ids") | grep -c . || true)"
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
    rc XGROUP DELCONSUMER "$STREAM" "$GROUP" "$cid" >/dev/null 2>&1 || true   # remove orphaned dead-pod consumer so it can't contaminate later runs
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
