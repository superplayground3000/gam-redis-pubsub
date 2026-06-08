#!/usr/bin/env bash
# LWW (multi-instance) verification harness. Boots the chart (profile=lww) with
# N>1 connect-source + connect-sink pods, then runs:
#   Proof A   — deterministic fence mechanism (3->1->2 + duplicate, direct to region)
#   Proof MW+ — POSITIVE: shared HINCRBY makes multi-writer-same-key safe (no loss)
#   Proof MW- — NEGATIVE control (proof-c.sh): local same-version counters DO lose
#               an update, invisible to the version-only check. PASSES when it
#               confirms the lost update (proves single-writer-per-key precondition)
#   Proof delete — tombstone semantics + no stale resurrection
#   Proof rename — atomic standby->active pairing + stale rename rejection
# Then a RATE SWEEP over SWEEP_TIERS: runs the verifier Job at each tier, records
# the per-tier verdict, finds the highest passing tier, assembles reports/sweep.json
# and renders reports/report.html.
# Exits 0 iff ALL proofs pass AND max_passing_tier >= the lowest swept tier.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/run-defaults.sh"

NS="${RRCS_NS:-lww-k8s}"
RELEASE="${RRCS_RELEASE:-lww}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
RESOURCE_PREFIX="lab-"

cleanup() { :; }
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "[boot] helm upgrade --install ${RELEASE} (profile=lww)"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  --set profile=lww -f "${VALUES_FILE}" --wait --timeout 5m
RESOURCE_PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

REGION_POD() { kubectl -n "${NS}" get pod -l app=redis-region -o jsonpath='{.items[0].metadata.name}'; }

echo "[proofA] deterministic 3->1->2 + duplicate, direct to redis-region"
# Deliver the Lua via `kubectl cp` + `redis-cli --eval` (reads the script from a
# file) rather than string-escaping it into a nested `sh -c` — the script contains
# single quotes and multiple lines, which shell-escaping mangles. `--eval FILE KEY ,
# ARGV...` is the robust path: the comma separates the single key from the ARGV list.
POD="$(REGION_POD)"
kubectl -n "${NS}" cp chart/files/connect/lww_set.lua "${POD}:/tmp/lww_set.lua"
PROOFA="$(kubectl -n "${NS}" exec "${POD}" -- sh -c '
  redis-cli DEL lwwproof:1 >/dev/null
  a=$(redis-cli --eval /tmp/lww_set.lua lwwproof:1 , v3 3 set 0 e)
  b=$(redis-cli --eval /tmp/lww_set.lua lwwproof:1 , v1 1 set 0 e)
  c=$(redis-cli --eval /tmp/lww_set.lua lwwproof:1 , v2 2 set 0 e)
  d=$(redis-cli --eval /tmp/lww_set.lua lwwproof:1 , v3 3 set 0 e)
  ver=$(redis-cli HGET lwwproof:1 ver); val=$(redis-cli HGET lwwproof:1 val)
  echo "$a $b $c $d $ver $val"
')"
echo "[proofA] results (want: 1 0 0 -1 3 v3): ${PROOFA}"
read -r A B C D VER VAL <<<"${PROOFA}"
if [[ "$A" != "1" || "$B" != "0" || "$C" != "0" || "$D" != "-1" || "$VER" != "3" || "$VAL" != "v3" ]]; then
  echo "[proofA] FAIL"; exit 1
fi
echo "[proofA] PASS"

# --- Deterministic proofs against the region pod -----------------------------
# Collect each proof's outcome as "name:pass" pairs. A proof script that exits
# non-zero records pass=false but does NOT abort the run, so the report still
# generates and the sweep still runs; allproofs tracks the overall gate.
PROOF_RESULTS=()
allproofs=true
run_proof() {
  local name="$1"; shift
  echo "[proof] ${name}: $*"
  if "$@"; then
    PROOF_RESULTS+=("${name}:true")
  else
    echo "[proof] ${name} FAILED (rc=$?)"
    PROOF_RESULTS+=("${name}:false")
    allproofs=false
  fi
}

run_proof "MW+"    bash "${SCRIPT_DIR}/proof-mwplus.sh" "${NS}" "$(REGION_POD)"
# MW- is the NEGATIVE control: proof-c.sh PASSES (exit 0) when it confirms the
# lost update, so a true here means the negative control behaved as designed.
run_proof "MW-"    bash "${SCRIPT_DIR}/proof-c.sh"      "${NS}" "$(REGION_POD)" 5
run_proof "delete" bash "${SCRIPT_DIR}/proof-delete.sh" "${NS}" "$(REGION_POD)"
run_proof "rename" bash "${SCRIPT_DIR}/proof-rename.sh" "${NS}" "$(REGION_POD)"

# --- Rate sweep --------------------------------------------------------------
# Parse SWEEP_TIERS (comma-separated). For each tier, render+apply the verifier
# Job, wait for completion, parse its RESULT_JSON verdict, and accumulate a JSON
# tier object. Track the highest tier whose verdict.pass==true.
IFS=',' read -r -a TIERS <<<"${SWEEP_TIERS}"
LOWEST_TIER="${TIERS[0]}"
max_passing_tier=0
TIER_JSON='[]'

run_tier() {
  local tier="$1"
  local epoch="run-${tier}-$$"
  local job="verifier-${epoch}"
  echo "[sweep] verifier Job at rate=${tier} epoch=${epoch}"
  helm template "${RELEASE}" ./chart -n "${NS}" -s templates/verifier-job.yaml \
    -f "${VALUES_FILE}" --set profile=lww \
    --set verifier.run=true --set "verifier.jobName=${job}" --set "verifier.epoch=${epoch}" \
    --set "verifier.rate=${tier}" --set "verifier.durationS=${DURATION_S}" \
    --set "verifier.warmupS=${WARMUP_S}" --set "verifier.drainS=${DRAIN_S}" \
    | kubectl apply -n "${NS}" -f -

  local job_full="${RESOURCE_PREFIX}${job}"
  local timeout_s=$(( DURATION_S*2 + WARMUP_S + DRAIN_S + 180 ))
  local deadline=$(( $(date +%s) + timeout_s ))
  while (( $(date +%s) < deadline )); do
    local st fa
    st=$(kubectl -n "${NS}" get job/"${job_full}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    fa=$(kubectl -n "${NS}" get job/"${job_full}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
    [[ "$st" == "True" || "$fa" == "True" ]] && break
    sleep 3
  done

  local result
  result="$(kubectl -n "${NS}" logs job/"${job_full}" | sed -n 's/^RESULT_JSON://p' | tail -n1)"
  kubectl -n "${NS}" delete job/"${job_full}" --wait=false >/dev/null 2>&1 || true

  if [[ -z "$result" ]]; then
    echo "[sweep] tier=${tier} FAIL: no RESULT_JSON"
    kubectl -n "${NS}" logs job/"${job_full}" --tail=30 2>/dev/null || true
    # Record a failed tier so the report still reflects the attempt.
    TIER_JSON="$(jq --argjson rate "${tier}" \
      '. + [{rate:$rate, pass:false, mismatches:0, stale:0, applied:0, duplicate:0, tombstones:0}]' \
      <<<"${TIER_JSON}")"
    allproofs=false
    return
  fi

  echo "[sweep] tier=${tier} ${result}"
  local pass
  pass=$(jq -r '.verdict.pass' <<<"${result}")
  TIER_JSON="$(jq --argjson rate "${tier}" --argjson r "${result}" \
    '. + [{rate:$rate,
           pass:($r.verdict.pass),
           mismatches:($r.lww.mismatches),
           stale:($r.lww.stale),
           applied:($r.lww.applied),
           duplicate:($r.lww.duplicate),
           tombstones:($r.lww.tombstones)}]' \
    <<<"${TIER_JSON}")"
  if [[ "$pass" == "true" ]] && (( tier > max_passing_tier )); then
    max_passing_tier="${tier}"
  fi
}

for tier in "${TIERS[@]}"; do
  run_tier "${tier}"
done

# --- Assemble sweep.json + render report -------------------------------------
mkdir -p reports
PROOF_JSON='[]'
for pr in "${PROOF_RESULTS[@]}"; do
  pname="${pr%:*}"; ppass="${pr##*:}"
  PROOF_JSON="$(jq --arg name "${pname}" --argjson pass "${ppass}" \
    '. + [{name:$name, pass:$pass}]' <<<"${PROOF_JSON}")"
done

jq -n \
  --arg lab "redis-connect-lww-hincrby-k8s" \
  --argjson max "${max_passing_tier}" \
  --argjson tiers "${TIER_JSON}" \
  --argjson proofs "${PROOF_JSON}" \
  '{lab:$lab, max_passing_tier:$max, tiers:$tiers, proofs:$proofs}' \
  > reports/sweep.json
echo "[report] wrote reports/sweep.json"

bash "${SCRIPT_DIR}/build-binaries.sh"
./bin/report-gen -in reports/sweep.json -out reports/report.html
echo "[report] wrote reports/report.html"

# --- Final verdict -----------------------------------------------------------
# Pass iff every proof passed AND the sweep cleared at least the lowest tier.
echo "[verify-lww] proofs: ${PROOF_RESULTS[*]}"
echo "[verify-lww] max_passing_tier=${max_passing_tier} (lowest swept tier=${LOWEST_TIER})"
if [[ "${allproofs}" == "true" ]] && (( max_passing_tier >= LOWEST_TIER )); then
  echo "[verify-lww] PASS — all proofs green; sweep cleared >= ${LOWEST_TIER} (max ${max_passing_tier}). Report: reports/report.html"
  exit 0
else
  reason="proofs=${allproofs}, max_passing_tier=${max_passing_tier} < lowest ${LOWEST_TIER}"
  [[ "${allproofs}" == "true" ]] && reason="sweep did not clear the lowest tier (${LOWEST_TIER}); max_passing_tier=${max_passing_tier}"
  echo "[verify-lww] FAIL — ${reason}. Report: reports/report.html"
  exit 1
fi
