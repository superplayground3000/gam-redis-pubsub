#!/usr/bin/env bash
# gen-sink-configs.sh — for every prefix in PREFIXES, materialise the reverse
# pipeline from reverse.tpl.yaml (fill __PORT__/__PREFIX__), publish it as a
# ConfigMap, and apply the per-prefix sink Deployment+Service (DESIGN §5.3).
# Deploys the FULL prefix set once; scenarios vary which prefixes receive traffic
# (via the writer's KEY_PREFIXES) and the toxics/consumers — not the sink topology.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

TPL="$LAB/pipelines/reverse.tpl.yaml"
[ -s "$TPL" ] || { echo "FATAL: $TPL missing — run gen-pipelines.sh first"; exit 1; }

for i in "${!PREFIX_ARR[@]}"; do
  p="${PREFIX_ARR[$i]}"
  port="$(tox_port "$i")"
  out="$LAB/pipelines/reverse-${p}.yaml"
  sed -e "s/__PORT__/${port}/g" -e "s/__PREFIX__/${p}/g" "$TPL" > "$out"
  # sanity: no placeholder left
  if grep -q '__PORT__\|__PREFIX__' "$out"; then echo "FATAL: placeholder left in $out"; exit 1; fi

  # ConfigMap from the materialised reverse config (key reverse.yaml -> mount path)
  kc create configmap "lab-sink-${p}-config" \
    --from-file=reverse.yaml="$out" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null

  CONFIG_SHA="$(sha1sum "$out" | cut -c1-12)"
  export NS CONNECT_IMAGE PREFIX="$p" SINK_REPLICAS CONFIG_SHA
  envsubst '${NS} ${CONNECT_IMAGE} ${PREFIX} ${SINK_REPLICAS} ${CONFIG_SHA}' \
    < "$LAB/manifests/sink.tpl.yaml" | kc apply -f - >/dev/null
  echo "[gen-sink] prefix=$p port=$port cfg-sha=$CONFIG_SHA replicas=$SINK_REPLICAS"
done
