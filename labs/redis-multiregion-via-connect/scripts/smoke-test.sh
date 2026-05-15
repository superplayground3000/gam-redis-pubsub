#!/usr/bin/env bash
# Asserts: every produced KV write reaches region within budget.
#   1) wait for writer to populate all 9 keys in central
#   2) check region eventually has all 9
#   3) inject probe writes per pattern, measure SET-to-SET propagation
set -euo pipefail

REDIS_CENTRAL_PORT="${REDIS_CENTRAL_PORT:-15379}"
REDIS_REGION_PORT="${REDIS_REGION_PORT:-15380}"
DASHBOARD_PORT="${DASHBOARD_PORT:-15080}"
WAIT_FOR_FILL_S="${WAIT_FOR_FILL_S:-12}"
PROBE_BUDGET_MS="${PROBE_BUDGET_MS:-3000}"
SETTLE_BUDGET_MS="${SETTLE_BUDGET_MS:-5000}"

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

# Use probe-only keys the writer never touches, so the writer's 1Hz updates
# don't race with the probe value during the polling window.
PROBES=(
  "lb:company:employees:id:probe1|company"
  "lb:functions:groups:id:probe2|functions"
  "lb:general:items:id:probe3|general"
)

# Map host port -> container name (for docker exec fallback)
_container_for_port() {
  case "$1" in
    "$REDIS_CENTRAL_PORT") echo "rmvc-redis-central" ;;
    "$REDIS_REGION_PORT")  echo "rmvc-redis-region" ;;
    *) echo "" ;;
  esac
}

# redis-cli wrapper: prefer host redis-cli, fall back to docker exec into the container.
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

fail() { echo "FAIL: $*"; exit 1; }

echo "[1/5] waiting ${WAIT_FOR_FILL_S}s for writer to populate keys..."
sleep "$WAIT_FOR_FILL_S"

echo "[2/5] dashboard /healthz"
curl -sf "http://127.0.0.1:${DASHBOARD_PORT}/healthz" >/dev/null || fail "dashboard /healthz not 2xx"
echo "  ok"

echo "[3/5] all 9 keys present in central"
for k in "${EXPECTED_KEYS[@]}"; do
  v=$(redc "$REDIS_CENTRAL_PORT" GET "$k" || true)
  [ -n "$v" ] || fail "central missing $k after fill window"
done
echo "  ok"

echo "[4/5] all 9 keys eventually present in region (budget ${SETTLE_BUDGET_MS}ms)"
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

echo "[5/5] probe-write propagation per pattern (budget ${PROBE_BUDGET_MS}ms each)"
for entry in "${PROBES[@]}"; do
  key="${entry%|*}"
  pattern="${entry#*|}"
  probe_id="smoke-$(date +%s%N)-$RANDOM"
  t_send=$(now_ms)
  value="{\"v\":-1,\"event_id\":\"$probe_id\",\"t_send_ms\":$t_send}"
  redc "$REDIS_CENTRAL_PORT" SET "$key" "$value" >/dev/null
  redc "$REDIS_CENTRAL_PORT" XADD app.events '*' \
    event_id "$probe_id" \
    key "$key" \
    value "$value" \
    pattern "$pattern" \
    t_send_ms "$t_send" >/dev/null

  deadline=$(( t_send + PROBE_BUDGET_MS ))
  arrived=0
  while [ "$(now_ms)" -lt "$deadline" ]; do
    v=$(redc "$REDIS_REGION_PORT" GET "$key" || true)
    if [ -n "$v" ] && [[ "$v" == *"$probe_id"* ]]; then
      arrival=$(now_ms)
      echo "  probe pattern=$pattern key=$key delta=$((arrival - t_send))ms"
      arrived=1
      break
    fi
    sleep 0.02
  done
  [ "$arrived" -eq 1 ] || fail "probe $probe_id did not propagate within ${PROBE_BUDGET_MS}ms"
done

echo
echo "PROPERTY DEMONSTRATED:"
echo "  - 9/9 KV keys propagate central -> region."
echo "  - Per-pattern probe SET-to-SET propagation < ${PROBE_BUDGET_MS}ms."
echo "  - Dashboard live at http://127.0.0.1:${DASHBOARD_PORT}/"
