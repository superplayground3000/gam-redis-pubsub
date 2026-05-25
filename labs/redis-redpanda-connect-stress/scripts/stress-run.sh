#!/usr/bin/env bash
# Top-level stress harness. See README for usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/tier-defs.sh"

PROFILE="${PROFILE_QOS:-alo}"
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
  DURATION_S=30  WARMUP_S=5  DRAIN_S=10  CHAOS_DOWN_S=8
EOF
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

NO_ARGS_RUN=$(( $# == 0 ? 1 : 0 ))
cleanup() {
  if (( NO_ARGS_RUN )); then
    echo "[teardown] docker compose down -v"
    docker compose down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Validate tiers against known SLO keys
for t in "${TIERS[@]}"; do
  if [[ -z "${TIER_P99_MS[$t]:-}" ]]; then
    echo "error: unknown tier '${t}'. Known: ${!TIER_P99_MS[*]}" >&2
    exit 2
  fi
done

# Validate modes
valid_modes=" throughput latency chaos "
for m in "${MODES[@]}"; do
  if [[ "${valid_modes}" != *" ${m} "* ]]; then
    echo "error: unknown mode '${m}'. Known: throughput latency chaos" >&2
    exit 2
  fi
done

# Boot the lab (idempotent).
echo "[boot] starting compose services (profile=${PROFILE})"
PROFILE_QOS="${PROFILE}" docker compose up -d --wait

run_one() {
  local tier="$1" mode="$2"
  local p99_ms="${TIER_P99_MS[$tier]}"
  local rate_min_pct="${TIER_RATE_MIN_PCT[$tier]}"
  local allow_missing
  allow_missing="$(allow_missing_for_profile "${PROFILE}")"
  local chaos_args=()
  local chaos_pid=""
  if [[ "${mode}" == "chaos" ]]; then
    # Pre-flight: refuse if jetstream is already > 200MB
    local bytes
    bytes=$(curl -fs "http://127.0.0.1:${NATS_MON_PORT:-17322}/jsz?streams=true&consumers=true&accounts=true" \
            | python3 -c 'import json,sys
d=json.load(sys.stdin)
b=0
for a in d.get("account_details",[]):
 for s in a.get("stream_detail",[]):
  if s.get("name") == "APP_EVENTS":
    b = s.get("state",{}).get("bytes", 0)
print(b)')
    if (( bytes > 200*1024*1024 )); then
      echo "[abort] JetStream APP_EVENTS already at ${bytes} bytes (>200MB). Tear down (docker compose down -v) and retry." >&2
      exit 3
    fi
    chaos_args=(--chaos-at-s="$(chaos_at_s)" --chaos-duration="${CHAOS_DOWN_S}")
    # Schedule the kill in the background timed against sustain start.
    (
      sleep "${WARMUP_S}"
      sleep "$(chaos_at_s)"
      bash "${SCRIPT_DIR}/chaos/kill-connect-sink.sh" "${CHAOS_DOWN_S}"
    ) &
    chaos_pid=$!
  fi

  echo "[run] tier=${tier} mode=${mode} profile=${PROFILE}"
  # Run collector as the host user so report files land owned by the invoking user.
  PROFILE_QOS="${PROFILE}" docker compose --profile tools run --rm \
    --user "$(id -u):$(id -g)" \
    collector \
      --tier="${tier}" --mode="${mode}" --profile="${PROFILE}" \
      --duration="${DURATION_S}s" --warmup="${WARMUP_S}s" --drain="${DRAIN_S}s" \
      --out="/reports/${tier}-${mode}-${PROFILE}.json" \
      --slo-rate-pct="${rate_min_pct}" --slo-p99-ms="${p99_ms}" \
      --slo-allow-missing="${allow_missing}" \
      "${chaos_args[@]}" || true

  if [[ -n "${chaos_pid}" ]]; then
    set +e
    wait "${chaos_pid}"
    chaos_rc=$?
    set -e
    if (( chaos_rc != 0 )); then
      echo "[chaos] WARN: kill-connect-sink.sh exited ${chaos_rc} (kept going; see container logs)" >&2
    fi
  fi

  # Purge JetStream so the next run starts hermetic. Non-fatal — if NATS
  # is unreachable the next run's pre-flight will catch a genuinely-broken
  # state. The collector's pipeline-quiescence (spec §6.3) ensures no
  # in-flight messages are lost by purging now.
  # Uses natsio/nats-box because the nats:alpine server image doesn't include
  # the nats CLI.
  docker run --rm --network rrcs-net natsio/nats-box:0.14.5 \
    nats --server nats://nats:4222 stream purge APP_EVENTS -f >/dev/null 2>&1 \
    || echo "[purge] WARN: nats stream purge APP_EVENTS failed (continuing)" >&2
}

mkdir -p reports

for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    run_one "${tier}" "${mode}"
  done
done

# Render summary table.
echo
printf "%-9s %-12s %-15s %-9s %-9s %-9s %s\n" "tier" "mode" "rate_achieved" "missing" "trimmed" "p99 ms" "verdict"
printf -- "-------------------------------------------------------------------------------\n"
all_pass=true
for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    f="reports/${tier}-${mode}-${PROFILE}.json"
    if [[ ! -f "$f" ]]; then
      printf "%-9s %-12s %-15s %-9s %-9s %-9s %s\n" "$tier" "$mode" "-" "-" "-" "-" "MISSING"
      all_pass=false
      continue
    fi
    python3 - "$f" "$tier" "$mode" <<'PY'
import json,sys
path, tier, mode = sys.argv[1], sys.argv[2], sys.argv[3]
r = json.load(open(path))
ach = r.get("rate_achieved_avg", 0)
miss = r.get("missing", 0)
trim = r.get("trimmed", 0)
p99 = r.get("latency_ms", {}).get("p99", 0)
verdict = "PASS" if r.get("verdict", {}).get("pass") else "FAIL"
print(f"{tier:<9} {mode:<12} {ach:6.1f}/{tier:<8} {miss:<9} {trim:<9} {p99:<9.1f} {verdict}")
PY
    pass=$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1]))["verdict"]["pass"] else 0)' "$f" 2>/dev/null || echo 0)
    [[ "$pass" == "1" ]] || all_pass=false
  done
done
printf -- "-------------------------------------------------------------------------------\n"

if $all_pass; then
  exit 0
fi
exit 1
