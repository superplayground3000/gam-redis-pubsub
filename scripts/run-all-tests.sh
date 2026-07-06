#!/usr/bin/env bash
# Single verification entrypoint for the ladder in rules/05-invariants.md:
#   L0  go test ./...                              (<10 s, always)
#   L1  helm lint + template + toggle renders      (seconds, always)
#   L2  labs/redis-cdc-error-alerting proof        (~7 min; skip: SKIP_L2=1)
#   L3  kind e2e build-images + verify-cdc         (~5 min; skip: SKIP_L3=1)
#   L4  failover chaos                             (~12 min; opt-in: RUN_FAILOVER=1)
# CI runs this with SKIP_L2=1 SKIP_L3=1 (no docker-heavy tiers on PR).
# Env knobs: KIND_NAME (default cdc), RRCS_NS (default cdc-k8s), RRCS_RELEASE (default cdc).
set -uo pipefail
cd "$(dirname "$0")/.."

KIND_NAME="${KIND_NAME:-cdc}"
export RRCS_NS="${RRCS_NS:-cdc-k8s}"
export RRCS_RELEASE="${RRCS_RELEASE:-cdc}"

declare -a SUMMARY=()
fail() { echo "[run-all-tests] $1 FAIL"; SUMMARY+=("$1 FAIL"); print_summary; exit 1; }
pass() { echo "[run-all-tests] $1 PASS"; SUMMARY+=("$1 PASS"); }
skip() { echo "[run-all-tests] $1 SKIPPED ($2)"; SUMMARY+=("$1 SKIPPED"); }
print_summary() {
  echo "[run-all-tests] ---- summary ----"
  for line in "${SUMMARY[@]}"; do echo "[run-all-tests]   $line"; done
}

echo "[run-all-tests] == L0: go test ./... =="
[ -f go.sum ] || go mod download all
go test ./... || fail L0
pass L0

echo "[run-all-tests] == L1: helm lint + template + toggle renders =="
helm lint chart/ || fail L1
helm template chart/ >/dev/null || fail L1
helm template chart/ --set observability.enabled=true --set latencyCalculator.enabled=true >/dev/null || fail L1
# Every component toggle: disabled render must drop the component's resources.
for t in writer.enabled:lab-writer dashboard.enabled:lab-dashboard \
         connect.source.enabled:lab-connect-source-pipeline \
         connect.sink.enabled:lab-connect-sink-pipeline \
         rbac.enabled:lab-connect-source-elector \
         latencyCalculator.enabled:lab-latency-calculator; do
  key="${t%%:*}"; res="${t#*:}"
  if helm template chart/ --set "$key=false" | grep -q "name: $res"; then
    echo "[run-all-tests] toggle $key=false still renders $res"
    fail L1
  fi
  if ! helm template chart/ --set "$key=true" | grep -q "name: $res"; then
    echo "[run-all-tests] $key=true does not render $res"
    fail L1
  fi
done
pass L1

echo "[run-all-tests] == L2: error-alerting lab proof =="
if [ "${SKIP_L2:-0}" = "1" ]; then
  skip L2 "SKIP_L2=1"
else
  labs/redis-cdc-error-alerting/scripts/verify-alert.sh || fail L2
  docker compose -f labs/redis-cdc-error-alerting/docker-compose.yml down -v >/dev/null 2>&1
  pass L2
fi

echo "[run-all-tests] == L3: kind e2e (build-images + verify-cdc) =="
if [ "${SKIP_L3:-0}" = "1" ]; then
  skip L3 "SKIP_L3=1"
else
  scripts/build-images.sh --kind --kind-name="$KIND_NAME" || fail L3
  scripts/verify-cdc.sh || fail L3
  pass L3
fi

echo "[run-all-tests] == L4: failover chaos =="
if [ "${RUN_FAILOVER:-0}" = "1" ]; then
  scripts/verify-failover.sh || fail L4
  pass L4
else
  skip L4 "opt-in via RUN_FAILOVER=1"
fi

print_summary
echo "[run-all-tests] PASS"
