#!/usr/bin/env bash
# Builds the single consolidated app image (writer/verifier/elector/dashboard/latency-calculator). Push and kind-load are opt-in.
# Usage:
#   scripts/build-images.sh                                   # build-only, tag :dev
#   scripts/build-images.sh --base-registry=corp.io/mirror/   # redirect Dockerfile FROM
#   scripts/build-images.sh --registry=corp.io/team --push    # retag + push to remote
#   scripts/build-images.sh --kind --kind-name=rrcs           # load into kind cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

BASE_REGISTRY=""
REGISTRY=""
TAG="dev"
PUSH=0
KIND=0
KIND_NAME="kind"
for arg in "$@"; do
  case "$arg" in
    --base-registry=*) BASE_REGISTRY="${arg#*=}";;
    --registry=*)      REGISTRY="${arg#*=}";;
    --tag=*)           TAG="${arg#*=}";;
    --push)            PUSH=1;;
    --kind)            KIND=1;;
    --kind-name=*)     KIND_NAME="${arg#*=}";;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

# Single consolidated image holding every Go binary. REGISTRY (if set) prefixes
# the local name; must match values images.registry so the chart pulls what we built.
prefix=""
[[ -n "${REGISTRY}" ]] && prefix="${REGISTRY%/}/"
APP_IMG="${prefix}redis-rrcs/cdc-apps:${TAG}"

echo "[build] ${APP_IMG} (BASE_REGISTRY='${BASE_REGISTRY}')"
DOCKER_BUILDKIT=1 docker build --build-arg "BASE_REGISTRY=${BASE_REGISTRY}" -t "${APP_IMG}" .

if (( KIND )); then
  echo "[kind] loading image into cluster '${KIND_NAME}'"
  kind load docker-image "${APP_IMG}" --name "${KIND_NAME}"
fi

if (( PUSH )); then
  if [[ -z "${REGISTRY}" ]]; then
    echo "[push] --push requires --registry=<ref>" >&2
    exit 2
  fi
  echo "[push] pushing to ${REGISTRY}"
  docker push "${APP_IMG}"
else
  echo "[push] skipped (no --push). Built locally:"
  echo "  ${APP_IMG}"
fi
