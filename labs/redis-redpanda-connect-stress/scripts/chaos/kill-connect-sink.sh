#!/usr/bin/env bash
# Stops connect-sink for DOWN_S seconds, then restarts and waits for healthy.
# Usage: kill-connect-sink.sh [DOWN_S]
set -euo pipefail

DOWN_S="${1:-8}"
CONTAINER="rrcs-connect-sink"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-60}"

echo "[chaos] stopping ${CONTAINER} for ${DOWN_S}s"
docker stop "${CONTAINER}" >/dev/null
sleep "${DOWN_S}"
echo "[chaos] starting ${CONTAINER}"
docker start "${CONTAINER}" >/dev/null

# Poll healthcheck until healthy or timeout. Without this, the harness records
# "recovery" before Connect is actually ready and produces misleading latency.
echo "[chaos] waiting for healthy (up to ${READY_TIMEOUT_S}s)"
deadline=$(( $(date +%s) + READY_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo unknown)
  if [[ "${status}" == "healthy" ]]; then
    echo "[chaos] ${CONTAINER} healthy"
    exit 0
  fi
  sleep 1
done

echo "[chaos] WARN: ${CONTAINER} did not reach healthy within ${READY_TIMEOUT_S}s (last status: ${status})" >&2
exit 1
