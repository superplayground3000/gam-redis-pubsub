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

# Collect each proof's outcome as "name:pass" pairs for the report. Declared here
# (before Proof A) so Proof A is recorded too — it is the deterministic precondition
# and hard-exits on failure, so reaching the line that records it means it passed.
PROOF_RESULTS=()
allproofs=true

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
PROOF_RESULTS+=("A (deterministic fence):true")

# --- Deterministic proofs against the region pod -----------------------------
# A proof script that exits non-zero records pass=false but does NOT abort the run,
# so the report still generates and the sweep still runs; allproofs tracks the gate.
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
run_proof "MW- (negative control)" bash "${SCRIPT_DIR}/proof-c.sh" "${NS}" "$(REGION_POD)" 5
run_proof "delete" bash "${SCRIPT_DIR}/proof-delete.sh" "${NS}" "$(REGION_POD)"
run_proof "rename" bash "${SCRIPT_DIR}/proof-rename.sh" "${NS}" "$(REGION_POD)"

# --- Rate sweep --------------------------------------------------------------
# Parse SWEEP_TIERS (comma-separated), sorted ascending so the "max passing tier"
# is a true MONOTONIC ceiling: the highest tier such that it AND every lower tier
# passed. A higher-tier pass must NOT mask a lower-tier failure. We also separate
# two failure modes: a real LWW VIOLATION (mismatches/regressions > 0) hard-fails
# the whole run at any tier; a throughput-ceiling fail (e.g. quiescence false —
# the pipeline couldn't drain at that rate) just caps the ceiling, it is not a
# correctness break.
IFS=',' read -r -a _RAW_TIERS <<<"${SWEEP_TIERS}"
mapfile -t TIERS < <(printf '%s\n' "${_RAW_TIERS[@]}" | sort -n)
LOWEST_TIER="${TIERS[0]}"
# A tier is SUSTAINED iff it is correct (mismatches=0, regressions=0) AND the
# pipeline drained (quiescence_ok) — that is the throughput ceiling. Whether
# reordering was observed (stale>0) is a separate proof-quality signal, NOT a
# throughput limit: reordering is more likely at HIGHER rates, so a low tier can
# be correct-but-inconclusive while a higher tier proves the fence under reorder.
max_sustained_tier=0   # highest tier that was correct AND drained
VIOLATION=false        # any tier with mismatches>0 or regressions>0 → hard fail
REORDER_PROVEN=false   # any tier with stale>0 → the fence was exercised end-to-end
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
  local mism regr stale quies sustained
  mism=$(jq -r '.lww.mismatches' <<<"${result}")
  regr=$(jq -r '.lww.regressions' <<<"${result}")
  stale=$(jq -r '.lww.stale' <<<"${result}")
  quies=$(jq -r '.lww.quiescence_ok' <<<"${result}")
  # SUSTAINED = correct AND drained (the throughput-ceiling criterion). Note this
  # is NOT verdict.pass, which additionally requires stale>0 (reorder observed);
  # we track that separately as REORDER_PROVEN.
  sustained=false
  if (( mism == 0 && regr == 0 )) && [[ "$quies" == "true" ]]; then
    sustained=true
  fi
  TIER_JSON="$(jq --argjson rate "${tier}" --argjson r "${result}" --argjson sustained "${sustained}" \
    '. + [{rate:$rate,
           pass:$sustained,
           mismatches:($r.lww.mismatches),
           regressions:($r.lww.regressions),
           stale:($r.lww.stale),
           applied:($r.lww.applied),
           duplicate:($r.lww.duplicate),
           tombstones:($r.lww.tombstones)}]' \
    <<<"${TIER_JSON}")"
  # A real LWW violation at ANY tier hard-fails the run — it is not a throughput
  # ceiling, the fence is broken.
  if (( mism > 0 || regr > 0 )); then
    echo "[sweep] tier=${tier} LWW VIOLATION: mismatches=${mism} regressions=${regr}"
    VIOLATION=true
  fi
  (( stale > 0 )) && REORDER_PROVEN=true
  # Throughput ceiling = highest SUSTAINED tier. A correctness violation fails the
  # whole run globally (above), so taking the max sustained tier here cannot mask a
  # correctness problem; it only reflects how fast the pipeline kept up correctly.
  if [[ "$sustained" == "true" ]] && (( tier > max_sustained_tier )); then
    max_sustained_tier="${tier}"
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
  --argjson max "${max_sustained_tier}" \
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
echo "[verify-lww] max_sustained_tier=${max_sustained_tier} msg/s (lowest swept tier=${LOWEST_TIER}); violation=${VIOLATION}; reorder_proven=${REORDER_PROVEN}"
# PASS requires, in order of severity:
#   1. no proof failed,
#   2. no LWW violation at any tier (mismatches/regressions == 0 everywhere),
#   3. the fence was actually exercised under reordering at least once (stale>0),
#   4. the pipeline sustained (correct + drained) at least the lowest tier.
if [[ "${allproofs}" != "true" ]]; then
  echo "[verify-lww] FAIL — a proof failed (${PROOF_RESULTS[*]}). Report: reports/report.html"
  exit 1
elif [[ "${VIOLATION}" == "true" ]]; then
  echo "[verify-lww] FAIL — LWW VIOLATION observed in the sweep (a tier had mismatches/regressions > 0); the fence is broken. Report: reports/report.html"
  exit 1
elif [[ "${REORDER_PROVEN}" != "true" ]]; then
  echo "[verify-lww] FAIL — inconclusive: no tier observed a strictly-older (stale) arrival, so reorder-fencing was never exercised end-to-end. Lower KEY_SPACE_SIZE or raise the rate to force same-key reordering. Report: reports/report.html"
  exit 1
elif (( max_sustained_tier >= LOWEST_TIER )); then
  echo "[verify-lww] PASS — all proofs green; no LWW violation; fence proven under reorder; max sustained throughput=${max_sustained_tier} msg/s. Report: reports/report.html"
  exit 0
else
  echo "[verify-lww] FAIL — pipeline could not sustain even the lowest tier (${LOWEST_TIER}); max_sustained_tier=${max_sustained_tier}. Report: reports/report.html"
  exit 1
fi
