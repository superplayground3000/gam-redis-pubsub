#!/usr/bin/env bash
# Asserts two properties:
#   (1) End-to-end propagation: every event server XADDs to redis-source appears
#       in redis-sink as a `event:<id>` hash, and the client computes p50/p99
#       latency from produced_at_ns to observed_at_ns.
#   (2) Durability across consumer restart: midway through the producer phase
#       we `docker compose stop consumer`, wait, then `start` it again. The
#       producer keeps running through the gap. Final count must still be N.

set -u
set -o pipefail

EXPECTED=${MAX_MESSAGES:-100}
KILL_AT=$((EXPECTED / 2))
CLIENT_TIMEOUT=120

echo "smoke: expecting ${EXPECTED} events end-to-end; will kill consumer once sink reaches ~${KILL_AT}"

# Get container IDs.
client_id=$(docker compose ps -aq client)
if [ -z "$client_id" ]; then
    echo "FAIL: client container not found"
    docker compose ps -a
    exit 1
fi

# --- Step 1: wait until the sink has ~half the events, then stop consumer.
KILL_DEADLINE=60
ELAPSED=0
killed=0
while [ "$ELAPSED" -lt "$KILL_DEADLINE" ]; do
    count=$(docker compose exec -T redis-sink redis-cli DBSIZE 2>/dev/null | tr -d '\r' | awk 'NR==1{print $NF}')
    count=${count:-0}
    if [ "$count" -ge "$KILL_AT" ]; then
        echo "smoke: sink count=${count}; stopping consumer to test durability"
        docker compose stop consumer >/dev/null 2>&1
        killed=1
        break
    fi
    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
done

if [ "$killed" -ne 1 ]; then
    echo "FAIL: sink never reached ${KILL_AT} events within ${KILL_DEADLINE}s (last count=${count:-?})"
    docker compose logs --tail=30
    exit 1
fi

# --- Step 2: leave consumer down for ~3 seconds so producer keeps running into the gap.
sleep 3
echo "smoke: restarting consumer"
docker compose start consumer >/dev/null 2>&1

# --- Step 3: wait for the client to exit (it stops once it has seen all N events).
ELAPSED=0
state="unknown"
while [ "$ELAPSED" -lt "$CLIENT_TIMEOUT" ]; do
    state=$(docker inspect "$client_id" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    if [ "$state" = "exited" ]; then
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ "$state" != "exited" ]; then
    echo "FAIL: client did not exit within ${CLIENT_TIMEOUT}s (last status: ${state})"
    docker compose ps -a
    docker compose logs --tail=30 client
    exit 1
fi

client_exit=$(docker inspect "$client_id" --format '{{.State.ExitCode}}')
if [ "$client_exit" != "0" ]; then
    echo "FAIL: client exited with code ${client_exit}"
    docker compose logs --tail=80 client
    docker compose logs --tail=50 consumer
    exit 1
fi
echo "smoke: client exited cleanly"

# --- Step 4: verify final state on the sink matches N.
final_count=$(docker compose exec -T redis-sink redis-cli DBSIZE 2>/dev/null | tr -d '\r' | awk 'NR==1{print $NF}')
final_count=${final_count:-0}
if [ "$final_count" -ne "$EXPECTED" ]; then
    echo "FAIL: redis-sink DBSIZE is ${final_count}, expected ${EXPECTED}"
    docker compose logs --tail=50 consumer
    exit 1
fi

# --- Step 5: extract and echo the client's latency stats.
echo ""
echo "--- client latency stats ---"
docker compose logs --no-log-prefix client 2>&1 | sed -n '/=== LATENCY STATS ===/,$p'

echo ""
echo "PASS: ${EXPECTED} events propagated end-to-end (server -> redis-source -> nats -> redis-sink) including across a consumer restart; latency stats above."
exit 0
