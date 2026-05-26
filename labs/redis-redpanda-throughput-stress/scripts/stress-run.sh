#!/usr/bin/env bash
# Top-level throughput-stress harness. See README for usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/tier-defs.sh"

TIERS=("${DEFAULT_TIERS[@]}")
MODES=("${DEFAULT_MODES[@]}")

for arg in "$@"; do
  case "$arg" in
    --tiers=*) IFS=',' read -r -a TIERS <<< "${arg#*=}";;
    --modes=*) IFS=',' read -r -a MODES <<< "${arg#*=}";;
    -h|--help)
      cat <<EOF
Usage: $0 [--tiers=5000,10000,...] [--modes=batch,single]

Env overrides:
  DURATION_S=30  WARMUP_S=5  DRAIN_S=10
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

# Validate tiers
for t in "${TIERS[@]}"; do
  if [[ -z "${TIER_RATE_MIN_PCT[$t]:-}" ]]; then
    echo "error: unknown tier '${t}'. Known: ${!TIER_RATE_MIN_PCT[*]}" >&2
    exit 2
  fi
done

# Validate modes
for m in "${MODES[@]}"; do
  case "$m" in
    batch|single) ;;
    *) echo "error: unknown mode '${m}'. Known: batch single" >&2; exit 2;;
  esac
done

echo "[boot] starting compose services"
docker compose up -d --wait

run_one() {
  local tier="$1" mode="$2"
  local rate_min_pct="${TIER_RATE_MIN_PCT[$tier]}"
  local p99_ms="${TIER_P99_MS[$tier]:-}"
  local p99_arg=()
  if [[ -n "${p99_ms}" ]]; then
    p99_arg=(--slo-p99-ms="${p99_ms}")
  fi

  echo "[run] tier=${tier} mode=${mode}"
  docker compose --profile tools run --rm \
    --user "$(id -u):$(id -g)" \
    collector \
      --tier="${tier}" --mode="${mode}" \
      --duration="${DURATION_S}s" --warmup="${WARMUP_S}s" --drain="${DRAIN_S}s" \
      --out="/reports/${tier}-${mode}.json" \
      --slo-rate-pct="${rate_min_pct}" \
      "${p99_arg[@]}" || true

  # Between-run hygiene: purge JetStream so accumulated bytes never approach the cap.
  docker run --rm --network rrts-net natsio/nats-box:0.14.5 \
    nats --server nats://nats:4222 stream purge APP_EVENTS -f >/dev/null 2>&1 \
    || echo "[purge] WARN: nats stream purge APP_EVENTS failed (continuing)" >&2
}

mkdir -p reports

for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    run_one "${tier}" "${mode}"
  done
done

echo
printf "%-9s %-8s %-15s %-9s %-9s %-9s %s\n" "tier" "mode" "rate_achieved" "missing" "trimmed" "p99 ms" "verdict"
printf -- "-----------------------------------------------------------------------\n"
all_pass=true
for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    f="reports/${tier}-${mode}.json"
    if [[ ! -f "$f" ]]; then
      printf "%-9s %-8s %-15s %-9s %-9s %-9s %s\n" "$tier" "$mode" "-" "-" "-" "-" "MISSING"
      all_pass=false
      continue
    fi
    python3 - "$f" "$tier" "$mode" <<'PY'
import json,sys
path, tier, mode = sys.argv[1], sys.argv[2], sys.argv[3]
r = json.load(open(path))
ach = r.get("rate_achieved", 0)
miss = r.get("missing", 0)
trim = r.get("trimmed", 0)
p99 = r.get("sync_latency_ms", {}).get("p99", 0)
verdict = "PASS" if r.get("verdict", {}).get("pass") else "FAIL"
print(f"{tier:<9} {mode:<8} {ach:6.1f}/{tier:<8} {miss:<9} {trim:<9} {p99:<9.1f} {verdict}")
PY
    pass=$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1]))["verdict"]["pass"] else 0)' "$f" 2>/dev/null || echo 0)
    [[ "$pass" == "1" ]] || all_pass=false
  done
done
printf -- "-----------------------------------------------------------------------\n"

if $all_pass; then exit 0; fi
exit 1
