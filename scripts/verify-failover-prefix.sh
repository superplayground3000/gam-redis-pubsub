#!/usr/bin/env bash
# verify-failover-prefix.sh — L4 variant proving per-group SINK failover isolation
# for native multi-subject sink groups (design D3 §9 T5, §6 / INV-1 rows 6/7/10 per
# group). Deploys the chart with TWO prefix sink groups (a: prefix-a, b: prefix-b),
# bursts prefixed traffic, then SIGKILLs the ACTIVE sink pod of group a mid-flight
# (while its durable still has un-acked/undelivered work) and asserts:
#   - group a recovers: a standby wins the Lease, re-binds the SAME stable durable
#     cdc_sink_a (bind:true, role-scoped — never pod-scoped), and JetStream
#     redelivers the un-acked PEL (maxDeliver=-1) => ZERO loss for prefix-a;
#   - ISOLATION: group b (cdc_sink_b) is untouched — its leader pod never changes
#     and every prefix-b key still lands (no loss), proving one group's failover
#     does not disturb another's.
#
# Unlike verify-failover.sh (source leg, pod-scoped-id loss baseline), the sink
# durable is ALWAYS stable, so this is single-sided: the design is that a sink
# failover never loses. The NEW properties under test are per-group replay + isolation.
#
# Requires the wildcard subscriber grant (scripts/gen-nats-auth.sh --force, §5).
# Usage: RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-failover-prefix.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-mg}"
RELEASE="${RRCS_RELEASE:-cdcmg}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NA="${NA:-20000}"                 # prefix-a burst — big enough that the sink is still
                                  # draining when we arm (a pollable mid-flight window)
NB="${NB:-3000}"                  # prefix-b burst (isolation channel)
ARM_LO="${ARM_LO:-2000}"          # kill once region prefix-a is in (ARM_LO, ARM_HI):
ARM_HI_FRAC="${ARM_HI_FRAC:-70}"  #   partway through, so >=1 msg is un-acked at kill
ARM_TIMEOUT_S="${ARM_TIMEOUT_S:-90}"
FAILOVER_TIMEOUT_S="${FAILOVER_TIMEOUT_S:-120}"
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-300}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"; GROUP="cdc_propagator"
LEASE_A="${PREFIX}connect-sink-a-elector"
LEASE_B="${PREFIX}connect-sink-b-elector"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
holder() { kubectl -n "$NS" get lease "$1" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
now_ms() { date +%s%3N; }
cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }   # $1=pattern
log() { echo "[failover-prefix] $*"; }
die() { echo "[failover-prefix] FAIL: $*" >&2; exit 1; }

log "=== fresh install: 2 prefix sink groups (ns=$NS) ==="
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set connect.sinkGroups[0].name=a --set connect.sinkGroups[0].prefixes[0]=prefix-a \
  --set connect.sinkGroups[1].name=b --set connect.sinkGroups[1].prefixes[0]=prefix-b \
  "${EXTRA_SET[@]}" --wait --timeout 6m || die "helm install failed"
for d in connect-source connect-sink-a connect-sink-b; do
  kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout=180s || die "$d rollout"
done
sleep 5
rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true

# record group b's leader up front — isolation means it must NOT change across a's kill.
B_LEADER_BEFORE="$(holder "$LEASE_B")"
log "group-b leader (must be stable): $B_LEADER_BEFORE"

runid="$(now_ms)"; ts="$(now_ms)"
burst() { # $1=prefix $2=count
  local p="$1" n="$2" i cmds; cmds="$(mktemp)"
  for (( i=1; i<=n; i++ )); do
    echo "XADD $STREAM * event_id ${runid}-${p}-${i} op create type string kv_key ${p}:${runid}:k${i} ts ${ts} body ${p}-v${i}"
  done > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"
}
log "producing prefix-a=$NA + prefix-b=$NB creates"
burst prefix-a "$NA"; burst prefix-b "$NB"

# arm: kill group a's leader while region prefix-a is partway (still draining).
ARM_HI=$(( NA * ARM_HI_FRAC / 100 ))
log "arming: wait until region prefix-a in ($ARM_LO, $ARM_HI) then SIGKILL group-a leader"
victim=""; deadline=$(( $(date +%s) + ARM_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  a="$(cnt "prefix-a:${runid}:*")"
  if (( a > ARM_LO && a < ARM_HI )); then victim="$(holder "$LEASE_A")"; [[ -n "$victim" ]] && break; fi
  (( a >= ARM_HI )) && die "prefix-a drained past arm window before kill (raise NA / lower ARM_HI) — got $a"
  sleep 0.5
done
[[ -n "$victim" ]] || die "could not arm within ${ARM_TIMEOUT_S}s"
a_at_kill="$(cnt "prefix-a:${runid}:*")"; b_at_kill="$(cnt "prefix-b:${runid}:*")"
log "SIGKILL group-a leader $victim (region prefix-a=$a_at_kill, prefix-b=$b_at_kill at kill)"
kubectl -n "$NS" delete pod "$victim" --grace-period=0 --force >/dev/null 2>&1 || true

# group a must fail over to a NEW leader.
deadline=$(( $(date +%s) + FAILOVER_TIMEOUT_S )); newA=""
until nh="$(holder "$LEASE_A")"; [[ -n "$nh" && "$nh" != "$victim" ]]; do
  (( $(date +%s) < deadline )) || die "group-a: no new lease holder after kill"
  sleep 2
done
newA="$(holder "$LEASE_A")"
log "group-a failed over: $victim -> $newA"

# settle: region stops growing.
log "waiting for region to settle (stop growing) ..."
prev=-1; stable=0; deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  cur="$(cnt "prefix-*")"
  if (( cur == prev )); then stable=$(( stable+1 )); (( stable>=3 )) && break; else stable=0; fi
  prev="$cur"; sleep 3
done

a_final="$(cnt "prefix-a:${runid}:*")"; b_final="$(cnt "prefix-b:${runid}:*")"
B_LEADER_AFTER="$(holder "$LEASE_B")"
log "final: prefix-a=$a_final/$NA, prefix-b=$b_final/$NB; group-b leader $B_LEADER_BEFORE -> $B_LEADER_AFTER"

result="$(printf '{"runid":"%s","victim":"%s","new_a_leader":"%s","a_at_kill":%d,"a_final":%d,"na":%d,"b_final":%d,"nb":%d,"b_leader_stable":%s}' \
  "$runid" "$victim" "$newA" "$a_at_kill" "$a_final" "$NA" "$b_final" "$NB" \
  "$([[ "$B_LEADER_BEFORE" == "$B_LEADER_AFTER" ]] && echo true || echo false)")"
echo "RESULT_JSON:${result}"

# ── assertions ──
(( a_final == NA )) || die "group-a LOST messages after SIGKILL: region prefix-a=$a_final, want $NA (durable replay failed)"
(( b_final == NB )) || die "group-b LOST messages during group-a failover: prefix-b=$b_final, want $NB (isolation broken)"
[[ "$B_LEADER_BEFORE" == "$B_LEADER_AFTER" ]] || die "group-b leadership changed ($B_LEADER_BEFORE -> $B_LEADER_AFTER) during group-a kill (isolation broken)"
(( a_at_kill < NA )) || log "WARN: prefix-a already complete at kill — replay window not exercised (raise NA)"

echo "[failover-prefix] PASS — group-a durable replayed with ZERO loss after SIGKILL; group-b unaffected (isolation held)"
