#!/usr/bin/env bash
# measure-shard-throughput.sh — T-8 throughput validation for subject-sharding
# v2 (docs/design/subject-sharding/design.md §13). Injects artificial RTT on
# the SINK↔NATS fetch path ONLY, then measures time-to-region for (a) traffic
# pinned to ONE shard and (b) the same volume spread over K=4 shards.
# Expected (design §0): single shard ≈ 1/RTT (Fetch(1) serialized), K children
# ≈ K/RTT; PASS when spread ≥ 2× pinned (conservative floor; theory 4×).
#
# TARGETING (cross-review fix): the delay is a FILTERED netem on the NATS
# pod's node-side veth matching `ip src <active sink pod IP>` — so only the
# sink leader's fetch requests are delayed. Delaying the whole NATS interface
# would slow the forward publish path identically (both runs collapse to the
# forward's 1/RTT ceiling, ratio pegs at ~1x) and delaying the sink pod's own
# veth would slow its serialized region-Redis applies (threads:1 — the apply
# lane, shared by all K children, becomes the 1/RTT bottleneck instead).
# Both alternatives make the K× fetch parallelism invisible.
#
# Prereqs: kind cluster (node container reachable via docker exec), tc + u32
# + sch_netem inside/available to the node (kind nodes are privileged and
# share the host kernel). The qdisc is REMOVED on exit.
# Usage: RTT_MS=50 NMSG=400 RRCS_NS=cdc-shard scripts/measure-shard-throughput.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-shard}"
RELEASE="${RRCS_RELEASE:-cdcsh}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
KIND_NAME="${KIND_NAME:-cdc}"
RTT_MS="${RTT_MS:-50}"          # one-way delay added to sink->NATS packets (ms)
NMSG="${NMSG:-400}"             # messages per measurement
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-600}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"
GROUP="cdc_propagator"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
log() { echo "[shard-tput] $*"; }
die() { echo "[shard-tput] FAIL: $*" >&2; exit 1; }
cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }

log "=== fresh install: sharded lb:company N=4 (ns=$NS) ==="
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}' \
  --set 'connect.sharding.families.lb:company.shards=4' \
  --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company' \
  --set 'connect.sinkGroups[0].shards={0,1,2,3,x}' \
  --set connect.sinkGroups[1].name=others --set connect.sinkGroups[1].catchAll=true \
  "${EXTRA_SET[@]}" --wait --timeout 6m
kubectl -n "$NS" rollout status "deploy/${PREFIX}connect-source" --timeout=180s
kubectl -n "$NS" rollout status "deploy/${PREFIX}connect-sink-shard-a" --timeout=180s
sleep 5

# ── filtered tc netem: delay ONLY sink-leader -> NATS packets ──
NATS_POD="$(kubectl -n "$NS" get pods -l app=nats -o jsonpath='{.items[0].metadata.name}')"
NODE="$(kubectl -n "$NS" get pod "$NATS_POD" -o jsonpath='{.spec.nodeName}')"
# the pod's eth0 peer index on the node side identifies its veth
PEER_IDX="$(kubectl -n "$NS" exec "$NATS_POD" -- cat /sys/class/net/eth0/iflink | tr -d '\r')"
VETH="$(docker exec "$NODE" sh -c "grep -l '^${PEER_IDX}\$' /sys/class/net/veth*/ifindex 2>/dev/null | head -1 | awk -F/ '{print \$5}'")"
[ -n "$VETH" ] || die "cannot resolve NATS pod veth on node $NODE (index $PEER_IDX)"
SINK_LEADER="$(kubectl -n "$NS" get lease "${PREFIX}connect-sink-shard-a-elector" -o jsonpath='{.spec.holderIdentity}')"
SINK_IP="$(kubectl -n "$NS" get pod "$SINK_LEADER" -o jsonpath='{.status.podIP}')"
[ -n "$SINK_IP" ] || die "cannot resolve active sink leader pod IP"
log "delaying ONLY $SINK_LEADER ($SINK_IP) -> NATS by ${RTT_MS}ms on $NODE/$VETH"
docker exec "$NODE" tc qdisc add dev "$VETH" root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 || die "tc prio failed"
docker exec "$NODE" tc qdisc add dev "$VETH" parent 1:4 handle 40: netem delay "${RTT_MS}ms" || die "tc netem failed"
docker exec "$NODE" tc filter add dev "$VETH" protocol ip parent 1: prio 1 u32 match ip src "$SINK_IP/32" flowid 1:4 || die "tc filter failed"
cleanup() { docker exec "$NODE" tc qdisc del dev "$VETH" root 2>/dev/null || true; }
trap cleanup EXIT

rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
runid="$(date +%s%3N)"; ts="$runid"

measure() { # $1=tag $2=key-mapper-fn-name: pinned|spread — prints elapsed seconds
  local tag="$1" mode="$2" i emp cmds t0 t1 got
  rr FLUSHDB >/dev/null
  cmds="$(mktemp)"
  for (( i=1; i<=NMSG; i++ )); do
    if [ "$mode" = pinned ]; then emp=4; else emp=$(( i % 4 )); fi   # 4 mod 4 = s0
    echo "XADD $STREAM * event_id ${runid}-${tag}-${i} op create type string kv_key lb:company:active:{employees:${emp}}:${tag}${runid}k${i} ts ${ts} body v${i}"
  done > "$cmds"
  t0=$(date +%s%3N)
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
  local deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    got="$(cnt "*:${tag}${runid}k*")"
    (( got == NMSG )) && break
    sleep 2
  done
  t1=$(date +%s%3N)
  (( got == NMSG )) || die "$tag: only $got/$NMSG applied within ${SETTLE_TIMEOUT_S}s"
  echo "$(( t1 - t0 ))"
}

log "measure 1/2: $NMSG msgs pinned to ONE shard (employees:4 -> s0)"
MS_PIN="$(measure pin pinned)"
RATE_PIN=$(( NMSG * 1000 / MS_PIN ))
log "pinned: ${MS_PIN}ms -> ${RATE_PIN} msg/s"

log "measure 2/2: $NMSG msgs spread over 4 shards"
MS_SPR="$(measure spr spread)"
RATE_SPR=$(( NMSG * 1000 / MS_SPR ))
log "spread: ${MS_SPR}ms -> ${RATE_SPR} msg/s"

# T-8 criterion: with the delay scoped to the sink fetch path only, spread
# over K=4 shards should approach 4x pinned; assert >= 2x (conservative floor
# absorbing forward-drain overhead and settle-poll granularity).
RATIO_X100=$(( RATE_SPR * 100 / (RATE_PIN > 0 ? RATE_PIN : 1) ))
log "spread/pinned ratio: ${RATIO_X100}% (theory at K=4, sink-fetch-bound: 400%)"
(( RATIO_X100 >= 200 )) || die "K-shard parallelism not visible: spread only ${RATIO_X100}% of pinned (want >=200%)"

echo "RESULT_JSON:{\"rtt_ms\":$RTT_MS,\"nmsg\":$NMSG,\"pinned_ms\":$MS_PIN,\"pinned_rate\":$RATE_PIN,\"spread_ms\":$MS_SPR,\"spread_rate\":$RATE_SPR,\"ratio_pct\":$RATIO_X100}"
echo "[shard-tput] PASS — K-shard fan-out beats single shard by ${RATIO_X100}% under ${RTT_MS}ms injected delay"
