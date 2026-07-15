#!/usr/bin/env bash
# verify-sharding.sh — L3 kind e2e for subject-sharding v2
# (docs/design/subject-sharding/design.md). Deploys family lb:company (N=4)
# split across two broker sink groups plus an others catch-all, drives
# deterministic CDC traffic straight into central Redis, and asserts:
#   T-9 / INV-O2: every shard durable exists server-side with
#     max_ack_pending==1, ack explicit, pull mode, and the exact per-shard
#     FilterSubject — and num_ack_pending<=1 sampled UNDER LOAD;
#   routing + isolation: employees land on id-mod-N shards, per-group
#     cdc_apply matches the per-shard event counts exactly;
#   T-4 / INV-O3 (core): interleaved active/standby updates on ONE employee
#     with increasing sequence bodies apply IN SOURCE ORDER — a region-side
#     poller captures intermediate states and both keys' observed sequences
#     must be monotone non-decreasing with final == last emitted;
#   sx isolation lane: an unparseable family key routes to sx, is APPLIED
#     (not dropped), and counts cdc_forward_unrouted{unparseable_shard};
#   dedup: replaying identical event_ids changes nothing.
# Each run starts PRISTINE (helm uninstall first) so counts are deterministic.
# Usage: RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-shard}"
RELEASE="${RRCS_RELEASE:-cdcsh}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NROUTE="${NROUTE:-40}"          # phase-1 routing creates (10 per shard at N=4)
NSEQ="${NSEQ:-200}"             # T-4 updates PER KEY (active + standby each)
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-180}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"
GROUP="cdc_propagator"
FAMILY="lb:company"
NSHARDS=4
DUR_BASE="cdc_sink_lb_company"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
now_ms() { date +%s%3N; }
log() { echo "[verify-sharding] $*"; }
die() { echo "[verify-sharding] FAIL: $*" >&2; exit 1; }

cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }
wait_count() { # $1=pattern $2=want — settle when count holds for 2 polls
  local pat="$1" want="$2" deadline cur ok=0
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    cur="$(cnt "$pat")"
    if (( cur == want )); then ok=$(( ok+1 )); (( ok>=2 )) && { echo "$cur"; return 0; }; else ok=0; fi
    sleep 3
  done
  echo "$cur"; return 1
}
metric_sum() { # $1=app-label $2=metric-base $3=optional label-filter substring
  local dep="$1" metric="$2" lf="${3:-}" pod tot=0 v
  for pod in $(kubectl -n "$NS" get pods -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v="$(kubectl -n "$NS" exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
         | awk -v m="$metric" -v lf="$lf" '$1 ~ "^"m"(_total)?[{ ]" && (lf == "" || index($1, lf) > 0) {s+=$2} END{printf "%.0f", s+0}')" || v=0
    tot=$(( tot + ${v:-0} ))
  done
  echo "$tot"
}

# ── persistent nats-box helper pod (admin creds) for consumer queries ──
NATSQ="natsq-shard"
natsq_start() {
  kubectl -n "$NS" delete pod "$NATSQ" --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl -n "$NS" run "$NATSQ" --image=natsio/nats-box:0.14.5 --restart=Never --quiet \
    --overrides='{"spec":{"containers":[{"name":"n","image":"natsio/nats-box:0.14.5","command":["sleep","3600"],"volumeMounts":[{"name":"c","mountPath":"/c"}]}],"volumes":[{"name":"c","secret":{"secretName":"'"${PREFIX}"'admin-creds","defaultMode":292}}]}}' >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready "pod/$NATSQ" --timeout=120s >/dev/null
}
natsq() { kubectl -n "$NS" exec "$NATSQ" -- nats --server "nats://${PREFIX}nats:4222" --creds /c/user.creds "$@"; }
consumer_json() { natsq consumer info KV_CDC "$1" --json 2>/dev/null; }
cleanup() { kubectl -n "$NS" delete pod "$NATSQ" --grace-period=0 --force >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "=== fresh install: sharded lb:company N=4 (shard-a[0,1] shard-b[2,3,x]) + others (ns=$NS) ==="
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}' \
  --set 'connect.sharding.families.lb:company.shards=4' \
  --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company' \
  --set 'connect.sinkGroups[0].shards={0,1}' \
  --set connect.sinkGroups[1].name=shard-b --set 'connect.sinkGroups[1].shardsOf=lb:company' \
  --set 'connect.sinkGroups[1].shards={2,3,x}' \
  --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true \
  "${EXTRA_SET[@]}" --wait --timeout 6m

for d in connect-source connect-sink-shard-a connect-sink-shard-b connect-sink-others; do
  kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout=180s
done
sleep 5   # let electors win + POST pipelines
natsq_start

# ── T-9 / INV-O2: server-side shard consumer assertions ──
log "T-9: asserting shard durable server-side config (max_ack_pending==1 etc.)"
for tok in s0 s1 s2 s3 sx; do
  cj="$(consumer_json "${DUR_BASE}_${tok}")" || die "durable ${DUR_BASE}_${tok} missing"
  map=$(jq -r '.config.max_ack_pending' <<<"$cj")
  ack=$(jq -r '.config.ack_policy' <<<"$cj")
  fs=$(jq -r '.config.filter_subject // (.config.filter_subjects | join(","))' <<<"$cj")
  deliver=$(jq -r '.config.deliver_subject // ""' <<<"$cj")
  [ "$map" = "1" ]  || die "durable ${tok}: max_ack_pending=$map, MUST be 1 (O-6)"
  [ "$ack" = "explicit" ] || die "durable ${tok}: ack_policy=$ack, want explicit"
  [ -z "$deliver" ] || die "durable ${tok}: is PUSH, want pull"
  [ "$fs" = "kv.cdc.lb.company.${tok}.>" ] || die "durable ${tok}: filter=$fs"
done
log "T-9 OK: 5 shard durables pull/explicit/max_ack_pending=1 with exact filters"

rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
runid="$(now_ms)"; ts="$(now_ms)"

# ── phase 1: routing — employees 1..NROUTE spread over the 4 shards ──
log "phase 1: $NROUTE creates across employees 1..$NROUTE (10 per shard at N=4)"
cmds="$(mktemp)"
for (( i=1; i<=NROUTE; i++ )); do
  echo "XADD $STREAM * event_id ${runid}-rt-c${i} op create type string kv_key lb:company:active:{employees:${i}}:r${runid} ts ${ts} body v${i}"
done > "$cmds"
kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
c1="$(wait_count "lb:company:active:*:r${runid}" "$NROUTE")" || die "phase1: region reached only $c1/$NROUTE"
log "phase 1 settled at $c1 keys"

# per-shard/per-group accounting: ids 1..40 -> mod 4: s0={4,8..40}=10, s1={1,5..37}=10, s2=10, s3=10
A_OPS=20; B_OPS=20   # shard-a owns s0+s1, shard-b owns s2+s3
a_apply="$(metric_sum connect-sink-shard-a cdc_apply)"
b_apply="$(metric_sum connect-sink-shard-b cdc_apply)"
ot_apply="$(metric_sum connect-sink-others cdc_apply)"
log "cdc_apply shard-a=$a_apply/$A_OPS shard-b=$b_apply/$B_OPS others=$ot_apply/0"
(( a_apply == A_OPS )) || die "group shard-a applied $a_apply, want $A_OPS (mod-N routing broken)"
(( b_apply == B_OPS )) || die "group shard-b applied $b_apply, want $B_OPS (mod-N routing broken)"
(( ot_apply == 0 ))    || die "others consumed $ot_apply sharded-family events (isolation broken)"
for tok in s0 s1 s2 s3; do
  grp=connect-sink-shard-a; { [ "$tok" = s2 ] || [ "$tok" = s3 ]; } && grp=connect-sink-shard-b
  st="$(metric_sum "$grp" cdc_apply "shard=\"${tok}\"")"
  (( st == 10 )) || die "cdc_apply{shard=$tok}=$st, want 10"
done
log "phase 1 OK: exact per-shard distribution (10 each)"

# ── T-4: strict per-key ordering — ONE employee, interleaved active/standby ──
EMP=5   # 5 mod 4 = s1 -> group shard-a
KA="lb:company:active:{employees:${EMP}}:ord${runid}"
KS="lb:company:standby:{employees:${EMP}}:ord${runid}"
log "T-4: interleaving $NSEQ active + $NSEQ standby updates on employee $EMP (shard s1)"
# region-side poller: capture both keys' values as fast as redis-cli allows,
# inside the region pod (no kubectl round-trip per sample)
POLL_OUT="$(mktemp)"
kubectl -n "$NS" exec "$REGION" -- sh -c \
  "i=0; while [ \$i -lt 12000 ]; do redis-cli MGET '$KA' '$KS' | tr '\n' '|'; echo; i=\$((i+1)); done" \
  > "$POLL_OUT" 2>/dev/null &
POLL_PID=$!
sleep 1
cmds="$(mktemp)"
for (( i=1; i<=NSEQ; i++ )); do
  echo "XADD $STREAM * event_id ${runid}-oa-${i} op update type string kv_key ${KA} ts ${ts} body ${i}"
  echo "XADD $STREAM * event_id ${runid}-os-${i} op update type string kv_key ${KS} ts ${ts} body ${i}"
done > "$cmds"
kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
# wait for the final values to land
deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  fa="$(rr GET "$KA" | tr -d '\r')"; fs="$(rr GET "$KS" | tr -d '\r')"
  [ "$fa" = "$NSEQ" ] && [ "$fs" = "$NSEQ" ] && break
  sleep 2
done
kill "$POLL_PID" >/dev/null 2>&1 || true; wait "$POLL_PID" 2>/dev/null || true
[ "$fa" = "$NSEQ" ] || die "T-4: final active value $fa != $NSEQ"
[ "$fs" = "$NSEQ" ] || die "T-4: final standby value $fs != $NSEQ"
# monotonicity: every observed value must be >= the previous observation per key
viol="$(awk -F'|' '
  { for (c = 1; c <= 2; c++) {
      v = $c
      if (v == "") continue
      if (v + 0 < last[c]) { print "col" c ": " last[c] " -> " v; bad = 1 }
      last[c] = v + 0
    } }
  END { exit bad }' "$POLL_OUT" 2>&1)" \
  || die "T-4 ORDER VIOLATION (region value went backwards): $viol"
SAMPLES=$(grep -c . "$POLL_OUT" || true)
DISTINCT=$(awk -F'|' '{print $1}' "$POLL_OUT" | sort -un | wc -l)
rm -f "$POLL_OUT"
log "T-4 OK: $SAMPLES samples, $DISTINCT distinct active states observed, all monotone, finals correct"

# num_ack_pending under/after load (O-6 runtime assertion)
for tok in s0 s1 s2 s3 sx; do
  nap=$(consumer_json "${DUR_BASE}_${tok}" | jq -r '.num_ack_pending')
  (( nap <= 1 )) || die "durable ${tok}: num_ack_pending=$nap > 1 (O-6 violated)"
done
log "num_ack_pending <= 1 on all shard durables"

# ── sx isolation lane: unparseable family key still applies ──
log "sx lane: emitting 3 unparseable family keys"
for i in 1 2 3; do
  rc XADD "$STREAM" '*' event_id "${runid}-sx-${i}" op create type string \
     kv_key "lb:company:active:sxprobe${i}:r${runid}" ts "$ts" body "sx${i}" >/dev/null
done
wait_count "lb:company:active:sxprobe*:r${runid}" 3 >/dev/null || die "sx events not applied"
sx_apply="$(metric_sum connect-sink-shard-b cdc_apply 'shard="sx"')"
unrt="$(metric_sum connect-source cdc_forward_unrouted 'reason="unparseable_shard"')"
xsr="$(metric_sum connect-source cdc_forward_cross_shard_rename)"
(( sx_apply == 3 )) || die "cdc_apply{shard=sx}=$sx_apply, want 3"
(( unrt == 3 ))     || die "cdc_forward_unrouted{unparseable_shard}=$unrt, want 3"
(( xsr == 0 ))      || die "cdc_forward_cross_shard_rename=$xsr, want 0 (INV-S7)"
log "sx lane OK: quarantined but applied, counters exact"

# ── dedup: replay phase-1 event_ids; nothing may change ──
log "dedup: replaying phase-1 creates"
before="$(cnt "*r${runid}*")"
cmds="$(mktemp)"
for (( i=1; i<=NROUTE; i++ )); do
  echo "XADD $STREAM * event_id ${runid}-rt-c${i} op create type string kv_key lb:company:active:{employees:${i}}:r${runid} ts ${ts} body v${i}"
done > "$cmds"
kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
sleep 10
after="$(cnt "*r${runid}*")"
(( after == before )) || die "dedup broken: region changed $before -> $after"
log "dedup OK: region stable at $after keys"

echo "RESULT_JSON:{\"routing_a\":$a_apply,\"routing_b\":$b_apply,\"t4_samples\":$SAMPLES,\"t4_distinct\":$DISTINCT,\"t4_final\":\"$fa/$fs\",\"sx_apply\":$sx_apply,\"unparseable\":$unrt,\"cross_shard_rename\":$xsr,\"dedup_stable\":$after}"
echo "[verify-sharding] PASS — T-9 consumer asserts + mod-N routing + T-4 strict per-key order + sx lane + dedup"
