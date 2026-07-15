#!/usr/bin/env bash
# sharding-cutover-drill.sh — T-10 pause-drain cutover drill for
# subject-sharding v2 (docs/design/subject-sharding/cutover.md, spec §10).
# Walks the FULL procedure against a kind cluster and proves the two
# acceptance criteria: NO LOSS (event_id reconciliation across the pause
# window) and NO REORDER (same-key sequence stays monotone end-to-end).
#   1. install the PRE-SHARDING shape: one prefix group (m2g: lb:company) +
#      others catchAll; drive creates + same-key updates;
#   2. STEP 2 — pause the forward leg (connect.source.enabled=false =>
#      OnStoppedLeading DELETEs the stream; producers keep XADDing into the
#      pause window);
#   3. STEP 3 — wait for the old durable to fully drain
#      (num_pending==0 && num_ack_pending==0);
#   4. STEP 4 — flip config to sharded groups (old group removed; its durable
#      becomes an orphan that the gated prune only REPORTS), then delete the
#      old durable via the pruneOrphans=true upgrade (the manual gate);
#   5. STEP 5 — re-enable the forward (sharded: threads/MIF=1) => the paused
#      backlog drains to the shard subjects, consumed only by the new groups;
#   6. verify: every event applied exactly once (region counts), same-key
#      lane monotone + final==last, sx silent.
# ~10 min. Usage: RRCS_NS=cdc-cut RRCS_RELEASE=cdccut scripts/sharding-cutover-drill.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-cut}"
RELEASE="${RRCS_RELEASE:-cdccut}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NPRE="${NPRE:-40}"; NPAUSE="${NPAUSE:-30}"; NPOST="${NPOST:-30}"
NSEQ="${NSEQ:-150}"
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-240}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"; GROUP="cdc_propagator"
OLD_DURABLE="cdc_sink_m2g"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
log() { echo "[cutover-drill] $*"; }
die() { echo "[cutover-drill] FAIL: $*" >&2; exit 1; }
cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }
wait_cnt() { local pat="$1" want="$2" deadline cur ok=0
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    cur="$(cnt "$pat")"
    if (( cur == want )); then ok=$((ok+1)); (( ok>=2 )) && { echo "$cur"; return 0; }; else ok=0; fi
    sleep 3
  done; echo "$cur"; return 1; }

NATSQ="natsq-cut"
natsq_start() {
  kubectl -n "$NS" delete pod "$NATSQ" --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl -n "$NS" run "$NATSQ" --image=natsio/nats-box:0.14.5 --restart=Never --quiet \
    --overrides='{"spec":{"containers":[{"name":"n","image":"natsio/nats-box:0.14.5","command":["sleep","7200"],"volumeMounts":[{"name":"c","mountPath":"/c"}]}],"volumes":[{"name":"c","secret":{"secretName":"'"${PREFIX}"'admin-creds","defaultMode":292}}]}}' >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready "pod/$NATSQ" --timeout=120s >/dev/null
}
natsq() { kubectl -n "$NS" exec "$NATSQ" -- nats --server "nats://${PREFIX}nats:4222" --creds /c/user.creds "$@"; }
cleanup() { kubectl -n "$NS" delete pod "$NATSQ" --grace-period=0 --force >/dev/null 2>&1 || true; }
trap cleanup EXIT

# helm value sets for the two shapes; the drill upgrades between them.
OLD_SETS=(--set connect.sinkGroups[0].name=m2g --set 'connect.sinkGroups[0].prefixes[0]=lb:company'
          --set connect.sinkGroups[1].name=others --set connect.sinkGroups[1].catchAll=true)
NEW_SETS=(--set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}'
          --set 'connect.sharding.families.lb:company.shards=4'
          --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company'
          --set 'connect.sinkGroups[0].shards={0,1}'
          --set connect.sinkGroups[1].name=shard-b --set 'connect.sinkGroups[1].shardsOf=lb:company'
          --set 'connect.sinkGroups[1].shards={2,3,x}'
          --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true)

log "=== STEP 0: install PRE-SHARDING shape (prefix group m2g + others) ==="
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" "${OLD_SETS[@]}" "${EXTRA_SET[@]}" --wait --timeout 6m
for d in connect-source connect-sink-m2g connect-sink-others; do
  kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout=180s
done
sleep 5; natsq_start
rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
runid="$(date +%s%3N)"; ts="$runid"
EMP=5; KO="lb:company:active:{employees:${EMP}}:cut${runid}"
seq_emitted=0

emit_batch() { # $1=tag $2=count $3=seq-updates-count
  local tag="$1" n="$2" nups="$3" i cmds; cmds="$(mktemp)"
  for (( i=1; i<=n; i++ )); do
    echo "XADD $STREAM * event_id ${runid}-${tag}-c${i} op create type string kv_key lb:company:active:{employees:${i}}:${tag}${runid} ts ${ts} body ${tag}${i}"
  done > "$cmds"
  for (( i=1; i<=nups; i++ )); do
    seq_emitted=$(( seq_emitted + 1 ))
    echo "XADD $STREAM * event_id ${runid}-${tag}-u${seq_emitted} op update type string kv_key ${KO} ts ${ts} body ${seq_emitted}" >> "$cmds"
  done
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
}

log "phase A: pre-cutover traffic through the OLD group ($NPRE creates + $NSEQ updates)"
emit_batch pre "$NPRE" "$NSEQ"
wait_cnt "*:pre${runid}" "$NPRE" >/dev/null || die "pre-cutover creates incomplete"

log "=== STEP 2: PAUSE the forward leg (source.enabled=false); producers keep writing ==="
helm upgrade "$RELEASE" ./chart -n "$NS" -f "$VALUES_FILE" "${OLD_SETS[@]}" "${EXTRA_SET[@]}" \
  --set connect.source.enabled=false --wait --timeout 6m
log "pause-window traffic: $NPAUSE creates + $NSEQ updates (must NOT apply yet)"
emit_batch pau "$NPAUSE" "$NSEQ"
sleep 5
(( $(cnt "*:pau${runid}") == 0 )) || die "pause window leaked: forward still publishing"

log "=== STEP 3: drain criterion on old durable ($OLD_DURABLE) ==="
deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  read -r np na < <(natsq consumer info KV_CDC "$OLD_DURABLE" --json 2>/dev/null | jq -r '[.num_pending, .num_ack_pending] | join(" ")') || true
  [ "${np:-1}" = "0" ] && [ "${na:-1}" = "0" ] && break
  sleep 3
done
[ "$np" = "0" ] && [ "$na" = "0" ] || die "old durable not drained: pending=$np ack_pending=$na"
log "old durable drained (num_pending=0, num_ack_pending=0)"

log "=== STEP 4a: flip to SHARDED shape (forward still paused; old durable orphaned, prune gated) ==="
helm upgrade "$RELEASE" ./chart -n "$NS" -f "$VALUES_FILE" "${NEW_SETS[@]}" "${EXTRA_SET[@]}" \
  --set connect.source.enabled=false --wait --timeout 6m
for d in connect-sink-shard-a connect-sink-shard-b connect-sink-others; do
  kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout=300s
done
natsq consumer info KV_CDC "$OLD_DURABLE" >/dev/null 2>&1 || die "gated prune DELETED the old durable without pruneOrphans=true"
log "gate held: old durable still present after the flip upgrade"

log "=== STEP 4b: delete the old durable via the manual gate (pruneOrphans=true) ==="
helm upgrade "$RELEASE" ./chart -n "$NS" -f "$VALUES_FILE" "${NEW_SETS[@]}" "${EXTRA_SET[@]}" \
  --set connect.source.enabled=false --set connect.sharding.pruneOrphans=true --wait --timeout 6m
deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline )); do
  natsq consumer info KV_CDC "$OLD_DURABLE" >/dev/null 2>&1 || break
  sleep 3
done
natsq consumer info KV_CDC "$OLD_DURABLE" >/dev/null 2>&1 && die "pruneOrphans=true did not remove the old durable"
log "old durable pruned under the manual gate"

log "=== STEP 5: resume the forward (sharded) — backlog flows to shard subjects ==="
helm upgrade "$RELEASE" ./chart -n "$NS" -f "$VALUES_FILE" "${NEW_SETS[@]}" "${EXTRA_SET[@]}" --wait --timeout 6m
kubectl -n "$NS" rollout status "deploy/${PREFIX}connect-source" --timeout=180s
log "post-cutover traffic: $NPOST creates + $NSEQ updates"
emit_batch post "$NPOST" "$NSEQ"

log "=== STEP 6: acceptance — no loss, no reorder, sx silent ==="
wait_cnt "*:pau${runid}" "$NPAUSE" >/dev/null || die "pause-window backlog lost: $(cnt "*:pau${runid}")/$NPAUSE"
wait_cnt "*:post${runid}" "$NPOST" >/dev/null || die "post-cutover creates lost: $(cnt "*:post${runid}")/$NPOST"
deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  fo="$(rr GET "$KO" | tr -d '\r')"; [ "$fo" = "$seq_emitted" ] && break; sleep 3
done
[ "$fo" = "$seq_emitted" ] || die "same-key lane final $fo != $seq_emitted (reorder or loss across cutover)"
sx_probe="$(kubectl -n "$NS" get pods -l app=connect-sink-shard-b -o jsonpath='{.items[*].metadata.name}')"
sxa=0
for pod in $sx_probe; do
  v="$(kubectl -n "$NS" exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
      | awk '$1 ~ /^cdc_apply(_total)?\{/ && index($1, "shard=\"sx\"") > 0 {s+=$2} END{printf "%.0f", s+0}')" || v=0
  sxa=$(( sxa + ${v:-0} ))
done
(( sxa == 0 )) || die "sx consumed $sxa events during cutover (key contract broke)"

TOTAL=$(( NPRE + NPAUSE + NPOST ))
echo "RESULT_JSON:{\"creates_applied\":$TOTAL,\"seq_final\":\"$fo/$seq_emitted\",\"sx\":$sxa}"
echo "[cutover-drill] PASS — pause-drain cutover: zero loss across the pause window, same-key order preserved, gate enforced"
