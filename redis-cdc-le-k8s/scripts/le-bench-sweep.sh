#!/usr/bin/env bash
# le-bench-sweep.sh — full leader-election benchmark across three timing configs.
#
# For each config: helm-upgrade the lease timings on BOTH legs, soak until the election
# re-stabilizes, then per leg run failover trials (random kill) + a worst-case (post-
# renew kill) batch on the sink, a control-plane-latency flap-onset ladder on the source,
# and a CDC correctness gate. Raw rows accumulate in reports/le/{failover,flap}.csv;
# correctness verdicts in reports/le/correctness.txt. Render with scripts/le-report.py.
#
# Configs (duration / renewDeadline / retryPeriod):
#   tight   3s / 2s / 1s
#   default 6s / 4s / 1s   <-- the value under test
#   stock  15s /10s / 2s   <-- client-go recommended defaults
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-k8s}"; RELEASE="${RRCS_RELEASE:-cdc}"; CTX="${CTX:-kind-cdc}"
NODE="${NODE:-cdc-control-plane}"; VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
TRIALS="${TRIALS:-10}"; PR_TRIALS="${PR_TRIALS:-5}"
FLAP_DELAYS="${FLAP_DELAYS:-1500 2500 4500 8000 12000}"
OUTDIR="${OUTDIR:-reports/le}"
K="kubectl --context ${CTX} -n ${NS}"
mkdir -p "${OUTDIR}"
FAILOVER_CSV="${OUTDIR}/failover.csv"; FLAP_CSV="${OUTDIR}/flap.csv"; CORRECT="${OUTDIR}/correctness.txt"
: > "${CORRECT}"; rm -f "${FAILOVER_CSV}" "${FLAP_CSV}"

# config name -> "duration renewDeadline retryPeriod"
declare -A CFG=( [default]="6s 4s 1s" [tight]="3s 2s 1s" [stock]="15s 10s 2s" )
ORDER=( default tight stock )

settle() {  # wait until both leg leases have a Ready holder, then soak
  local deadline=$(( $(date +%s) + 180 ))
  for lease in lab-connect-source-elector lab-connect-sink-elector; do
    while (( $(date +%s) < deadline )); do
      local h; h=$(${K} get lease "${lease}" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
      [[ -n "${h}" ]] && ${K} get pod "${h}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True && break
      sleep 2
    done
  done
  echo "[sweep] soak 20s for election to stabilize"; sleep 20
}

correctness_gate() {  # run the verifier Job once; record PASS/FAIL verdict
  local cfg="$1" epoch="run-$(date +%s)" job; job="verifier-${epoch}"
  helm template "${RELEASE}" ./chart -n "${NS}" -s templates/verifier-job.yaml \
    -f "${VALUES_FILE}" --set profile=cdc --set verifier.run=true \
    --set "verifier.jobName=${job}" --set "verifier.epoch=${epoch}" | ${K} apply -f - >/dev/null
  local full="lab-${job}" deadline=$(( $(date +%s) + 240 ))
  while (( $(date +%s) < deadline )); do
    local st fa
    st=$(${K} get job/"${full}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    fa=$(${K} get job/"${full}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
    [[ "${st}" == "True" || "${fa}" == "True" ]] && break; sleep 3
  done
  local result; result=$(${K} logs job/"${full}" 2>/dev/null | sed -n 's/^RESULT_JSON://p' | tail -n1 || true)
  local pass; pass=$(echo "${result}" | jq -r '.verdict.pass' 2>/dev/null || echo "unknown")
  echo "${cfg}: verdict.pass=${pass}  $(echo "${result}" | jq -c '{dedup_delta:.cdc.dedup_delta,ops_ok:.cdc.ops_ok,replay_ok:.cdc.replay_ok}' 2>/dev/null)" | tee -a "${CORRECT}"
}

for cfg in "${ORDER[@]}"; do
  read -r DUR RENEW RETRY <<< "${CFG[$cfg]}"
  echo "============================================================"
  echo "[sweep] config=${cfg}  duration=${DUR} renewDeadline=${RENEW} retryPeriod=${RETRY}"
  echo "============================================================"
  helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
    --set profile=cdc -f "${VALUES_FILE}" \
    --set connect.source.lease.duration="${DUR}" --set connect.source.lease.renewDeadline="${RENEW}" --set connect.source.lease.retryPeriod="${RETRY}" \
    --set connect.sink.lease.duration="${DUR}"   --set connect.sink.lease.renewDeadline="${RENEW}"   --set connect.sink.lease.retryPeriod="${RETRY}" \
    --wait --timeout 5m >/dev/null
  echo "[sweep] upgraded; settling"; settle

  NS="${NS}" CTX="${CTX}" LEASE=lab-connect-source-elector APP=connect-source LEG=source \
    CONFIG="${cfg}" TRIALS="${TRIALS}" KILL_MODE=random OUT="${FAILOVER_CSV}" scripts/le-bench.sh
  NS="${NS}" CTX="${CTX}" LEASE=lab-connect-sink-elector   APP=connect-sink   LEG=sink \
    CONFIG="${cfg}" TRIALS="${TRIALS}" KILL_MODE=random OUT="${FAILOVER_CSV}" scripts/le-bench.sh
  NS="${NS}" CTX="${CTX}" LEASE=lab-connect-sink-elector   APP=connect-sink   LEG=sink \
    CONFIG="${cfg}" TRIALS="${PR_TRIALS}" KILL_MODE=post-renew OUT="${FAILOVER_CSV}" scripts/le-bench.sh

  NS="${NS}" CTX="${CTX}" NODE="${NODE}" LEASE=lab-connect-source-elector APP=connect-source \
    CONFIG="${cfg}" DELAYS="${FLAP_DELAYS}" OBSERVE=20 OUT="${FLAP_CSV}" scripts/le-flap.sh

  echo "[sweep] correctness gate for ${cfg}"; settle; correctness_gate "${cfg}"
done

# restore the default config so the cluster is left in a known state
read -r DUR RENEW RETRY <<< "${CFG[default]}"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --set profile=cdc -f "${VALUES_FILE}" \
  --set connect.source.lease.duration="${DUR}" --set connect.source.lease.renewDeadline="${RENEW}" --set connect.source.lease.retryPeriod="${RETRY}" \
  --set connect.sink.lease.duration="${DUR}" --set connect.sink.lease.renewDeadline="${RENEW}" --set connect.sink.lease.retryPeriod="${RETRY}" \
  --wait --timeout 5m >/dev/null || true

echo "[sweep] DONE. raw -> ${FAILOVER_CSV}, ${FLAP_CSV}; correctness -> ${CORRECT}"
echo "[sweep] render: scripts/le-report.py ${OUTDIR}"
