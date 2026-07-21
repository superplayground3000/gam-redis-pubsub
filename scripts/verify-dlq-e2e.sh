#!/usr/bin/env bash
# verify-dlq-e2e.sh — prove the Dead-Letter Queue feature works END-TO-END in
# Kubernetes with connect.deadLetter.enabled=true and the committed (regenerated)
# subscriber creds (design: docs/superpowers/specs/2026-07-13-hash-decode-dlq-design.md).
#
# What it proves, on a FRESH namespace:
#   0. verify-cdc.sh with the DLQ ENABLED still passes (happy path unaffected).
#   1. KV_CDC is bound to BOTH kv.cdc.> and dlq.cdc.> (the enabled render extends subjects).
#   2. N poison hash bodies (op=create type=hash body='["a","b"]' — parseable JSON but not an
#      OBJECT, so the HSET args_mapping would throw un-counted) are:
#        a. PARKED: dlq.cdc.hash_decode_error subject count grows by exactly N (INV-1 no-loss);
#        b. NON-BLOCKING: cdc_sink num_ack_pending drains to 0, ack_floor advances past them,
#           num_redelivered does not grow (no poison loop, no head-of-line block);
#        c. COUNTED & CONFIRMED: on the sink :4195/metrics, cdc_unprocessable{reason} +N,
#           cdc_dlq_forwarded{reason} +N (routed), output_sent{label=dlq_out} +N (PubAck-
#           confirmed parked), output_error{label=dlq_out} +0 (the dashboard's metric pair);
#        d. UNBLOCKED: a NORMAL create injected after the poison still reaches region Redis.
#   3. The parked message carries the header contract: Nats-Msg-Id=dlq.<event_id>, dlq_reason,
#      dlq_error, dlq_orig_subject.
#
# Conventions (rules/50-lessons.md): capture-then-grep (never `bigcmd | grep -q` under
# pipefail); RRCS_NS/RRCS_RELEASE overridable; verify-cdc.sh is consumed, never modified.
#
# Usage:
#   scripts/verify-dlq-e2e.sh
#   RRCS_NS=cdc-dlq RRCS_RELEASE=cdc-dlq scripts/verify-dlq-e2e.sh
# Exit 0 iff every assertion is green. On success the namespace is deleted; on
# failure it is LEFT UP for debugging (the script says which).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-dlq}"
RELEASE="${RRCS_RELEASE:-cdc-dlq}"
CTX="${RRCS_CONTEXT:-kind-cdc}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
N="${DLQ_N:-5}"
REASON="hash_decode_error"
# ── DLQ layout mode ───────────────────────────────────────────────────────────
# Default (RRCS_DLQ_MODE unset or "legacy"): the shipped legacy layout — normal
# traffic on kv.cdc.<op>, DLQ parked OUT of the stream prefix at dlq.cdc.<reason>,
# stream bound to BOTH kv.cdc.> and dlq.cdc.>. This path is byte-for-byte the
# original proof; nothing below its guards changes.
#
# RRCS_DLQ_MODE=segment: the opt-in shared-prefix layout
# (docs/superpowers/plans/2026-07-20-shared-prefix-subject-layout.md). Normal
# traffic moves under kv.cdc.aio.<op>, the DLQ moves IN-prefix to kv.cdc.dlq.<reason>,
# and the stream binding stays the single superset kv.cdc.> (no dlq.cdc.> subject).
# We install with the segment values and flip the two mode-dependent assertions
# (the DLQ subject and the stream-binding check) accordingly.
DLQ_MODE="${RRCS_DLQ_MODE:-legacy}"
case "$DLQ_MODE" in
  legacy)
    DLQ_SUBJECT="dlq.cdc.${REASON}"
    # Extra helm --set for step-0's verify-cdc install (empty = pure default).
    MODE_SET=""
    ;;
  segment)
    DLQ_SUBJECT="kv.cdc.dlq.${REASON}"
    # Space-separated pairs — verify-cdc.sh's RRCS_SET splits on whitespace into
    # one --set each (scripts/verify-cdc.sh:11,16).
    MODE_SET="nats.stream.normalSegment=aio connect.deadLetter.segment=dlq"
    ;;
  *)
    echo "[dlq-e2e] FAIL: unknown RRCS_DLQ_MODE='${DLQ_MODE}' (expected 'legacy' or 'segment')" >&2
    exit 1
    ;;
esac
STREAM="KV_CDC"
DURABLE="cdc_sink"
CENTRAL_STREAM="app.events"
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-120}"
RUNID="$(date +%s)"
PROBE="dlq-natsbox-${RUNID}"

log()  { echo "[dlq-e2e] $*"; }
die()  { echo "[dlq-e2e] FAIL: $*" >&2; NS_LEFT_UP=1; exit 1; }
k()    { kubectl --context "$CTX" -n "$NS" "$@"; }

# ── preflight ────────────────────────────────────────────────────────────────
[ "$(kubectl config current-context)" = "$CTX" ] || die "current kube context is '$(kubectl config current-context)', expected '$CTX' (set RRCS_CONTEXT or switch context — verify-cdc.sh inherits the current context)"
command -v curl >/dev/null || die "curl required on the host for :4195/metrics scraping"
command -v jq   >/dev/null || die "jq required"

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

# ── 0. clean slate + verify-cdc with the DLQ ENABLED (happy path proof) ──────
if kubectl --context "$CTX" get ns "$NS" >/dev/null 2>&1; then
  log "deleting pre-existing namespace ${NS}"
  kubectl --context "$CTX" delete ns "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
fi

log "=== step 0: verify-cdc.sh with connect.deadLetter.enabled=true (mode=${DLQ_MODE}, fresh ns ${NS}) ==="
# RRCS_SET stays exactly "connect.deadLetter.enabled=true" in legacy mode (MODE_SET
# empty); segment mode appends the two segment keys so the install renders the
# in-prefix layout under test.
DLQ_RRCS_SET="connect.deadLetter.enabled=true${MODE_SET:+ $MODE_SET}"
VERIFY_LOG="$(mktemp)"
set +e
RRCS_NS="$NS" RRCS_RELEASE="$RELEASE" RRCS_VALUES="$VALUES_FILE" \
  RRCS_SET="$DLQ_RRCS_SET" \
  scripts/verify-cdc.sh 2>&1 | tee "$VERIFY_LOG"
VC_RC="${PIPESTATUS[0]}"
set -e
VERDICT_LINE="$(grep -E '"verdict"|verdict.pass|\[verify-cdc\] (PASS|FAIL)' "$VERIFY_LOG" | tail -n2 || true)"
[ "$VC_RC" = "0" ] || die "verify-cdc.sh (DLQ enabled) exited $VC_RC — happy path did not pass. Last lines: $VERDICT_LINE"
grep -q '\[verify-cdc\] PASS' "$VERIFY_LOG" || die "verify-cdc.sh did not print PASS"
log "verify-cdc verdict: $(grep '\[verify-cdc\] PASS' "$VERIFY_LOG" | tail -n1)"

RESOURCE_PREFIX="$(helm --kube-context "$CTX" get values "$RELEASE" -n "$NS" -o json | jq -r '.resourcePrefix // "lab-"')"
CENTRAL="deploy/${RESOURCE_PREFIX}redis-central"
REGION="deploy/${RESOURCE_PREFIX}redis-region"
NATS_URL="nats://${RESOURCE_PREFIX}nats:4222"
ADMIN_SECRET="${RESOURCE_PREFIX}admin-creds"
log "resourcePrefix=${RESOURCE_PREFIX} central=${CENTRAL} region=${REGION} nats=${NATS_URL} adminSecret=${ADMIN_SECRET}"

# ── nats admin helper (throwaway nats-box pod with the release's admin creds) ─
log "starting nats-box probe ${PROBE} (admin creds from secret ${ADMIN_SECRET})"
kubectl --context "$CTX" run "$PROBE" -n "$NS" --image=natsio/nats-box:0.14.5 --restart=Never \
  --overrides="{\"spec\":{\"volumes\":[{\"name\":\"c\",\"secret\":{\"secretName\":\"${ADMIN_SECRET}\",\"defaultMode\":292}}],\"containers\":[{\"name\":\"nb\",\"image\":\"natsio/nats-box:0.14.5\",\"command\":[\"sleep\",\"3600\"],\"volumeMounts\":[{\"name\":\"c\",\"mountPath\":\"/creds\",\"readOnly\":true}]}]}}" \
  >/dev/null 2>&1 || die "could not create nats-box probe pod"
k wait --for=condition=Ready "pod/${PROBE}" --timeout=60s >/dev/null 2>&1 || die "nats-box probe not Ready"
na() { k exec "$PROBE" -- nats --server "$NATS_URL" --creds /creds/user.creds "$@"; }

# ── 1. stream binding (mode-dependent) ───────────────────────────────────────
# legacy: KV_CDC bound to BOTH kv.cdc.> and out-of-prefix dlq.cdc.>.
# segment: KV_CDC bound to the single superset kv.cdc.> ONLY (the in-prefix DLQ
#          kv.cdc.dlq.> is already covered by kv.cdc.>, so no dlq.cdc.> is added).
log "=== step 1: KV_CDC subject binding (mode=${DLQ_MODE}) ==="
STREAM_SUBJECTS="$(na stream info "$STREAM" --json 2>/dev/null | jq -r '.config.subjects | join(",")')"
log "KV_CDC subjects: [${STREAM_SUBJECTS}]"
echo "$STREAM_SUBJECTS" | grep -q 'kv.cdc.>'  || die "KV_CDC not bound to kv.cdc.> (got [${STREAM_SUBJECTS}])"
if [ "$DLQ_MODE" = "segment" ]; then
  echo "$STREAM_SUBJECTS" | grep -q 'dlq.cdc.>' \
    && die "segment mode: KV_CDC must NOT add an out-of-prefix dlq.cdc.> subject — the in-prefix DLQ lives under kv.cdc.> (got [${STREAM_SUBJECTS}])"
  # Also assert the sink consumer filter narrowed to the segment (kv.cdc.aio.>),
  # not the bare superset kv.cdc.> (which would re-consume its own dead letters).
  SINK_FILTER="$(na consumer info "$STREAM" "$DURABLE" --json 2>/dev/null | jq -r 'if ((.config.filter_subjects // []) | length) > 0 then (.config.filter_subjects | join(",")) else (.config.filter_subject // "") end')"
  log "segment mode: cdc_sink filter=[${SINK_FILTER}]"
  echo "$SINK_FILTER" | grep -q 'kv.cdc.aio.>' \
    || die "segment mode: cdc_sink filter must be kv.cdc.aio.> (got [${SINK_FILTER}])"
else
  echo "$STREAM_SUBJECTS" | grep -q 'dlq.cdc.>' || die "KV_CDC not bound to dlq.cdc.> — enabled render did not extend subjects (got [${STREAM_SUBJECTS}]); check the nats-init Job log"
fi

# ── metrics helpers ──────────────────────────────────────────────────────────
# Only the leader sink pod has the pipeline (elector); standbys return an empty
# /metrics. Concatenate all sink pods so we always capture the leader's series.
sink_metrics_dump() {
  local out="$1" pods p port=24800 idx=0 pid tries body
  : > "$out"
  pods="$(k get pods -o name | grep -E "/${RESOURCE_PREFIX}connect-sink" | sed 's|^pod/||')"
  [ -n "$pods" ] || die "no connect-sink pods found"
  for p in $pods; do
    port=$((24800 + idx)); idx=$((idx + 1))
    k port-forward "pod/${p}" "${port}:4195" >/dev/null 2>&1 &
    pid=$!
    body=""
    for _ in $(seq 1 20); do
      body="$(curl -s --max-time 2 "localhost:${port}/metrics" 2>/dev/null || true)"
      [ -n "$body" ] && break
      sleep 0.3
    done
    { kill "$pid"; } >/dev/null 2>&1 || true
    printf '%s\n' "$body" >> "$out"
  done
}
# metric_val <dumpfile> <metric_name> <label-substring> — sum $NF over matching series
metric_val() {
  local f="$1" name="$2" lbl="$3" v
  v="$(grep -E "^${name}\{" "$f" 2>/dev/null | grep -F "$lbl" | awk '{s+=$NF} END{printf "%d", s+0}')"
  echo "${v:-0}"
}

# ── consumer + subject baseline (right before injection) ─────────────────────
consumer_field() { na consumer info "$STREAM" "$DURABLE" --json 2>/dev/null | jq -r "$1"; }
dlq_count() {
  # `nats stream subjects` returns {subject: count}; {} when none retained.
  na stream subjects "$STREAM" "$DLQ_SUBJECT" --json 2>/dev/null \
    | jq -r --arg s "$DLQ_SUBJECT" '.[$s] // 0' 2>/dev/null || echo 0
}

log "=== step 2: baseline (consumer ${DURABLE}, subject ${DLQ_SUBJECT}, sink metrics) ==="
BASE_ACKFLOOR="$(consumer_field '.ack_floor.stream_seq')"
BASE_REDELIV="$(consumer_field '.num_redelivered')"
BASE_DLQ="$(dlq_count)"
BASE_DUMP="$(mktemp)"; sink_metrics_dump "$BASE_DUMP"
BASE_UNPROC="$(metric_val "$BASE_DUMP" cdc_unprocessable "reason=\"${REASON}\"")"
BASE_FWD="$(metric_val "$BASE_DUMP" cdc_dlq_forwarded "reason=\"${REASON}\"")"
BASE_SENT="$(metric_val "$BASE_DUMP" output_sent 'label="dlq_out"')"
BASE_ERR="$(metric_val "$BASE_DUMP" output_error 'label="dlq_out"')"
log "baseline: ack_floor=${BASE_ACKFLOOR} num_redelivered=${BASE_REDELIV} dlq_count=${BASE_DLQ} unproc=${BASE_UNPROC} forwarded=${BASE_FWD} sent(dlq_out)=${BASE_SENT} err(dlq_out)=${BASE_ERR}"

# ── 3. inject N poison + 1 normal into the central stream ────────────────────
log "=== step 3: inject N=${N} poison hash bodies + 1 normal create into ${CENTRAL_STREAM} ==="
NOW_MS="$(date +%s%3N)"
NORMAL_KEY="dlqe2e::normal::${RUNID}"
# Inject via redis-cli ARGV mode (one exec per XADD), NOT batched stdin. The poison
# body ["a","b"] contains double quotes; redis-cli's inline (stdin) parser rejects
# them ("Invalid argument(s)") and the XADD silently fails. In argv mode each field
# is a literal argument, so the quotes are stored verbatim. Body is a parseable JSON
# ARRAY (non-object) => the reverse hash guard flags hash_decode_error.
for (( i=1; i<=N; i++ )); do
  k exec "$CENTRAL" -- redis-cli XADD "$CENTRAL_STREAM" '*' \
    event_id "dlqe2e-${RUNID}-${i}" op create type hash \
    kv_key "dlqe2e::poison::${RUNID}::${i}" ts "$NOW_MS" body '["a","b"]' >/dev/null
done
# one NORMAL create (type=string) injected AFTER the poison — the unblocked proof
k exec "$CENTRAL" -- redis-cli XADD "$CENTRAL_STREAM" '*' \
  event_id "dlqe2e-normal-${RUNID}" op create type string \
  kv_key "$NORMAL_KEY" ts "$NOW_MS" body "hello-${RUNID}" >/dev/null
log "injected ${N} poison (kv_key dlqe2e::poison::${RUNID}::*) + normal ${NORMAL_KEY}"

# ── 4. poll until poison is parked + consumer drains ─────────────────────────
log "=== step 4: settle (poll up to ${POLL_TIMEOUT_S}s) ==="
WANT_DLQ=$(( BASE_DLQ + N ))
cur_dlq=0 ackpend=99 normal_present=0 acked_zero_seen=0
deadline=$(( $(date +%s) + POLL_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  cur_dlq="$(dlq_count)"
  ackpend="$(consumer_field '.num_ack_pending')"; ackpend="${ackpend:-99}"
  (( ackpend == 0 )) && acked_zero_seen=1
  normal_present="$(k exec "$REGION" -- redis-cli EXISTS "$NORMAL_KEY" 2>/dev/null | tr -dc '0-9')"; normal_present="${normal_present:-0}"
  if (( cur_dlq >= WANT_DLQ && acked_zero_seen == 1 && normal_present == 1 )); then break; fi
  sleep 3
done
# final settle read of the consumer
sleep 2
FIN_ACKFLOOR="$(consumer_field '.ack_floor.stream_seq')"
FIN_REDELIV="$(consumer_field '.num_redelivered')"
FIN_ACKPEND="$(consumer_field '.num_ack_pending')"; FIN_ACKPEND="${FIN_ACKPEND:-99}"
(( FIN_ACKPEND == 0 )) && acked_zero_seen=1
cur_dlq="$(dlq_count)"

# segment mode: confirm normal traffic actually transited kv.cdc.aio.* (the whole
# point of the layout) — not the bare legacy kv.cdc.<op> subjects. Sum the retained
# message counts under kv.cdc.aio.> (`nats stream subjects` returns {subject:count}).
AIO_MSGS=-1
if [ "$DLQ_MODE" = "segment" ]; then
  AIO_MSGS="$(na stream subjects "$STREAM" 'kv.cdc.aio.>' --json 2>/dev/null | jq -r 'add // 0' 2>/dev/null || echo 0)"
  log "segment mode: messages retained under kv.cdc.aio.* = ${AIO_MSGS}"
fi

# ── 5. sink metrics after ────────────────────────────────────────────────────
FIN_DUMP="$(mktemp)"; sink_metrics_dump "$FIN_DUMP"
FIN_UNPROC="$(metric_val "$FIN_DUMP" cdc_unprocessable "reason=\"${REASON}\"")"
FIN_FWD="$(metric_val "$FIN_DUMP" cdc_dlq_forwarded "reason=\"${REASON}\"")"
FIN_SENT="$(metric_val "$FIN_DUMP" output_sent 'label="dlq_out"')"
FIN_ERR="$(metric_val "$FIN_DUMP" output_error 'label="dlq_out"')"

D_DLQ=$(( cur_dlq - BASE_DLQ ))
D_UNPROC=$(( FIN_UNPROC - BASE_UNPROC ))
D_FWD=$(( FIN_FWD - BASE_FWD ))
D_SENT=$(( FIN_SENT - BASE_SENT ))
D_ERR=$(( FIN_ERR - BASE_ERR ))
D_REDELIV=$(( FIN_REDELIV - BASE_REDELIV ))
D_ACKFLOOR=$(( FIN_ACKFLOOR - BASE_ACKFLOOR ))

# ── 6. header dump for one parked message ────────────────────────────────────
log "=== step 6: parked-message header contract (${DLQ_SUBJECT}) ==="
HDR_RAW="$(na stream get "$STREAM" -S "$DLQ_SUBJECT" 2>&1 || true)"
echo "----- nats stream get ${STREAM} -S ${DLQ_SUBJECT} (last msg on subject) -----"
echo "$HDR_RAW"
echo "-------------------------------------------------------------"
hdr_ok=1
for h in "Nats-Msg-Id: dlq.dlqe2e-${RUNID}" "dlq_reason: ${REASON}" "dlq_error:" "dlq_orig_subject: kv.cdc"; do
  echo "$HDR_RAW" | grep -qi "$h" || { log "WARN header missing/mismatch: '$h'"; hdr_ok=0; }
done

# ── 7. verdict ───────────────────────────────────────────────────────────────
PASS=true; REASONS=""
add_fail() { PASS=false; REASONS="${REASONS}${REASONS:+; }$1"; }
(( D_DLQ    == N )) || add_fail "dlq subject delta ${D_DLQ} != ${N} (LOSS/dup)"
(( acked_zero_seen == 1 )) || add_fail "num_ack_pending never reached 0 (head-of-line block; final=${FIN_ACKPEND})"
(( D_ACKFLOOR >= N )) || add_fail "ack_floor advanced only ${D_ACKFLOOR} (< ${N}; poison not acked past)"
(( D_REDELIV == 0 )) || add_fail "num_redelivered grew by ${D_REDELIV} (poison loop / redelivery)"
(( D_UNPROC == N )) || add_fail "cdc_unprocessable{${REASON}} delta ${D_UNPROC} != ${N}"
(( D_FWD    == N )) || add_fail "cdc_dlq_forwarded{${REASON}} delta ${D_FWD} != ${N}"
(( D_SENT   == N )) || add_fail "output_sent{dlq_out} delta ${D_SENT} != ${N} (not PubAck-confirmed parked)"
(( D_ERR    == 0 )) || add_fail "output_error{dlq_out} delta ${D_ERR} != 0 (DLQ publish errors)"
(( normal_present == 1 )) || add_fail "normal create ${NORMAL_KEY} absent from region (pipeline blocked)"
(( hdr_ok == 1 )) || add_fail "parked-message header contract mismatch"
if [ "$DLQ_MODE" = "segment" ]; then
  (( AIO_MSGS >= 1 )) || add_fail "segment mode: no normal traffic observed under kv.cdc.aio.* (got ${AIO_MSGS})"
fi

RESULT="$(printf '{"runid":"%s","ns":"%s","n":%d,"reason":"%s","stream_subjects":"%s","dlq_delta":%d,"unproc_delta":%d,"forwarded_delta":%d,"output_sent_dlq_out_delta":%d,"output_error_dlq_out_delta":%d,"num_ack_pending_final":%d,"num_ack_pending_reached_zero":%s,"num_redelivered_delta":%d,"ack_floor_delta":%d,"normal_present":%d,"header_contract_ok":%d,"pass":%s}' \
  "$RUNID" "$NS" "$N" "$REASON" "$STREAM_SUBJECTS" "$D_DLQ" "$D_UNPROC" "$D_FWD" "$D_SENT" "$D_ERR" \
  "$FIN_ACKPEND" "$([ "$acked_zero_seen" = 1 ] && echo true || echo false)" "$D_REDELIV" "$D_ACKFLOOR" \
  "$normal_present" "$hdr_ok" "$PASS")"
echo "RESULT_JSON:${RESULT}"

if [ "$PASS" = "true" ]; then
  log "PASS — poison parked (dlq +${D_DLQ}), confirmed (output_sent{dlq_out} +${D_SENT}, error 0), consumer unblocked (ack_pending->0, redeliver +0), normal delivered, headers OK"
  exit 0
fi
echo "[dlq-e2e] FAIL — ${REASONS}" >&2
NS_LEFT_UP=1
exit 1
