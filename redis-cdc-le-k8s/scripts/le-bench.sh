#!/usr/bin/env bash
# le-bench.sh — measure leader-election failover latency for ONE connect leg.
#
# Each trial: confirm the leg is at full HA (REPLICAS Ready) and its Lease is settled,
# record the holder + its last renewTime, force-delete the holder pod (ungraceful → the
# Lease is left to EXPIRE — the path LeaseDuration governs), then watch the Lease until a
# standby acquires it.
#
# Two independent failover numbers per trial:
#   failover_acquire_s  = acquireTime(new) - t_kill
#       acquireTime is stamped by the WINNING POD via Go time.Now() (CLOCK_REALTIME).
#       t_kill is the host's CLOCK_REALTIME (date +%s.%N). On single-node kind every
#       container shares the one host kernel, and CLOCK_REALTIME is NOT virtualized by
#       time namespaces (only MONOTONIC/BOOTTIME are) — so these two reads come from the
#       SAME wall clock with zero domain offset. This is the precise acquire instant.
#   failover_observed_s = t_detect - t_kill
#       Both stamped by THIS host's clock (t_detect = host time at the first poll that
#       sees the holder change). Single-clock by construction, needs no cross-process
#       assumption; an upper bound biased high by at most one poll interval (~kubectl
#       latency). Corroborates failover_acquire.
#
# Decomposition (why the number is what it is):
#   lease_remaining_s  = (renewTime(old) + leaseDur) - t_kill   # LeaseDuration component
#   acquire_overhead_s = acquireTime(new) - (renewTime(old)+leaseDur)  # retry+jitter+API
#
# tr_delta = leaseTransitions(new) - leaseTransitions(old): >1 means the holder changed
# more than once during the window (flapping) — flagged, not silently averaged.
#
# KILL_MODE:
#   random    (default) kill at an arbitrary point in the renew cycle — natural
#             operator-observed distribution; lease_remaining ∈ [0, leaseDur].
#   post-renew kill immediately after a fresh renew — lease_remaining ≈ leaseDur, i.e.
#             the WORST CASE for failover. Bounds the max.
#
# Usage:
#   NS=cdc-k8s CTX=kind-cdc LEASE=lab-connect-sink-elector APP=connect-sink \
#   REPLICAS=3 TRIALS=10 CONFIG=default LEG=sink KILL_MODE=random OUT=reports/le/raw.csv \
#   scripts/le-bench.sh
set -euo pipefail

NS="${NS:-cdc-k8s}"; CTX="${CTX:-kind-cdc}"
LEASE="${LEASE:?LEASE required}"; APP="${APP:?APP required}"
LEG="${LEG:?LEG required}"; CONFIG="${CONFIG:?CONFIG required}"
REPLICAS="${REPLICAS:-3}"; TRIALS="${TRIALS:-10}"
KILL_MODE="${KILL_MODE:-random}"; OUT="${OUT:?OUT required}"
SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-120}"; ACQUIRE_TIMEOUT="${ACQUIRE_TIMEOUT:-60}"
K="kubectl --context ${CTX} -n ${NS}"

mkdir -p "$(dirname "${OUT}")"
if [[ ! -f "${OUT}" ]]; then
  echo "config,leg,kill_mode,trial,h_old,renew_old,t_kill,h_new,acquire_new,t_detect,lease_dur,failover_acquire_s,failover_observed_s,lease_remaining_s,acquire_overhead_s,tr_delta" > "${OUT}"
fi

ready_count() {
  ${K} get pods -l "app=${APP}" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true
}
wait_full_ha() {
  local deadline=$(( $(date +%s) + SETTLE_TIMEOUT )) rc holder
  while (( $(date +%s) < deadline )); do
    rc=$(ready_count)
    holder=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
    if [[ "${rc}" == "${REPLICAS}" && -n "${holder}" ]] \
       && ${K} get pod "${holder}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
      return 0
    fi
    sleep 1
  done
  echo "[le-bench] ${LEG}: HA did not settle (ready=${rc:-?}/${REPLICAS}, holder=${holder:-none})" >&2
  return 1
}

for ((t=1; t<=TRIALS; t++)); do
  wait_full_ha
  read -r H_OLD RENEW_OLD LEASE_DUR TR_OLD < <(${K} get lease "${LEASE}" \
    -o jsonpath='{.spec.holderIdentity}{" "}{.spec.renewTime}{" "}{.spec.leaseDurationSeconds}{" "}{.spec.leaseTransitions}{"\n"}')
  TR_OLD="${TR_OLD:-0}"

  if [[ "${KILL_MODE}" == "post-renew" ]]; then
    # wait until renewTime advances, then kill at once → lease_remaining ≈ leaseDur (worst case)
    rdeadline=$(( $(date +%s) + 10 ))
    while (( $(date +%s) < rdeadline )); do
      rn=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.renewTime}')
      [[ "${rn}" != "${RENEW_OLD}" ]] && { RENEW_OLD="${rn}"; break; }
      sleep 0.1
    done
  fi

  T_KILL=$(date +%s.%N)
  ${K} delete pod "${H_OLD}" --grace-period=0 --force >/dev/null 2>&1

  H_NEW=""; ACQUIRE_NEW=""; T_DETECT=""
  adeadline=$(( $(date +%s) + ACQUIRE_TIMEOUT ))
  while (( $(date +%s) < adeadline )); do
    read -r H_NEW ACQUIRE_NEW < <(${K} get lease "${LEASE}" \
      -o jsonpath='{.spec.holderIdentity}{" "}{.spec.acquireTime}{"\n"}' 2>/dev/null || true)
    if [[ -n "${H_NEW}" && "${H_NEW}" != "${H_OLD}" ]]; then T_DETECT=$(date +%s.%N); break; fi
    sleep 0.1
  done
  if [[ -z "${H_NEW}" || "${H_NEW}" == "${H_OLD}" ]]; then
    echo "[le-bench] ${LEG} trial ${t}: no failover within ${ACQUIRE_TIMEOUT}s" >&2; exit 1
  fi
  TR_NEW=$(${K} get lease "${LEASE}" -o jsonpath='{.spec.leaseTransitions}' 2>/dev/null || echo "${TR_OLD}")

  read -r FA FO REMAIN OVH < <(python3 - "$T_KILL" "$ACQUIRE_NEW" "$RENEW_OLD" "$LEASE_DUR" "$T_DETECT" <<'PY'
import sys, datetime
def ep(s): return datetime.datetime.strptime(s.replace("Z","+0000"),"%Y-%m-%dT%H:%M:%S.%f%z").timestamp()
t_kill=float(sys.argv[1]); acq=ep(sys.argv[2]); renew_old=ep(sys.argv[3]); dur=float(sys.argv[4]); t_det=float(sys.argv[5])
print(f"{acq-t_kill:.3f} {t_det-t_kill:.3f} {(renew_old+dur)-t_kill:.3f} {acq-(renew_old+dur):.3f}")
PY
)
  echo "${CONFIG},${LEG},${KILL_MODE},${t},${H_OLD},${RENEW_OLD},${T_KILL},${H_NEW},${ACQUIRE_NEW},${T_DETECT},${LEASE_DUR},${FA},${FO},${REMAIN},${OVH},$((TR_NEW-TR_OLD))" >> "${OUT}"
  printf '[le-bench] %-5s %-6s %-10s %2d/%d  acquire=%ss observed=%ss  (remaining=%ss + overhead=%ss) tr+%d  %s->%s\n' \
    "${CONFIG}" "${LEG}" "${KILL_MODE}" "${t}" "${TRIALS}" "${FA}" "${FO}" "${REMAIN}" "${OVH}" "$((TR_NEW-TR_OLD))" "${H_OLD##*-}" "${H_NEW##*-}"
done
echo "[le-bench] ${CONFIG}/${LEG}/${KILL_MODE}: ${TRIALS} trials -> ${OUT}"
