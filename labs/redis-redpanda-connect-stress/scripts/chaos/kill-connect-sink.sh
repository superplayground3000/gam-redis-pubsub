#!/usr/bin/env bash
# Stops connect-sink for DOWN_S seconds, then restarts it.
# Usage: kill-connect-sink.sh [DOWN_S]
set -euo pipefail

DOWN_S="${1:-8}"
CONTAINER="rrcs-connect-sink"

echo "[chaos] stopping ${CONTAINER} for ${DOWN_S}s"
docker stop "${CONTAINER}" >/dev/null
sleep "${DOWN_S}"
echo "[chaos] starting ${CONTAINER}"
docker start "${CONTAINER}" >/dev/null
echo "[chaos] done"
