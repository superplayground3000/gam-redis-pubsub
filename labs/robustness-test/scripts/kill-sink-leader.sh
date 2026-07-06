#!/usr/bin/env bash
# kill-sink-leader.sh — phase 2: force-kill the SINK-leg leader while messages
# are in flight; assert a new Lease holder appears and region KV ends with ALL
# N keys (zero loss; JetStream ackWait redelivery covers the killed pod's
# un-acked batch). Exit 0 pass / 1 fail / 3 inconclusive (retry).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

N="${N_SINKKILL:-5000}"
SINK_TIMEOUT_S="${SINK_TIMEOUT_S:-300}"
FAILOVER_TIMEOUT_S="${FAILOVER_TIMEOUT_S:-120}"

runid="$(now_ms)"
h="$(holder "$SINK_LEASE")"; [[ -n "$h" ]] || die "no sink lease holder"
log "sink leader: $h; producing N=$N (runid=$runid)"
xadd_batch "$runid" "$N" sinkkill

# Arm: kill only while the sink is mid-flight (some but not all keys applied).
deadline=$(( $(date +%s) + FAILOVER_TIMEOUT_S ))
cur=0
while :; do
  cur="$(region_count "$runid" sinkkill)"
  (( cur > 0 )) && break
  (( $(date +%s) < deadline )) || die "sink applied nothing within ${FAILOVER_TIMEOUT_S}s"
  sleep 1
done
(( cur < N )) || { log "INCONCLUSIVE: sink finished all $N before the kill — raise N_SINKKILL"; exit 3; }
[[ "$(holder "$SINK_LEASE")" == "$h" ]] || { log "INCONCLUSIVE: sink leadership moved before kill"; exit 3; }

log "SIGKILL sink leader $h at region_count=${cur}/${N}"
kubectl -n "$NS" delete pod "$h" --grace-period=0 --force >/dev/null 2>&1 || true

nh="$(wait_new_holder "$SINK_LEASE" "$h" "$FAILOVER_TIMEOUT_S")" || die "no new sink lease holder within ${FAILOVER_TIMEOUT_S}s"
log "new sink leader: $nh"

final="$(wait_region_full "$runid" sinkkill "$N" "$SINK_TIMEOUT_S")"
loss=$(( N - final ))
log "region has ${final}/${N} keys (loss=${loss})"
(( loss == 0 )) || die "lost ${loss} messages after sink-leader SIGKILL"
log "PASS — zero loss after sink-leader SIGKILL (N=${N})"
