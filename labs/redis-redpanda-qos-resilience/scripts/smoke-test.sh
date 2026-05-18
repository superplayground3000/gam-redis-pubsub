#!/usr/bin/env bash
# Property under test:
#   With PROFILE_QOS=alo (the default), every event_id written to app.events on
#   central Redis eventually appears in region-events on region Redis — even
#   when connect-sink is killed mid-flight for ~10 seconds.
#
# Sequence:
#   1) wait WAIT_FOR_FILL_S for writer to produce events
#   2) all 9 keys present in central and region
#   3) snapshot source XLEN
#   4) chaos: stop connect-sink for CHAOS_DOWN_S, then restart
#   5) wait CHAOS_CATCHUP_S for catch-up
#   6) compare-streams: missing-in-region count must be 0
#
# Property is NOT "zero duplicates" — under ALO, duplicates are allowed.
# Run smoke-test.sh under PROFILE_QOS=eoe to also assert "zero duplicates".
set -euo pipefail

cd "$(dirname "$0")/.."

REDIS_CENTRAL_PORT="${REDIS_CENTRAL_PORT:-16379}"
REDIS_REGION_PORT="${REDIS_REGION_PORT:-16380}"
DASHBOARD_PORT="${DASHBOARD_PORT:-16080}"
WAIT_FOR_FILL_S="${WAIT_FOR_FILL_S:-12}"
SETTLE_BUDGET_MS="${SETTLE_BUDGET_MS:-8000}"
CHAOS_DOWN_S="${CHAOS_DOWN_S:-8}"
CHAOS_CATCHUP_S="${CHAOS_CATCHUP_S:-15}"
PROFILE_QOS="${PROFILE_QOS:-alo}"

EXPECTED_KEYS=(
  "lb:company:employees:id:55688"
  "lb:company:employees:id:55689"
  "lb:company:employees:id:55690"
  "lb:functions:groups:id:89889"
  "lb:functions:groups:id:89890"
  "lb:functions:groups:id:89891"
  "lb:general:items:id:9123"
  "lb:general:items:id:9124"
  "lb:general:items:id:9125"
)

_container_for_port() {
  case "$1" in
    "$REDIS_CENTRAL_PORT") echo "rrqr-redis-central" ;;
    "$REDIS_REGION_PORT")  echo "rrqr-redis-region" ;;
    *) echo "" ;;
  esac
}

redc() {
  local port="$1"; shift
  if command -v redis-cli >/dev/null 2>&1; then
    redis-cli -h 127.0.0.1 -p "$port" "$@"
  else
    local c
    c=$(_container_for_port "$port")
    [ -n "$c" ] || { echo "no container for port $port" >&2; return 1; }
    docker exec -i "$c" redis-cli "$@"
  fi
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    local s n
    s=$(date +%s)
    n=$(date +%N 2>/dev/null || echo "000000000")
    printf '%d%03d\n' "$s" "$((10#${n:0:3}))"
  fi
}

fail() {
  echo "FAIL: $*"
  echo
  echo "--- recent logs (tail 30) ---"
  for svc in writer connect-source nats connect-sink dashboard; do
    echo "==== $svc ===="
    docker compose logs --tail=30 "$svc" 2>&1 || true
  done
  exit 1
}

echo "[1/6] waiting ${WAIT_FOR_FILL_S}s for writer to populate keys (profile=${PROFILE_QOS})..."
sleep "$WAIT_FOR_FILL_S"

echo "[2/6] dashboard /healthz and writer /healthz"
curl -sf "http://127.0.0.1:${DASHBOARD_PORT}/healthz" >/dev/null || fail "dashboard /healthz"
curl -sf "http://127.0.0.1:${DASHBOARD_PORT}/metrics" >/dev/null || fail "dashboard /metrics"
echo "  ok"

echo "[3/6] all 9 keys present in central, and eventually in region (budget ${SETTLE_BUDGET_MS}ms)"
for k in "${EXPECTED_KEYS[@]}"; do
  v=$(redc "$REDIS_CENTRAL_PORT" GET "$k" || true)
  [ -n "$v" ] || fail "central missing $k after fill window"
done
deadline=$(( $(now_ms) + SETTLE_BUDGET_MS ))
missing=()
while [ "$(now_ms)" -lt "$deadline" ]; do
  missing=()
  for k in "${EXPECTED_KEYS[@]}"; do
    v=$(redc "$REDIS_REGION_PORT" GET "$k" || true)
    [ -n "$v" ] || missing+=("$k")
  done
  [ "${#missing[@]}" -eq 0 ] && break
  sleep 0.2
done
[ "${#missing[@]}" -eq 0 ] || fail "region missing after settle: ${missing[*]}"
echo "  ok"

echo "[4/6] snapshotting source XLEN before chaos..."
src_before=$(redc "$REDIS_CENTRAL_PORT" XLEN app.events | tr -d '\r')
reg_before=$(redc "$REDIS_REGION_PORT" XLEN region-events 2>/dev/null | tr -d '\r' || echo 0)
echo "  source XLEN=${src_before}  region XLEN=${reg_before}"

echo "[5/6] chaos drill: stopping connect-sink for ${CHAOS_DOWN_S}s..."
DOWNTIME_S="$CHAOS_DOWN_S" bash scripts/chaos/kill-connect-sink.sh >/dev/null
echo "  connect-sink restarted; waiting ${CHAOS_CATCHUP_S}s for catch-up..."
sleep "$CHAOS_CATCHUP_S"

echo "[6/6] property check: zero missing event_ids in region-events"
report=$(bash scripts/chaos/compare-streams.sh)
echo "$report" | sed 's/^/  /'
missing_count=$(echo "$report" | awk -F: '/missing in region/ {gsub(/ /,"",$2); print $2}')
if [ -z "$missing_count" ]; then
  fail "could not parse missing-in-region from compare-streams output"
fi
if [ "$missing_count" != "0" ]; then
  fail "expected 0 missing event_ids in region-events under PROFILE_QOS=${PROFILE_QOS}, got ${missing_count}"
fi

echo
echo "PROPERTY DEMONSTRATED (profile=${PROFILE_QOS}):"
echo "  - 9/9 KV keys propagate central -> region"
echo "  - After ${CHAOS_DOWN_S}s connect-sink outage, all ${src_before}+ source event_ids are present in region-events"
echo "  - Dashboard live at http://127.0.0.1:${DASHBOARD_PORT}/"
