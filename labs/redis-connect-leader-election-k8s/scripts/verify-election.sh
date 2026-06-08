#!/usr/bin/env bash
# Leader-election verification harness. Boots the chart, then:
#   Proof A : steady state -> exactly one connect pod consumes (single-active).
#   Proof B1: SIGSTOP the leader's elector -> measured dual-active OVERLAP window.
#   Proof B2: force-delete the leader pod  -> measured zero-active GAP window.
# Exits 0 iff Proof A passes AND (B1 overlap>0 OR B2 gap>0) — gating works AND is best-effort.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/run-defaults.sh"

NS="${LEL_NS:-lel-k8s}"
RELEASE="${LEL_RELEASE:-lel}"
VALUES_FILE="${LEL_VALUES:-chart/values-dev.yaml}"

echo "[boot] helm upgrade --install ${RELEASE}"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  -f "${VALUES_FILE}" --wait --timeout 5m
PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

K() { kubectl -n "${NS}" "$@"; }
OBS() { K exec "deploy/${PREFIX}observer" -- wget -qO- "http://localhost:8070/$1"; }
LEASE_NAME="${PREFIX}connect-elector"

leader_pod() { K get lease "${LEASE_NAME}" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true; }
# PID of the elector binary (exact comm match, so we never hit tini/PID 1).
elector_pid() { K exec "$1" -c elector -- pgrep -x elector | head -n1; }
now_ms() { date +%s%3N; }

echo "[writer] reset + start rate=${RATE}"
K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data='{"epoch":"run"}' http://localhost:8081/reset >/dev/null
K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data="{\"rate\":${RATE}}" http://localhost:8081/rate >/dev/null

# Wait for a leader to be elected (lease holder present).
echo "[proofA] waiting for a lease holder…"
for _ in $(seq 1 30); do [[ -n "$(leader_pod)" ]] && break; sleep 1; done

echo "[proofA] settle ${SETTLE_S}s, then observe a clean ${OBS_WINDOW_S}s window"
sleep "${SETTLE_S}"
A_START="$(now_ms)"
sleep "${OBS_WINDOW_S}"
A_VERDICT="$(OBS "verdict?since_unix_ms=${A_START}")"
echo "[proofA] ${A_VERDICT}"
SA="$(echo "$A_VERDICT" | jq -r '.single_active')"
LEADER="$(leader_pod)"
echo "[proofA] lease holder = ${LEADER}"
if [[ "$SA" != "true" || -z "$LEADER" ]]; then
  echo "[proofA] FAIL (single_active=$SA holder=$LEADER)"
  echo "[proofA] recent samples:"; OBS "timeline?since_unix_ms=${A_START}" | jq -c '.[]' | tail -8 || true
  exit 1
fi
echo "[proofA] PASS"

echo "[proofB1] SIGSTOP elector on leader ${LEADER} for ${OVERLAP_WAIT_S}s"
B1_START="$(now_ms)"
PID="$(elector_pid "${LEADER}")"
echo "[proofB1] elector pid on ${LEADER} = ${PID}"
K exec "${LEADER}" -c elector -- kill -STOP "${PID}"
sleep "${OVERLAP_WAIT_S}"
K exec "${LEADER}" -c elector -- kill -CONT "${PID}" || true
B1_VERDICT="$(OBS "verdict?since_unix_ms=${B1_START}")"
echo "[proofB1] ${B1_VERDICT}"
OVERLAP="$(echo "$B1_VERDICT" | jq -r '.overlap_pairs')"
echo "[proofB1] reconverge ${SETTLE_S}s"
sleep "${SETTLE_S}"

LEADER2="$(leader_pod)"
echo "[proofB2] force-delete current leader ${LEADER2}"
B2_START="$(now_ms)"
K delete pod "${LEADER2}" --force --grace-period=0 >/dev/null 2>&1 || true
sleep "${GAP_WAIT_S}"
B2_VERDICT="$(OBS "verdict?since_unix_ms=${B2_START}")"
echo "[proofB2] ${B2_VERDICT}"
GAP="$(echo "$B2_VERDICT" | jq -r '.gap_pairs')"

echo "----"
echo "[verdict] single_active=${SA} overlap_pairs=${OVERLAP} gap_pairs=${GAP}"
if [[ "$SA" == "true" && ( "${OVERLAP:-0}" -gt 0 || "${GAP:-0}" -gt 0 ) ]]; then
  echo "[verify-election] PASS — active-gating works AND is best-effort (measured window)"
  exit 0
fi
echo "[verify-election] FAIL — gating or best-effort window not observed"
exit 1
