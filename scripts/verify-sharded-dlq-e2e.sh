#!/usr/bin/env bash
# verify-sharded-dlq-e2e.sh — L3 kind e2e for the SHARDED dead-letter queue
# (design docs/design/multi-env-mixed-sink/design.md §5, E2-E4; implementation-plan P5).
# Proves park-then-ack works on the subject-sharding-v2 sink WITHOUT breaking the
# v2 ordering chain (O-6/O-7) or INV-1 write-then-ack.
#
# Topology: one sharded env (connect.envId=<envId>) on family lb:company N=4, split
# shard-a[0,1] / shard-b[2,3,x] + an others catch-all, DLQ ON in in-prefix segment
# mode (normalSegment=aio, deadLetter.segment=dlq) so the DLQ lane is
# kv.cdc.dlq.<envId>.<reason> under the single fixed kv.cdc.> binding.
#
# What it proves, on a FRESH namespace:
#   0. verify-cdc baseline is NOT re-run here (verify-sharding.sh owns the sharded
#      happy-path proof); this script installs the sharded+DLQ topology directly and
#      focuses on the park behaviour.
#   1. Three poison classes injected at SPECIFIC shards each PARK on
#      kv.cdc.dlq.<envId>.<reason> (env token present), PubAck-confirmed:
#        - hash_decode_error at shard s0 (employee ids mod 4 == 0), via the honest
#          forward path (central-Redis XADD op=create type=hash body='["a","b"]');
#        - unknown_op       at shard s1 (ids mod 4 == 1), central-Redis XADD op=frobnicate;
#        - decode_error     at shard s2 (ids mod 4 == 2), DIRECT NATS publish of an
#          enc=gzip:base64 envelope with an UNDECODABLE body — the honest forward always
#          encodes correctly, so a decode_error is not reachable through it (same
#          limitation verify-dlq-e2e.sh notes); publishing straight onto the shard
#          subject kv.cdc.aio.lb.company.s2.create is the faithful way to exercise it.
#   2. Per poisoned shard: num_ack_pending drains to 0, ack_floor advances past the
#      poison, num_redelivered does NOT grow (no head-of-line block, no poison loop).
#   3. A NORMAL create injected on the SAME shard AFTER its poison still reaches region
#      Redis (the shard UNBLOCKED); a normal on an UNTOUCHED shard (s3) applies too and
#      its durable never blocked (other shards unaffected).
#   4. Sink metrics (per group): cdc_unprocessable{shard,reason} +N, cdc_dlq_forwarded
#      {shard,reason} +N, output_sent{label=dlq_out} +N (confirmed parked),
#      output_error{label=dlq_out} +0.
#   5. Header contract on a parked copy: Nats-Msg-Id=dlq.<envId>.<id>, dlq_reason,
#      dlq_env=<envId>, dlq_shard=<K>.
#
# INV-S1 (sharding-off render byte-identity) is a RENDER assertion, proven by the L1
# diff in the P5 evidence, not here.
#
# Conventions (rules/50-lessons.md): capture-then-grep (never `bigcmd | grep -q` under
# pipefail); RRCS_NS/RRCS_RELEASE/RRCS_ENVID overridable; verify-cdc.sh/verify-sharding.sh
# are consumed patterns, never modified.
#
# Usage:
#   scripts/verify-sharded-dlq-e2e.sh
#   RRCS_NS=cdc-sdlq RRCS_RELEASE=cdcsdlq RRCS_ENVID=enva scripts/verify-sharded-dlq-e2e.sh
# Exit 0 iff every assertion is green. On success the namespace is deleted; on failure
# it is LEFT UP for debugging.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-sdlq}"
RELEASE="${RRCS_RELEASE:-cdcsdlq}"
CTX="${RRCS_CONTEXT:-kind-cdc}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
ENVID="${RRCS_ENVID:-enva}"
NPER="${DLQ_NPER:-3}"                 # poison messages per class
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-150}"
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-180}"

STREAM="KV_CDC"
CENTRAL_STREAM="app.events"
GROUP="cdc_propagator"
DUR_BASE="cdc_sink_${ENVID}_lb_company"
DLQ_ROOT="kv.cdc.dlq.${ENVID}"        # segment-mode DLQ root (design §5, E2)
RUNID="$(date +%s)"
PROBE="sdlq-natsbox-${RUNID}"

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
NATS_URL="nats://${PREFIX}nats:4222"
ADMIN_SECRET="${PREFIX}admin-creds"

log()  { echo "[sharded-dlq-e2e] $*"; }
die()  { echo "[sharded-dlq-e2e] FAIL: $*" >&2; NS_LEFT_UP=1; exit 1; }
k()    { kubectl --context "$CTX" -n "$NS" "$@"; }
rc()   { k exec -i "$CENTRAL" -- redis-cli "$@"; }
rr()   { k exec -i "$REGION"  -- redis-cli "$@"; }

# ── preflight ────────────────────────────────────────────────────────────────
[ "$(kubectl config current-context)" = "$CTX" ] || die "current kube context is '$(kubectl config current-context)', expected '$CTX' (set RRCS_CONTEXT)"
command -v jq >/dev/null || die "jq required"

NS_LEFT_UP=0
cleanup() {
  local rc=$?
  kubectl --context "$CTX" -n "$NS" delete pod "$PROBE" --grace-period=0 --force >/dev/null 2>&1 || true
  if (( rc == 0 )); then
    log "SUCCESS — deleting namespace ${NS}"
    kubectl --context "$CTX" delete ns "$NS" --wait=false >/dev/null 2>&1 || true
  else
    log "namespace ${NS} LEFT UP for debugging (kubectl -n ${NS} get pods,jobs)"
  fi
}
trap cleanup EXIT

# ── 0. fresh install: sharded lb:company N=4 + DLQ (segment mode) + envId ─────
if kubectl --context "$CTX" get ns "$NS" >/dev/null 2>&1; then
  log "deleting pre-existing namespace ${NS}"
  kubectl --context "$CTX" delete ns "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
fi
log "=== step 0: install sharded+DLQ (envId=${ENVID}, ns=${NS}) ==="
helm --kube-context "$CTX" upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set "connect.envId=${ENVID}" \
  --set connect.deadLetter.enabled=true \
  --set connect.deadLetter.segment=dlq \
  --set nats.stream.normalSegment=aio \
  --set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}' \
  --set 'connect.sharding.families.lb:company.shards=4' \
  --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company' \
  --set 'connect.sinkGroups[0].shards={0,1}' \
  --set connect.sinkGroups[1].name=shard-b --set 'connect.sinkGroups[1].shardsOf=lb:company' \
  --set 'connect.sinkGroups[1].shards={2,3,x}' \
  --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true \
  --wait --timeout 6m

for d in connect-source connect-sink-shard-a connect-sink-shard-b connect-sink-others; do
  k rollout status "deploy/${PREFIX}${d}" --timeout=180s
done
sleep 5   # let electors win + POST pipelines

# ── nats helpers (throwaway nats-box pod) ────────────────────────────────────
# Two creds mounts: admin for stream/consumer inspection, publisher for the
# direct decode_error injection — the minted admin creds deliberately have NO
# pub grant on kv.cdc.> (permission model), only the publisher creds do.
PUBLISHER_SECRET="${PREFIX}publisher-creds"
log "starting nats-box probe ${PROBE}"
kubectl --context "$CTX" run "$PROBE" -n "$NS" --image=natsio/nats-box:0.14.5 --restart=Never \
  --overrides="{\"spec\":{\"volumes\":[{\"name\":\"c\",\"secret\":{\"secretName\":\"${ADMIN_SECRET}\",\"defaultMode\":292}},{\"name\":\"p\",\"secret\":{\"secretName\":\"${PUBLISHER_SECRET}\",\"defaultMode\":292}}],\"containers\":[{\"name\":\"nb\",\"image\":\"natsio/nats-box:0.14.5\",\"command\":[\"sleep\",\"3600\"],\"volumeMounts\":[{\"name\":\"c\",\"mountPath\":\"/creds\",\"readOnly\":true},{\"name\":\"p\",\"mountPath\":\"/pubcreds\",\"readOnly\":true}]}]}}" \
  >/dev/null 2>&1 || die "could not create nats-box probe pod"
k wait --for=condition=Ready "pod/${PROBE}" --timeout=60s >/dev/null 2>&1 || die "nats-box probe not Ready"
na()  { k exec "$PROBE" -- nats --server "$NATS_URL" --creds /creds/user.creds "$@"; }
napub() { k exec "$PROBE" -- nats --server "$NATS_URL" --creds /pubcreds/user.creds "$@"; }

# ── helpers ──────────────────────────────────────────────────────────────────
consumer_field() { na consumer info "$STREAM" "$1" --json 2>/dev/null | jq -r "$2"; }
lane_count() {  # $1=reason — retained message count on kv.cdc.dlq.<envId>.<reason>
  local subj="${DLQ_ROOT}.$1"
  na stream subjects "$STREAM" "$subj" --json 2>/dev/null \
    | jq -r --arg s "$subj" '.[$s] // 0' 2>/dev/null || echo 0
}
# metric_sum <app-label> <metric-base> [label-substring] — sum across the group's pods
metric_sum() {
  local dep="$1" metric="$2" lf="${3:-}" pod tot=0 v
  for pod in $(k get pods -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v="$(k exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
         | awk -v m="$metric" -v lf="$lf" '$1 ~ "^"m"(_total)?[{ ]" && (lf == "" || index($1, lf) > 0) {s+=$2} END{printf "%.0f", s+0}')" || v=0
    tot=$(( tot + ${v:-0} ))
  done
  echo "$tot"
}
now_ms() { date +%s%3N; }

rr FLUSHDB >/dev/null
rc XGROUP CREATE "$CENTRAL_STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
TS="$(now_ms)"

# Employee ids chosen so id mod 4 pins the shard: {4,8,12}->s0 {1,5,9}->s1 {6,10,14}->s2 {3,7,11}->s3
ids_for_shard() { # $1=shard-index $2=count -> echo space-separated ids
  local sh="$1" cnt="$2" i out="" id
  for (( i=0; i<cnt; i++ )); do id=$(( sh + i*4 )); [ "$id" -eq 0 ] && id=4; out="$out $id"; done
  echo "$out"
}
S0_IDS="$(ids_for_shard 0 "$NPER")"   # hash_decode_error
S1_IDS="$(ids_for_shard 1 "$NPER")"   # unknown_op
S2_IDS="$(ids_for_shard 2 "$NPER")"   # decode_error (direct publish)

# ── baselines ────────────────────────────────────────────────────────────────
log "=== step 1: baselines (DLQ lanes, poisoned-shard durables, sink metrics) ==="
declare -A BASE_LANE
for r in hash_decode_error unknown_op decode_error; do BASE_LANE[$r]="$(lane_count "$r")"; done
B_S0_ACKFLOOR="$(consumer_field "${DUR_BASE}_s0" '.ack_floor.stream_seq')"
B_S1_ACKFLOOR="$(consumer_field "${DUR_BASE}_s1" '.ack_floor.stream_seq')"
B_S2_ACKFLOOR="$(consumer_field "${DUR_BASE}_s2" '.ack_floor.stream_seq')"
B_S0_REDELIV="$(consumer_field "${DUR_BASE}_s0" '.num_redelivered')"
B_S1_REDELIV="$(consumer_field "${DUR_BASE}_s1" '.num_redelivered')"
B_S2_REDELIV="$(consumer_field "${DUR_BASE}_s2" '.num_redelivered')"
BA_UNPROC="$(metric_sum connect-sink-shard-a cdc_unprocessable)"
BA_FWD="$(metric_sum connect-sink-shard-a cdc_dlq_forwarded)"
BA_SENT="$(metric_sum connect-sink-shard-a output_sent 'label="dlq_out"')"
BB_SENT="$(metric_sum connect-sink-shard-b output_sent 'label="dlq_out"')"
BA_ERR="$(metric_sum connect-sink-shard-a output_error 'label="dlq_out"')"
BB_ERR="$(metric_sum connect-sink-shard-b output_error 'label="dlq_out"')"
log "baseline lanes: hash=${BASE_LANE[hash_decode_error]} unknown=${BASE_LANE[unknown_op]} decode=${BASE_LANE[decode_error]}"

# ── 2. inject poison at specific shards ──────────────────────────────────────
log "=== step 2: inject ${NPER}/class poison (s0=hash, s1=unknown, s2=decode) + normals ==="
# hash_decode_error @ s0 — honest forward path (parseable JSON array, not an object)
cmds="$(mktemp)"
for id in $S0_IDS; do
  echo "XADD $CENTRAL_STREAM * event_id sdlq-${RUNID}-h${id} op create type hash kv_key lb:company:active:{employees:${id}}:h${RUNID} ts ${TS} body [\"a\",\"b\"]"
done > "$cmds"
# unknown_op @ s1 — honest forward path (op the sink does not know)
for id in $S1_IDS; do
  echo "XADD $CENTRAL_STREAM * event_id sdlq-${RUNID}-u${id} op frobnicate type string kv_key lb:company:active:{employees:${id}}:u${RUNID} ts ${TS} body zzz"
done >> "$cmds"
# NOTE poison body ["a","b"] contains quotes — feed via redis-cli stdin is fine here
# because each XADD line is parsed by redis-cli's inline lexer which keeps the quotes
# as part of the token when unbalanced-safe; if a future edit hits "Invalid argument(s)"
# switch these two loops to per-XADD argv mode like verify-dlq-e2e.sh does.
k exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"

# decode_error @ s2 — DIRECT publish onto the shard subject (forward can't emit it).
# enc=gzip:base64 with an undecodable body => the sink's decode .catch(null) fires.
for id in $S2_IDS; do
  payload="$(jq -cn --arg k "lb:company:active:{employees:${id}}:d${RUNID}" --arg e "sdlq-${RUNID}-d${id}" --arg ts "$TS" \
    '{op:"create",type:"hash",kv_key:$k,enc:"gzip:base64",body:"!!!not-base64!!!",ts:($ts|tonumber),event_id:$e}')"
  napub pub "kv.cdc.aio.lb.company.s2.create" "$payload" -H "Nats-Msg-Id:$id-src-${RUNID}" >/dev/null 2>&1 \
    || die "direct decode_error publish to s2 failed"
done

# normals AFTER poison: same-shard unblock (s0) + untouched-shard (s3) applies
NORMAL_S0="lb:company:active:{employees:4}:n0-${RUNID}"     # s0, after the s0 poison
NORMAL_S3="lb:company:active:{employees:3}:n3-${RUNID}"     # s3, never poisoned
for spec in "n0 4 $NORMAL_S0" "n3 3 $NORMAL_S3"; do
  set -- $spec
  k exec -i "$CENTRAL" -- redis-cli XADD "$CENTRAL_STREAM" '*' \
    event_id "sdlq-${RUNID}-$1" op create type string kv_key "$3" ts "$TS" body "ok-$1-${RUNID}" >/dev/null
done
log "injected ${NPER} hash@s0, ${NPER} unknown@s1, ${NPER} decode@s2 + normals @s0,@s3"

# ── 3. settle ────────────────────────────────────────────────────────────────
log "=== step 3: settle (poll up to ${POLL_TIMEOUT_S}s) ==="
deadline=$(( $(date +%s) + POLL_TIMEOUT_S ))
n0_present=0 n3_present=0
while (( $(date +%s) < deadline )); do
  h="$(lane_count hash_decode_error)"; u="$(lane_count unknown_op)"; dd="$(lane_count decode_error)"
  n0_present="$(rr EXISTS "$NORMAL_S0" 2>/dev/null | tr -dc '0-9')"; n0_present="${n0_present:-0}"
  n3_present="$(rr EXISTS "$NORMAL_S3" 2>/dev/null | tr -dc '0-9')"; n3_present="${n3_present:-0}"
  ap0="$(consumer_field "${DUR_BASE}_s0" '.num_ack_pending')"; ap0="${ap0:-9}"
  ap1="$(consumer_field "${DUR_BASE}_s1" '.num_ack_pending')"; ap1="${ap1:-9}"
  ap2="$(consumer_field "${DUR_BASE}_s2" '.num_ack_pending')"; ap2="${ap2:-9}"
  if (( h >= BASE_LANE[hash_decode_error]+NPER && u >= BASE_LANE[unknown_op]+NPER && dd >= BASE_LANE[decode_error]+NPER \
        && n0_present == 1 && n3_present == 1 && ap0 == 0 && ap1 == 0 && ap2 == 0 )); then
    break
  fi
  sleep 3
done
sleep 2

# ── 4. final reads ───────────────────────────────────────────────────────────
declare -A FIN_LANE
for r in hash_decode_error unknown_op decode_error; do FIN_LANE[$r]="$(lane_count "$r")"; done
F_S0_ACKFLOOR="$(consumer_field "${DUR_BASE}_s0" '.ack_floor.stream_seq')"
F_S1_ACKFLOOR="$(consumer_field "${DUR_BASE}_s1" '.ack_floor.stream_seq')"
F_S2_ACKFLOOR="$(consumer_field "${DUR_BASE}_s2" '.ack_floor.stream_seq')"
F_S0_REDELIV="$(consumer_field "${DUR_BASE}_s0" '.num_redelivered')"
F_S1_REDELIV="$(consumer_field "${DUR_BASE}_s1" '.num_redelivered')"
F_S2_REDELIV="$(consumer_field "${DUR_BASE}_s2" '.num_redelivered')"
FA_UNPROC="$(metric_sum connect-sink-shard-a cdc_unprocessable)"
FA_FWD="$(metric_sum connect-sink-shard-a cdc_dlq_forwarded)"
FA_SENT="$(metric_sum connect-sink-shard-a output_sent 'label="dlq_out"')"
FB_SENT="$(metric_sum connect-sink-shard-b output_sent 'label="dlq_out"')"
FA_ERR="$(metric_sum connect-sink-shard-a output_error 'label="dlq_out"')"
FB_ERR="$(metric_sum connect-sink-shard-b output_error 'label="dlq_out"')"
# every shard durable at rest must satisfy O-6 (num_ack_pending<=1)
NAP_MAX=0
for tok in s0 s1 s2 s3 sx; do
  nap="$(consumer_field "${DUR_BASE}_${tok}" '.num_ack_pending')"; nap="${nap:-9}"
  (( nap > NAP_MAX )) && NAP_MAX="$nap"
done

# ── 5. header contract on a parked hash_decode_error copy ─────────────────────
log "=== step 5: parked-message header contract (${DLQ_ROOT}.hash_decode_error) ==="
HDR_RAW="$(na stream get "$STREAM" -S "${DLQ_ROOT}.hash_decode_error" 2>&1 || true)"
echo "$HDR_RAW"
hdr_ok=1
for hh in "Nats-Msg-Id: dlq.${ENVID}." "dlq_reason: hash_decode_error" "dlq_env: ${ENVID}" "dlq_shard: s0"; do
  echo "$HDR_RAW" | grep -qi "$hh" || { log "WARN header missing/mismatch: '$hh'"; hdr_ok=0; }
done

# ── 6. verdict ───────────────────────────────────────────────────────────────
D_LANE_H=$(( FIN_LANE[hash_decode_error] - BASE_LANE[hash_decode_error] ))
D_LANE_U=$(( FIN_LANE[unknown_op]        - BASE_LANE[unknown_op] ))
D_LANE_D=$(( FIN_LANE[decode_error]      - BASE_LANE[decode_error] ))
D_A_UNPROC=$(( FA_UNPROC - BA_UNPROC ))
D_A_FWD=$(( FA_FWD - BA_FWD ))
D_SENT=$(( (FA_SENT - BA_SENT) + (FB_SENT - BB_SENT) ))
D_ERR=$(( (FA_ERR - BA_ERR) + (FB_ERR - BB_ERR) ))
D_S0_RE=$(( F_S0_REDELIV - B_S0_REDELIV )); D_S1_RE=$(( F_S1_REDELIV - B_S1_REDELIV )); D_S2_RE=$(( F_S2_REDELIV - B_S2_REDELIV ))
D_S0_AF=$(( F_S0_ACKFLOOR - B_S0_ACKFLOOR )); D_S1_AF=$(( F_S1_ACKFLOOR - B_S1_ACKFLOOR )); D_S2_AF=$(( F_S2_ACKFLOOR - B_S2_ACKFLOOR ))

PASS=true; REASONS=""
add_fail() { PASS=false; REASONS="${REASONS}${REASONS:+; }$1"; }
(( D_LANE_H == NPER )) || add_fail "hash lane delta ${D_LANE_H} != ${NPER}"
(( D_LANE_U == NPER )) || add_fail "unknown lane delta ${D_LANE_U} != ${NPER}"
(( D_LANE_D == NPER )) || add_fail "decode lane delta ${D_LANE_D} != ${NPER}"
(( D_A_UNPROC >= 2*NPER )) || add_fail "shard-a cdc_unprocessable delta ${D_A_UNPROC} < ${NPER} hash + ${NPER} unknown"
(( D_A_FWD >= 2*NPER )) || add_fail "shard-a cdc_dlq_forwarded delta ${D_A_FWD} < 2*${NPER}"
(( D_SENT == 3*NPER )) || add_fail "output_sent{dlq_out} delta ${D_SENT} != 3*${NPER} (not all PubAck-confirmed)"
(( D_ERR == 0 )) || add_fail "output_error{dlq_out} delta ${D_ERR} != 0 (DLQ publish errors)"
(( D_S0_RE == 0 && D_S1_RE == 0 && D_S2_RE == 0 )) || add_fail "poison redelivery loop (s0=${D_S0_RE} s1=${D_S1_RE} s2=${D_S2_RE})"
(( D_S0_AF >= NPER && D_S1_AF >= NPER && D_S2_AF >= NPER )) || add_fail "poisoned-shard ack_floor did not advance (s0=${D_S0_AF} s1=${D_S1_AF} s2=${D_S2_AF})"
(( n0_present == 1 )) || add_fail "normal on poisoned shard s0 absent (shard blocked)"
(( n3_present == 1 )) || add_fail "normal on untouched shard s3 absent"
(( NAP_MAX <= 1 )) || add_fail "num_ack_pending ${NAP_MAX} > 1 on a shard durable (O-6 violated)"
(( hdr_ok == 1 )) || add_fail "parked header contract mismatch (env/shard/msg-id)"

RESULT="$(printf '{"runid":"%s","ns":"%s","envId":"%s","nper":%d,"lane_delta":{"hash":%d,"unknown":%d,"decode":%d},"shardA_unproc_delta":%d,"shardA_fwd_delta":%d,"output_sent_dlq_out_delta":%d,"output_error_dlq_out_delta":%d,"poison_redeliver":{"s0":%d,"s1":%d,"s2":%d},"ack_floor_delta":{"s0":%d,"s1":%d,"s2":%d},"normal_s0":%d,"normal_s3":%d,"num_ack_pending_max":%d,"header_ok":%d,"pass":%s}' \
  "$RUNID" "$NS" "$ENVID" "$NPER" "$D_LANE_H" "$D_LANE_U" "$D_LANE_D" "$D_A_UNPROC" "$D_A_FWD" "$D_SENT" "$D_ERR" \
  "$D_S0_RE" "$D_S1_RE" "$D_S2_RE" "$D_S0_AF" "$D_S1_AF" "$D_S2_AF" "$n0_present" "$n3_present" "$NAP_MAX" "$hdr_ok" "$PASS")"
echo "RESULT_JSON:${RESULT}"

if [ "$PASS" = "true" ]; then
  log "PASS — 3 poison classes parked on kv.cdc.dlq.${ENVID}.<reason> (env token), PubAck-confirmed (output_sent{dlq_out} +${D_SENT}, error 0), poisoned shards unblocked (ack_floor advanced, redeliver +0, ack_pending->0), normals on s0/s3 applied, O-6 held (num_ack_pending<=1), headers OK"
  exit 0
fi
echo "[sharded-dlq-e2e] FAIL — ${REASONS}" >&2
NS_LEFT_UP=1
exit 1
