#!/usr/bin/env bash
# A-vs-C failover comparison harness. For each method (A=Deployment+leader-election,
# C=StatefulSet replicas:1) it boots the chart, runs a clean steady-state check, then
# injects two faults on the ACTIVE consumer — graceful delete and force delete —
# measuring for each:
#   failover_time_s = gap_pairs * SAMPLE_MS/1000   (zero-active gap = liveness recovery)
#   overlap_pairs                                    (>=2 active at once; robustness breach)
#   at_most_1_held  = (overlap_pairs == 0)
# Prints a comparison table. Exits 0 iff every method reached steady single-active AND
# every scenario held at-most-1 (overlap_pairs == 0) with a readable verdict.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/run-defaults.sh"

NS="${LEL_NS:-lel-k8s}"
RELEASE="${LEL_RELEASE:-lel}"
VALUES_FILE="${LEL_VALUES:-chart/values-dev.yaml}"

K() { kubectl -n "${NS}" "$@"; }
now_ms() { date +%s%3N; }

ROWS=()        # "method|fault|failover_s|overlap"
FAIL=0

# active_pod METHOD -> name of the pod currently consuming.
active_pod() {
  local method="$1"
  if [[ "$method" == "A" ]]; then
    K get lease "${PREFIX}connect-elector" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true
  else
    echo "${PREFIX}connect-0"
  fi
}

# wait_active_ready METHOD -> 0 once the active consumer pod exists and is Ready (~60s).
# Guards against injecting the next fault on a still-terminating / not-yet-recreated pod.
wait_active_ready() {
  local method="$1" pod cond
  for _ in $(seq 1 60); do
    pod="$(active_pod "$method")"
    if [[ -n "$pod" ]]; then
      cond="$(K get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
      [[ "$cond" == "True" ]] && return 0
    fi
    sleep 1
  done
  echo "[${method}] active consumer pod not Ready after 60s" >&2
  return 1
}

# reset_counters wipes the observer's consumed:* signal between methods so a previous
# method's frozen counters never pollute the next method's overlap/gap math. The stream
# (app.events) and consumer group (electors) are intentionally SHARED across methods —
# that is the fairness guarantee: both methods see the identical writer load. Per-method
# measurement is isolated by this counter reset PLUS the clean post-settle steady window,
# so cross-method consumer-group / PEL residue cannot leak into a failover number. (We do
# not destroy the group here: doing so under a live consumer risks a NOGROUP stall.)
reset_counters() {
  K exec "deploy/${PREFIX}redis-central" -- \
    sh -c "redis-cli --scan --pattern 'consumed:*' | xargs -r redis-cli del" >/dev/null 2>&1 || true
}

# vnum JSON FIELD -> the numeric value of .FIELD, or empty string if missing/null/non-numeric.
vnum() { printf '%s' "$1" | jq -er ".${2} | numbers" 2>/dev/null || true; }

# measure_fault METHOD FAULT_KIND -> echoes exactly "failover_s overlap" (or "ERR ERR").
measure_fault() {
  local method="$1" kind="$2" pod start verdict gap overlap fs
  pod="$(active_pod "$method")"
  if [[ -z "$pod" ]]; then echo "[${method}/${kind}] no active pod" >&2; echo "ERR ERR"; return; fi
  echo "[${method}/${kind}] injecting on ${pod}" >&2
  start="$(now_ms)"
  if [[ "$kind" == "graceful-delete" ]]; then
    K delete pod "$pod" >/dev/null 2>&1 || true
  else
    K delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
  fi
  sleep "${FAULT_WAIT_S}"
  verdict="$(OBS "verdict?since_unix_ms=${start}" 2>/dev/null || true)"
  echo "[${method}/${kind}] ${verdict}" >&2
  gap="$(vnum "$verdict" gap_pairs)"
  overlap="$(vnum "$verdict" overlap_pairs)"
  if [[ -z "$gap" || -z "$overlap" ]]; then
    echo "[${method}/${kind}] unreadable verdict -> recording ERR" >&2
    echo "ERR ERR"
    return
  fi
  fs="$(awk -v g="$gap" -v ms="${SAMPLE_MS}" 'BEGIN{printf "%.1f", g*ms/1000}')"
  echo "${fs} ${overlap}"
}

# scenario METHOD KIND -> waits for readiness, measures, appends a row, updates FAIL.
scenario() {
  local method="$1" kind="$2" fs ov
  wait_active_ready "$method" || FAIL=1
  read -r fs ov < <(measure_fault "$method" "$kind")
  ROWS+=("${method}|${kind}|${fs}|${ov}")
  if [[ ! "$ov" =~ ^[0-9]+$ ]] || [[ "$ov" -gt 0 ]]; then FAIL=1; fi
}

run_method() {
  local method="$1"
  echo "================ METHOD ${method} ================"
  echo "[boot] helm upgrade --install ${RELEASE} (method=${method})"
  helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
    -f "${VALUES_FILE}" --set "method=${method}" --wait --timeout 5m
  PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"
  # Derive the sample interval from the chart's effective values so failover_time_s
  # (= gap_pairs * SAMPLE_MS/1000) cannot drift from the observer's real cadence. An
  # explicit SAMPLE_MS env var still wins.
  SAMPLE_MS="${SAMPLE_MS:-$(helm get values "${RELEASE}" -n "${NS}" --all -o json | jq -r '.observer.sampleIntervalMs // 100')}"

  # OBS() depends on PREFIX, so (re)define it here.
  OBS() { K exec "deploy/${PREFIX}observer" -- wget -qO- "http://localhost:8070/$1"; }

  reset_counters
  echo "[writer] reset + start rate=${RATE}"
  K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data='{"epoch":"run"}' http://localhost:8081/reset >/dev/null
  K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data="{\"rate\":${RATE}}" http://localhost:8081/rate >/dev/null

  echo "[steady] settle ${SETTLE_S}s, observe ${OBS_WINDOW_S}s"
  sleep "${SETTLE_S}"
  wait_active_ready "$method" || true
  local s_start sv sa
  s_start="$(now_ms)"
  sleep "${OBS_WINDOW_S}"
  sv="$(OBS "verdict?since_unix_ms=${s_start}" 2>/dev/null || true)"
  echo "[steady] ${sv}"
  sa="$(printf '%s' "$sv" | jq -er '.single_active' 2>/dev/null || true)"
  if [[ "$sa" != "true" ]]; then
    echo "[steady] FAIL — method ${method} did not reach single-active (verdict: '${sv}')"
    FAIL=1
  fi

  scenario "$method" "graceful-delete"
  echo "[reconverge] ${SETTLE_S}s"
  sleep "${SETTLE_S}"
  scenario "$method" "force-delete"
}

for m in ${METHODS}; do run_method "$m"; done

echo ""
echo "==================== COMPARISON ===================="
printf "%-7s %-16s %-18s %-15s %s\n" "method" "fault" "failover_time_s" "overlap_pairs" "at_most_1_held"
for row in "${ROWS[@]}"; do
  IFS='|' read -r m f fs ov <<<"$row"
  if [[ "$ov" =~ ^[0-9]+$ ]]; then
    amh="yes"; [[ "$ov" -gt 0 ]] && amh="no"
  else
    amh="?"
  fi
  printf "%-7s %-16s %-18s %-15s %s\n" "$m" "$f" "$fs" "$ov" "$amh"
done
echo "===================================================="

if [[ "$FAIL" -eq 0 ]]; then
  echo "[verify-failover] PASS — both methods steady single-active AND at-most-1 held under graceful+force delete"
  exit 0
fi
echo "[verify-failover] FAIL — see rows above (steady single-active failed, verdict unreadable, or overlap_pairs>0)"
exit 1
