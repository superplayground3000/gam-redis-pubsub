#!/usr/bin/env bash
# kill-standby.sh — phase 3 (control): force-kill one NON-leader pod on each
# Connect leg during traffic; assert both Lease holders are unchanged and the
# region ends with ALL N keys.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

N="${N_STANDBY:-2000}"
SINK_TIMEOUT_S="${SINK_TIMEOUT_S:-300}"

runid="$(now_ms)"
hs="$(holder "$SRC_LEASE")";  [[ -n "$hs" ]] || die "no source lease holder"
hk="$(holder "$SINK_LEASE")"; [[ -n "$hk" ]] || die "no sink lease holder"

# standby_of <deploy-basename> <holder> — any pod of that leg that is not the holder
standby_of() {
  kubectl -n "$NS" get pods -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' \
    | grep "^${PREFIX}$1-" | grep -vx "$2" | head -1
}
ss="$(standby_of connect-source "$hs")"; [[ -n "$ss" ]] || die "no source standby pod found"
sk="$(standby_of connect-sink "$hk")";   [[ -n "$sk" ]] || die "no sink standby pod found"

log "leaders src=$hs sink=$hk; killing standbys src=$ss sink=$sk during N=$N traffic (runid=$runid)"
xadd_batch "$runid" "$N" standby &
XPID=$!
kubectl -n "$NS" delete pod "$ss" "$sk" --grace-period=0 --force >/dev/null 2>&1 || true
wait "$XPID" || die "background xadd_batch failed (traffic generation aborted)"

# verify the kill took effect: kubectl wait --for=delete treats only real
# deletion/NotFound as success, so a transient API error cannot fake
# disappearance (it makes wait fail -> loud die), unlike a bare `get` poll.
kubectl -n "$NS" wait --for=delete "pod/$ss" "pod/$sk" --timeout=60s >/dev/null 2>&1 \
  || die "killed standby pods still present after 60s — kill did not take effect"
log "kill verified: $ss and $sk are gone"

sleep 5
[[ "$(holder "$SRC_LEASE")" == "$hs" ]] || die "source leadership moved after standby kill (was $hs, now $(holder "$SRC_LEASE"))"
[[ "$(holder "$SINK_LEASE")" == "$hk" ]] || die "sink leadership moved after standby kill (was $hk, now $(holder "$SINK_LEASE"))"

final="$(wait_region_full "$runid" standby "$N" "$SINK_TIMEOUT_S")"
loss=$(( N - final ))
log "region has ${final}/${N} keys (loss=${loss})"
(( loss == 0 )) || die "lost ${loss} messages after standby SIGKILL"
log "PASS — zero loss, leadership stable after standby SIGKILL (N=${N})"
