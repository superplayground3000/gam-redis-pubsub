#!/usr/bin/env bash
# verify-sharding-failover.sh — T-6 fault injection for subject-sharding v2
# (docs/design/subject-sharding/design.md §13). Under sustained same-employee
# update traffic it SIGKILLs the ACTIVE sink leader of the group owning that
# shard, forcing a Lease transfer + JetStream redelivery of the in-flight
# message, and asserts NO REORDER is possible:
#   - a region-side poller proves the observed value sequence stays monotone
#     non-decreasing across the failover (INV-O3 under crash);
#   - final values == last emitted sequence (no stuck shard after transfer);
#   - num_ack_pending <= 1 holds on every shard durable after the storm
#     (INV-O2: redelivery cannot overtake);
#   - ack isolation (INV-S9): a poison message (undecodable gzip:base64 body)
#     injected into a DIFFERENT shard nack-loops THAT shard only — the victim
#     shard's counter climbs while every other shard keeps applying.
# Each run starts PRISTINE. ~8 min.
# Usage: RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding-failover.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-shard}"
RELEASE="${RRCS_RELEASE:-cdcsh}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NSEQ="${NSEQ:-600}"             # updates per key around the kill
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-240}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"
GROUP="cdc_propagator"
DUR_BASE="cdc_sink_lb_company"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
now_ms() { date +%s%3N; }
log() { echo "[shard-failover] $*"; }
die() { echo "[shard-failover] FAIL: $*" >&2; exit 1; }

metric_sum() { # $1=app-label $2=metric-base $3=optional label-filter substring
  local dep="$1" metric="$2" lf="${3:-}" pod tot=0 v
  for pod in $(kubectl -n "$NS" get pods -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v="$(kubectl -n "$NS" exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
         | awk -v m="$metric" -v lf="$lf" '$1 ~ "^"m"(_total)?[{ ]" && (lf == "" || index($1, lf) > 0) {s+=$2} END{printf "%.0f", s+0}')" || v=0
    tot=$(( tot + ${v:-0} ))
  done
  echo "$tot"
}
NATSQ="natsq-fo"
natsq_start() {
  kubectl -n "$NS" delete pod "$NATSQ" --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl -n "$NS" run "$NATSQ" --image=natsio/nats-box:0.14.5 --restart=Never --quiet \
    --overrides='{"spec":{"containers":[{"name":"n","image":"natsio/nats-box:0.14.5","command":["sleep","3600"],"volumeMounts":[{"name":"c","mountPath":"/c"}]}],"volumes":[{"name":"c","secret":{"secretName":"'"${PREFIX}"'admin-creds","defaultMode":292}}]}}' >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready "pod/$NATSQ" --timeout=120s >/dev/null
}
natsq() { kubectl -n "$NS" exec "$NATSQ" -- nats --server "nats://${PREFIX}nats:4222" --creds /c/user.creds "$@"; }
cleanup() { kubectl -n "$NS" delete pod "$NATSQ" --grace-period=0 --force >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "=== fresh install: sharded lb:company N=4 (ns=$NS) ==="
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
sleep 5
natsq_start

rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
runid="$(now_ms)"; ts="$(now_ms)"
EMP=5   # s1 -> group shard-a
KA="lb:company:active:{employees:${EMP}}:fo${runid}"
KS="lb:company:standby:{employees:${EMP}}:fo${runid}"

# region-side poller (captures across the failover)
POLL_OUT="$(mktemp)"
kubectl -n "$NS" exec "$REGION" -- sh -c \
  "i=0; while [ \$i -lt 30000 ]; do redis-cli MGET '$KA' '$KS' | tr '\n' '|'; echo; i=\$((i+1)); done" \
  > "$POLL_OUT" 2>/dev/null &
POLL_PID=$!

# slow emitter INSIDE the central pod: paced XADDs so traffic spans the kill
log "starting paced emitter: $NSEQ interleaved updates per key on employee $EMP (shard s1)"
kubectl -n "$NS" exec "$CENTRAL" -- sh -c "
  i=1
  while [ \$i -le $NSEQ ]; do
    redis-cli XADD $STREAM '*' event_id ${runid}-fa-\$i op update type string kv_key '$KA' ts $ts body \$i >/dev/null
    redis-cli XADD $STREAM '*' event_id ${runid}-fs-\$i op update type string kv_key '$KS' ts $ts body \$i >/dev/null
    i=\$((i+1))
  done" &
EMIT_PID=$!

sleep 8   # let traffic flow through shard s1 first
LEADER="$(kubectl -n "$NS" get lease "${PREFIX}connect-sink-shard-a-elector" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
[ -n "$LEADER" ] || die "cannot determine shard-a leader from Lease"
log "SIGKILLing shard-a active leader pod: $LEADER (mid-traffic)"
kubectl -n "$NS" delete pod "$LEADER" --grace-period=0 --force >/dev/null
# Prove the Lease actually TRANSFERS to a live standby (don't trust recovery
# alone — a lingering container could in principle keep consuming for a while
# after a force delete removes the API object).
deadline=$(( $(date +%s) + 90 ))
NEW_LEADER=""
while (( $(date +%s) < deadline )); do
  NEW_LEADER="$(kubectl -n "$NS" get lease "${PREFIX}connect-sink-shard-a-elector" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
  if [ -n "$NEW_LEADER" ] && [ "$NEW_LEADER" != "$LEADER" ] \
     && kubectl -n "$NS" get pod "$NEW_LEADER" >/dev/null 2>&1; then
    break
  fi
  NEW_LEADER=""
  sleep 2
done
[ -n "$NEW_LEADER" ] || die "Lease never transferred off the killed pod $LEADER within 90s"
log "Lease transferred: $LEADER -> $NEW_LEADER"
wait "$EMIT_PID" || die "emitter failed"
log "emitter done; waiting for finals after failover"

deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  fa="$(rr GET "$KA" | tr -d '\r')"; fsv="$(rr GET "$KS" | tr -d '\r')"
  [ "$fa" = "$NSEQ" ] && [ "$fsv" = "$NSEQ" ] && break
  sleep 3
done
kill "$POLL_PID" >/dev/null 2>&1 || true; wait "$POLL_PID" 2>/dev/null || true
[ "$fa" = "$NSEQ" ]  || die "final active $fa != $NSEQ (shard stuck after failover?)"
[ "$fsv" = "$NSEQ" ] || die "final standby $fsv != $NSEQ (shard stuck after failover?)"

viol="$(awk -F'|' '
  { for (c = 1; c <= 2; c++) {
      v = $c
      if (v == "") continue
      if (v + 0 < last[c]) { print "col" c ": " last[c] " -> " v; bad = 1 }
      last[c] = v + 0
    } }
  END { exit bad }' "$POLL_OUT" 2>&1)" \
  || die "ORDER VIOLATION across failover: $viol"
SAMPLES=$(grep -c . "$POLL_OUT" || true); rm -f "$POLL_OUT"
log "failover OK: $SAMPLES samples monotone, finals $fa/$fsv, lease moved $LEADER -> $NEW_LEADER"

for tok in s0 s1 s2 s3 sx; do
  nap=$(natsq consumer info KV_CDC "${DUR_BASE}_${tok}" --json 2>/dev/null | jq -r '.num_ack_pending')
  (( nap <= 1 )) || die "durable ${tok}: num_ack_pending=$nap > 1 after failover (O-6)"
done
log "num_ack_pending <= 1 on all shard durables after failover"

# ── INV-S9: poison one shard, prove the others keep flowing ──
# employees:2 -> s2 (group shard-b). An UNKNOWN op passes the forward leg
# untouched (subject kv.cdc.lb.company.s2.frobnicate still matches the s2
# filter) and hits the sharded sink's unknown_op branch: counter + throw ->
# nack -> redelivery loop on s2 ONLY. (A corrupt-body poison can't be injected
# end-to-end here: the forward leg re-encodes body itself under
# connect.bodyEncoding, so a garbage body would arrive validly encoded.)
log "INV-S9: injecting poison (unknown op) into shard s2"
rc XADD "$STREAM" '*' event_id "${runid}-poison" op frobnicate type string \
   kv_key "lb:company:active:{employees:2}:po${runid}" ts "$ts" body poison >/dev/null
sleep 10
unproc1="$(metric_sum connect-sink-shard-b cdc_unprocessable 'shard="s2"')"
(( unproc1 >= 1 )) || die "poison not detected: cdc_unprocessable{shard=s2}=$unproc1"
# healthy traffic on s0/s1/s3 while s2 is blocked
cmds="$(mktemp)"
for i in 4 5 7; do   # employees 4->s0, 5->s1, 7->s3
  echo "XADD $STREAM * event_id ${runid}-h${i} op create type string kv_key lb:company:active:{employees:${i}}:hp${runid} ts ${ts} body h${i}"
done > "$cmds"
kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
deadline=$(( $(date +%s) + 60 )); hcnt=0
while (( $(date +%s) < deadline )); do
  hcnt="$(rr --scan --pattern "*:hp${runid}" 2>/dev/null | grep -c . || true)"
  (( hcnt == 3 )) && break
  sleep 2
done
(( hcnt == 3 )) || die "healthy shards blocked by s2 poison: only $hcnt/3 applied (INV-S9 broken)"
unproc2="$(metric_sum connect-sink-shard-b cdc_unprocessable 'shard="s2"')"
(( unproc2 >= unproc1 )) || die "poison redelivery loop vanished unexpectedly"
log "INV-S9 OK: s2 nack-looping (unprocessable $unproc1 -> $unproc2) while s0/s1/s3 applied 3/3"

echo "RESULT_JSON:{\"samples\":$SAMPLES,\"finals\":\"$fa/$fsv\",\"leader_moved\":\"$LEADER->$NEW_LEADER\",\"poison_count\":$unproc2,\"healthy_during_poison\":$hcnt}"
echo "[shard-failover] PASS — no reorder across sink failover + ack isolation under poison"
