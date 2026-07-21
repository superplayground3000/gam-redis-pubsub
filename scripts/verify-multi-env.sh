#!/usr/bin/env bash
# verify-multi-env.sh — L3 kind e2e for the multi-env mixed-sink topology
# (design docs/design/multi-env-mixed-sink/design.md §3/§4/§5/§7/§12;
# implementation-plan.md P7). ONE shared JetStream stream is fanned out to TWO
# downstream sink environments of DIFFERENT shapes at once, each with its own
# region Redis and its own env-scoped durable set:
#
#   - Release A (envId=enva): the PUBLISHER + a SHARDED sink, combined in one
#     bundled-NATS release. Owns central Redis, the shared NATS, and its own
#     region Redis. Declares family lb:company N=4 (so the forward emits the
#     per-shard subjects), consumes it across a shard group {0..3,x} + an "others"
#     catch-all, DLQ on in in-prefix segment mode (kv.cdc.dlq.enva.<reason>).
#   - Release B (envId=envb): an ALL-IN-ONE sink-only release, external NATS ->
#     release A's bundled NATS (reusing release A's minted subscriber/admin creds
#     Secrets, same account — the pattern proven by verify-multi-env-cross-park.sh),
#     its OWN region Redis, DLQ on (kv.cdc.dlq.envb.<reason>). Its single whole-
#     segment durable cdc_sink_envb binds kv.cdc.aio.> — a superset of the per-shard
#     subjects — so it receives a FULL server-side fan-out copy of every event.
#
# Segment mode (nats.stream.normalSegment=aio + deadLetter.segment=dlq) keeps the
# stream binding a single kv.cdc.> root for BOTH envs: normal traffic under
# kv.cdc.aio.<...>, each env's DLQ under kv.cdc.dlq.<env>.<reason>, no out-of-prefix
# second root. This folds in verify-multi-env-cross-park.sh's E2 proof (assertion C
# below) generalized to an AIO+sharded pair, so that standalone script is retired.
#
# Assertions (design §12 "verify-multi-env.sh" row):
#   A. FAN-OUT — both envs receive+apply ALL normal traffic; per-env region key
#      counts are equal (each env got a full copy, VF-2).
#   B. DISJOINT DURABLES — env A's durables (cdc_sink_enva_*) and env B's
#      (cdc_sink_envb) are env-prefixed and set-disjoint (nats consumer ls diff);
#      no shared ack floor.
#   C. POISON CROSS-PARK (folds cross-park E2) — ONE poison hash event parks a
#      SEPARATE copy in EACH env's lane (kv.cdc.dlq.enva.hash_decode_error AND
#      kv.cdc.dlq.envb.hash_decode_error, each +1), the two parked copies carry
#      DISTINCT env-scoped msg-ids (dlq.enva.<eid> vs dlq.envb.<eid>) — no dedup
#      swallow — and BOTH envs' poisoned durables advance their ack floor (unblock).
#   D. ISOLATION — env A's poison does NOT stall env B: a normal injected AFTER the
#      poison is applied by env B, and env A's OTHER shards keep applying too.
#   E. ENV ATTRIBUTION — what P1 shipped: env is carried by the env-scoped durable
#      NAMES (each env's durables advance delivered independently; proven by B+the
#      per-env floors) and by the ServiceMonitor `env` external-label relabeling
#      (an L1 render fact, asserted here on the live rendered ServiceMonitor object).
#   F. MANIFEST GATE (design §7, P2; OPTIONAL — see MANIFEST_GATE below) — with
#      nats.topologyManifest.enabled, a sink whose family N drifts from the
#      publisher manifest fails its init CLOSED; corrected values pass. Requires the
#      user-provisioned $KV.cdc_topology.> grant (design §7) which the committed lab
#      creds do NOT mint — so this block SELF-SKIPS (loud, non-fatal) if the manifest
#      never becomes readable. Set MANIFEST_GATE=skip to force-skip, =require to fail
#      when it cannot run.
#
# Conventions (rules/50-lessons.md): capture-then-grep under pipefail; overridable
# NS/RELEASE/prefixes; verify-cdc.sh / verify-sharding.sh / verify-dlq-e2e.sh are
# consumed patterns, never modified.
#
# Usage:
#   scripts/verify-multi-env.sh
#   RRCS_NS=cdc-menv scripts/verify-multi-env.sh
#   MANIFEST_GATE=require scripts/verify-multi-env.sh   # fail if the gate can't run
# Runtime env vars: RRCS_NS (default cdc-menv), RRCS_CONTEXT (default kind-cdc),
#   RRCS_VALUES (default chart/values-dev.yaml), RRCS_RELEASE_A/B, RRCS_PREFIX_A/B,
#   MANIFEST_GATE (auto|require|skip, default auto).
# Expected duration: ~7 min (two installs + a manifest-gate reinstall). STANDALONE —
#   see scripts/run-all-tests.sh RUN_MULTIENV header for the CPU co-tenancy warning.
# Exit 0 iff every non-skipped assertion is green. Success deletes the namespace;
# failure leaves it up for debugging.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-menv}"
CTX="${RRCS_CONTEXT:-kind-cdc}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
REL_A="${RRCS_RELEASE_A:-menva}"
REL_B="${RRCS_RELEASE_B:-menvb}"
PREFIX_A="${RRCS_PREFIX_A:-lab-}"        # release A keeps the values-dev default prefix
PREFIX_B="${RRCS_PREFIX_B:-envb-}"       # release B distinct prefix (same namespace)
ENVA="enva"
ENVB="envb"
MANIFEST_GATE="${MANIFEST_GATE:-auto}"   # auto | require | skip
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-180}"
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-180}"
NNORMAL="${NNORMAL:-8}"                   # normal family creates spread across shards
NOTHERS="${NOTHERS:-4}"                   # non-family creates -> others catch-all

STREAM="KV_CDC"
CENTRAL_STREAM="app.events"
GROUP="cdc_propagator"
REASON="hash_decode_error"
RUNID="$(date +%s)"
PROBE="menv-natsbox-${RUNID}"

CENTRAL="deploy/${PREFIX_A}redis-central"
REGION_A="deploy/${PREFIX_A}redis-region"
REGION_B="deploy/${PREFIX_B}redis-region"
NATS_URL="nats://${PREFIX_A}nats:4222"
ADMIN_SECRET="${PREFIX_A}admin-creds"
SUBSCRIBER_SECRET="${PREFIX_A}subscriber-creds"

log() { echo "[multi-env] $*"; }
die() { echo "[multi-env] FAIL: $*" >&2; NS_LEFT_UP=1; exit 1; }
k()   { kubectl --context "$CTX" -n "$NS" "$@"; }

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

# ── 0a. install release A: publisher + SHARDED sink (envId=enva, bundled NATS) ─
if kubectl --context "$CTX" get ns "$NS" >/dev/null 2>&1; then
  log "deleting pre-existing namespace ${NS}"
  kubectl --context "$CTX" delete ns "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
fi
log "=== step 0a: install release A (${REL_A}, envId=${ENVA}: publisher + sharded sink, segment mode, DLQ on) ==="
helm --kube-context "$CTX" upgrade --install "$REL_A" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set "resourcePrefix=${PREFIX_A}" \
  --set "connect.envId=${ENVA}" \
  --set connect.source.enabled=true \
  --set connect.sink.enabled=true \
  --set connect.deadLetter.enabled=true \
  --set connect.deadLetter.segment=dlq \
  --set nats.stream.normalSegment=aio \
  --set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}' \
  --set 'connect.sharding.families.lb:company.shards=4' \
  --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company' \
  --set 'connect.sinkGroups[0].shards={0,1,2,3,x}' \
  --set connect.sinkGroups[1].name=others --set connect.sinkGroups[1].catchAll=true \
  --wait --timeout 6m
for d in connect-source connect-sink-shard-a connect-sink-others; do
  k rollout status "deploy/${PREFIX_A}${d}" --timeout=180s
done

# ── 0b. install release B: ALL-IN-ONE sink-only (envId=envb, external -> A) ────
# Reuse release A's minted subscriber/admin creds Secrets (same NATS account) and
# point at its NATS Service. Source + writer OFF; its own bundled region Redis.
log "=== step 0b: install release B (${REL_B}, envId=${ENVB}: AIO sink-only, external NATS -> ${NATS_URL}) ==="
helm --kube-context "$CTX" upgrade --install "$REL_B" ./chart -n "$NS" \
  --set profile=cdc -f "$VALUES_FILE" \
  --set "resourcePrefix=${PREFIX_B}" \
  --set "connect.envId=${ENVB}" \
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
k rollout status "deploy/${PREFIX_B}connect-sink" --timeout=180s
sleep 5   # let all electors win + POST pipelines

# ── nats admin helper (release A's admin creds) ──────────────────────────────
log "starting nats-box probe ${PROBE}"
kubectl --context "$CTX" run "$PROBE" -n "$NS" --image=natsio/nats-box:0.14.5 --restart=Never \
  --overrides="{\"spec\":{\"volumes\":[{\"name\":\"c\",\"secret\":{\"secretName\":\"${ADMIN_SECRET}\",\"defaultMode\":292}}],\"containers\":[{\"name\":\"nb\",\"image\":\"natsio/nats-box:0.14.5\",\"command\":[\"sleep\",\"3600\"],\"volumeMounts\":[{\"name\":\"c\",\"mountPath\":\"/creds\",\"readOnly\":true}]}]}}" \
  >/dev/null 2>&1 || die "could not create nats-box probe pod"
k wait --for=condition=Ready "pod/${PROBE}" --timeout=60s >/dev/null 2>&1 || die "nats-box probe not Ready"
na() { k exec "$PROBE" -- nats --server "$NATS_URL" --creds /creds/user.creds "$@"; }

rc() { k exec -i "$CENTRAL" -- redis-cli "$@"; }
rrA() { k exec -i "$REGION_A" -- redis-cli "$@"; }
rrB() { k exec -i "$REGION_B" -- redis-cli "$@"; }
consumer_field() { na consumer info "$STREAM" "$1" --json 2>/dev/null | jq -r "$2"; }
lane_count() {  # $1=env $2=reason — retained message count on kv.cdc.dlq.<env>.<reason>
  local subj="kv.cdc.dlq.$1.$2"
  na stream subjects "$STREAM" "$subj" --json 2>/dev/null \
    | jq -r --arg s "$subj" '.[$s] // 0' 2>/dev/null || echo 0
}
cntA() { rrA --scan --pattern "$1" 2>/dev/null | grep -c . || true; }
cntB() { rrB --scan --pattern "$1" 2>/dev/null | grep -c . || true; }
now_ms() { date +%s%3N; }

DUR_A_SHARDS=(cdc_sink_enva_lb_company_s0 cdc_sink_enva_lb_company_s1 \
              cdc_sink_enva_lb_company_s2 cdc_sink_enva_lb_company_s3 \
              cdc_sink_enva_lb_company_sx cdc_sink_enva_others)
DUR_B="cdc_sink_envb"
DUR_A_S0="cdc_sink_enva_lb_company_s0"   # the poison lands on s0 (id mod 4 == 0)

# ── 1. baselines ─────────────────────────────────────────────────────────────
log "=== step 1: baselines (durable ls, lanes, floors) ==="
rc XGROUP CREATE "$CENTRAL_STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
# Warm-up readiness PROOF before the measured run (2026-07-21 lesson): a sleep
# after rollout is not evidence the apply path works — a startup-window race once
# made the first per-lane deliveries vanish (delivered+acked+apply-counted, key
# absent in region; root-caused as startup exposure, not pipeline semantics).
# Inject one disposable family event + one non-family event, WAIT until BOTH
# regions actually applied both, then flush and start the measured test from a
# proven-hot pipeline.
log "warm-up: proving both sinks' apply paths end-to-end before the measured run"
# RETRY ROUNDS: a probe injected during the elector-churn window can stall in the
# forward's PEL (replayed only on the next forward restart — an availability
# delay, not a loss). A fresh probe pair per round proves steady state is
# reached; stale stuck probes are harmless (idempotent create, replays later).
WARM_OK=0; wa=0; wb=0; wround=0
for wround in 1 2 3 4; do
  rc XADD "$CENTRAL_STREAM" '*' event_id "warmup-${RUNID}-r${wround}-f" op create type string \
    kv_key "lb:company:active:{employees:1}:warmup${RUNID}r${wround}" ts "$(now_ms)" body warm >/dev/null
  rc XADD "$CENTRAL_STREAM" '*' event_id "warmup-${RUNID}-r${wround}-o" op create type string \
    kv_key "misc:warmup:${wround}:${RUNID}" ts "$(now_ms)" body warm >/dev/null
  WU_DEADLINE=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < WU_DEADLINE )); do
    wa=$(( $(cntA "*warmup${RUNID}r${wround}") + $(cntA "misc:warmup:${wround}:${RUNID}") ))
    wb=$(( $(cntB "*warmup${RUNID}r${wround}") + $(cntB "misc:warmup:${wround}:${RUNID}") ))
    if (( wa >= 2 && wb >= 2 )); then WARM_OK=1; break 2; fi
    sleep 3
  done
  log "warm-up round ${wround}: not fully applied yet (A ${wa}/2, B ${wb}/2) — injecting a fresh probe pair"
done
(( WARM_OK == 1 )) || die "warm-up: sinks did not apply a full probe pair in ${wround} rounds (last: env A ${wa}/2, env B ${wb}/2) — apply path not proven, refusing to start the measured run"
log "warm-up OK (round ${wround}): both envs applied the readiness probes (A=${wa}/2 B=${wb}/2)"
rrA FLUSHDB >/dev/null; rrB FLUSHDB >/dev/null
TS="$(now_ms)"

# (B) durable disjointness + env-prefixing, up front.
CONSUMERS="$(na consumer ls "$STREAM" 2>/dev/null | tr -d '\r')"
log "server-side consumers: $(tr '\n' ' ' <<<"$CONSUMERS")"
B_OK=1
for d in "${DUR_A_SHARDS[@]}"; do grep -qw "$d" <<<"$CONSUMERS" || { log "WARN missing env A durable $d"; B_OK=0; }; done
grep -qw "$DUR_B" <<<"$CONSUMERS" || { log "WARN missing env B durable $DUR_B"; B_OK=0; }
# env A durables all carry the enva token; env B's the envb token; no shared name.
if grep -q 'cdc_sink_envb_' <<<"$CONSUMERS"; then log "WARN env B leaked a sharded durable"; B_OK=0; fi

BASE_LANE_A="$(lane_count "$ENVA" "$REASON")"; BASE_LANE_B="$(lane_count "$ENVB" "$REASON")"
BASE_AF_A_S0="$(consumer_field "$DUR_A_S0" '.ack_floor.stream_seq')"
BASE_AF_B="$(consumer_field "$DUR_B" '.ack_floor.stream_seq')"
BASE_DLV_A_S0="$(consumer_field "$DUR_A_S0" '.delivered.stream_seq')"
BASE_DLV_B="$(consumer_field "$DUR_B" '.delivered.stream_seq')"
log "baseline lanes: A=${BASE_LANE_A} B=${BASE_LANE_B}"

# ── 2. FAN-OUT: inject normal family + non-family traffic ─────────────────────
log "=== step 2: inject ${NNORMAL} family + ${NOTHERS} non-family normals ==="
cmds="$(mktemp)"
# family lb:company keys spread across shards 0..3 (id mod 4). Applied by env A's
# shard groups AND by env B's whole-segment durable.
for (( i=1; i<=NNORMAL; i++ )); do
  echo "XADD $CENTRAL_STREAM * event_id menv-${RUNID}-f${i} op create type string kv_key lb:company:active:{employees:${i}}:f${RUNID} ts ${TS} body v${i}"
done > "$cmds"
# non-family keys route to kv.cdc.aio.others.<op> (env A catch-all + env B whole-segment).
for (( i=1; i<=NOTHERS; i++ )); do
  echo "XADD $CENTRAL_STREAM * event_id menv-${RUNID}-o${i} op create type string kv_key misc:thing:${i}:o${RUNID} ts ${TS} body w${i}"
done >> "$cmds"
k exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null; rm -f "$cmds"
TOTAL_NORMAL=$(( NNORMAL + NOTHERS ))

# settle: both region Redises reach TOTAL_NORMAL keys for this run
log "=== step 3: settle fan-out (poll up to ${SETTLE_TIMEOUT_S}s) ==="
deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
ca=0; cb=0
while (( $(date +%s) < deadline )); do
  ca="$(cntA "*${RUNID}")"; cb="$(cntB "*${RUNID}")"
  if (( ca >= TOTAL_NORMAL && cb >= TOTAL_NORMAL )); then break; fi
  sleep 3
done
sleep 2
ca="$(cntA "*${RUNID}")"; cb="$(cntB "*${RUNID}")"

# ── 4. POISON CROSS-PARK: ONE poison hash at shard s0 ────────────────────────
log "=== step 4: inject ONE poison hash event (parseable JSON array, not an object) ==="
NOW_MS="$(now_ms)"
EID="menv-poison-${RUNID}"
# argv mode (not stdin) — the poison body contains quotes; redis-cli inline parsing
# would reject them (verify-dlq-e2e.sh convention). id 4 -> id mod 4 == 0 -> shard s0.
k exec "$CENTRAL" -- redis-cli XADD "$CENTRAL_STREAM" '*' \
  event_id "$EID" op create type hash kv_key "lb:company:active:{employees:4}:poison-${RUNID}" ts "$NOW_MS" body '["a","b"]' >/dev/null
log "injected poison event_id=${EID} (targets env A shard s0 + env B whole-segment)"

# settle: BOTH env lanes must gain a copy
log "=== step 5: settle poison cross-park (poll up to ${POLL_TIMEOUT_S}s) ==="
deadline=$(( $(date +%s) + POLL_TIMEOUT_S ))
la="$BASE_LANE_A"; lb="$BASE_LANE_B"
while (( $(date +%s) < deadline )); do
  la="$(lane_count "$ENVA" "$REASON")"; lb="$(lane_count "$ENVB" "$REASON")"
  if (( la >= BASE_LANE_A+1 && lb >= BASE_LANE_B+1 )); then break; fi
  sleep 3
done
sleep 2
la="$(lane_count "$ENVA" "$REASON")"; lb="$(lane_count "$ENVB" "$REASON")"

# distinct env-scoped msg-ids on the two parked copies
HDR_A="$(na stream get "$STREAM" -S "kv.cdc.dlq.${ENVA}.${REASON}" 2>&1 || true)"
HDR_B="$(na stream get "$STREAM" -S "kv.cdc.dlq.${ENVB}.${REASON}" 2>&1 || true)"
MSGID_A_OK=0; MSGID_B_OK=0
echo "$HDR_A" | grep -qi "Nats-Msg-Id: dlq.${ENVA}." && MSGID_A_OK=1
echo "$HDR_B" | grep -qi "Nats-Msg-Id: dlq.${ENVB}." && MSGID_B_OK=1

# ── 6. ISOLATION: normal AFTER poison must still apply in BOTH envs ──────────
log "=== step 6: inject post-poison normal (isolation) ==="
# id 3 -> shard s3 (a DIFFERENT env A shard than the poisoned s0), also applied by env B.
POST_KEY="lb:company:active:{employees:3}:post-${RUNID}"
k exec "$CENTRAL" -- redis-cli XADD "$CENTRAL_STREAM" '*' \
  event_id "menv-post-${RUNID}" op create type string kv_key "$POST_KEY" ts "$(now_ms)" body "post-${RUNID}" >/dev/null
deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
postA=0; postB=0
while (( $(date +%s) < deadline )); do
  postA="$(rrA EXISTS "$POST_KEY" 2>/dev/null | tr -dc '0-9')"; postA="${postA:-0}"
  postB="$(rrB EXISTS "$POST_KEY" 2>/dev/null | tr -dc '0-9')"; postB="${postB:-0}"
  if (( postA == 1 && postB == 1 )); then break; fi
  sleep 3
done

# ── 7. final reads ───────────────────────────────────────────────────────────
FIN_AF_A_S0="$(consumer_field "$DUR_A_S0" '.ack_floor.stream_seq')"
FIN_AF_B="$(consumer_field "$DUR_B" '.ack_floor.stream_seq')"
FIN_DLV_A_S0="$(consumer_field "$DUR_A_S0" '.delivered.stream_seq')"
FIN_DLV_B="$(consumer_field "$DUR_B" '.delivered.stream_seq')"
# every env A shard durable at rest must satisfy O-6 (num_ack_pending<=1)
NAP_MAX=0
for d in "${DUR_A_SHARDS[@]}"; do
  nap="$(consumer_field "$d" '.num_ack_pending')"; nap="${nap:-9}"
  (( nap > NAP_MAX )) && NAP_MAX="$nap"
done

# ── 8. (E) env attribution: ServiceMonitor env external-label relabeling ─────
# P1's env label is a ServiceMonitor relabeling (external-label route), not a raw
# /metrics label. Assert each env's rendered ServiceMonitor carries its env value.
log "=== step 8: env attribution (durable-name + ServiceMonitor relabel) ==="
SM_A_OK=0; SM_B_OK=0
SM_A="$(helm template "$REL_A" ./chart -f "$VALUES_FILE" --set "resourcePrefix=${PREFIX_A}" \
   --set "connect.envId=${ENVA}" --set observability.enabled=true -s templates/observability/servicemonitor.yaml 2>/dev/null || true)"
SM_B="$(helm template "$REL_B" ./chart -f "$VALUES_FILE" --set "resourcePrefix=${PREFIX_B}" \
   --set "connect.envId=${ENVB}" --set observability.enabled=true -s templates/observability/servicemonitor.yaml 2>/dev/null || true)"
echo "$SM_A" | grep -A1 'targetLabel: env' | grep -q "replacement: \"${ENVA}\"" && SM_A_OK=1
echo "$SM_B" | grep -A1 'targetLabel: env' | grep -q "replacement: \"${ENVB}\"" && SM_B_OK=1

# per-env delivered advanced independently (durable-name attribution)
D_DLV_A=$(( FIN_DLV_A_S0 - BASE_DLV_A_S0 )); D_DLV_B=$(( FIN_DLV_B - BASE_DLV_B ))

# ── 9. (F) MANIFEST GATE (optional; self-skipping) ───────────────────────────
GATE_STATUS="skipped"
if [ "$MANIFEST_GATE" != "skip" ]; then
  log "=== step 9: manifest gate (design §7, P2) — MANIFEST_GATE=${MANIFEST_GATE} ==="
  # Enable the topology manifest on the publisher (release A) so it writes
  # cdc_topology/current. This needs the user-provisioned $KV.cdc_topology.> grant
  # (design §7) which the committed lab creds do NOT mint — so we PROBE readability
  # and self-skip if the manifest never materializes.
  helm --kube-context "$CTX" upgrade "$REL_A" ./chart -n "$NS" \
    --reuse-values --set nats.topologyManifest.enabled=true --wait --timeout 4m >/dev/null 2>&1 \
    || log "note: publisher upgrade for the manifest gate returned nonzero (creds may lack \$KV.cdc_topology.> — probing readability next)"
  MANIFEST_READY=0
  gdeadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < gdeadline )); do
    if na kv get cdc_topology current --raw >/dev/null 2>&1; then MANIFEST_READY=1; break; fi
    sleep 3
  done
  if (( MANIFEST_READY == 1 )); then
    # Install a THROWAWAY mismatched sharded sink (envId=envc, wrong N=8). Its
    # external nats-init read hook must FAIL CLOSED on the families drift.
    log "manifest readable — installing mismatched sink envc (N=8 vs publisher N=4), expecting fail-closed"
    set +e
    helm --kube-context "$CTX" upgrade --install menvc ./chart -n "$NS" \
      --set profile=cdc -f "$VALUES_FILE" --set resourcePrefix=envc- \
      --set connect.envId=envc --set connect.source.enabled=false --set writer.enabled=false \
      --set connect.deadLetter.enabled=true --set connect.deadLetter.segment=dlq --set nats.stream.normalSegment=aio \
      --set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}' \
      --set 'connect.sharding.families.lb:company.shards=8' \
      --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company' \
      --set 'connect.sinkGroups[0].shards={0,1,2,3,4,5,6,7,x}' \
      --set connect.sinkGroups[1].name=others --set connect.sinkGroups[1].catchAll=true \
      --set nats.topologyManifest.enabled=true \
      --set nats.external.enabled=true --set "nats.external.url=${NATS_URL}" \
      --set "nats.external.auth.subscriberSecret=${SUBSCRIBER_SECRET}" \
      --set "nats.external.auth.adminSecret=${ADMIN_SECRET}" \
      --wait --timeout 3m >/tmp/menvc_bad.log 2>&1
    BAD_RC=$?
    set -e
    # The pre-install hook Job for release menvc must have failed closed WITH the
    # topology-DRIFT message. A bare nonzero helm rc is NOT accepted as proof: helm
    # fails a hook Job for many unrelated reasons (image pull, RBAC, timeout), and
    # counting any of them as "the manifest gate rejected the drift" would green a run
    # where the gate never actually fired. The DRIFT signal in the hook log is the
    # drift-specific evidence the gate ran and blocked (design §12/§16).
    HOOKLOG="$(k logs -l "job-name" --tail=-1 2>/dev/null | grep -i 'topology DRIFT' || true)"
    if [ -n "$HOOKLOG" ]; then
      log "mismatched sink failed closed with the topology-DRIFT signal (helm rc=${BAD_RC}); ${HOOKLOG}"
      # Correct the mismatch (N=4) → init passes. Uninstall the FAILED release
      # first: helm leaves it in FAILED state and the sinks' wait-consumer
      # initContainers from the bad revision keep their pods (and CPU requests)
      # around, which made the corrected --wait time out on a busy kind node.
      log "correcting envc to N=4 → init must pass"
      helm --kube-context "$CTX" uninstall menvc -n "$NS" --wait >/dev/null 2>&1 || true
      if helm --kube-context "$CTX" upgrade --install menvc ./chart -n "$NS" \
          --set profile=cdc -f "$VALUES_FILE" --set resourcePrefix=envc- \
          --set connect.envId=envc --set connect.source.enabled=false --set writer.enabled=false \
          --set connect.deadLetter.enabled=true --set connect.deadLetter.segment=dlq --set nats.stream.normalSegment=aio \
          --set 'connect.sharding.keyPattern=\{employees:(?P<id>[0-9]+)\}' \
          --set 'connect.sharding.families.lb:company.shards=4' \
          --set connect.sinkGroups[0].name=shard-a --set 'connect.sinkGroups[0].shardsOf=lb:company' \
          --set 'connect.sinkGroups[0].shards={0,1,2,3,x}' \
          --set connect.sinkGroups[1].name=others --set connect.sinkGroups[1].catchAll=true \
          --set nats.topologyManifest.enabled=true \
          --set nats.external.enabled=true --set "nats.external.url=${NATS_URL}" \
          --set "nats.external.auth.subscriberSecret=${SUBSCRIBER_SECRET}" \
          --set "nats.external.auth.adminSecret=${ADMIN_SECRET}" \
          --wait --timeout 4m >/tmp/menvc_ok.log 2>&1; then
        GATE_STATUS="pass"
      else
        GATE_STATUS="fail-corrected-install-did-not-pass"
      fi
    elif (( BAD_RC != 0 )); then
      # helm failed but WITHOUT the drift signal — inconclusive. Do not credit a bare
      # nonzero rc as the manifest gate rejecting the mismatch (it may be an unrelated
      # failure); the case "fail-*" arm in the verdict turns this into an overall FAIL.
      GATE_STATUS="fail-mismatch-rejected-without-drift-signal"
      log "WARN: mismatched sink helm rc=${BAD_RC} but NO 'topology DRIFT' signal in the hook log — cannot attribute the block to the manifest gate (see /tmp/menvc_bad.log)"
    else
      GATE_STATUS="fail-mismatch-was-not-rejected"
    fi
    helm --kube-context "$CTX" uninstall menvc -n "$NS" >/dev/null 2>&1 || true
  else
    GATE_STATUS="skipped-manifest-unreadable"
    log "WARN: ================================================================"
    log "WARN: manifest gate (assertion F) SKIPPED — cdc_topology/current never became"
    log "WARN:   readable. The committed lab creds (gen-nats-auth.sh) do NOT mint the"
    log "WARN:   \$KV.cdc_topology.> grant the manifest publish/read path requires"
    log "WARN:   (design §7). Provision that grant (superset, mirroring the DLQ grant)"
    log "WARN:   and re-run with MANIFEST_GATE=require to prove P2 at L3."
    log "WARN: ================================================================"
  fi
fi

# ── 10. verdict ──────────────────────────────────────────────────────────────
D_LANE_A=$(( la - BASE_LANE_A )); D_LANE_B=$(( lb - BASE_LANE_B ))
D_AF_A_S0=$(( FIN_AF_A_S0 - BASE_AF_A_S0 )); D_AF_B=$(( FIN_AF_B - BASE_AF_B ))

PASS=true; REASONS=""
add_fail() { PASS=false; REASONS="${REASONS}${REASONS:+; }$1"; }
# (A) fan-out
(( ca == TOTAL_NORMAL )) || add_fail "env A region key count ${ca} != ${TOTAL_NORMAL} (fan-out/apply gap)"
(( cb == TOTAL_NORMAL )) || add_fail "env B region key count ${cb} != ${TOTAL_NORMAL} (fan-out/apply gap)"
(( ca == cb ))           || add_fail "env A/B region counts differ (${ca} vs ${cb}) — not a full fan-out copy each"
# (B) disjoint durables
(( B_OK == 1 )) || add_fail "durable set not env-prefixed/disjoint as expected"
# (C) poison cross-park
(( D_LANE_A == 1 )) || add_fail "env A lane delta ${D_LANE_A} != 1"
(( D_LANE_B == 1 )) || add_fail "env B lane delta ${D_LANE_B} != 1 (DEDUP SWALLOW — msg-id not env-scoped?)"
(( MSGID_A_OK == 1 )) || add_fail "env A parked copy missing Nats-Msg-Id dlq.${ENVA}.*"
(( MSGID_B_OK == 1 )) || add_fail "env B parked copy missing Nats-Msg-Id dlq.${ENVB}.*"
(( D_AF_A_S0 >= 1 )) || add_fail "env A shard s0 ack_floor did not advance (${D_AF_A_S0}) — poison blocked it"
(( D_AF_B >= 1 ))    || add_fail "env B durable ack_floor did not advance (${D_AF_B}) — poison blocked it"
# (D) isolation
(( postA == 1 )) || add_fail "post-poison normal absent in env A region (env A shard blocked)"
(( postB == 1 )) || add_fail "post-poison normal absent in env B region (env A poison stalled env B)"
(( NAP_MAX <= 1 )) || add_fail "num_ack_pending ${NAP_MAX} > 1 on an env A shard durable (O-6 violated)"
# (E) env attribution
(( SM_A_OK == 1 )) || add_fail "env A ServiceMonitor missing env=${ENVA} relabeling (P1 external-label route)"
(( SM_B_OK == 1 )) || add_fail "env B ServiceMonitor missing env=${ENVB} relabeling (P1 external-label route)"
(( D_DLV_A >= 1 )) || add_fail "env A durable delivered did not advance (${D_DLV_A}) — no per-env attribution"
(( D_DLV_B >= 1 )) || add_fail "env B durable delivered did not advance (${D_DLV_B}) — no per-env attribution"
# (F) manifest gate
if [ "$MANIFEST_GATE" = "require" ] && [ "$GATE_STATUS" != "pass" ]; then
  add_fail "manifest gate required but status=${GATE_STATUS}"
fi
case "$GATE_STATUS" in fail-*) add_fail "manifest gate regressed: ${GATE_STATUS}";; esac

RESULT="$(printf '{"runid":"%s","ns":"%s","fanout":{"envA":%d,"envB":%d,"want":%d},"durables_disjoint":%d,"lane_delta":{"enva":%d,"envb":%d},"msgid_scoped":{"enva":%d,"envb":%d},"ackfloor_delta":{"enva_s0":%d,"envb":%d},"post_poison":{"enva":%d,"envb":%d},"num_ack_pending_max":%d,"servicemonitor_env":{"enva":%d,"envb":%d},"delivered_delta":{"enva_s0":%d,"envb":%d},"manifest_gate":"%s","pass":%s}' \
  "$RUNID" "$NS" "$ca" "$cb" "$TOTAL_NORMAL" "$B_OK" "$D_LANE_A" "$D_LANE_B" "$MSGID_A_OK" "$MSGID_B_OK" \
  "$D_AF_A_S0" "$D_AF_B" "$postA" "$postB" "$NAP_MAX" "$SM_A_OK" "$SM_B_OK" "$D_DLV_A" "$D_DLV_B" "$GATE_STATUS" "$PASS")"
echo "RESULT_JSON:${RESULT}"

if [ "$PASS" = "true" ]; then
  log "PASS — fan-out to both envs (A=${ca} B=${cb}=${TOTAL_NORMAL}), env-disjoint durables, one poison cross-parked in BOTH lanes (A +${D_LANE_A}, B +${D_LANE_B}) with distinct env-scoped msg-ids and both floors advanced, env A poison did NOT stall env B (post-poison applied in both), O-6 held (num_ack_pending<=1), env attribution present (ServiceMonitor relabel + per-env durable floors), manifest gate=${GATE_STATUS}"
  exit 0
fi
echo "[multi-env] FAIL — ${REASONS}" >&2
NS_LEFT_UP=1
exit 1
