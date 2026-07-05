#!/usr/bin/env bash
# Renders the chart to plain YAML at out/manifests.yaml.
# Usage: scripts/render.sh [--profile=lww] [--values=path] [extra helm args...]
# Env: RRCS_NS (default rrcs-k8s)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

NS="${RRCS_NS:-rrcs-k8s}"
PROFILE="cdc"
VALUES=""
EXTRA=()
for arg in "$@"; do
  case "$arg" in
    --profile=*) PROFILE="${arg#*=}";;
    --values=*)  VALUES="${arg#*=}";;
    *)           EXTRA+=("$arg");;
  esac
done

mkdir -p out
args=(template rrcs ./chart --namespace "${NS}")
[[ -n "${PROFILE}" ]] && args+=(--set "profile=${PROFILE}")
[[ -n "${VALUES}" ]]  && args+=(-f "${VALUES}")

helm "${args[@]}" "${EXTRA[@]}" > out/manifests.yaml

echo "wrote out/manifests.yaml"
echo "NOTE: the chart does not create the namespace. Apply with:"
echo "  kubectl create namespace ${NS} --dry-run=client -o yaml | kubectl apply -f -"
echo "  kubectl apply -n ${NS} -f out/manifests.yaml"
