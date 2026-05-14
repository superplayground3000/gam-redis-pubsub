#!/usr/bin/env bash
# smoke-test.sh: assert the demonstrated property —
#   For each region X, median observed XADD latency to its LOCAL shard is below
#   LOCAL_THRESHOLD_MS, AND median to its FAR shard is above FAR_THRESHOLD_MS.
#
# Reads /shared/measurements.jsonl (bind-mounted at ./shared/measurements.jsonl).

set -uo pipefail

LAB_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$LAB_DIR"

# Pull thresholds from .env if present, else fall back to .env.example, else defaults.
if [ -f .env ]; then
  set -a; . ./.env; set +a
elif [ -f .env.example ]; then
  set -a; . ./.env.example; set +a
fi

LOCAL_THRESHOLD_MS=${LOCAL_THRESHOLD_MS:-80}
FAR_THRESHOLD_MS=${FAR_THRESHOLD_MS:-300}
MIN_SAMPLES=${MIN_SAMPLES:-10}

# Topology: which shard is local/far from each region.
declare -A LOCAL_SHARD=( [a]=redis-a [b]=redis-b [c]=redis-c )
declare -A FAR_SHARD=(   [a]=redis-c [b]=redis-c [c]=redis-a )

MEAS=shared/measurements.jsonl

echo "=== smoke-test: redis-cluster-multiregion-streams ==="
echo "thresholds: local <= ${LOCAL_THRESHOLD_MS}ms,  far >= ${FAR_THRESHOLD_MS}ms,  min samples = ${MIN_SAMPLES}"

# --- 1) wait for enough samples across all (region, shard) cells ---
DEADLINE=$(( $(date +%s) + 60 ))
while :; do
  if [ ! -s "$MEAS" ]; then
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "FAIL: no measurements file or empty after 60s: $MEAS" >&2
      docker compose logs --tail=50
      exit 1
    fi
    sleep 1
    continue
  fi
  # Count XADD samples per (region, shard). Want at least MIN_SAMPLES each.
  enough=1
  for region in a b c; do
    for shard in redis-a redis-b redis-c; do
      count=$(grep -F "\"region\":\"$region\"" "$MEAS" \
              | grep -F "\"target_shard\":\"$shard\"" \
              | grep -cF "\"op\":\"XADD\"")
      if [ "$count" -lt "$MIN_SAMPLES" ]; then
        enough=0
      fi
    done
  done
  if [ "$enough" -eq 1 ]; then break; fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "FAIL: timed out waiting for $MIN_SAMPLES samples per (region, shard) cell" >&2
    docker compose logs --tail=50
    exit 1
  fi
  sleep 1
done
echo "have >= $MIN_SAMPLES samples per (region, shard); computing medians..."

# --- 2) compute median latency per (region, op, shard) ---
median_latency() {
  local region=$1 op=$2 shard=$3
  grep -F "\"region\":\"$region\"" "$MEAS" \
    | grep -F "\"target_shard\":\"$shard\"" \
    | grep -F "\"op\":\"$op\"" \
    | grep -vF '"err":' \
    | sed -E 's/.*"latency_ms":([0-9.]+).*/\1/' \
    | sort -n \
    | awk '{ a[NR]=$1 } END { if (NR==0) print "NaN"; else if (NR%2==1) print a[(NR+1)/2]; else printf "%.3f\n", (a[NR/2]+a[NR/2+1])/2 }'
}

# Build the result table and check the property.
printf "\n%-10s | %-12s | %-12s | %-12s | %-10s\n" "region" "redis-a XADD" "redis-b XADD" "redis-c XADD" "verdict"
printf -- "-----------+--------------+--------------+--------------+-----------\n"

FAILED=0
for region in a b c; do
  m_a=$(median_latency "$region" XADD redis-a)
  m_b=$(median_latency "$region" XADD redis-b)
  m_c=$(median_latency "$region" XADD redis-c)

  local_shard=${LOCAL_SHARD[$region]}
  far_shard=${FAR_SHARD[$region]}
  case "$local_shard" in
    redis-a) m_local=$m_a ;;
    redis-b) m_local=$m_b ;;
    redis-c) m_local=$m_c ;;
  esac
  case "$far_shard" in
    redis-a) m_far=$m_a ;;
    redis-b) m_far=$m_b ;;
    redis-c) m_far=$m_c ;;
  esac

  verdict="PASS"
  if awk -v v="$m_local" -v th="$LOCAL_THRESHOLD_MS" 'BEGIN { exit !(v+0 > th+0) }'; then
    verdict="FAIL"
    FAILED=1
  fi
  if awk -v v="$m_far" -v th="$FAR_THRESHOLD_MS" 'BEGIN { exit !(v+0 < th+0) }'; then
    verdict="FAIL"
    FAILED=1
  fi

  printf "%-10s | %-12s | %-12s | %-12s | %-10s\n" "$region" "$m_a" "$m_b" "$m_c" "$verdict"
done

echo
if [ "$FAILED" -ne 0 ]; then
  echo "FAIL: at least one region's local/far latency asymmetry was not observed." >&2
  echo "      expected: local <= ${LOCAL_THRESHOLD_MS}ms, far >= ${FAR_THRESHOLD_MS}ms" >&2
  docker compose logs --tail=50 client-a client-b client-c proxy-init cluster-init
  exit 1
fi

echo "PASS: in every region, the LOCAL shard's median XADD latency stayed below"
echo "      ${LOCAL_THRESHOLD_MS}ms while the FAR shard's median was at least ${FAR_THRESHOLD_MS}ms."
echo "      Shard locality dominates — co-locating a Redis with each region does"
echo "      not help for streams owned by another region's master."
exit 0
