#!/usr/bin/env bash
# verify-cdc.sh — boot the chart (profile=cdc), run the verifier Job, and assert
# its RESULT_JSON verdict.pass. Exit 0 only when dedup + per-op + replay all pass.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-k8s}"
RELEASE="${RRCS_RELEASE:-cdc}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
# RRCS_SET: optional space-separated key=value pairs appended as extra --set
# flags to every helm invocation (e.g. RRCS_SET="connect.image=repo/img:tag").
# Empty (default) = behavior unchanged.
EXTRA_SET=()
for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done
EPOCH="run-$(date +%s)"

echo "[boot] helm upgrade --install ${RELEASE} (profile=cdc) ns=${NS}"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  --set profile=cdc -f "${VALUES_FILE}" "${EXTRA_SET[@]}" --wait --timeout 5m
RESOURCE_PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

# The connect legs roll whenever a pipeline ConfigMap changes (checksum/connect-config
# annotation), and helm --wait can return before the new ReplicaSet is observed.
# Wait for both rollouts so the verifier doesn't race the leader election.
for d in connect-source connect-sink; do
  kubectl -n "${NS}" rollout status "deploy/${RESOURCE_PREFIX}${d}" --timeout=180s
done

JOB="verifier-${EPOCH}"
echo "[verify] launching verifier Job ${JOB}"
helm template "${RELEASE}" ./chart -n "${NS}" -s templates/verifier-job.yaml \
  -f "${VALUES_FILE}" --set profile=cdc "${EXTRA_SET[@]}" \
  --set verifier.run=true --set "verifier.jobName=${JOB}" --set "verifier.epoch=${EPOCH}" \
  | kubectl apply -n "${NS}" -f -

JOB_FULL="${RESOURCE_PREFIX}${JOB}"
deadline=$(( $(date +%s) + 240 ))
while (( $(date +%s) < deadline )); do
  st=$(kubectl -n "${NS}" get job/"${JOB_FULL}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
  fa=$(kubectl -n "${NS}" get job/"${JOB_FULL}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
  [[ "$st" == "True" || "$fa" == "True" ]] && break
  sleep 3
done

# `|| true` so a failed `kubectl logs` (e.g. job pod evicted) doesn't abort under
# `set -e` before the empty-RESULT diagnostic below can report it.
RESULT="$(kubectl -n "${NS}" logs job/"${JOB_FULL}" 2>/dev/null | sed -n 's/^RESULT_JSON://p' | tail -n1 || true)"
if [[ -z "${RESULT}" ]]; then
  echo "[verify-cdc] FAIL — no RESULT_JSON from verifier Job"; exit 1
fi
# Emit the raw compact RESULT_JSON line so downstream tools (gen-report.sh) can
# parse it, then a human-friendly summary.
echo "RESULT_JSON:${RESULT}"
echo "${RESULT}" | jq '{dedup_delta:.cdc.dedup_delta, ops_ok:.cdc.ops_ok, replay_ok:.cdc.replay_ok, verdict:.verdict}'
PASS=$(echo "${RESULT}" | jq -r '.verdict.pass')
if [[ "${PASS}" == "true" ]]; then
  echo "[verify-cdc] PASS — dedup + per-op + replay all green"; exit 0
fi
echo "[verify-cdc] FAIL — $(echo "${RESULT}" | jq -r '.verdict.reason')"; exit 1
