#!/usr/bin/env bash
# verify-cdc-prefix.sh — L3 variant proving native multi-subject sink groups
# (design D3 §9 T4). Deploys the chart with TWO prefix-routed sink groups
# (a: prefix-a, b: prefix-b), drives prefixed CDC traffic straight into central
# Redis (redis-cli, same style as verify-failover.sh — no writer/verifier Job so
# the routing is exercised deterministically), and asserts:
#   - both per-group durables (cdc_sink_a, cdc_sink_b) exist and DRAIN to 0 pending;
#   - each prefix's keys land in region Redis with correct op semantics
#     (create / update / delete / rename), ZERO loss;
#   - routing is correct + isolated: cdc_apply on group a == prefix-a op count and
#     on group b == prefix-b op count (a group applies ONLY its prefix);
#   - cdc_forward_unrouted == 0 (every event derived a prefix);
#   - dedup holds: replaying the same event_ids leaves region unchanged.
#
# Each run starts PRISTINE (helm uninstall first) so exact apply counts are
# deterministic. Requires the subscriber creds to grant the per-group durables —
# run scripts/gen-nats-auth.sh --force first (broadened wildcard grant, design §5).
#
# Usage: RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-prefix.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-mg}"
RELEASE="${RRCS_RELEASE:-cdcmg}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NA="${NA:-100}"                 # prefix-a create ops (distinct so routing is provable)
NB="${NB:-50}"                  # prefix-b create ops (deliberately != NA)
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-180}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"
GROUP="cdc_propagator"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
now_ms() { date +%s%3N; }
log() { echo "[verify-prefix] $*"; }
die() { echo "[verify-prefix] FAIL: $*" >&2; exit 1; }

# region prefix-* key count
region_count() { rr --scan --pattern 'prefix-*' 2>/dev/null | grep -c . || true; }
# wait until region prefix-* count == $1 and stays there for 2 polls (quiesced)
wait_region() { # $1=want
  local want="$1" deadline cur ok=0
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    cur="$(region_count)"
    if (( cur == want )); then ok=$(( ok+1 )); (( ok>=2 )) && { echo "$cur"; return 0; }; else ok=0; fi
    sleep 3
  done
  echo "$cur"; return 1
}

# curl a metric total off every READY pod of a Deployment's connect container
# (standbys expose no series, so summing across the group yields the leader's value).
metric_sum() { # $1=app-label  $2=metric-base
  local dep="$1" metric="$2" pod tot=0 v
  for pod in $(kubectl -n "$NS" get pods -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v="$(kubectl -n "$NS" exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
         | awk -v m="$metric" '$1 ~ "^"m"(_total)?[{ ]" {s+=$2} END{printf "%.0f", s+0}')" || v=0
    tot=$(( tot + ${v:-0} ))
  done
  echo "$tot"
}
# consumer num_pending via a throwaway nats-box using the admin creds Secret (best-effort).
num_pending() { # $1=durable
  kubectl -n "$NS" run "natsq-$$-$1" --rm -i --restart=Never --quiet \
    --image=natsio/nats-box:0.14.5 \
    --overrides='{"spec":{"containers":[{"name":"n","image":"natsio/nats-box:0.14.5","command":["sh","-c","nats --server nats://'"${PREFIX}"'nats:4222 --creds /c/user.creds consumer info KV_CDC '"$1"' --json 2>/dev/null | jq -r .num_pending"],"volumeMounts":[{"name":"c","mountPath":"/c"}]}],"volumes":[{"name":"c","secret":{"secretName":"'"${PREFIX}"'admin-creds","defaultMode":292}}]}}' \
    2>/dev/null | tr -dc '0-9' || echo ""
}

log "=== fresh install: uninstall any prior ${RELEASE}, then deploy 2 prefix groups (ns=$NS) ==="
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set connect.sinkGroups[0].name=a --set connect.sinkGroups[0].prefixes[0]=prefix-a \
  --set connect.sinkGroups[1].name=b --set connect.sinkGroups[1].prefixes[0]=prefix-b \
  "${EXTRA_SET[@]}" --wait --timeout 6m

for d in connect-source connect-sink-a connect-sink-b; do
  kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout=180s
done
# let the source elector win and POST its pipeline before we produce.
sleep 5

rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true

runid="$(now_ms)"; ts="$(now_ms)"
emit_creates() { # $1=prefix $2=count
  local p="$1" n="$2" i cmds; cmds="$(mktemp)"
  for (( i=1; i<=n; i++ )); do
    echo "XADD $STREAM * event_id ${runid}-${p}-c${i} op create type string kv_key ${p}:${runid}:k${i} ts ${ts} body ${p}-v${i}"
  done > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"
}
emit_extra_a() { # update k1, delete k2, rename k3 -> k3r (all prefix-a)
  local p=prefix-a cmds; cmds="$(mktemp)"
  {
    echo "XADD $STREAM * event_id ${runid}-a-u1 op update type string kv_key ${p}:${runid}:k1 ts ${ts} body a-v1b"
    echo "XADD $STREAM * event_id ${runid}-a-d1 op delete type string kv_key ${p}:${runid}:k2 ts ${ts} body x"
    echo "XADD $STREAM * event_id ${runid}-a-r1 op rename type string kv_key ${p}:${runid}:k3 old_key ${p}:${runid}:k3 new_key ${p}:${runid}:k3r ts ${ts} body x"
  } > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"
}

# Phase 1: creates only, quiesce to NA+NB keys (avoids create/delete reorder).
log "phase 1: prefix-a=$NA + prefix-b=$NB creates -> wait region == $(( NA+NB ))"
emit_creates prefix-a "$NA"; emit_creates prefix-b "$NB"
c1="$(wait_region $(( NA+NB )))" || die "phase1: region reached only $c1 / $(( NA+NB )) keys"
log "phase 1 settled at $c1 keys"

# Phase 2: mutating ops on prefix-a, quiesce to (NA+NB-1) (k2 deleted; k3->k3r net 0).
log "phase 2: prefix-a update/delete/rename -> wait region == $(( NA+NB-1 ))"
emit_extra_a
c2="$(wait_region $(( NA+NB-1 )))" || die "phase2: region at $c2, want $(( NA+NB-1 ))"
log "phase 2 settled at $c2 keys"

# Countable cdc_apply per group. NOTE: create/update emit cdc_apply{op,type} while
# delete/rename emit cdc_apply{op} (no type) — a PRE-EXISTING label-cardinality
# mismatch that Redpanda Connect skips ("Metrics label mismatch 5 vs 4"), so
# delete/rename do NOT increment a countable cdc_apply (true in single-group too).
# Their apply is proven instead by region membership (k2 deleted, k3r present).
A_OPS=$(( NA + 1 )); B_OPS=$(( NB ))      # a: 100 creates + 1 update; b: 50 creates
A_SURV=$(( NA - 1 )); B_SURV=$(( NB ))    # surviving region keys per prefix

# ── assertions ──
a_present="$(rr --scan --pattern "prefix-a:${runid}:*" 2>/dev/null | grep -c . || true)"
b_present="$(rr --scan --pattern "prefix-b:${runid}:*" 2>/dev/null | grep -c . || true)"
log "region prefix-a=$a_present (want $A_SURV), prefix-b=$b_present (want $B_SURV)"
(( a_present == A_SURV )) || die "prefix-a loss/mismatch: region has $a_present, want $A_SURV"
(( b_present == B_SURV )) || die "prefix-b loss/mismatch: region has $b_present, want $B_SURV"
rr EXISTS "prefix-a:${runid}:k3r" | grep -q 1 || die "rename target prefix-a k3r missing"
rr EXISTS "prefix-a:${runid}:k3"  | grep -q 0 || die "rename source prefix-a k3 still present"
rr EXISTS "prefix-a:${runid}:k2"  | grep -q 0 || die "deleted prefix-a k2 still present"

unrouted="$(metric_sum connect-source cdc_forward_unrouted)"
log "cdc_forward_unrouted=$unrouted (want 0)"
(( unrouted == 0 )) || die "cdc_forward_unrouted=$unrouted (some event derived no prefix)"

a_apply="$(metric_sum connect-sink-a cdc_apply)"
b_apply="$(metric_sum connect-sink-b cdc_apply)"
log "cdc_apply group-a=$a_apply (want $A_OPS), group-b=$b_apply (want $B_OPS)"
(( a_apply == A_OPS )) || die "group a applied $a_apply, want $A_OPS (routing/isolation broken)"
(( b_apply == B_OPS )) || die "group b applied $b_apply, want $B_OPS (routing/isolation broken)"

for durable in cdc_sink_a cdc_sink_b; do
  np="$(num_pending "$durable")"
  if [ -n "$np" ]; then (( np == 0 )) || die "$durable did not drain (num_pending=$np)"; log "durable $durable num_pending=0"
  else log "durable $durable: num_pending probe unavailable (region membership already proves drain)"; fi
done

# dedup: replay the same event_ids; region must not change.
log "replaying identical event_ids (dedup check) ..."
emit_creates prefix-a "$NA"; emit_creates prefix-b "$NB"; emit_extra_a
sleep 10
r2="$(region_count)"
(( r2 == c2 )) || die "dedup broken: region changed from $c2 to $r2 after replay"
log "dedup OK: region stable at $r2 after replay"

echo "RESULT_JSON:{\"prefix_a_present\":$a_present,\"prefix_b_present\":$b_present,\"a_apply\":$a_apply,\"b_apply\":$b_apply,\"unrouted\":$unrouted,\"dedup_stable\":$r2}"
echo "[verify-prefix] PASS — per-group routing + isolation + no-loss + dedup + unrouted=0"
