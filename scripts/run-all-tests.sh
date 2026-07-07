#!/usr/bin/env bash
# Single verification entrypoint for the ladder in rules/05-invariants.md:
#   L0  go test ./...                              (<10 s, always)
#   L1  helm lint + template + toggle renders      (seconds, always)
#   L2  routing harness + error-alerting lab proof (~8 min; skip: SKIP_L2=1)
#   L3  kind e2e build-images + verify-cdc         (~5 min; skip: SKIP_L3=1)
#   L4  failover chaos                             (~12 min; opt-in: RUN_FAILOVER=1)
# CI runs this with SKIP_L2=1 SKIP_L3=1 (no docker-heavy tiers on PR).
# RUN_PREFIX=1 additionally runs the multi-subject sink-group variants (design D3)
#   in a SEPARATE namespace cdc-mg: verify-cdc-prefix.sh + verify-cdc-twoseg.sh at
#   L3 and (with RUN_FAILOVER=1) verify-failover-prefix.sh at L4. Needs the wildcard subscriber
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
# Every render below is captured once and grepped as a variable. Never pipe a
# live `helm template` into `grep -q` here: under pipefail, grep -q exits at
# the first match, helm takes SIGPIPE (exit 141) once the render outgrows the
# pipe buffer, and the check flakes FAIL on a good render — or, negated,
# silently masks a real failure (bit CI on 2026-07-07, rules/50-lessons.md).
helm lint chart/ || fail L1
DEFAULT_OUT=$(helm template chart/) || fail L1
helm template chart/ --set observability.enabled=true --set latencyCalculator.enabled=true >/dev/null || fail L1
# Every component toggle: disabled render must drop the component's resources.
for t in writer.enabled:lab-writer dashboard.enabled:lab-dashboard \
         connect.source.enabled:lab-connect-source-pipeline \
         connect.sink.enabled:lab-connect-sink-pipeline \
         rbac.enabled:lab-connect-source-elector \
         latencyCalculator.enabled:lab-latency-calculator; do
  key="${t%%:*}"; res="${t#*:}"
  OFF_OUT=$(helm template chart/ --set "$key=false") || fail L1
  if grep -q "name: $res" <<<"$OFF_OUT"; then
    echo "[run-all-tests] toggle $key=false still renders $res"
    fail L1
  fi
  ON_OUT=$(helm template chart/ --set "$key=true") || fail L1
  if ! grep -q "name: $res" <<<"$ON_OUT"; then
    echo "[run-all-tests] $key=true does not render $res"
    fail L1
  fi
done

# ── Multi-subject sink groups (design D3) ──
# A 3-group set: two prefix-routed groups plus a catch-all "others" group.
MG=(--set connect.sinkGroups[0].name=a --set connect.sinkGroups[0].prefixes[0]=prefix-a
    --set connect.sinkGroups[1].name=b --set connect.sinkGroups[1].prefixes[0]=prefix-b
    --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true)
MG_OUT=$(helm template chart/ "${MG[@]}") || fail L1
# Each enabled group renders its own sink Deployment, elector, and pipeline CM.
for res in lab-connect-sink-others lab-connect-sink-a lab-connect-sink-b \
           lab-connect-sink-a-pipeline lab-connect-sink-b-pipeline \
           lab-connect-sink-a-elector lab-connect-sink-b-elector; do
  grep -q "name: $res" <<<"$MG_OUT" \
    || { echo "[run-all-tests] multi-group render missing $res"; fail L1; }
done
# Prefix routing turns on the kv_prefix publish subject AND the unrouted counter.
# (kv_prefix appears only under prefix routing — in the publish subject + mapping.)
grep 'subject:' <<<"$MG_OUT" | grep kv_prefix >/dev/null \
  || { echo "[run-all-tests] prefix-routed publish subject missing"; fail L1; }
grep -q 'cdc_forward_unrouted' <<<"$MG_OUT" \
  || { echo "[run-all-tests] cdc_forward_unrouted counter missing under prefix routing"; fail L1; }
# Default (no groups) must NOT emit the prefix subject or the unrouted counter.
if grep -q kv_prefix <<<"$DEFAULT_OUT"; then
  echo "[run-all-tests] default render leaked prefix routing"; fail L1
fi
if grep -q cdc_forward_unrouted <<<"$DEFAULT_OUT"; then
  echo "[run-all-tests] default render leaked cdc_forward_unrouted"; fail L1
fi
# INV-3 per-group toggle: disabling group b drops ITS objects, keeps group a,
# and drops cdc_sink_b from the nats-init durable set.
MGOFF_OUT=$(helm template chart/ "${MG[@]}" --set connect.sinkGroups[1].enabled=false) || fail L1
if grep -q 'name: lab-connect-sink-b$' <<<"$MGOFF_OUT"; then
  echo "[run-all-tests] sinkGroups[b].enabled=false still renders connect-sink-b"; fail L1
fi
grep -q 'name: lab-connect-sink-a$' <<<"$MGOFF_OUT" \
  || { echo "[run-all-tests] disabling group b wrongly dropped group a"; fail L1; }
if grep -oE "SINK_GROUPS='[^']*'" <<<"$MGOFF_OUT" | grep cdc_sink_b >/dev/null; then
  echo "[run-all-tests] disabled group b still provisions durable cdc_sink_b"; fail L1
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

# whole-stream implicit group + prefixed group => double delivery, must fail-loud
if helm template chart/ --set connect.sinkGroups[0].name=default \
     --set connect.sinkGroups[1].name=a --set connect.sinkGroups[1].prefixes[0]=prefix-a >/dev/null 2>&1; then
  echo "[run-all-tests] whole-stream default + prefixed group should fail-loud (double delivery)"; fail L1
fi

# ── First-two-segment routing + others catch-all ──
TSG=(--set connect.sinkGroups[0].name=caveat --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat'
     --set connect.sinkGroups[1].name=g2m    --set 'connect.sinkGroups[1].prefixes[0]=tg:g2m'
     --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true)
TSG_OUT=$(helm template chart/ "${TSG[@]}") || fail L1
for want in 'kv.cdc.tg.caveat.>' 'kv.cdc.tg.g2m.>' 'kv.cdc.others.>' \
            '"tg:caveat":"tg.caveat"' 'name: lab-connect-sink-others' 'name: cdc_forward_others'; do
  grep -qF "$want" <<<"$TSG_OUT" \
    || { echo "[run-all-tests] two-seg render missing $want"; fail L1; }
done
grep -oE "SINK_GROUPS='[^']*'" <<<"$TSG_OUT" | grep 'cdc_sink_others' >/dev/null \
  || { echo "[run-all-tests] others durable missing from nats-init"; fail L1; }
# default render must stay clean of ALL two-seg machinery
if grep -qE 'cdc_forward_others|let routes' <<<"$DEFAULT_OUT"; then
  echo "[run-all-tests] default render leaked two-seg routing"; fail L1
fi
# no-catchAll render: a set-miss must count as unrouted, not others (match the
# metric block, not the explanatory comment that also names the counter)
MG2=(--set connect.sinkGroups[0].name=caveat --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat')
MG2_OUT=$(helm template chart/ "${MG2[@]}") || fail L1
if grep -q 'name: cdc_forward_others' <<<"$MG2_OUT"; then
  echo "[run-all-tests] cdc_forward_others rendered WITHOUT a catchAll group"; fail L1
fi
# fail-loud grammar/structure set (§ two-seg): each render must exit nonzero
for badset in \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=a:b:c" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=Tg:caveat" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=others" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=others:x" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=unknown" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=tg:caveat" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=tg" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].catchAll=true --set connect.sinkGroups[1].prefixes[0]=q" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].catchAll=true --set connect.sinkGroups[2].name=z2 --set connect.sinkGroups[2].catchAll=true"; do
  # shellcheck disable=SC2086
  if helm template chart/ "${MG2[@]}" $badset >/dev/null 2>&1; then
    echo "[run-all-tests] expected fail-loud render for '$badset' but it succeeded"; fail L1
  fi
done
if helm template chart/ --set connect.sinkGroups[0].name=others --set connect.sinkGroups[0].catchAll=true >/dev/null 2>&1; then
  echo "[run-all-tests] catchAll without any prefixed group should fail-loud"; fail L1
fi
pass L1

echo "[run-all-tests] == L2: error-alerting lab proof =="
if [ "${SKIP_L2:-0}" = "1" ]; then
  skip L2 "SKIP_L2=1"
else
  scripts/test-forward-routing.sh || fail L2
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
    RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-twoseg.sh || fail L3
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
