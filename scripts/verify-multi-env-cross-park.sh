#!/usr/bin/env bash
# verify-multi-env-cross-park.sh — L3 kind e2e proving DLQ env-scoping (design
# docs/design/multi-env-mixed-sink/design.md §5.4, E2). Two DLQ-enabled sink envs
# consume ONE shared JetStream stream; a SINGLE poison event must park a SEPARATE
# copy in EACH env's lane — neither dedup-swallowing the other.
#
# Why this is the load-bearing E2 test: JetStream Nats-Msg-Id dedup is stream-wide
# and subject-INDEPENDENT. Poison is a property of the MESSAGE, identical for every
# env, so with a bare shared msg-id (dlq.<event_id>) the SECOND env to park within
# the dupe window gets PubAck{duplicate} — it acks but its parked copy is DISCARDED
# (its lane stays EMPTY while it believes it parked). E2 scopes the msg-id by env
# (dlq.<envId>.<event_id>) so each env stores its OWN copy. This test fails on any
# regression to a bare msg-id: env B's lane would be empty.
#
# Topology (kept as light as E2 allows — two AIO sink releases, NOT sharded, on ONE
# bundled NATS):
#   - Release A (full, bundled NATS + central Redis + its own region Redis): the
#     PUBLISHER + env A's AIO sink, envId=enva, DLQ on (legacy out-of-prefix
#     dlq.cdc, so no segment wiring is needed and the bundled stream binds
#     kv.cdc.>,dlq.cdc.> for us). Owns the shared NATS.
#   - Release B (sink-only): env B's AIO sink, envId=envb, DLQ on, source OFF,
#     writer OFF, its OWN region Redis, pointed at release A's bundled NATS via
#     nats.external.* (reusing release A's minted subscriber/admin creds Secrets —
#     same NATS account). Its external nats-init creates the cdc_sink_envb durable
#     on the already-existing stream.
#   Both AIO durables (cdc_sink_enva, cdc_sink_envb) bind kv.cdc.> and get a full
#   server-side fan-out copy of every event (VF-2).
#
# Assertions on ONE injected poison hash event:
#   1. BOTH lanes get exactly one copy: dlq.cdc.enva.hash_decode_error == +1 AND
#      dlq.cdc.envb.hash_decode_error == +1 (no dedup swallow — the E2 core).
#   2. The two parked copies carry DISTINCT msg-ids: dlq.enva.<eid> vs dlq.envb.<eid>.
#   3. Each env's durable advanced its ack floor past the poison (both unblocked).
#
# Conventions (rules/50-lessons.md): capture-then-grep under pipefail; overridable
# NS/prefixes; verify-dlq-e2e.sh is the modelled pattern, never modified.
#
# Usage:
#   scripts/verify-multi-env-cross-park.sh
#   RRCS_NS=cdc-xpark scripts/verify-multi-env-cross-park.sh
# Exit 0 iff every assertion is green. Success deletes the namespace; failure leaves
# it up for debugging.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-xpark}"
CTX="${RRCS_CONTEXT:-kind-cdc}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
REL_A="${RRCS_RELEASE_A:-xparka}"
REL_B="${RRCS_RELEASE_B:-xparkb}"
PREFIX_A="${RRCS_PREFIX_A:-lab-}"        # release A keeps the values-dev default prefix
PREFIX_B="${RRCS_PREFIX_B:-envb-}"       # release B distinct prefix (same namespace)
ENVA="enva"
ENVB="envb"
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-150}"

STREAM="KV_CDC"
CENTRAL_STREAM="app.events"
REASON="hash_decode_error"
RUNID="$(date +%s)"
PROBE="xpark-natsbox-${RUNID}"

CENTRAL="deploy/${PREFIX_A}redis-central"
NATS_URL="nats://${PREFIX_A}nats:4222"
ADMIN_SECRET="${PREFIX_A}admin-creds"
SUBSCRIBER_SECRET="${PREFIX_A}subscriber-creds"

log() { echo "[xpark] $*"; }
die() { echo "[xpark] FAIL: $*" >&2; NS_LEFT_UP=1; exit 1; }
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
    log "namespace ${NS} LEFT UP for debugging"
  fi
}
trap cleanup EXIT

# ── 0. install release A (publisher + env A AIO sink, bundled NATS) ──────────
if kubectl --context "$CTX" get ns "$NS" >/dev/null 2>&1; then
  log "deleting pre-existing namespace ${NS}"
  kubectl --context "$CTX" delete ns "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
fi
log "=== step 0a: install release A (${REL_A}, envId=${ENVA}, bundled NATS, DLQ legacy) ==="
helm --kube-context "$CTX" upgrade --install "$REL_A" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set "resourcePrefix=${PREFIX_A}" \
  --set "connect.envId=${ENVA}" \
  --set connect.source.enabled=true \
  --set connect.sink.enabled=true \
  --set connect.deadLetter.enabled=true \
  --wait --timeout 6m
for d in connect-source connect-sink; do
  k rollout status "deploy/${PREFIX_A}${d}" --timeout=180s
done

# ── 0b. install release B (sink-only, external -> release A's NATS) ──────────
# Reuse release A's minted subscriber/admin creds Secrets (same NATS account) and
# point at its NATS Service. Source + writer OFF; its own bundled region Redis.
log "=== step 0b: install release B (${REL_B}, envId=${ENVB}, external NATS -> ${NATS_URL}) ==="
helm --kube-context "$CTX" upgrade --install "$REL_B" ./chart -n "$NS" \
  --set profile=cdc -f "$VALUES_FILE" \
  --set "resourcePrefix=${PREFIX_B}" \
  --set "connect.envId=${ENVB}" \
  --set connect.source.enabled=false \
  --set connect.sink.enabled=true \
  --set connect.sink.bootstrap.deliver=new \
  --set connect.deadLetter.enabled=true \
  --set writer.enabled=false \
  --set nats.external.enabled=true \
  --set "nats.external.url=${NATS_URL}" \
  --set "nats.external.auth.subscriberSecret=${SUBSCRIBER_SECRET}" \
  --set "nats.external.auth.adminSecret=${ADMIN_SECRET}" \
  --wait --timeout 6m
k rollout status "deploy/${PREFIX_B}connect-sink" --timeout=180s
sleep 5   # let both electors win + POST pipelines

# ── nats admin helper (release A's admin creds) ──────────────────────────────
log "starting nats-box probe ${PROBE}"
kubectl --context "$CTX" run "$PROBE" -n "$NS" --image=natsio/nats-box:0.14.5 --restart=Never \
  --overrides="{\"spec\":{\"volumes\":[{\"name\":\"c\",\"secret\":{\"secretName\":\"${ADMIN_SECRET}\",\"defaultMode\":292}}],\"containers\":[{\"name\":\"nb\",\"image\":\"natsio/nats-box:0.14.5\",\"command\":[\"sleep\",\"3600\"],\"volumeMounts\":[{\"name\":\"c\",\"mountPath\":\"/creds\",\"readOnly\":true}]}]}}" \
  >/dev/null 2>&1 || die "could not create nats-box probe pod"
k wait --for=condition=Ready "pod/${PROBE}" --timeout=60s >/dev/null 2>&1 || die "nats-box probe not Ready"
na() { k exec "$PROBE" -- nats --server "$NATS_URL" --creds /creds/user.creds "$@"; }

lane_count() { # $1=full subject
  na stream subjects "$STREAM" "$1" --json 2>/dev/null | jq -r --arg s "$1" '.[$s] // 0' 2>/dev/null || echo 0
}
consumer_field() { na consumer info "$STREAM" "$1" --json 2>/dev/null | jq -r "$2"; }

LANE_A="dlq.cdc.${ENVA}.${REASON}"
LANE_B="dlq.cdc.${ENVB}.${REASON}"
DUR_A="cdc_sink_${ENVA}"
DUR_B="cdc_sink_${ENVB}"

# ── 1. baselines ─────────────────────────────────────────────────────────────
log "=== step 1: baselines ==="
BASE_A="$(lane_count "$LANE_A")"; BASE_B="$(lane_count "$LANE_B")"
BASE_AF_A="$(consumer_field "$DUR_A" '.ack_floor.stream_seq')"
BASE_AF_B="$(consumer_field "$DUR_B" '.ack_floor.stream_seq')"
log "baseline lanes: A(${LANE_A})=${BASE_A} B(${LANE_B})=${BASE_B}"

# ── 2. inject ONE poison hash event (parseable JSON array, not an object) ────
log "=== step 2: inject ONE poison hash event into ${CENTRAL_STREAM} ==="
NOW_MS="$(date +%s%3N)"
EID="xpark-${RUNID}"
# argv mode (not stdin) — the poison body contains quotes; redis-cli inline parsing
# would reject them (verify-dlq-e2e.sh:209-217).
k exec "$CENTRAL" -- redis-cli XADD "$CENTRAL_STREAM" '*' \
  event_id "$EID" op create type hash kv_key "xpark::poison::${RUNID}" ts "$NOW_MS" body '["a","b"]' >/dev/null
log "injected poison event_id=${EID}"

# ── 3. settle: BOTH lanes must gain a copy ───────────────────────────────────
log "=== step 3: settle (poll up to ${POLL_TIMEOUT_S}s) ==="
deadline=$(( $(date +%s) + POLL_TIMEOUT_S ))
cur_a="$BASE_A" cur_b="$BASE_B"
while (( $(date +%s) < deadline )); do
  cur_a="$(lane_count "$LANE_A")"; cur_b="$(lane_count "$LANE_B")"
  if (( cur_a >= BASE_A+1 && cur_b >= BASE_B+1 )); then break; fi
  sleep 3
done
sleep 2
cur_a="$(lane_count "$LANE_A")"; cur_b="$(lane_count "$LANE_B")"
FIN_AF_A="$(consumer_field "$DUR_A" '.ack_floor.stream_seq')"
FIN_AF_B="$(consumer_field "$DUR_B" '.ack_floor.stream_seq')"

# ── 4. distinct msg-ids on the two parked copies ─────────────────────────────
log "=== step 4: msg-id disjointness ==="
HDR_A="$(na stream get "$STREAM" -S "$LANE_A" 2>&1 || true)"
HDR_B="$(na stream get "$STREAM" -S "$LANE_B" 2>&1 || true)"
MSGID_A_OK=0; MSGID_B_OK=0
echo "$HDR_A" | grep -qi "Nats-Msg-Id: dlq.${ENVA}." && MSGID_A_OK=1
echo "$HDR_B" | grep -qi "Nats-Msg-Id: dlq.${ENVB}." && MSGID_B_OK=1

# ── 5. verdict ───────────────────────────────────────────────────────────────
D_A=$(( cur_a - BASE_A )); D_B=$(( cur_b - BASE_B ))
D_AF_A=$(( FIN_AF_A - BASE_AF_A )); D_AF_B=$(( FIN_AF_B - BASE_AF_B ))
PASS=true; REASONS=""
add_fail() { PASS=false; REASONS="${REASONS}${REASONS:+; }$1"; }
(( D_A == 1 )) || add_fail "env A lane delta ${D_A} != 1"
(( D_B == 1 )) || add_fail "env B lane delta ${D_B} != 1 (DEDUP SWALLOW — msg-id not env-scoped?)"
(( MSGID_A_OK == 1 )) || add_fail "env A parked copy missing Nats-Msg-Id dlq.${ENVA}.*"
(( MSGID_B_OK == 1 )) || add_fail "env B parked copy missing Nats-Msg-Id dlq.${ENVB}.*"
(( D_AF_A >= 1 )) || add_fail "env A durable ack_floor did not advance (${D_AF_A})"
(( D_AF_B >= 1 )) || add_fail "env B durable ack_floor did not advance (${D_AF_B})"

RESULT="$(printf '{"runid":"%s","ns":"%s","event_id":"%s","envA_lane_delta":%d,"envB_lane_delta":%d,"msgid_A_scoped":%d,"msgid_B_scoped":%d,"ackfloor_delta":{"enva":%d,"envb":%d},"pass":%s}' \
  "$RUNID" "$NS" "$EID" "$D_A" "$D_B" "$MSGID_A_OK" "$MSGID_B_OK" "$D_AF_A" "$D_AF_B" "$PASS")"
echo "RESULT_JSON:${RESULT}"

if [ "$PASS" = "true" ]; then
  log "PASS — one poison event parked a SEPARATE copy in BOTH env lanes (A +${D_A}, B +${D_B}), distinct env-scoped msg-ids, both durables advanced (no dedup swallow — E2 holds)"
  exit 0
fi
echo "[xpark] FAIL — ${REASONS}" >&2
NS_LEFT_UP=1
exit 1
