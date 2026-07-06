#!/usr/bin/env bash
# verify-robustness.sh — single entrypoint. Validates CONNECT_IMAGE (default
# hpdevelop/connect:v4.92.0-batch-nats) in kind against the two requirements in
# docs/labs/robustness-test/request.md. Phases:
#   0 e2e correctness      (scripts/verify-cdc.sh, RRCS_SET image override)
#   1 A/B failover canary  (scripts/verify-failover.sh; retried on rc=3, max 2)
#   2 sink-leader SIGKILL  (kill-sink-leader.sh; retried on rc=3, max 2)
#   3 standby SIGKILL      (kill-standby.sh)
#   4 poison metrics       (poison-metrics.sh)
# Exit 0 iff every phase PASSes. Artifacts: labs/robustness-test/reports/<ts>/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${LAB_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

KIND_NAME="${KIND_NAME:-cdc}"
export RRCS_NS="$NS" RRCS_RELEASE="$RELEASE" RRCS_PREFIX="$PREFIX"
export RRCS_SET="connect.image=${CONNECT_IMAGE}"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
OUT="${LAB_DIR}/reports/${RUN_TS}"
mkdir -p "$OUT"
declare -A VERDICT
ORDER=(p0_e2e p1_failover_ab p2_sink_leader_kill p3_standby_kill p4_poison_metrics)

log() { echo "[robustness] $*"; }

# run_phase <name> <retries-on-rc3> <cmd...>
run_phase() {
  local name="$1" retries="$2"; shift 2
  local attempt rc
  for (( attempt=0; attempt<=retries; attempt++ )); do
    log "=== ${name} (attempt $((attempt+1))) ==="
    rc=0; "$@" 2>&1 | tee "${OUT}/${name}.attempt$((attempt+1)).log" || rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then VERDICT[$name]=PASS; return 0; fi
    if (( rc == 3 && attempt < retries )); then log "${name} INCONCLUSIVE (rc=3) — retrying"; continue; fi
    VERDICT[$name]=$([[ $rc == 3 ]] && echo INCONCLUSIVE || echo FAIL)
    return 1
  done
}

finish() {
  local pass=true k
  for k in "${ORDER[@]}"; do [[ "${VERDICT[$k]:-SKIPPED}" == "PASS" ]] || pass=false; done
  local digest
  digest="$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$CONNECT_IMAGE" 2>/dev/null)" || digest="unknown"
  {
    echo "{"
    echo "  \"image\": \"${CONNECT_IMAGE}\", \"digest\": \"${digest}\", \"started\": \"${RUN_TS}\","
    echo "  \"phases\": {"
    local first=1
    for k in "${ORDER[@]}"; do
      (( first )) || echo ","; first=0
      printf '    "%s": "%s"' "$k" "${VERDICT[$k]:-SKIPPED}"
    done
    echo ""
    echo "  },"
    echo "  \"pass\": ${pass}"
    echo "}"
  } > "${OUT}/report.json"
  {
    echo "# robustness-test report ${RUN_TS}"
    echo ""
    echo "Image: \`${CONNECT_IMAGE}\` (${digest})"
    echo ""
    echo "| Phase | Verdict |"
    echo "|---|---|"
    for k in "${ORDER[@]}"; do echo "| ${k} | ${VERDICT[$k]:-SKIPPED} |"; done
    echo ""
    echo "Overall: $($pass && echo PASS || echo FAIL)"
  } > "${OUT}/report.md"
  jq . "${OUT}/report.json" >/dev/null   # self-check the JSON is valid
  log "report: ${OUT}/report.md"
  $pass && { log "OVERALL PASS"; exit 0; } || { log "OVERALL FAIL"; exit 1; }
}
trap finish EXIT

cd "$REPO_DIR"

# Preflight
docker image inspect "$CONNECT_IMAGE" >/dev/null 2>&1 || { echo "[robustness] FAIL: image ${CONNECT_IMAGE} not in local docker store" >&2; exit 1; }
kind get clusters 2>/dev/null | grep -qx "$KIND_NAME"  || { echo "[robustness] FAIL: kind cluster '${KIND_NAME}' not found (kind create cluster --name ${KIND_NAME})" >&2; exit 1; }
log "loading images into kind '${KIND_NAME}'"
scripts/build-images.sh --kind --kind-name="$KIND_NAME" >"${OUT}/build-images.log" 2>&1
kind load docker-image "$CONNECT_IMAGE" --name "$KIND_NAME" >>"${OUT}/build-images.log" 2>&1

run_phase p0_e2e 0 scripts/verify-cdc.sh || exit 1
run_phase p1_failover_ab 2 scripts/verify-failover.sh || exit 1

# verify-failover leaves source overrides (maxInFlight=1, readLimit=2000) in the
# release — restore default config (still with the target image) before phases 2-4.
log "restoring default config with connect.image=${CONNECT_IMAGE}"
helm upgrade --install "$RELEASE" ./chart -n "$NS" \
  --set profile=cdc -f chart/values-dev.yaml \
  --set "connect.image=${CONNECT_IMAGE}" --wait --timeout 5m >"${OUT}/redeploy.log" 2>&1
kubectl -n "$NS" rollout status "$SRC_DEPLOY" "$SINK_DEPLOY" --timeout=180s >>"${OUT}/redeploy.log" 2>&1

run_phase p2_sink_leader_kill 2 "${SCRIPT_DIR}/kill-sink-leader.sh" || exit 1
run_phase p3_standby_kill 0 "${SCRIPT_DIR}/kill-standby.sh" || exit 1
run_phase p4_poison_metrics 1 "${SCRIPT_DIR}/poison-metrics.sh" || exit 1
