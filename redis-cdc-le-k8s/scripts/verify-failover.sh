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
N="${N:-5000}"                        # backlog > READ_LIMIT so the reader fills a full un-acked batch
                                      # with margin (a serialized publisher keeps it un-drained at kill)
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-1}"   # forward-output concurrency during the test: 1 => a serialized
                                      # publisher, so PEL entries are genuinely UN-published at kill
                                      # (real loss, not merely orphaned-but-already-delivered)
READ_LIMIT="${READ_LIMIT:-2000}"      # input XREADGROUP batch: read a big chunk into the PEL that the
                                      # serialized publisher cannot drain before the kill => large,
                                      # deterministic read-but-unpublished in-flight set to strand
PENDING_THRESHOLD="${PENDING_THRESHOLD:-500}"
ARM_TIMEOUT_S="${ARM_TIMEOUT_S:-60}"
FAILOVER_TIMEOUT_S="${FAILOVER_TIMEOUT_S:-120}"
DRAIN_TIMEOUT_S="${DRAIN_TIMEOUT_S:-240}"   # fixed run: max wait for the reused-consumer PEL to drain to 0
SINK_TIMEOUT_S="${SINK_TIMEOUT_S:-300}"     # max wait for the sink to catch up (adaptive: until region stops growing)
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
    --set "connect.source.consumerClientId=${client_val}" \
    --set "connect.source.maxInFlight=${MAX_IN_FLIGHT}" \
    --set "connect.source.readLimit=${READ_LIMIT}" --wait --timeout 5m
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

  # 4) arm: poll the CURRENT leader's PEL, re-reading the lease holder each iteration (a fresh
  #    rollout can hand leadership around before it settles, so a once-captured holder may be a
  #    draining old-RS pod with an empty PEL). When the active consumer's PEL crosses the
  #    threshold, THAT holder is the kill target and its consumer name is CID.
  local h="" cid="" armed=0
  deadline=$(( $(date +%s) + ARM_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    local ch ccid p
    ch="$(holder)"
    if [[ -n "$ch" ]]; then
      if [[ "$mode" == baseline ]]; then ccid="$ch"; else ccid="cdc_propagator_active"; fi
      p="$(pending_count_for "$ccid")"; p="${p:-0}"
      if (( p >= PENDING_THRESHOLD )); then h="$ch"; cid="$ccid"; armed=1; break; fi
    fi
    sleep 0.3
  done
  (( armed == 1 )) || { echo "[failover] INCONCLUSIVE: no leader PEL reached $PENDING_THRESHOLD within ${ARM_TIMEOUT_S}s (raise N or lower throughput)"; return 3; }
  local arm_depth; arm_depth="$(pending_count_for "$cid")"
  log "armed: holder=$h CID=$cid PEL_depth=$arm_depth"

  # 5) SIGKILL the active pod WHILE it holds a deep un-acked (mostly un-published) PEL.
  #    We measure the orphaned residual after failover rather than snapshotting entry-ids here:
  #    the live pod keeps acking between any snapshot and the kill, so only the entries still
  #    un-acked at the instant of death matter, and those are exactly the dead consumer's
  #    residual PEL once the dust settles.
  log "SIGKILL $h"
  kubectl -n "$NS" delete pod "$h" --grace-period=0 --force >/dev/null 2>&1 || true

  # 6) wait for failover
  deadline=$(( $(date +%s) + FAILOVER_TIMEOUT_S ))
  until [[ -n "$(holder)" && "$(holder)" != "$h" ]]; do
    (( $(date +%s) < deadline )) || die "no new lease holder after kill"
    sleep 2
  done
  log "new holder: $(holder)"

  # 7) settle. For fixed, wait until the (reused, stable) consumer's PEL drains to 0 — the new
  #    leader re-read it from "0", re-published and acked. Then, for BOTH modes, wait for the
  #    sink to catch up by polling region membership until it STOPS GROWING (adaptive: robust to
  #    variable sink lag and to any N; a fixed sleep would falsely inflate loss on the fixed run).
  if [[ "$mode" == fixed ]]; then
    deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S ))
    while (( $(date +%s) < deadline )); do
      local still; still="$(pending_count_for "$cid")"; still="${still:-0}"
      (( still == 0 )) && break
      sleep 2
    done
  fi
  local prev=-1 stable=0 cur=0
  deadline=$(( $(date +%s) + SINK_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    cur="$(rr --scan --pattern "lb:failover:active:{run:${runid}:k*}" 2>/dev/null | grep -c . || true)"
    if (( cur == prev )); then stable=$(( stable + 1 )); (( stable >= 3 )) && break; else stable=0; fi
    prev="$cur"; sleep 3
  done
  log "sink settled: region has $cur / $N keys for this run"

  # 8) measure. residual = entries still un-acked under the run's consumer name after settle.
  #    baseline: CID is the DEAD pod name (never reused) => its PEL is orphaned forever.
  #    fixed:    CID is the stable name (reused by the new leader) => its PEL drains to 0.
  local residual; residual="$(pending_count_for "$cid")"; residual="${residual:-0}"
  local present; present="$(rr --scan --pattern "lb:failover:active:{run:${runid}:k*}" 2>/dev/null | grep -c . || true)"
  local loss=$(( N - present ))

  # 9) report
  local result
  result="$(printf '{"mode":"%s","runid":"%s","cid":"%s","n":%d,"arm_depth":%d,"pel_residual":%d,"region_present":%d,"loss_keys":%d}' \
    "$mode" "$runid" "$cid" "$N" "$arm_depth" "$residual" "$present" "$loss")"
  echo "$result" > "${REPORT_DIR}/${runid}-${mode}.json"
  echo "RESULT_JSON:${result}"

  # 10) assert. Both oracles must agree: orphaned PEL (forward leg) AND missing region keys (e2e).
  if [[ "$mode" == baseline ]]; then
    (( loss > 0 ))     || die "baseline expected loss but region has all keys (kill mistimed -> INCONCLUSIVE, retry)"
    (( residual > 0 )) || die "baseline expected entries orphaned in the dead consumer PEL but it is empty (INCONCLUSIVE, retry)"
    log "baseline OK: loss_keys=$loss, orphaned PEL residual=$residual under dead consumer $cid"
    rc XGROUP DELCONSUMER "$STREAM" "$GROUP" "$cid" >/dev/null 2>&1 || true   # remove orphaned dead-pod consumer so it can't contaminate later runs
  else
    (( loss == 0 ))     || die "fixed expected NO loss but region missing $loss keys (fix insufficient on this image)"
    (( residual == 0 )) || die "fixed expected the reused consumer PEL to drain but $residual entries still un-acked (fix insufficient)"
    log "fixed OK: loss_keys=0, reused-consumer PEL fully drained (armed at depth $arm_depth)"
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
