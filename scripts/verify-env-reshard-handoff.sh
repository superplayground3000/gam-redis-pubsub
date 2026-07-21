#!/usr/bin/env bash
# verify-env-reshard-handoff.sh — L3 kind e2e mechanizing the AIO->sharded per-env
# handoff runbook (docs/design/multi-env-mixed-sink/runbook-aio-to-sharded-handoff.md,
# design §8.3/E7, implementation-plan P6/P7). Migrates ONE downstream env from an
# all-in-one (AIO) whole-segment durable onto a sharded durable set via the P6
# assert-only mode, and proves the runbook's load-bearing safety properties: no
# loss, no reorder for keys touched after the cutover, and R2 (pre-cutover keys keep
# their AIO terminal value) — WITHOUT touching the publisher or a second env.
#
# Topology (external-PROD-NATS shape; assert-only mode fails render on bundled):
#   - Release H (envId=envh): PUBLISHER + AIO sink, bundled NATS + central Redis +
#     its own region Redis. Declares family lb:company N=4 (so the forward already
#     emits per-shard subjects — the runbook precondition "prefixRouting ON"), DLQ on
#     in segment mode. Its own AIO sink is the "second env that keeps flowing" across
#     env C's handoff (design §12: no-loss/no-reorder for the migrating env WHILE a
#     second env keeps flowing).
#   - Release C (envId=envc): the MIGRATING env — a sink-only external release
#     pointed at release H's NATS (reusing its subscriber/admin creds Secrets), its
#     OWN region Redis. Starts AIO (whole-segment cdc_sink_envc filtering
#     kv.cdc.aio.>), then cuts over to the sharded durable set.
#
# Mechanized runbook steps (each GATE asserted):
#   1. Drive family+others traffic; env C (AIO) applies it all.
#   2. Quiesce env C's sink (scale 0), wait a FULL ackWait quiesce (num_ack_pending==0
#      stable), read F0 = cdc_sink_envc ack_floor.stream_seq (the APPLIED prefix — the
#      only safe anchor, runbook step 1 / E7).
#   3. F1 COVERAGE (runbook step 2): the sharded target's rendered filters must cover
#      all three classes of the old kv.cdc.aio.> traffic — every shard s0..sN-1 + sx,
#      every configured prefix (none here), and the others catch-all. Script-assert
#      the union ⊇ {s0..s3, sx, others} BEFORE deleting the old AIO durable.
#   4. NEGATIVE (runbook safety net): precreate every shard/others durable at
#      by_start_sequence F0+1 (MAP per the chart triple) EXCEPT one → helm upgrade to
#      sharded + handoffAssertOnly=true FAILS closed (init refuses to auto-create the
#      missing durable). Then precreate the missing one.
#   5. Delete the old AIO durable, POSITIVE upgrade → assert-only init PASSES (every
#      derived durable exists and is by_start_sequence). Resume env C sharded.
#   6. Assertions: NO LOSS (every event emitted ≥ F0+1 applied exactly-once-or-
#      idempotently to region C), NO REORDER for a key touched after F0 (monotone
#      sequence like verify-sharding.sh T-4; MAP=1 per shard), R2 (a key written ONLY
#      before F0 retains its AIO terminal value — the sharded durables never re-apply
#      it), num_ack_pending ≤ 1 on shard durables throughout, and the second env
#      (release H AIO) kept applying the post-F0 traffic. Toggle OFF re-renders the
#      create path (runbook step 6 GATE, a render assertion).
#
# Conventions (rules/50-lessons.md): capture-then-grep under pipefail; overridable
# NS/RELEASE/prefixes; verify-cdc.sh / verify-sharding.sh are consumed patterns,
# never modified.
#
# Usage:
#   scripts/verify-env-reshard-handoff.sh
#   RRCS_NS=cdc-hoff scripts/verify-env-reshard-handoff.sh
# Runtime env vars: RRCS_NS (default cdc-hoff), RRCS_CONTEXT (default kind-cdc),
#   RRCS_VALUES (default chart/values-dev.yaml), RRCS_RELEASE_H (default hrshh),
#   RRCS_RELEASE_C (default hrshc), RRCS_PREFIX_H (default lab-), RRCS_PREFIX_C
#   (default envc-).
# Expected duration: ~10 min (two installs + quiesce + precreate + two upgrades).
#   STANDALONE — see scripts/run-all-tests.sh RUN_HANDOFF header for the CPU
#   co-tenancy warning.
# Exit 0 iff every assertion is green. Success deletes the namespace; failure leaves
# it up for debugging.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-hoff}"
CTX="${RRCS_CONTEXT:-kind-cdc}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
REL_H="${RRCS_RELEASE_H:-hrshh}"
REL_C="${RRCS_RELEASE_C:-hrshc}"
PREFIX_H="${RRCS_PREFIX_H:-lab-}"        # host keeps the values-dev default prefix
PREFIX_C="${RRCS_PREFIX_C:-envc-}"       # migrating env distinct prefix (same ns)
ENVH="envh"
ENVC="envc"
ACKWAIT_S="${ACKWAIT_S:-30}"             # chart nats.stream.consumer.ackWait default
NSEQ="${NSEQ:-150}"                      # post-F0 ordering updates (no-reorder proof)
NOTHERS="${NOTHERS:-4}"                  # pre-F0 non-family creates
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-180}"
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-200}"

STREAM="KV_CDC"
CENTRAL_STREAM="app.events"
GROUP="cdc_propagator"
RUNID="$(date +%s)"
PROBE="hoff-natsbox-${RUNID}"

CENTRAL="deploy/${PREFIX_H}redis-central"
REGION_H="deploy/${PREFIX_H}redis-region"
REGION_C="deploy/${PREFIX_C}redis-region"
NATS_URL="nats://${PREFIX_H}nats:4222"
ADMIN_SECRET="${PREFIX_H}admin-creds"
SUBSCRIBER_SECRET="${PREFIX_H}subscriber-creds"

AIO_DUR="cdc_sink_${ENVC}"               # env C's pre-handoff whole-segment durable
# sharded durable triples the chart derives for env C (durable|filter|MAP) — must
# match the SINK_GROUPS record byte-for-byte so precreate == what assert-only checks.
SHARD_SPECS=(
  "cdc_sink_envc_lb_company_s0|kv.cdc.aio.lb.company.s0.>|1"
  "cdc_sink_envc_lb_company_s1|kv.cdc.aio.lb.company.s1.>|1"
  "cdc_sink_envc_lb_company_s2|kv.cdc.aio.lb.company.s2.>|1"
  "cdc_sink_envc_lb_company_s3|kv.cdc.aio.lb.company.s3.>|1"
  "cdc_sink_envc_lb_company_sx|kv.cdc.aio.lb.company.sx.>|1"
  "cdc_sink_envc_others|kv.cdc.aio.others.>|1024"
)
MISS_DUR="cdc_sink_envc_lb_company_s2"   # the durable deliberately left out (negative)

log() { echo "[handoff] $*"; }
die() { echo "[handoff] FAIL: $*" >&2; NS_LEFT_UP=1; exit 1; }
k()   { kubectl --context "$CTX" -n "$NS" "$@"; }

# shared sharded --set args (env C target topology) — an array (each token its own
# element) so nothing is word-split or glob-expanded (the keyPattern carries [0-9]).
# Reused byte-for-byte across the render gate and both cutover upgrades.
SHARDED_ARGS=(
  --set profile=cdc -f "$VALUES_FILE" --set "resourcePrefix=${PREFIX_C}"
  --set "connect.envId=${ENVC}" --set connect.source.enabled=false --set writer.enabled=false
  --set connect.deadLetter.enabled=true --set connect.deadLetter.segment=dlq --set nats.stream.normalSegment=aio
  --set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}'
  --set 'connect.sharding.families.lb:company.shards=4'
  --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company' --set 'connect.sinkGroups[0].shards={0,1,2,3,x}'
  --set connect.sinkGroups[1].name=others --set connect.sinkGroups[1].catchAll=true
  --set nats.external.enabled=true --set "nats.external.url=${NATS_URL}"
  --set "nats.external.auth.subscriberSecret=${SUBSCRIBER_SECRET}" --set "nats.external.auth.adminSecret=${ADMIN_SECRET}"
)

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

# ── 0. render-time GATE (runbook step 6): toggle OFF has the create path, ─────
#       toggle ON compiles it out. Do this before touching the cluster.
log "=== step 0: render gate — assert-only compiles out the create path (runbook step 6) ==="
ON_INIT=$(helm template "$REL_C" ./chart "${SHARDED_ARGS[@]}" --set connect.sink.handoffAssertOnly=true \
            -s templates/nats-init-external-job.yaml 2>/dev/null) || die "assert-only render failed"
OFF_INIT=$(helm template "$REL_C" ./chart "${SHARDED_ARGS[@]}" --set connect.sink.handoffAssertOnly=false \
            -s templates/nats-init-external-job.yaml 2>/dev/null) || die "create-path render failed"
# The executed create command has the exact signature `... consumer add "$STREAM"
# "$CONSUMER"`; a same-named COMMENT (`# `nats consumer add`...`) appears in BOTH
# renders, so match the executed form specifically (leading `nats --server`).
grep -qF 'handoff assert-only' <<<"$ON_INIT" \
  || die "assert-only render missing the [handoff assert-only] branch"
grep -qF 'by_start_sequence' <<<"$ON_INIT" \
  || die "assert-only render missing the by_start_sequence assertion"
grep -qE 'consumer add "\$STREAM" "\$CONSUMER"' <<<"$OFF_INIT" \
  || die "create-path (handoffAssertOnly=false) render missing an actual 'consumer add' call"
# the ON render must NOT execute a create — only the OFF render does.
if grep -qE 'consumer add "\$STREAM" "\$CONSUMER"' <<<"$ON_INIT"; then
  die "assert-only render still executes 'consumer add' (create path not compiled out)"
fi
log "render gate OK: assert-only asserts by_start_sequence, create path present only with the toggle OFF"

# ── 1. install host (publisher + AIO sink envh) then env C (AIO sink-only) ────
if kubectl --context "$CTX" get ns "$NS" >/dev/null 2>&1; then
  log "deleting pre-existing namespace ${NS}"
  kubectl --context "$CTX" delete ns "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
fi
log "=== step 1a: install release H (${REL_H}, envId=${ENVH}: publisher + AIO sink, family N=4) ==="
helm --kube-context "$CTX" upgrade --install "$REL_H" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set "resourcePrefix=${PREFIX_H}" \
  --set "connect.envId=${ENVH}" \
  --set connect.source.enabled=true \
  --set connect.sink.enabled=true \
  --set connect.sinkAllInOne.enabled=true \
  --set connect.deadLetter.enabled=true \
  --set connect.deadLetter.segment=dlq \
  --set nats.stream.normalSegment=aio \
  --set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}' \
  --set 'connect.sharding.families.lb:company.shards=4' \
  --wait --timeout 6m
for d in connect-source connect-sink; do
  k rollout status "deploy/${PREFIX_H}${d}" --timeout=180s
done

log "=== step 1b: install release C (${REL_C}, envId=${ENVC}: AIO sink-only, external -> ${NATS_URL}) ==="
helm --kube-context "$CTX" upgrade --install "$REL_C" ./chart -n "$NS" \
  --set profile=cdc -f "$VALUES_FILE" \
  --set "resourcePrefix=${PREFIX_C}" \
  --set "connect.envId=${ENVC}" \
  --set connect.source.enabled=false \
  --set connect.sink.enabled=true \
  --set connect.sinkAllInOne.enabled=true \
  --set connect.sink.bootstrap.deliver=new \
  --set connect.deadLetter.enabled=true \
  --set connect.deadLetter.segment=dlq \
  --set nats.stream.normalSegment=aio \
  --set writer.enabled=false \
  --set nats.external.enabled=true \
  --set "nats.external.url=${NATS_URL}" \
  --set "nats.external.auth.subscriberSecret=${SUBSCRIBER_SECRET}" \
  --set "nats.external.auth.adminSecret=${ADMIN_SECRET}" \
  --wait --timeout 6m
k rollout status "deploy/${PREFIX_C}connect-sink" --timeout=180s
sleep 5

# ── nats admin helper (host admin creds) ─────────────────────────────────────
log "starting nats-box probe ${PROBE}"
kubectl --context "$CTX" run "$PROBE" -n "$NS" --image=natsio/nats-box:0.14.5 --restart=Never \
  --overrides="{\"spec\":{\"volumes\":[{\"name\":\"c\",\"secret\":{\"secretName\":\"${ADMIN_SECRET}\",\"defaultMode\":292}}],\"containers\":[{\"name\":\"nb\",\"image\":\"natsio/nats-box:0.14.5\",\"command\":[\"sleep\",\"3600\"],\"volumeMounts\":[{\"name\":\"c\",\"mountPath\":\"/creds\",\"readOnly\":true}]}]}}" \
  >/dev/null 2>&1 || die "could not create nats-box probe pod"
k wait --for=condition=Ready "pod/${PROBE}" --timeout=60s >/dev/null 2>&1 || die "nats-box probe not Ready"
na() { k exec "$PROBE" -- nats --server "$NATS_URL" --creds /creds/user.creds "$@"; }

rc() { k exec -i "$CENTRAL" -- redis-cli "$@"; }
rrH() { k exec -i "$REGION_H" -- redis-cli "$@"; }
rrC() { k exec -i "$REGION_C" -- redis-cli "$@"; }
consumer_field() { na consumer info "$STREAM" "$1" --json 2>/dev/null | jq -r "$2"; }
cntC() { rrC --scan --pattern "$1" 2>/dev/null | grep -c . || true; }
cntH() { rrH --scan --pattern "$1" 2>/dev/null | grep -c . || true; }
now_ms() { date +%s%3N; }

rrH FLUSHDB >/dev/null; rrC FLUSHDB >/dev/null
rc XGROUP CREATE "$CENTRAL_STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
TS="$(now_ms)"

# ── 2. pre-F0 traffic (applied by AIO env C), incl. the R2 key ───────────────
log "=== step 2: drive pre-F0 traffic (family + others + R2 key), env C AIO applies it ==="
PRE_KEY="lb:company:active:{employees:7}:pre-${RUNID}"   # id 7 -> shard s3 after cutover; written ONLY pre-F0
cmds="$(mktemp)"
# a handful of family keys across shards + the R2 key + non-family others
for id in 1 2 3 4 5 6; do
  echo "XADD $CENTRAL_STREAM * event_id hoff-${RUNID}-pre-f${id} op create type string kv_key lb:company:active:{employees:${id}}:pre-${RUNID} ts ${TS} body preA"
done > "$cmds"
echo "XADD $CENTRAL_STREAM * event_id hoff-${RUNID}-pre-r7 op create type string kv_key ${PRE_KEY} ts ${TS} body R2VALUE" >> "$cmds"
for (( i=1; i<=NOTHERS; i++ )); do
  echo "XADD $CENTRAL_STREAM * event_id hoff-${RUNID}-pre-o${i} op create type string kv_key misc:pre:${i}:${RUNID} ts ${TS} body preO"
done >> "$cmds"
k exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
PRE_TOTAL=$(( 6 + 1 + NOTHERS ))
deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  cpre="$(cntC "*pre-${RUNID}")"; cpreo="$(cntC "misc:pre:*:${RUNID}")"
  (( cpre + cpreo >= PRE_TOTAL )) && break
  sleep 3
done
R2_BEFORE="$(rrC GET "$PRE_KEY" | tr -d '\r')"
[ "$R2_BEFORE" = "R2VALUE" ] || die "pre-F0 R2 key not applied by AIO env C (got '${R2_BEFORE}')"
log "pre-F0 applied; R2 key ${PRE_KEY}=${R2_BEFORE}"

# ── 3. quiesce env C's sink and read F0 (runbook step 1) ─────────────────────
log "=== step 3: quiesce env C sink (scale 0), wait full ackWait quiesce, read F0 ==="
k scale "deploy/${PREFIX_C}connect-sink" --replicas=0
k rollout status "deploy/${PREFIX_C}connect-sink" --timeout=90s || true
# wait num_ack_pending==0 stable across two reads ~an ackWait apart
qok=0
for _ in $(seq 1 20); do
  nap="$(consumer_field "$AIO_DUR" '.num_ack_pending')"; nap="${nap:-9}"
  if (( nap == 0 )); then qok=$(( qok+1 )); (( qok >= 2 )) && break; else qok=0; fi
  sleep "$ACKWAIT_S"
done
(( qok >= 2 )) || die "env C AIO durable never quiesced (num_ack_pending stayed > 0)"
F0="$(consumer_field "$AIO_DUR" '.ack_floor.stream_seq')"
if [ -z "$F0" ] || [ "$F0" = "null" ]; then die "could not read F0 (ack_floor.stream_seq) from ${AIO_DUR}"; fi
SSEQ=$(( F0 + 1 ))
log "quiesced; F0=ack_floor=${F0}; new durables will start at F0+1=${SSEQ}"

# ── 4. F1 coverage check (runbook step 2) BEFORE deleting the old AIO durable ─
log "=== step 4: F1 coverage — sharded filters must cover kv.cdc.aio.> {shards,sx,others} ==="
RENDER_FILTERS=$(helm template "$REL_C" ./chart "${SHARDED_ARGS[@]}" --set connect.sink.handoffAssertOnly=true \
  -s templates/nats-init-external-job.yaml 2>/dev/null | grep -oE 'kv\.cdc\.aio\.[^ "|]+' | sort -u)
cover_ok=1
for want in kv.cdc.aio.lb.company.s0.\> kv.cdc.aio.lb.company.s1.\> kv.cdc.aio.lb.company.s2.\> \
            kv.cdc.aio.lb.company.s3.\> kv.cdc.aio.lb.company.sx.\> kv.cdc.aio.others.\>; do
  grep -qF "${want//\\/}" <<<"$RENDER_FILTERS" || { log "WARN F1 coverage missing filter ${want//\\/}"; cover_ok=0; }
done
(( cover_ok == 1 )) || die "F1 coverage gate failed — sharded filter union does NOT cover the old kv.cdc.aio.> traffic"
log "F1 coverage OK: {s0,s1,s2,s3,sx,others} all present (no configured publisher prefixes to cover)"

# ── 5. NEGATIVE: precreate all-but-one durable, assert-only upgrade FAILS ─────
precreate() { # $1=durable $2=filter $3=map
  na consumer add "$STREAM" "$1" --pull --filter "$2" --ack explicit \
    --deliver by_start_sequence --start-sequence "$SSEQ" --replay instant \
    --wait "${ACKWAIT_S}s" --max-pending "$3" --max-deliver=-1 --defaults >/dev/null 2>&1 \
    || die "precreate of durable $1 failed"
}
log "=== step 5: precreate durables at F0+1 EXCEPT ${MISS_DUR} (negative case) ==="
for spec in "${SHARD_SPECS[@]}"; do
  IFS='|' read -r dur filt mapv <<<"$spec"
  [ "$dur" = "$MISS_DUR" ] && { log "  (skipping ${dur} — negative)"; continue; }
  precreate "$dur" "$filt" "$mapv"
done
log "assert-only upgrade with ${MISS_DUR} MISSING — expect fail-closed"
set +e
helm --kube-context "$CTX" upgrade "$REL_C" ./chart -n "$NS" "${SHARDED_ARGS[@]}" \
  --set connect.sink.handoffAssertOnly=true --wait --timeout 3m >/tmp/hoff_neg.log 2>&1
NEG_RC=$?
set -e
NEG_HOOK="$(k logs -l "job-name" --tail=-1 2>/dev/null | grep -i "does NOT exist" | grep -i "$MISS_DUR" || true)"
if (( NEG_RC == 0 )) && [ -z "$NEG_HOOK" ]; then
  die "assert-only upgrade with a MISSING durable did NOT fail closed (rc=${NEG_RC})"
fi
log "negative OK: init refused to auto-create ${MISS_DUR} (helm rc=${NEG_RC})"

# ── 6. precreate the missing durable, delete old AIO, POSITIVE upgrade ────────
log "=== step 6: precreate ${MISS_DUR}, delete old AIO durable, assert-only upgrade PASSES ==="
for spec in "${SHARD_SPECS[@]}"; do
  IFS='|' read -r dur filt mapv <<<"$spec"
  [ "$dur" = "$MISS_DUR" ] || continue
  precreate "$dur" "$filt" "$mapv"
done
na consumer rm "$STREAM" "$AIO_DUR" --force >/dev/null 2>&1 || die "could not delete old AIO durable ${AIO_DUR}"
na consumer info "$STREAM" "$AIO_DUR" >/dev/null 2>&1 && die "old AIO durable ${AIO_DUR} still present after delete"

# inject POST-F0 traffic BEFORE resume so it is all > F0 and delivered from F0+1.
log "injecting post-F0 traffic: ${NSEQ} ordered updates on one key + a no-loss batch"
ORD_KEY="lb:company:active:{employees:9}:ord-${RUNID}"   # id 9 -> shard s1
LOSS_TS="$(now_ms)"
cmds="$(mktemp)"
for (( i=1; i<=NSEQ; i++ )); do
  echo "XADD $CENTRAL_STREAM * event_id hoff-${RUNID}-ord-${i} op update type string kv_key ${ORD_KEY} ts ${LOSS_TS} body ${i}"
done > "$cmds"
# a no-loss batch: distinct keys across shards + others, each emitted exactly once
for id in 4 8 12 5 13 6 10 3 11; do
  echo "XADD $CENTRAL_STREAM * event_id hoff-${RUNID}-post-f${id} op create type string kv_key lb:company:active:{employees:${id}}:post-${RUNID} ts ${LOSS_TS} body postA"
done >> "$cmds"
for (( i=1; i<=NOTHERS; i++ )); do
  echo "XADD $CENTRAL_STREAM * event_id hoff-${RUNID}-post-o${i} op create type string kv_key misc:post:${i}:${RUNID} ts ${LOSS_TS} body postO"
done >> "$cmds"
k exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
POST_NOLOSS=$(( 9 + NOTHERS ))   # distinct post-F0 keys expected in region C (excl. the ordering key)

# start a region-C ordering poller (like verify-sharding.sh T-4) before resume
POLL_OUT="$(mktemp)"
k exec "$REGION_C" -- sh -c \
  "i=0; while [ \$i -lt 9000 ]; do redis-cli GET '$ORD_KEY'; i=\$((i+1)); done" \
  > "$POLL_OUT" 2>/dev/null &
POLL_PID=$!

helm --kube-context "$CTX" upgrade "$REL_C" ./chart -n "$NS" "${SHARDED_ARGS[@]}" \
  --set connect.sink.handoffAssertOnly=true --wait --timeout 4m >/tmp/hoff_pos.log 2>&1 \
  || { kill "$POLL_PID" 2>/dev/null || true; die "assert-only upgrade FAILED after all durables precreated (see /tmp/hoff_pos.log)"; }
POS_HOOK="$(k logs -l "job-name" --tail=-1 2>/dev/null | grep -ci 'by_start_sequence' || true)"
for d in connect-sink-shard-a connect-sink-others; do
  k rollout status "deploy/${PREFIX_C}${d}" --timeout=180s || true
done
log "assert-only upgrade PASSED (hook by_start_sequence asserts: ${POS_HOOK})"

# ── 7. settle post-F0 apply, then stop the poller ────────────────────────────
log "=== step 7: settle post-F0 apply on the sharded env C ==="
deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
noloss=0; ord_final=""
while (( $(date +%s) < deadline )); do
  noloss="$(cntC "*post-${RUNID}")"; noloss=$(( noloss + $(cntC "misc:post:*:${RUNID}") ))
  ord_final="$(rrC GET "$ORD_KEY" | tr -d '\r')"
  if (( noloss >= POST_NOLOSS )) && [ "$ord_final" = "$NSEQ" ]; then break; fi
  sleep 3
done
sleep 2
kill "$POLL_PID" >/dev/null 2>&1 || true; wait "$POLL_PID" 2>/dev/null || true
noloss="$(cntC "*post-${RUNID}")"; noloss=$(( noloss + $(cntC "misc:post:*:${RUNID}") ))
ord_final="$(rrC GET "$ORD_KEY" | tr -d '\r')"

# ── 8. final reads / assertions material ─────────────────────────────────────
# no-reorder: region value never went backwards (monotone), final == NSEQ
ORD_VIOL="$(awk 'NF{ v=$1+0; if (seen && v < last) { print last" -> "v; bad=1 } last=v; seen=1 } END{ exit bad }' "$POLL_OUT" 2>&1)" && ORD_MONO=1 || ORD_MONO=0
ORD_SAMPLES=$(grep -c . "$POLL_OUT" || true)
rm -f "$POLL_OUT"
# R2: pre-F0-only key retains its AIO terminal value (never re-applied post-cutover)
R2_AFTER="$(rrC GET "$PRE_KEY" | tr -d '\r')"
# num_ack_pending <= 1 on every shard durable
NAP_MAX=0
for spec in "${SHARD_SPECS[@]}"; do
  IFS='|' read -r dur _f mapv <<<"$spec"
  [ "$mapv" = "1" ] || continue
  nap="$(consumer_field "$dur" '.num_ack_pending')"; nap="${nap:-9}"
  (( nap > NAP_MAX )) && NAP_MAX="$nap"
done
# second env (host AIO) kept flowing: it also applied the post-F0 no-loss batch
h_noloss="$(cntH "*post-${RUNID}")"; h_noloss=$(( h_noloss + $(cntH "misc:post:*:${RUNID}") ))

# ── 9. verdict ───────────────────────────────────────────────────────────────
PASS=true; REASONS=""
add_fail() { PASS=false; REASONS="${REASONS}${REASONS:+; }$1"; }
(( noloss == POST_NOLOSS ))  || add_fail "no-loss: env C region got ${noloss}/${POST_NOLOSS} post-F0 keys"
[ "$ord_final" = "$NSEQ" ]   || add_fail "no-reorder: final ordering value ${ord_final} != ${NSEQ}"
(( ORD_MONO == 1 ))          || add_fail "no-reorder: region value went backwards: ${ORD_VIOL}"
[ "$R2_AFTER" = "R2VALUE" ]  || add_fail "R2: pre-F0 key value changed after handoff (${R2_BEFORE} -> ${R2_AFTER})"
(( NAP_MAX <= 1 ))           || add_fail "num_ack_pending ${NAP_MAX} > 1 on a shard durable (O-6)"
(( POS_HOOK >= 6 ))          || add_fail "assert-only hook logged only ${POS_HOOK} by_start_sequence asserts (want >=6)"
(( h_noloss == POST_NOLOSS )) || add_fail "second env (host AIO) got ${h_noloss}/${POST_NOLOSS} post-F0 keys (did not keep flowing)"

RESULT="$(printf '{"runid":"%s","ns":"%s","F0":%s,"post_noloss":{"got":%d,"want":%d},"ord_final":"%s","ord_samples":%d,"ord_monotone":%d,"r2":{"before":"%s","after":"%s"},"num_ack_pending_max":%d,"assert_hook_count":%d,"second_env_noloss":%d,"pass":%s}' \
  "$RUNID" "$NS" "$F0" "$noloss" "$POST_NOLOSS" "$ord_final" "$ORD_SAMPLES" "$ORD_MONO" "$R2_BEFORE" "$R2_AFTER" "$NAP_MAX" "$POS_HOOK" "$h_noloss" "$PASS")"
echo "RESULT_JSON:${RESULT}"

if [ "$PASS" = "true" ]; then
  log "PASS — AIO->sharded handoff at F0=${F0}: assert-only rejected a missing durable then passed at F0+1, no loss (${noloss}/${POST_NOLOSS} post-F0 keys), no reorder (${ORD_SAMPLES} samples monotone, final=${ord_final}), R2 held (pre-F0 key=${R2_AFTER}), O-6 held (num_ack_pending<=1), second env kept flowing (${h_noloss}/${POST_NOLOSS})"
  exit 0
fi
echo "[handoff] FAIL — ${REASONS}" >&2
NS_LEFT_UP=1
exit 1
