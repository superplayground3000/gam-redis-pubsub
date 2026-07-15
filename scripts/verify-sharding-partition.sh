#!/usr/bin/env bash
# verify-sharding-partition.sh — closes cross-review CRITICAL #1 for
# subject-sharding v2: proves the sharded forward output BLOCKS AND RETRIES IN
# PLACE when the JetStream publish FAILS WHILE THE PROCESS STAYS ALIVE — a
# different failure mode from the pod-kill of verify-sharding-replay.sh. If
# Connect's plain nats_jetstream output ever gave up and nacked after an
# internal retry cap, the redis_streams PEL replay would re-emit the nacked
# (older) event AFTER later events already published → the region value for
# that key would go BACKWARDS after recovery. The monotone assertion below is
# therefore the direct O-4 oracle.
# Mechanism: iptables DROP toward the NATS pod IP inside the kind node for
# PARTITION_S seconds mid-traffic (network partition; connect-source and its
# elector keep running), then restore and assert:
#   - output_error on connect-source INCREASED during the partition (proves
#     real publish failures were exercised — guards against a vacuous pass);
#   - region capture stays monotone per key across partition + recovery;
#   - finals == last emitted sequence; distinct-key creates all present.
# Prereqs: kind (node reachable via docker exec; iptables inside the node).
# ~6 min. Usage: RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding-partition.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-shard}"
RELEASE="${RRCS_RELEASE:-cdcsh}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NSEQ="${NSEQ:-500}"             # paced same-key updates per lane
NKEYS="${NKEYS:-30}"            # distinct-key creates (loss check)
PARTITION_S="${PARTITION_S:-45}"
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-300}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"; GROUP="cdc_propagator"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
log() { echo "[shard-partition] $*"; }
die() { echo "[shard-partition] FAIL: $*" >&2; exit 1; }
cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }
metric_sum() { # $1=app-label $2=metric-base
  local dep="$1" metric="$2" pod tot=0 v
  for pod in $(kubectl -n "$NS" get pods -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v="$(kubectl -n "$NS" exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
         | awk -v m="$metric" '$1 ~ "^"m"(_total)?[{ ]" {s+=$2} END{printf "%.0f", s+0}')" || v=0
    tot=$(( tot + ${v:-0} ))
  done
  echo "$tot"
}

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

NATS_POD="$(kubectl -n "$NS" get pods -l app=nats -o jsonpath='{.items[0].metadata.name}')"
NATS_IP="$(kubectl -n "$NS" get pod "$NATS_POD" -o jsonpath='{.status.podIP}')"
NODE="$(docker ps --format '{{.Names}}' | grep -m1 control-plane)"
[ -n "$NATS_IP" ] && [ -n "$NODE" ] || die "cannot resolve NATS pod IP / kind node"
unblock() { docker exec "$NODE" iptables -D FORWARD -d "$NATS_IP" -j DROP 2>/dev/null || true; }
trap unblock EXIT

rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
runid="$(date +%s%3N)"; ts="$runid"
EMP=5
KA="lb:company:active:{employees:${EMP}}:pt${runid}"
KS="lb:company:standby:{employees:${EMP}}:pt${runid}"

POLL_OUT="$(mktemp)"
kubectl -n "$NS" exec "$REGION" -- sh -c \
  "i=0; while [ \$i -lt 40000 ]; do redis-cli MGET '$KA' '$KS' | tr '\n' '|'; echo; i=\$((i+1)); done" \
  > "$POLL_OUT" 2>/dev/null &
POLL_PID=$!

log "starting paced emitter: $NSEQ interleaved updates per key + $NKEYS creates (spans the partition)"
kubectl -n "$NS" exec "$CENTRAL" -- sh -c "
  i=1
  while [ \$i -le $NSEQ ]; do
    redis-cli XADD $STREAM '*' event_id ${runid}-pa-\$i op update type string kv_key '$KA' ts $ts body \$i >/dev/null
    redis-cli XADD $STREAM '*' event_id ${runid}-ps-\$i op update type string kv_key '$KS' ts $ts body \$i >/dev/null
    if [ \$(( i % $(( NSEQ / NKEYS )) )) -eq 0 ] && [ \$(( i / $(( NSEQ / NKEYS )) )) -le $NKEYS ]; then
      k=\$(( i / $(( NSEQ / NKEYS )) ))
      redis-cli XADD $STREAM '*' event_id ${runid}-pk-\$k op create type string kv_key \"lb:company:active:{employees:\$k}:pk${runid}\" ts $ts body k\$k >/dev/null
    fi
    i=\$((i+1))
  done" &
EMIT_PID=$!

sleep 6
ERR0="$(metric_sum connect-source output_error)"
log "PARTITIONING NATS ($NATS_IP) for ${PARTITION_S}s mid-traffic (iptables DROP on $NODE); output_error baseline=$ERR0"
docker exec "$NODE" iptables -I FORWARD 1 -d "$NATS_IP" -j DROP
sleep "$PARTITION_S"
unblock
log "partition lifted; waiting for emitter + drain"
wait "$EMIT_PID" || die "emitter failed"

ERR1="$(metric_sum connect-source output_error)"
deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  fa="$(rr GET "$KA" | tr -d '\r')"; fsv="$(rr GET "$KS" | tr -d '\r')"
  kc="$(cnt "*:pk${runid}")"
  [ "$fa" = "$NSEQ" ] && [ "$fsv" = "$NSEQ" ] && (( kc == NKEYS )) && break
  sleep 3
done
kill "$POLL_PID" >/dev/null 2>&1 || true; wait "$POLL_PID" 2>/dev/null || true
[ "$fa" = "$NSEQ" ]  || die "final active $fa != $NSEQ after partition recovery"
[ "$fsv" = "$NSEQ" ] || die "final standby $fsv != $NSEQ after partition recovery"
(( kc == NKEYS ))    || die "loss across partition: $kc/$NKEYS creates reached region"
(( ERR1 > ERR0 ))    || die "VACUOUS: output_error did not increase ($ERR0 -> $ERR1) — the partition never caused a live publish failure; the O-4 blocking claim was not exercised"

viol="$(awk -F'|' '
  { for (c = 1; c <= 2; c++) {
      v = $c
      if (v == "") continue
      if (v + 0 < last[c]) { print "col" c ": " last[c] " -> " v; bad = 1 }
      last[c] = v + 0
    } }
  END { exit bad }' "$POLL_OUT" 2>&1)" \
  || die "ORDER VIOLATION across live publish failure (output nacked instead of blocking — O-4 broken): $viol"
SAMPLES=$(grep -c . "$POLL_OUT" || true); rm -f "$POLL_OUT"
log "partition OK: output_error $ERR0 -> $ERR1 (real failures), $SAMPLES samples monotone, finals $fa/$fsv, $kc/$NKEYS creates"

echo "RESULT_JSON:{\"output_error_delta\":$(( ERR1 - ERR0 )),\"samples\":$SAMPLES,\"finals\":\"$fa/$fsv\",\"creates\":$kc}"
echo "[shard-partition] PASS — live publish failures blocked in place: no nack-reorder, no loss (O-4/D-7)"
