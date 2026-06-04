#!/usr/bin/env bash
# LWW verification harness. Boots the chart (profile=lww), runs Proof A
# (deterministic 3->1->2 + duplicate, direct to redis-region) and Proof B
# (end-to-end verifier Job at a target rate). Exits 0 iff both pass.
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
EPOCH="run-$(date +%s)-$$"

cleanup() { :; }
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "[boot] helm upgrade --install ${RELEASE} (profile=lww)"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  --set profile=lww -f "${VALUES_FILE}" --wait --timeout 5m
RESOURCE_PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

REGION_POD() { kubectl -n "${NS}" get pod -l app=redis-region -o jsonpath='{.items[0].metadata.name}'; }

echo "[proofA] deterministic 3->1->2 + duplicate, direct to redis-region"
LUA="$(cat chart/files/connect/lww_set.lua)"
PROOFA="$(kubectl -n "${NS}" exec "$(REGION_POD)" -- sh -c '
  S="'"$(printf '%s' "$LUA" | sed "s/'/'\\\\''/g")"'"
  redis-cli DEL lwwproof:1 >/dev/null
  a=$(redis-cli EVAL "$S" 1 lwwproof:1 v3 3)
  b=$(redis-cli EVAL "$S" 1 lwwproof:1 v1 1)
  c=$(redis-cli EVAL "$S" 1 lwwproof:1 v2 2)
  d=$(redis-cli EVAL "$S" 1 lwwproof:1 v3 3)
  ver=$(redis-cli HGET lwwproof:1 ver); val=$(redis-cli HGET lwwproof:1 val)
  echo "$a $b $c $d $ver $val"
')"
echo "[proofA] results (want: 1 0 0 -1 3 v3): ${PROOFA}"
read -r A B C D VER VAL <<<"${PROOFA}"
if [[ "$A" != "1" || "$B" != "0" || "$C" != "0" || "$D" != "-1" || "$VER" != "3" || "$VAL" != "v3" ]]; then
  echo "[proofA] FAIL"; exit 1
fi
echo "[proofA] PASS"

echo "[proofB] verifier Job at rate=${RATE} epoch=${EPOCH}"
JOB="verifier-${EPOCH}"
helm template "${RELEASE}" ./chart -n "${NS}" -s templates/verifier-job.yaml \
  -f "${VALUES_FILE}" --set profile=lww \
  --set verifier.run=true --set "verifier.jobName=${JOB}" --set "verifier.epoch=${EPOCH}" \
  --set "verifier.rate=${RATE}" --set "verifier.durationS=${DURATION_S}" \
  --set "verifier.warmupS=${WARMUP_S}" --set "verifier.drainS=${DRAIN_S}" \
  | kubectl apply -n "${NS}" -f -

JOB_FULL="${RESOURCE_PREFIX}${JOB}"
timeout_s=$(( DURATION_S*2 + WARMUP_S + DRAIN_S + 180 ))
deadline=$(( $(date +%s) + timeout_s ))
while (( $(date +%s) < deadline )); do
  st=$(kubectl -n "${NS}" get job/"${JOB_FULL}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
  fa=$(kubectl -n "${NS}" get job/"${JOB_FULL}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
  [[ "$st" == "True" || "$fa" == "True" ]] && break
  sleep 3
done

RESULT="$(kubectl -n "${NS}" logs job/"${JOB_FULL}" | sed -n 's/^RESULT_JSON://p' | tail -n1)"
echo "[proofB] ${RESULT:-<no result>}"
kubectl -n "${NS}" delete job/"${JOB_FULL}" --wait=false >/dev/null 2>&1 || true
[[ -z "$RESULT" ]] && { echo "[proofB] FAIL: no verdict"; kubectl -n "${NS}" logs job/"${JOB_FULL}" --tail=30 || true; exit 1; }

PASS=$(echo "$RESULT" | jq -r '.verdict.pass')
echo "$RESULT" | jq '{rate_achieved_avg:.lww.rate_achieved_avg, stale:.lww.stale, duplicate:.lww.duplicate, mismatches:.lww.mismatches, writes_per_key_avg:.lww.writes_per_key_avg, verdict:.verdict}'
if [[ "$PASS" == "true" ]]; then
  echo "[verify-lww] PASS — both proofs green"; exit 0
else
  echo "[verify-lww] FAIL — $(echo "$RESULT" | jq -r '.verdict.reason')"; exit 1
fi
