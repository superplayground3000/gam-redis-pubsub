#!/usr/bin/env bash
# Smoke test asserts the property: every one of the 9 tracked KVs is being
# propagated from central-redis to region-redis through the
# Vector → JetStream pipeline, and the per-event propagation delay is bounded.
#
# Steps:
#   1. Wait until producer has emitted enough ticks for every key to have been
#      written at least twice (so we'll observe at least one propagated update
#      for each key).
#   2. Read every tracked key from BOTH redis instances. Every key must be
#      present on region-redis and equal to its central-redis value (eventual
#      consistency; we re-check inside a bounded loop).
#   3. Sample JetStream stream info to confirm cdc.> messages have flowed.
#   4. Hit /api/state on the dashboard and verify it reports all 9 keys
#      in_sync.
#   5. Spot-check propagation delay: tail relay-consume logs for "applied"
#      lines; the highest delay_ms observed must be under MAX_ACCEPTABLE_DELAY_MS.

set -u
set -o pipefail

TRACKED_KEYS=(
  "lb:company:employees:id:55688"
  "lb:company:employees:id:55689"
  "lb:company:employees:id:55690"
  "lb:funtions:groups:id:89889"
  "lb:funtions:groups:id:89890"
  "lb:funtions:groups:id:89891"
  "lb:general:items:id:9123"
  "lb:general:items:id:9124"
  "lb:general:items:id:9125"
)

CONVERGE_DEADLINE=45      # seconds
MAX_ACCEPTABLE_DELAY_MS=3000

echo "smoke: waiting for region-redis to converge with central-redis on all ${#TRACKED_KEYS[@]} keys (deadline ${CONVERGE_DEADLINE}s)"

start=$(date +%s)
converged=0
last_mismatch_summary=""
while :; do
  now=$(date +%s)
  elapsed=$((now - start))
  if [ "$elapsed" -ge "$CONVERGE_DEADLINE" ]; then
    break
  fi

  mismatches=0
  last_mismatch_summary=""
  for k in "${TRACKED_KEYS[@]}"; do
    cVal=$(docker compose exec -T central-redis redis-cli GET "$k" 2>/dev/null | tr -d '\r')
    rVal=$(docker compose exec -T region-redis  redis-cli GET "$k" 2>/dev/null | tr -d '\r')
    if [ -z "$rVal" ]; then
      mismatches=$((mismatches+1))
      last_mismatch_summary="missing on region: $k"
      continue
    fi
    if [ "$cVal" != "$rVal" ]; then
      mismatches=$((mismatches+1))
      last_mismatch_summary="value drift on $k"
    fi
  done
  if [ "$mismatches" -eq 0 ] && [ -n "$cVal" ]; then
    converged=1
    break
  fi
  sleep 1
done

if [ "$converged" -ne 1 ]; then
  echo "FAIL: region-redis did not converge within ${CONVERGE_DEADLINE}s; last_state=${last_mismatch_summary}"
  echo "---- last central values ----"
  for k in "${TRACKED_KEYS[@]}"; do
    v=$(docker compose exec -T central-redis redis-cli GET "$k" 2>/dev/null | tr -d '\r')
    echo "central $k = $v"
  done
  echo "---- last region values ----"
  for k in "${TRACKED_KEYS[@]}"; do
    v=$(docker compose exec -T region-redis redis-cli GET "$k" 2>/dev/null | tr -d '\r')
    echo "region  $k = $v"
  done
  exit 1
fi
echo "smoke: all ${#TRACKED_KEYS[@]} keys are in sync between central-redis and region-redis (after ${elapsed}s)"

# JetStream stream info: confirm messages have flowed through cdc.>
js_msgs=$(docker compose exec -T nats sh -c "wget -qO- http://localhost:8222/jsz?streams=true" 2>/dev/null | grep -oE '"messages":[[:space:]]*[0-9]+' | head -n1 | grep -oE '[0-9]+')
js_msgs=${js_msgs:-0}
if [ "$js_msgs" -lt 9 ]; then
  echo "FAIL: JetStream stream has only ${js_msgs} messages; expected at least 9 (one per key)"
  exit 1
fi
echo "smoke: JetStream stream has ${js_msgs} messages (expected >= 9)"

# Dashboard /api/state
dash_state=$(docker compose exec -T dashboard wget -qO- http://localhost:8080/api/state 2>/dev/null)
if ! echo "$dash_state" | grep -q '"match":true'; then
  echo "FAIL: dashboard /api/state has no match:true rows"
  echo "$dash_state" | head -c 500
  exit 1
fi
match_count=$(echo "$dash_state" | grep -o '"match":true' | wc -l | tr -d ' ')
if [ "$match_count" -lt "${#TRACKED_KEYS[@]}" ]; then
  echo "FAIL: dashboard reports only ${match_count}/${#TRACKED_KEYS[@]} keys in sync"
  exit 1
fi
echo "smoke: dashboard reports ${match_count}/${#TRACKED_KEYS[@]} keys in sync"

# Propagation delay spot check.
max_delay=$(docker compose logs --no-color --tail=400 relay-consume 2>/dev/null \
  | grep -oE 'delay_ms=[0-9]+' | grep -oE '[0-9]+' \
  | sort -n | tail -n1)
max_delay=${max_delay:-0}
if [ "$max_delay" -gt "$MAX_ACCEPTABLE_DELAY_MS" ]; then
  echo "FAIL: observed propagation delay ${max_delay}ms exceeds threshold ${MAX_ACCEPTABLE_DELAY_MS}ms"
  echo "---- recent relay-consume log ----"
  docker compose logs --tail=30 relay-consume
  exit 1
fi
echo "smoke: max observed propagation delay = ${max_delay} ms (under ${MAX_ACCEPTABLE_DELAY_MS}ms threshold)"

echo
echo "PASS: 9/9 tracked keys propagated from central-redis through Vector + JetStream to region-redis,"
echo "      JetStream stream contains ${js_msgs} messages, dashboard reports all-in-sync,"
echo "      max observed propagation delay = ${max_delay} ms."
exit 0
