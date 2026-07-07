#!/usr/bin/env bash
# Single verification entrypoint for the ladder in rules/05-invariants.md:
#   L0  go test ./...                              (<10 s, always)
#   L1  helm lint + template + toggle renders      (seconds, always)
#   L2  labs/redis-cdc-error-alerting proof        (~7 min; skip: SKIP_L2=1)
#   L3  kind e2e build-images + verify-cdc         (~5 min; skip: SKIP_L3=1)
#   L4  failover chaos                             (~12 min; opt-in: RUN_FAILOVER=1)
# CI runs this with SKIP_L2=1 SKIP_L3=1 (no docker-heavy tiers on PR).
# RUN_PREFIX=1 additionally runs the multi-subject sink-group variants (design D3)
#   in a SEPARATE namespace cdc-mg: verify-cdc-prefix.sh at L3 and (with
#   RUN_FAILOVER=1) verify-failover-prefix.sh at L4. Needs the wildcard subscriber
#   grant (committed) — see scripts/gen-nats-auth.sh / values connect.sinkGroups.
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

# ── Multi-subject sink groups (design D3) ──
# A 3-group set: a catch-all "default" plus two prefix-routed groups.
MG=(--set connect.sinkGroups[0].name=default
    --set connect.sinkGroups[1].name=a --set connect.sinkGroups[1].prefixes[0]=prefix-a
    --set connect.sinkGroups[2].name=b --set connect.sinkGroups[2].prefixes[0]=prefix-b)
helm template chart/ "${MG[@]}" >/dev/null || fail L1
# Each enabled group renders its own sink Deployment, elector, and pipeline CM.
for res in lab-connect-sink lab-connect-sink-a lab-connect-sink-b \
           lab-connect-sink-a-pipeline lab-connect-sink-b-pipeline \
           lab-connect-sink-a-elector lab-connect-sink-b-elector; do
  helm template chart/ "${MG[@]}" | grep -q "name: $res" \
    || { echo "[run-all-tests] multi-group render missing $res"; fail L1; }
done
# Prefix routing turns on the kv_prefix publish subject AND the unrouted counter.
# (kv_prefix appears only under prefix routing — in the publish subject + mapping.)
helm template chart/ "${MG[@]}" | grep 'subject:' | grep -q kv_prefix \
  || { echo "[run-all-tests] prefix-routed publish subject missing"; fail L1; }
helm template chart/ "${MG[@]}" | grep -q 'cdc_forward_unrouted' \
  || { echo "[run-all-tests] cdc_forward_unrouted counter missing under prefix routing"; fail L1; }
# Default (no groups) must NOT emit the prefix subject or the unrouted counter.
if helm template chart/ | grep -q kv_prefix; then
  echo "[run-all-tests] default render leaked prefix routing"; fail L1
fi
if helm template chart/ | grep -q cdc_forward_unrouted; then
  echo "[run-all-tests] default render leaked cdc_forward_unrouted"; fail L1
fi
# INV-3 per-group toggle: disabling group a drops ITS objects, keeps group b,
# and drops cdc_sink_a from the nats-init durable set.
if helm template chart/ "${MG[@]}" --set connect.sinkGroups[1].enabled=false | grep -q 'name: lab-connect-sink-a$'; then
  echo "[run-all-tests] sinkGroups[a].enabled=false still renders connect-sink-a"; fail L1
fi
helm template chart/ "${MG[@]}" --set connect.sinkGroups[1].enabled=false | grep -q 'name: lab-connect-sink-b$' \
  || { echo "[run-all-tests] disabling group a wrongly dropped group b"; fail L1; }
if helm template chart/ "${MG[@]}" --set connect.sinkGroups[1].enabled=false | grep -oE "SINK_GROUPS='[^']*'" | grep -q cdc_sink_a; then
  echo "[run-all-tests] disabled group a still provisions durable cdc_sink_a"; fail L1
fi
# Fail-loud validation (§7): illegal prefix, illegal name, and unimplemented mode
# must each fail the render (exit nonzero).
for bad in 'connect.sinkGroups[1].prefixes[0]=Bad.Prefix' \
           'connect.sinkGroups[1].name=UPPER' \
           'connect.sinkGroups[1].mode=shared'; do
  if helm template chart/ --set connect.sinkGroups[0].name=default \
       --set connect.sinkGroups[1].name=z --set "$bad" >/dev/null 2>&1; then
    echo "[run-all-tests] expected fail-loud render for '$bad' but it succeeded"; fail L1
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
  if [ "${RUN_PREFIX:-0}" = "1" ]; then
    RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-prefix.sh || fail L3
  fi
  pass L3
fi

echo "[run-all-tests] == L4: failover chaos =="
if [ "${RUN_FAILOVER:-0}" = "1" ]; then
  scripts/verify-failover.sh || fail L4
  if [ "${RUN_PREFIX:-0}" = "1" ]; then
    RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-failover-prefix.sh || fail L4
  fi
  pass L4
else
  skip L4 "opt-in via RUN_FAILOVER=1"
fi

print_summary
echo "[run-all-tests] PASS"
