#!/usr/bin/env bash
# verify-cdc-twoseg.sh — L3 variant proving FIRST-TWO-SEGMENT key-prefix routing
# plus the "others" catch-all (docs/requests/first-two-seg-routing.md). Deploys
# the chart with THREE sink groups — caveat (tg:caveat), g2m (tg:g2m), others
# (catchAll) — drives prefixed CDC traffic straight into central Redis
# (redis-cli, deterministic; no writer/verifier Job), and asserts:
#   - two-seg routing + ISOLATION: cdc_apply on group caveat == tg:caveat op
#     count, on g2m == tg:g2m op count (a group applies ONLY its prefix);
#   - catch-all: keys matching NO configured prefix (tg:stray:*, misc:*) land in
#     region via the others group; cdc_apply(others) == their count and
#     cdc_forward_others == their count (reason=no_match is ROUTED, not parked);
#   - cdc_forward_unrouted == 0 (no malformed keys were produced);
#   - op semantics on a two-seg family (update/delete/rename on tg:caveat),
#     ZERO loss, and dedup (replaying identical event_ids changes nothing).
# Each run starts PRISTINE (helm uninstall first) so exact counts are
# deterministic. Needs the wildcard subscriber grant (already committed).
# Usage: RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-twoseg.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-mg}"
RELEASE="${RRCS_RELEASE:-cdcmg}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NC="${NC:-80}"                  # tg:caveat creates
NG="${NG:-40}"                  # tg:g2m creates (deliberately != NC)
NS1="${NS1:-20}"                # tg:stray creates  -> others (2-seg miss)
NS2="${NS2:-10}"                # misc creates      -> others (1-seg miss)
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
log() { echo "[verify-twoseg] $*"; }
die() { echo "[verify-twoseg] FAIL: $*" >&2; exit 1; }

cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }   # $1=pattern
# every test key embeds ":${runid}:" (misc included), so this counts them all
region_total() { cnt "*:${runid}:*"; }
wait_region() { # $1=want — settle when the count holds for 2 polls
  local want="$1" deadline cur ok=0
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    cur="$(region_total)"
    if (( cur == want )); then ok=$(( ok+1 )); (( ok>=2 )) && { echo "$cur"; return 0; }; else ok=0; fi
    sleep 3
  done
  echo "$cur"; return 1
}
# sum a metric across every pod of a Deployment's connect container (standbys
# expose no series, so the sum equals the leader's value)
metric_sum() { # $1=app-label  $2=metric-base
  local dep="$1" metric="$2" pod tot=0 v
  for pod in $(kubectl -n "$NS" get pods -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v="$(kubectl -n "$NS" exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
         | awk -v m="$metric" '$1 ~ "^"m"(_total)?[{ ]" {s+=$2} END{printf "%.0f", s+0}')" || v=0
    tot=$(( tot + ${v:-0} ))
  done
  echo "$tot"
}

log "=== fresh install: caveat(tg:caveat) + g2m(tg:g2m) + others(catchAll) (ns=$NS) ==="
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set connect.sinkGroups[0].name=caveat --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat' \
  --set connect.sinkGroups[1].name=g2m    --set 'connect.sinkGroups[1].prefixes[0]=tg:g2m' \
  --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true \
  "${EXTRA_SET[@]}" --wait --timeout 6m

for d in connect-source connect-sink-caveat connect-sink-g2m connect-sink-others; do
  kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout=180s
done
# let the electors win and POST their pipelines before producing
sleep 5

rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true

runid="$(now_ms)"; ts="$(now_ms)"
emit_creates() { # $1=key-prefix (e.g. tg:caveat)  $2=count  $3=id-tag
  local p="$1" n="$2" tag="$3" i cmds; cmds="$(mktemp)"
  for (( i=1; i<=n; i++ )); do
    echo "XADD $STREAM * event_id ${runid}-${tag}-c${i} op create type string kv_key ${p}:${runid}:k${i} ts ${ts} body ${tag}-v${i}"
  done > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"
}
emit_extra_caveat() { # update k1, delete k2, rename k3 -> k3r (all tg:caveat)
  local p="tg:caveat" cmds; cmds="$(mktemp)"
  {
    echo "XADD $STREAM * event_id ${runid}-cv-u1 op update type string kv_key ${p}:${runid}:k1 ts ${ts} body cv-v1b"
    echo "XADD $STREAM * event_id ${runid}-cv-d1 op delete type string kv_key ${p}:${runid}:k2 ts ${ts} body x"
    echo "XADD $STREAM * event_id ${runid}-cv-r1 op rename type string kv_key ${p}:${runid}:k3 old_key ${p}:${runid}:k3 new_key ${p}:${runid}:k3r ts ${ts} body x"
  } > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"
}

T1=$(( NC + NG + NS1 + NS2 ))
log "phase 1: creates — tg:caveat=$NC tg:g2m=$NG tg:stray=$NS1 misc=$NS2 -> wait region == $T1"
emit_creates "tg:caveat" "$NC"  cv
emit_creates "tg:g2m"    "$NG"  gm
emit_creates "tg:stray"  "$NS1" st
emit_creates "misc"      "$NS2" ms
c1="$(wait_region "$T1")" || die "phase1: region reached only $c1 / $T1 keys"
log "phase 1 settled at $c1 keys"

T2=$(( T1 - 1 ))   # k2 deleted; k3->k3r is net 0
log "phase 2: tg:caveat update/delete/rename -> wait region == $T2"
emit_extra_caveat
c2="$(wait_region "$T2")" || die "phase2: region at $c2, want $T2"
log "phase 2 settled at $c2 keys"

# Countable cdc_apply per group. NOTE (pre-existing, single-group too):
# delete/rename emit cdc_apply{op} while create/update emit cdc_apply{op,type};
# Connect skips the mismatched series, so delete/rename are NOT countable —
# their apply is proven by region membership (k2 gone, k3r present).
CV_OPS=$(( NC + 1 )); GM_OPS=$(( NG )); OT_OPS=$(( NS1 + NS2 ))

# ── assertions ──
cv_present="$(cnt "tg:caveat:${runid}:*")"
gm_present="$(cnt "tg:g2m:${runid}:*")"
st_present="$(cnt "tg:stray:${runid}:*")"
ms_present="$(cnt "misc:${runid}:*")"
log "region: caveat=$cv_present/$(( NC-1 )) g2m=$gm_present/$NG stray=$st_present/$NS1 misc=$ms_present/$NS2"
(( cv_present == NC - 1 )) || die "tg:caveat loss/mismatch: region has $cv_present, want $(( NC-1 ))"
(( gm_present == NG ))     || die "tg:g2m loss/mismatch: region has $gm_present, want $NG"
(( st_present == NS1 ))    || die "tg:stray (others) loss: region has $st_present, want $NS1"
(( ms_present == NS2 ))    || die "misc (others) loss: region has $ms_present, want $NS2"
rr EXISTS "tg:caveat:${runid}:k3r" | grep -q 1 || die "rename target k3r missing"
rr EXISTS "tg:caveat:${runid}:k3"  | grep -q 0 || die "rename source k3 still present"
rr EXISTS "tg:caveat:${runid}:k2"  | grep -q 0 || die "deleted k2 still present"

unrouted="$(metric_sum connect-source cdc_forward_unrouted)"
others_m="$(metric_sum connect-source cdc_forward_others)"
log "cdc_forward_unrouted=$unrouted (want 0), cdc_forward_others=$others_m (want $OT_OPS)"
(( unrouted == 0 ))       || die "cdc_forward_unrouted=$unrouted (malformed key or routing regression)"
(( others_m == OT_OPS ))  || die "cdc_forward_others=$others_m, want $OT_OPS (catch-all accounting broken)"

cv_apply="$(metric_sum connect-sink-caveat cdc_apply)"
gm_apply="$(metric_sum connect-sink-g2m    cdc_apply)"
ot_apply="$(metric_sum connect-sink-others cdc_apply)"
log "cdc_apply caveat=$cv_apply/$CV_OPS g2m=$gm_apply/$GM_OPS others=$ot_apply/$OT_OPS"
(( cv_apply == CV_OPS )) || die "group caveat applied $cv_apply, want $CV_OPS (routing/isolation broken)"
(( gm_apply == GM_OPS )) || die "group g2m applied $gm_apply, want $GM_OPS (routing/isolation broken)"
(( ot_apply == OT_OPS )) || die "group others applied $ot_apply, want $OT_OPS (catch-all broken)"

# dedup: replay the same event_ids; region must not change
log "replaying identical event_ids (dedup check) ..."
emit_creates "tg:caveat" "$NC"  cv
emit_creates "tg:g2m"    "$NG"  gm
emit_creates "tg:stray"  "$NS1" st
emit_creates "misc"      "$NS2" ms
emit_extra_caveat
sleep 10
r2="$(region_total)"
(( r2 == c2 )) || die "dedup broken: region changed from $c2 to $r2 after replay"
log "dedup OK: region stable at $r2 after replay"

echo "RESULT_JSON:{\"caveat_present\":$cv_present,\"g2m_present\":$gm_present,\"others_present\":$(( st_present + ms_present )),\"cv_apply\":$cv_apply,\"gm_apply\":$gm_apply,\"ot_apply\":$ot_apply,\"unrouted\":$unrouted,\"forward_others\":$others_m,\"dedup_stable\":$r2}"
echo "[verify-twoseg] PASS — two-seg routing + others catch-all + isolation + no-loss + dedup"
