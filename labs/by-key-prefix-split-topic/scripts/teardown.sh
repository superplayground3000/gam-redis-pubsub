#!/usr/bin/env bash
# teardown.sh — remove all lab resources. Keeps the kind cluster itself (shared).
# Uninstalls the chart release and deletes every lab-owned object (label lab=prefix-split)
# plus the generated ConfigMaps.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

echo "[teardown] deleting lab-owned objects (label lab=prefix-split) in $NS"
kc delete deploy,svc,configmap,pod -l lab=prefix-split --ignore-not-found --wait=false 2>/dev/null || true
kc delete configmap lab-source-config --ignore-not-found 2>/dev/null || true
for p in "${PREFIX_ARR[@]}"; do kc delete configmap "lab-sink-${p}-config" --ignore-not-found 2>/dev/null || true; done

echo "[teardown] uninstalling helm release $RELEASE"
helm uninstall "$RELEASE" -n "$NS" 2>/dev/null || true

if [ "${DELETE_NS:-0}" = "1" ]; then
  echo "[teardown] deleting namespace $NS"
  kubectl delete ns "$NS" --ignore-not-found --wait=false || true
fi

echo "[teardown] remaining lab objects:"
kc get deploy,svc -l lab=prefix-split 2>/dev/null || true
echo "[teardown] done (kind cluster '$KIND_NAME' kept)"
