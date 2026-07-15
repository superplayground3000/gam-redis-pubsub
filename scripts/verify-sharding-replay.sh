#!/usr/bin/env bash
# verify-sharding-replay.sh — T-7 fault injection for subject-sharding v2
# (docs/design/subject-sharding/design.md §13). SIGKILLs the FORWARD leader
# mid-burst so its read-but-unpublished Redis PEL strands, then the standby
# takes the Lease, replays the PEL from id 0 (stable consumerClientId), and
# continues. Asserts the ordering chain survives the replay:
#   - O-4/O-5: per-key apply order at region stays monotone across the crash
#     (PEL replay is a contiguous tail under serialized publish; replayed
#     duplicates are absorbed by Nats-Msg-Id dedup or idempotent re-apply);
#   - no loss: every distinct-key create emitted around the kill reaches region;
#   - finals == last emitted sequence for the same-key update lane.
# NOTE the deliberate contrast with verify-failover.sh: here max_in_flight is
# HARD-CODED to 1 by sharding (no values override needed to serialize).
# Each run starts PRISTINE. ~8 min.
# Usage: RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding-replay.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-shard}"
RELEASE="${RRCS_RELEASE:-cdcsh}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NSEQ="${NSEQ:-400}"             # same-key updates per lane
NKEYS="${NKEYS:-60}"            # distinct-key creates (loss check)
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-240}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"
GROUP="cdc_propagator"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
now_ms() { date +%s%3N; }
log() { echo "[shard-replay] $*"; }
die() { echo "[shard-replay] FAIL: $*" >&2; exit 1; }
cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }

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

rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
runid="$(now_ms)"; ts="$(now_ms)"
EMP=5
KA="lb:company:active:{employees:${EMP}}:rp${runid}"
KS="lb:company:standby:{employees:${EMP}}:rp${runid}"

POLL_OUT="$(mktemp)"
kubectl -n "$NS" exec "$REGION" -- sh -c \
  "i=0; while [ \$i -lt 30000 ]; do redis-cli MGET '$KA' '$KS' | tr '\n' '|'; echo; i=\$((i+1)); done" \
  > "$POLL_OUT" 2>/dev/null &
POLL_PID=$!

# burst: same-key update lanes + distinct-key creates, all through the
# serialized forward — the reader (limit 50) pulls into its PEL faster than
# the max_in_flight=1 publisher drains, so a SIGKILL strands a real PEL.
log "bursting $((NSEQ*2)) same-key updates + $NKEYS distinct creates, then SIGKILL forward leader"
cmds="$(mktemp)"
for (( i=1; i<=NSEQ; i++ )); do
  echo "XADD $STREAM * event_id ${runid}-ra-${i} op update type string kv_key ${KA} ts ${ts} body ${i}"
  echo "XADD $STREAM * event_id ${runid}-rs-${i} op update type string kv_key ${KS} ts ${ts} body ${i}"
done > "$cmds"
for (( i=1; i<=NKEYS; i++ )); do
  echo "XADD $STREAM * event_id ${runid}-rk-${i} op create type string kv_key lb:company:active:{employees:${i}}:rk${runid} ts ${ts} body k${i}" >> "$cmds"
done
kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"

LEADER="$(kubectl -n "$NS" get lease "${PREFIX}connect-source-elector" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
[ -n "$LEADER" ] || die "cannot determine forward leader from Lease"
kubectl -n "$NS" delete pod "$LEADER" --grace-period=0 --force >/dev/null
log "SIGKILLed forward leader $LEADER mid-drain (PEL stranded); waiting for takeover + replay"

deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  fa="$(rr GET "$KA" | tr -d '\r')"; fsv="$(rr GET "$KS" | tr -d '\r')"
  kc="$(cnt "*:rk${runid}")"
  [ "$fa" = "$NSEQ" ] && [ "$fsv" = "$NSEQ" ] && (( kc == NKEYS )) && break
  sleep 3
done
kill "$POLL_PID" >/dev/null 2>&1 || true; wait "$POLL_PID" 2>/dev/null || true
[ "$fa" = "$NSEQ" ]  || die "final active $fa != $NSEQ after replay"
[ "$fsv" = "$NSEQ" ] || die "final standby $fsv != $NSEQ after replay"
(( kc == NKEYS ))    || die "loss across forward crash: $kc/$NKEYS distinct keys reached region"

viol="$(awk -F'|' '
  { for (c = 1; c <= 2; c++) {
      v = $c
      if (v == "") continue
      if (v + 0 < last[c]) { print "col" c ": " last[c] " -> " v; bad = 1 }
      last[c] = v + 0
    } }
  END { exit bad }' "$POLL_OUT" 2>&1)" \
  || die "ORDER VIOLATION across forward crash/replay: $viol"
SAMPLES=$(grep -c . "$POLL_OUT" || true); rm -f "$POLL_OUT"
NEW_LEADER="$(kubectl -n "$NS" get lease "${PREFIX}connect-source-elector" -o jsonpath='{.spec.holderIdentity}')"
log "replay OK: $SAMPLES samples monotone, finals $fa/$fsv, $kc/$NKEYS keys, leader $LEADER -> $NEW_LEADER"

echo "RESULT_JSON:{\"samples\":$SAMPLES,\"finals\":\"$fa/$fsv\",\"distinct_keys\":$kc,\"leader_moved\":\"$LEADER->$NEW_LEADER\"}"
echo "[shard-replay] PASS — forward crash + PEL replay preserved per-key order and lost nothing"
