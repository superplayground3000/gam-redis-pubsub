#!/usr/bin/env bash
# Port-forward the dashboard Service to 0.0.0.0 for LAN access.
set -euo pipefail
NS="${RRCS_NS:-lww-k8s}"
RELEASE="${RRCS_RELEASE:-lww}"
LOCAL_PORT="${LOCAL_PORT:-8080}"
PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json 2>/dev/null | jq -r '.resourcePrefix // "lab-"')"
SVC="${PREFIX}dashboard"

echo "[dashboard] forwarding svc/${SVC} :8080 -> 0.0.0.0:${LOCAL_PORT} (ns=${NS})"
echo "[dashboard] reachable at:"
for ip in 127.0.0.1 $(hostname -I 2>/dev/null || true); do
  echo "    http://${ip}:${LOCAL_PORT}"
done
trap 'echo; echo "[dashboard] stopped"; exit 0' INT TERM
exec kubectl -n "${NS}" port-forward --address 0.0.0.0 "svc/${SVC}" "${LOCAL_PORT}:8080"
