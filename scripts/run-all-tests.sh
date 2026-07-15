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
# RUN_SHARDING=1 additionally runs the subject-sharding v2 variants in namespace
#   cdc-shard: verify-sharding.sh (T-4 ordering + T-9 consumer asserts) at L3 and
#   (with RUN_FAILOVER=1) verify-sharding-failover.sh + verify-sharding-replay.sh
#   at L4. measure-shard-throughput.sh (T-8, tc netem) and
#   sharding-cutover-drill.sh (T-10) stay manual-only.
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

# ── Subject-sharding v2 (docs/design/subject-sharding/design.md) ──
# T-1 (sharding ON assertions; sharding OFF byte-identity is implied by the
# leak checks below — every sharding artifact is grepped absent from the
# default render). Family lb:company, N=4, two shard groups + catchAll.
SH_VALUES=$(mktemp); trap 'rm -f "$SH_VALUES"' EXIT
cat > "$SH_VALUES" <<'EOF'
connect:
  sharding:
    keyPattern: '\{employees:(?P<id>[0-9]+)\}'
    families:
      "lb:company":
        shards: 4
  sinkGroups:
    - { name: shard-a, shardsOf: "lb:company", shards: [0, 1] }
    - { name: shard-b, shardsOf: "lb:company", shards: [2, 3, "x"] }
    - { name: others,  catchAll: true }
EOF
SH_OUT=$(helm template chart/ -f "$SH_VALUES") || fail L1
# INV-O1: forward serialization — threads:1, max_in_flight:1, NO fallback/reject.
FWD=$(awk '/name: .*connect-source-pipeline$/{f=1} f' <<<"$SH_OUT")
grep -q 'threads: 1' <<<"$FWD" || { echo "[run-all-tests] sharded forward missing threads: 1 (O-3)"; fail L1; }
grep -q 'max_in_flight: 1' <<<"$FWD" || { echo "[run-all-tests] sharded forward missing max_in_flight: 1 (O-4)"; fail L1; }
if grep -qE 'fallback:|reject:' <<<"$FWD"; then
  echo "[run-all-tests] sharded forward still renders a fallback/reject path (O-4 broken)"; fail L1
fi
# Sink broker variant: copies:1 + threads:1 hard-coded, one durable per shard.
grep -q 'copies: 1' <<<"$SH_OUT" || { echo "[run-all-tests] sharded sink missing broker copies: 1"; fail L1; }
for d in s0 s1 s2 s3 sx; do
  grep -q "durable: \"cdc_sink_lb_company_${d}\"" <<<"$SH_OUT" \
    || { echo "[run-all-tests] sharded sink missing durable cdc_sink_lb_company_${d}"; fail L1; }
done
# nats-init: every shard durable record carries max_ack_pending=1 (O-6).
for d in s0 s1 s2 s3 sx; do
  grep -oE "SINK_GROUPS='[^']*'" <<<"$SH_OUT" | grep -q "cdc_sink_lb_company_${d}|kv.cdc.lb.company.${d}.>|1|" \
    || { echo "[run-all-tests] nats-init record for ${d} missing hard-coded maxpending=1"; fail L1; }
done
# wait-consumer gates ALL shard durables of each group.
grep -q 'for d in cdc_sink_lb_company_s0 cdc_sink_lb_company_s1;' <<<"$SH_OUT" \
  || { echo "[run-all-tests] wait-consumer does not gate all shard durables"; fail L1; }
# T-5 / INV-S8: kv_key must never be a metric label (metric label blocks only —
# kv_key legitimately appears in mappings/log fields).
if grep -A5 -e '- metric:' <<<"$SH_OUT" | grep -q 'kv_key:'; then
  echo "[run-all-tests] a metric block labels by kv_key (unbounded cardinality)"; fail L1
fi
# Default render must stay clean of ALL sharding machinery (T-1 byte-identity proxy).
if grep -qE 'shard_map|kv_shard_reason|cdc_forward_cross_shard_rename|reverse-sharded|copies: 1' <<<"$DEFAULT_OUT"; then
  echo "[run-all-tests] default render leaked sharding machinery"; fail L1
fi
# T-3 fail-loud matrix: each bad config must fail the render.
SH_BASE=(--set 'connect.sharding.families.lb:company.shards=4'
         --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company'
         --set 'connect.sinkGroups[0].shards={0,1,2,3,x}')
for badsh in \
  "--set connect.sinkGroups[0].shards={0,1,2,x}" \
  "--set connect.sinkGroups[0].shards={0,1,2,3,3,x}" \
  "--set connect.sinkGroups[0].shards={0,1,2,3}" \
  "--set connect.sinkGroups[0].shards={0,1,2,3,7,x}" \
  "--set connect.sinkGroups[1].name=p --set connect.sinkGroups[1].prefixes[0]=lb:company" \
  "--set connect.sinkGroups[1].name=p --set connect.sinkGroups[1].prefixes[0]=lb" \
  "--set connect.sinkGroups[0].consumer.maxAckPending=1024" \
  "--set connect.sinkGroups[0].catchAll=true" \
  "--set connect.source.maxInFlight=256" \
  "--set connect.sharding.keyPattern=nocapture" \
  "--set connect.sinkGroups[0].shardsOf=nope"; do
  # shellcheck disable=SC2086
  if helm template chart/ "${SH_BASE[@]}" $badsh >/dev/null 2>&1; then
    echo "[run-all-tests] expected fail-loud sharding render for '$badsh' but it succeeded"; fail L1
  fi
done
pass L1

echo "[run-all-tests] == L2: error-alerting lab proof =="
if [ "${SKIP_L2:-0}" = "1" ]; then
  skip L2 "SKIP_L2=1"
else
  scripts/test-forward-routing.sh || fail L2
  scripts/test-shard-mapping.sh || fail L2
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
  if [ "${RUN_SHARDING:-0}" = "1" ]; then
    RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding.sh || fail L3
  fi
  pass L3
fi

echo "[run-all-tests] == L4: failover chaos =="
if [ "${RUN_FAILOVER:-0}" = "1" ]; then
  scripts/verify-failover.sh || fail L4
  if [ "${RUN_PREFIX:-0}" = "1" ]; then
    RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-failover-prefix.sh || fail L4
  fi
  if [ "${RUN_SHARDING:-0}" = "1" ]; then
    RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding-failover.sh || fail L4
    RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding-replay.sh || fail L4
    RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding-partition.sh || fail L4
  fi
  pass L4
else
  skip L4 "opt-in via RUN_FAILOVER=1"
fi

print_summary
echo "[run-all-tests] PASS"
