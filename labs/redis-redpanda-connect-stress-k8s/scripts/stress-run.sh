#!/usr/bin/env bash
# Kubernetes-native stress harness. Drives the tier x mode matrix against the
# chart installed in namespace $NS, extracting each verdict from the collector
# Job's stdout (RESULT_JSON sentinel). See README.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/tier-defs.sh"

NS="${RRCS_NS:-rrcs-k8s}"
RELEASE="${RRCS_RELEASE:-rrcs}"
PROFILE="${PROFILE_QOS:-alo}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
RESULT_SENTINEL="RESULT_JSON:"
TIERS=("${DEFAULT_TIERS[@]}")
MODES=("${DEFAULT_MODES[@]}")

for arg in "$@"; do
  case "$arg" in
    --tiers=*)   IFS=',' read -r -a TIERS <<< "${arg#*=}";;
    --modes=*)   IFS=',' read -r -a MODES <<< "${arg#*=}";;
    --profile=*) PROFILE="${arg#*=}";;
    -h|--help)
      cat <<EOF
Usage: $0 [--tiers=10,1000,10000] [--modes=throughput,latency,chaos] [--profile=alo|amo|eoe]

Env overrides:
  RRCS_NS=rrcs-k8s  RRCS_RELEASE=rrcs  RRCS_VALUES=chart/values-dev.yaml
  DURATION_S=30  WARMUP_S=5  DRAIN_S=10  CHAOS_DOWN_S=8
EOF
      exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

# Validate tiers/modes against known SLO keys (same as compose harness).
for t in "${TIERS[@]}"; do
  if [[ -z "${TIER_P99_MS[$t]:-}" ]]; then
    echo "error: unknown tier '${t}'. Known: ${!TIER_P99_MS[*]}" >&2; exit 2
  fi
done
valid_modes=" throughput latency chaos "
for m in "${MODES[@]}"; do
  if [[ "${valid_modes}" != *" ${m} "* ]]; then
    echo "error: unknown mode '${m}'. Known: throughput latency chaos" >&2; exit 2
  fi
done

NO_ARGS_RUN=$(( $# == 0 ? 1 : 0 ))
CHAOS_PID=""
PF_PID=""
cleanup() {
  if [[ -n "${CHAOS_PID}" ]]; then kill "${CHAOS_PID}" >/dev/null 2>&1 || true; fi
  if [[ -n "${PF_PID}" ]]; then kill "${PF_PID}" >/dev/null 2>&1 || true; fi
  if (( NO_ARGS_RUN )); then
    echo "[teardown] helm uninstall ${RELEASE} -n ${NS}"
    helm uninstall "${RELEASE}" -n "${NS}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Boot the chart (idempotent). nats-init is a plain Job, so --wait does not deadlock.
echo "[boot] helm upgrade --install ${RELEASE} (profile=${PROFILE})"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  --set "profile=${PROFILE}" -f "${VALUES_FILE}" --wait --timeout 5m

# Resolve runtime config from the installed release (external-mode-aware).
HELM_VALUES_JSON="$(helm get values "${RELEASE}" -n "${NS}" -o json)"
STREAM_NAME="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.stream.name // "APP_EVENTS"')"
NATS_EXTERNAL="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.external.enabled // false')"
NATS_MONITOR_URL="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.external.monitorUrl // empty')"
NATS_URL="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.external.url // empty')"
[[ -z "$NATS_URL" ]] && NATS_URL="nats://nats:4222"
if [[ "$NATS_EXTERNAL" == "true" ]]; then
  ADMIN_SECRET="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.external.auth.adminSecret // empty')"
else
  ADMIN_SECRET="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.auth.secrets.admin // "admin-creds"')"
fi
echo "[config] stream=${STREAM_NAME} ext=${NATS_EXTERNAL} url=${NATS_URL} mon=${NATS_MONITOR_URL:-<unset>} admin=${ADMIN_SECRET:-<unset>}"

# One port-forward for the chaos pre-flight (NATS monitoring), opened lazily.
needs_pf=0
for m in "${MODES[@]}"; do [[ "$m" == "chaos" ]] && needs_pf=1; done
if (( needs_pf )); then
  if [[ "$NATS_EXTERNAL" == "true" ]]; then
    if [[ -z "$NATS_MONITOR_URL" ]]; then
      echo "[chaos-preflight] ERROR: chaos mode requires nats.external.monitorUrl to be set" >&2
      echo "                  (so the >200 MB JetStream backlog safety check can run)." >&2
      echo "                  Either set nats.external.monitorUrl, or remove chaos from --modes." >&2
      exit 2
    fi
    JSZ_URL="${NATS_MONITOR_URL%/}/jsz"
  else
    kubectl -n "${NS}" port-forward svc/nats 18222:8222 >/dev/null 2>&1 &
    PF_PID=$!
    pf_ok=0
    for _ in $(seq 1 15); do
      if curl -fs "http://127.0.0.1:18222/jsz" >/dev/null 2>&1; then pf_ok=1; break; fi
      sleep 1
    done
    (( pf_ok )) || { echo "[error] NATS port-forward not ready on :18222" >&2; exit 1; }
    JSZ_URL="http://127.0.0.1:18222/jsz"
  fi
fi

mkdir -p reports

# Resolve the nats-box image (with images.registry prefix) ONCE, from the
# merged effective values — works in BOTH bundled and external modes since
# nats-init-job.yaml is gated off in external mode and unavailable to `-s`.
HELM_VALUES_ALL_JSON="$(helm get values "${RELEASE}" -n "${NS}" -a -o json)"
PURGE_REG="$(echo "$HELM_VALUES_ALL_JSON" | jq -r '.images.registry // ""')"
PURGE_NATSBOX="$(echo "$HELM_VALUES_ALL_JSON" | jq -r '.natsBox.image // "natsio/nats-box:0.14.5"')"
PURGE_IMG="${PURGE_REG}${PURGE_NATSBOX}"

jetstream_bytes() {
  [[ -z "${JSZ_URL:-}" ]] && { echo 0; return; }
  curl -fs "${JSZ_URL}?streams=true&consumers=true&accounts=true" \
    | STREAM_NAME="${STREAM_NAME}" python3 -c 'import json,os,sys
target=os.environ["STREAM_NAME"]
d=json.load(sys.stdin); b=0
for a in d.get("account_details",[]):
 for s in a.get("stream_detail",[]):
  if s.get("name")==target: b=s.get("state",{}).get("bytes",0)
print(b)'
}

# Returns 0 = Complete, 1 = Failed, 2 = timed out.
wait_job_terminal() {
  local job="$1" timeout_s="$2" deadline
  deadline=$(( $(date +%s) + timeout_s ))
  while (( $(date +%s) < deadline )); do
    local complete failed
    complete=$(kubectl -n "${NS}" get "job/${job}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    failed=$(kubectl -n "${NS}" get "job/${job}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
    [[ "${complete}" == "True" ]] && return 0
    [[ "${failed}" == "True" ]] && return 1
    sleep 2
  done
  return 2
}

run_one() {
  local tier="$1" mode="$2"
  local p99_ms="${TIER_P99_MS[$tier]}"
  local rate_min_pct="${TIER_RATE_MIN_PCT[$tier]}"
  local allow_missing chaos_sets=()
  allow_missing="$(allow_missing_for_profile "${PROFILE}")"

  if [[ "${mode}" == "chaos" ]]; then
    local bytes; bytes="$(jetstream_bytes)"
    if (( bytes > 200*1024*1024 )); then
      echo "[abort] ${STREAM_NAME} already ${bytes} bytes (>200MB). helm uninstall and retry." >&2
      exit 3
    fi
    chaos_sets=(--set "collector.chaosAtS=$(chaos_at_s)" --set "collector.chaosDurationS=${CHAOS_DOWN_S}")
    ( sleep "${WARMUP_S}"; sleep "$(chaos_at_s)"; bash "${SCRIPT_DIR}/chaos/scale-connect-sink.sh" "${CHAOS_DOWN_S}" ) &
    CHAOS_PID=$!
  fi

  local job
  job="collector-${tier}-${mode}-${PROFILE}-$(date +%s)"
  echo "[run] tier=${tier} mode=${mode} profile=${PROFILE} job=${job}"

  helm template "${RELEASE}" ./chart -n "${NS}" -s templates/collector-job.yaml \
    -f "${VALUES_FILE}" \
    --set "profile=${PROFILE}" \
    --set "collector.run=true" \
    --set "collector.jobName=${job}" \
    --set "collector.tier=${tier}" \
    --set "collector.mode=${mode}" \
    --set "collector.durationS=${DURATION_S}" \
    --set "collector.warmupS=${WARMUP_S}" \
    --set "collector.drainS=${DRAIN_S}" \
    --set "collector.sloRatePct=${rate_min_pct}" \
    --set "collector.sloP99Ms=${p99_ms}" \
    --set "collector.sloAllowMissing=${allow_missing}" \
    "${chaos_sets[@]}" \
    | kubectl apply -n "${NS}" -f -

  # Wait for terminal state: complete OR failed (a failing verdict is NOT a Job
  # failure - the collector exits 0 on report; only a genuine error fails it).
  local timeout_s=$(( DURATION_S + WARMUP_S + DRAIN_S + 120 ))
  local term_rc=0
  wait_job_terminal "${job}" "${timeout_s}" || term_rc=$?
  if (( term_rc == 0 )) \
     && kubectl -n "${NS}" logs "job/${job}" | sed -n "s/^${RESULT_SENTINEL}//p" | tail -n 1 > "reports/${tier}-${mode}-${PROFILE}.json" \
     && [[ -s "reports/${tier}-${mode}-${PROFILE}.json" ]]; then
    echo "[ok] report saved"
  else
    echo "[ERROR] collector ${job} did not produce a verdict (term_rc=${term_rc})" >&2
    kubectl -n "${NS}" logs "job/${job}" --tail=20 >&2 || true
    rm -f "reports/${tier}-${mode}-${PROFILE}.json"
  fi

  kubectl -n "${NS}" delete "job/${job}" --wait=true >/dev/null 2>&1 || true

  if [[ -n "${CHAOS_PID}" ]]; then
    local rc
    set +e; wait "${CHAOS_PID}"; rc=$?; set -e
    CHAOS_PID=""
    (( rc != 0 )) && echo "[chaos] WARN: scaler exited ${rc}" >&2
  fi

  # Purge JetStream so the next run starts hermetic. Mount admin creds (chart-
  # rendered in bundled mode, user-supplied Secret name in external mode); skip
  # with warning if admin Secret is not configured.
  if [[ -z "${ADMIN_SECRET}" ]]; then
    echo "[purge] WARN: admin creds not configured (skipping purge — runs are not hermetic)" >&2
    return 0
  fi
  local purge_name
  purge_name="nats-purge-$(date +%s)"
  local overrides
  overrides="$(jq -n \
    --arg name "$purge_name" \
    --arg image "$PURGE_IMG" \
    --arg secret "$ADMIN_SECRET" \
    --arg server "$NATS_URL" \
    --arg stream "$STREAM_NAME" \
    '{
      spec: {
        volumes: [{name: "creds", secret: {secretName: $secret, defaultMode: 292}}],
        containers: [{
          name: $name,
          image: $image,
          volumeMounts: [{name: "creds", mountPath: "/tmp/creds", readOnly: true}],
          command: ["nats", "--server", $server, "--creds", "/tmp/creds/user.creds", "stream", "purge", $stream, "-f"]
        }]
      }
    }')"
  kubectl -n "${NS}" run "${purge_name}" --rm -i --restart=Never --image="${PURGE_IMG}" \
    --overrides="${overrides}" >/dev/null 2>&1 \
    || echo "[purge] WARN: stream purge failed (continuing)" >&2
}

for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    run_one "${tier}" "${mode}"
  done
done

# Summary table (same reducer as the compose harness).
echo
printf "%-9s %-12s %-15s %-9s %-9s %-9s %s\n" "tier" "mode" "rate_achieved" "missing" "trimmed" "p99 ms" "verdict"
printf -- "-------------------------------------------------------------------------------\n"
all_pass=true
for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    f="reports/${tier}-${mode}-${PROFILE}.json"
    if [[ ! -f "$f" ]]; then
      printf "%-9s %-12s %-15s %-9s %-9s %-9s %s\n" "$tier" "$mode" "-" "-" "-" "-" "MISSING/ERROR"
      all_pass=false; continue
    fi
    python3 - "$f" "$tier" "$mode" <<'PY'
import json,sys
path, tier, mode = sys.argv[1], sys.argv[2], sys.argv[3]
r = json.load(open(path))
ach = r.get("rate_achieved_avg", 0); miss = r.get("missing", 0)
trim = r.get("trimmed", 0); p99 = r.get("latency_ms", {}).get("p99", 0)
verdict = "PASS" if r.get("verdict", {}).get("pass") else "FAIL"
print(f"{tier:<9} {mode:<12} {ach:6.1f}/{tier:<8} {miss:<9} {trim:<9} {p99:<9.1f} {verdict}")
PY
    pass=$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1]))["verdict"]["pass"] else 0)' "$f" 2>/dev/null || echo 0)
    [[ "$pass" == "1" ]] || all_pass=false
  done
done
printf -- "-------------------------------------------------------------------------------\n"
$all_pass && exit 0 || exit 1
