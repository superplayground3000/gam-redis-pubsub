#!/usr/bin/env bash
# Builds all Go binaries locally to ./bin (no Docker). Satisfies the
# "binary builds must provide local build scripts" requirement.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${LAB_DIR}"
mkdir -p bin
# Keep the writer's embedded hmax.lua in sync with the chart source of truth.
cp chart/files/connect/hmax.lua writer/hmax.lua
for m in writer verifier gc-sweeper report-gen; do
  echo "[build] ${m}"
  ( cd "${m}" && go build -o "../bin/${m}" . )
done
echo "[ok] binaries in ./bin: $(ls bin)"
