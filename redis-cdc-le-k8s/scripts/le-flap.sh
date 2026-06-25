#!/usr/bin/env bash
# le-flap.sh — measure leadership FLAP onset under control-plane latency for ONE leg.
#
# Why: failover latency alone makes "smaller LeaseDuration is always better" look free.
# It is not. The cost of tight timing is reduced tolerance for apiserver latency / GC
# pauses: a leader that cannot renew its Lease within RenewDeadline voluntarily steps
# down (anti-split-brain) — a FLAP — even though nothing crashed. This script induces
# that condition directly and finds the delay at which each config starts flapping.
#
# Method: inject egress netem delay on the CURRENT leader pod's eth0 (its renew traffic
# to the apiserver), watch the Lease for LEASE_TRANSITIONS increments while the leader
# pod stays alive, then remove the delay. Targeted to one pod's netns (nsenter), fully
# revertible. The leader pod is NEVER killed here — any holder change is a pure
# renew-deadline flap.
#
# Prediction: a renew RTT of ~D forces a flap once D approaches RenewDeadline. So tight
# (RenewDeadline=2s) flaps at smaller D than default (4s) than stock (10s).
#
# Usage:
#   NS=cdc-k8s CTX=kind-cdc NODE=cdc-control-plane LEASE=lab-connect-source-elector \
#   APP=connect-source CONFIG=default DELAYS="1500 2500 4500" OBSERVE=20 \
#   OUT=reports/le/flap.csv scripts/le-flap.sh
set -euo pipefail

NS="${NS:-cdc-k8s}"; CTX="${CTX:-kind-cdc}"; NODE="${NODE:-cdc-control-plane}"
LEASE="${LEASE:?LEASE required}"; APP="${APP:?APP required}"; CONFIG="${CONFIG:?CONFIG required}"
DELAYS="${DELAYS:-1500 2500 4500}"   # ms egress delay points to probe
OBSERVE="${OBSERVE:-20}"             # s to watch for a flap at each delay
OUT="${OUT:?OUT required}"
K="kubectl --context ${CTX} -n ${NS}"

mkdir -p "$(dirname "${OUT}")"
[[ -f "${OUT}" ]] || echo "config,leg,lease,renew_deadline_s,delay_ms,flapped,transitions_delta,holder_before,holder_after,observe_s" > "${OUT}"

RENEW_DL=$(${K} get deploy -l "app=${APP}" -o jsonpath='{.items[0].spec.template.spec.containers[?(@.name=="elector")].env[?(@.name=="RENEW_DEADLINE")].value}' 2>/dev/null || echo "?")

# resolve current leader pod -> node-side container PID (guarded: never pid<=1)
leader_pid() {
  local pod cid pid
  pod=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.holderIdentity}')
  [[ -n "${pod}" ]] || { echo "[le-flap] no holder" >&2; return 1; }
  cid=$(${K} get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's#containerd://##')
  pid=$(docker exec "${NODE}" crictl inspect --output go-template --template '{{.info.pid}}' "${cid}" 2>/dev/null)
  if ! [[ "${pid}" =~ ^[0-9]+$ ]] || (( pid <= 1 )); then
    echo "[le-flap] refusing pid='${pid}' for pod ${pod} (safety guard)" >&2; return 1
  fi
  echo "${pod} ${pid}"
}
netem() { docker exec "${NODE}" nsenter -t "$2" -n tc qdisc "$1" dev eth0 ${3:+root netem delay "$3"ms} 2>/dev/null; }

for D in ${DELAYS}; do
  read -r POD PID < <(leader_pid)
  # safety: confirm this netns is the pod's (eth0 is a veth peer, not the node's eth0)
  if ! docker exec "${NODE}" nsenter -t "${PID}" -n ip -o link show eth0 | grep -q 'eth0@if'; then
    echo "[le-flap] eth0 in pid ${PID} netns is not a veth — aborting for safety" >&2; exit 1
  fi
  TR0=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.leaseTransitions}'); TR0="${TR0:-0}"
  H0=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.holderIdentity}')

  docker exec "${NODE}" nsenter -t "${PID}" -n tc qdisc add dev eth0 root netem delay "${D}ms" >/dev/null
  deadline=$(( $(date +%s) + OBSERVE )); flapped=0
  while (( $(date +%s) < deadline )); do
    TRn=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.leaseTransitions}' 2>/dev/null || echo "${TR0}")
    if (( ${TRn:-TR0} > TR0 )); then flapped=1; break; fi
    sleep 0.5
  done
  # revert delay (idempotent; ignore error if pod already replaced)
  docker exec "${NODE}" nsenter -t "${PID}" -n tc qdisc del dev eth0 root >/dev/null 2>&1 || true
  TRn=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.leaseTransitions}' 2>/dev/null || echo "${TR0}")
  Hn=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "?")

  echo "${CONFIG},${APP#connect-},${LEASE},${RENEW_DL},${D},${flapped},$(( ${TRn:-TR0} - TR0 )),${H0##*-},${Hn##*-},${OBSERVE}" >> "${OUT}"
  printf '[le-flap] %-5s renewDeadline=%s  delay=%4sms  -> %s (tr+%d)  %s->%s\n' \
    "${CONFIG}" "${RENEW_DL}" "${D}" "$([[ ${flapped} == 1 ]] && echo FLAP || echo stable)" \
    "$(( ${TRn:-TR0} - TR0 ))" "${H0##*-}" "${Hn##*-}"
  # let it re-stabilize before the next delay point
  sleep 5
done
echo "[le-flap] ${CONFIG}/${APP}: done -> ${OUT}"
