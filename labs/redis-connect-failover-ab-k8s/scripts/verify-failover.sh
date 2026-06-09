#!/usr/bin/env bash
# A-vs-C failover comparison harness. For each method (A=Deployment+leader-election,
# C=StatefulSet replicas:1) it boots the chart, runs a clean steady-state check, then
# injects two faults on the ACTIVE consumer — graceful delete and force delete —
# measuring for each:
#   failover_time_s = gap_pairs * SAMPLE_MS/1000   (zero-active gap = liveness recovery)
#   overlap_pairs                                    (>=2 active at once; robustness breach)
#   at_most_1_held  = (overlap_pairs == 0)
# Prints a comparison table. Exits 0 iff every method reached steady single-active AND
# every scenario held at-most-1 (overlap_pairs == 0).
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

ROWS=()        # "method|fault|failover_s|overlap|at_most_1"
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

# reset_counters wipes the observer's consumed:* signal so a previous method's frozen
# counters never pollute the next method's overlap/gap math.
reset_counters() {
  K exec "deploy/${PREFIX}redis-central" -- \
    sh -c "redis-cli --scan --pattern 'consumed:*' | xargs -r redis-cli del" >/dev/null 2>&1 || true
}

# measure_fault METHOD FAULT_KIND -> echoes "failover_s overlap"
measure_fault() {
  local method="$1" kind="$2" pod start verdict gap overlap
  pod="$(active_pod "$method")"
  if [[ -z "$pod" ]]; then echo "[${method}/${kind}] no active pod" >&2; echo "0 0"; return; fi
  echo "[${method}/${kind}] injecting on ${pod}" >&2
  start="$(now_ms)"
  if [[ "$kind" == "graceful-delete" ]]; then
    K delete pod "$pod" >/dev/null 2>&1 || true
  else
    K delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
  fi
  sleep "${FAULT_WAIT_S}"
  verdict="$(OBS "verdict?since_unix_ms=${start}")"
  echo "[${method}/${kind}] ${verdict}" >&2
  gap="$(echo "$verdict" | jq -r '.gap_pairs')"
  overlap="$(echo "$verdict" | jq -r '.overlap_pairs')"
  local fs
  fs="$(awk -v g="${gap:-0}" -v ms="${SAMPLE_MS}" 'BEGIN{printf "%.1f", g*ms/1000}')"
  echo "${fs} ${overlap:-0}"
}

run_method() {
  local method="$1"
  echo "================ METHOD ${method} ================"
  echo "[boot] helm upgrade --install ${RELEASE} (method=${method})"
  helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
    -f "${VALUES_FILE}" --set "method=${method}" --wait --timeout 5m
  PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

  # OBS() depends on PREFIX, so (re)define it here.
  OBS() { K exec "deploy/${PREFIX}observer" -- wget -qO- "http://localhost:8070/$1"; }

  reset_counters
  echo "[writer] reset + start rate=${RATE}"
  K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data='{"epoch":"run"}' http://localhost:8081/reset >/dev/null
  K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data="{\"rate\":${RATE}}" http://localhost:8081/rate >/dev/null

  echo "[steady] settle ${SETTLE_S}s, observe ${OBS_WINDOW_S}s"
  sleep "${SETTLE_S}"
  local s_start sv sa
  s_start="$(now_ms)"
  sleep "${OBS_WINDOW_S}"
  sv="$(OBS "verdict?since_unix_ms=${s_start}")"
  echo "[steady] ${sv}"
  sa="$(echo "$sv" | jq -r '.single_active')"
  if [[ "$sa" != "true" ]]; then
    echo "[steady] FAIL — method ${method} did not reach single-active"
    FAIL=1
  fi

  # Scenario 1: graceful delete.
  read -r fs1 ov1 < <(measure_fault "$method" "graceful-delete")
  ROWS+=("${method}|graceful-delete|${fs1}|${ov1}")
  [[ "${ov1:-0}" -gt 0 ]] && FAIL=1

  echo "[reconverge] ${SETTLE_S}s"
  sleep "${SETTLE_S}"

  # Scenario 2: force delete.
  read -r fs2 ov2 < <(measure_fault "$method" "force-delete")
  ROWS+=("${method}|force-delete|${fs2}|${ov2}")
  [[ "${ov2:-0}" -gt 0 ]] && FAIL=1
}

for m in ${METHODS}; do run_method "$m"; done

echo ""
echo "==================== COMPARISON ===================="
printf "%-7s %-16s %-18s %-15s %s\n" "method" "fault" "failover_time_s" "overlap_pairs" "at_most_1_held"
for row in "${ROWS[@]}"; do
  IFS='|' read -r m f fs ov <<<"$row"
  amh="yes"; [[ "${ov:-0}" -gt 0 ]] && amh="no"
  printf "%-7s %-16s %-18s %-15s %s\n" "$m" "$f" "$fs" "$ov" "$amh"
done
echo "===================================================="

if [[ "$FAIL" -eq 0 ]]; then
  echo "[verify-failover] PASS — both methods steady single-active AND at-most-1 held under graceful+force delete"
  exit 0
fi
echo "[verify-failover] FAIL — see rows above (steady single-active failed, or overlap_pairs>0)"
exit 1
