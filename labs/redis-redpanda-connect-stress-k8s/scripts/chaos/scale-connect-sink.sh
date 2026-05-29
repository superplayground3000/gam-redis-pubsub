#!/usr/bin/env bash
# Scales connect-sink to 0 for DOWN_S seconds, then back to 1, waiting for the
# readiness probe (via rollout status) to confirm real recovery.
# Usage: scale-connect-sink.sh [DOWN_S]
# Env: RRCS_NS (default rrcs-k8s), READY_TIMEOUT_S (default 60)
set -euo pipefail

NS="${RRCS_NS:-rrcs-k8s}"
DOWN_S="${1:-8}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-60}"
DEPLOY=connect-sink

echo "[chaos] scaling ${DEPLOY} to 0 for ${DOWN_S}s"
kubectl -n "${NS}" scale deploy/"${DEPLOY}" --replicas=0
# Wait for the pod to terminate gracefully (parity with docker stop).
kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=30s

sleep "${DOWN_S}"

echo "[chaos] scaling ${DEPLOY} back to 1"
kubectl -n "${NS}" scale deploy/"${DEPLOY}" --replicas=1
# rollout status returns ready only once the /ready probe passes (real gate).
if kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout="${READY_TIMEOUT_S}s"; then
  echo "[chaos] ${DEPLOY} recovered (ready)"
  exit 0
fi
echo "[chaos] WARN: ${DEPLOY} not ready within ${READY_TIMEOUT_S}s" >&2
exit 1
