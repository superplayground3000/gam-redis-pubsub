#!/usr/bin/env bash
# Asserts the property: each of the three consumer groups received the same set
# of message IDs the producer wrote. Run from inside the lab directory by
# validate_lab.sh after `docker compose up -d --wait` has succeeded.

set -u
set -o pipefail

EXPECTED=${MAX_MESSAGES:-10}
TIMEOUT=60
ELAPSED=0

echo "smoke: waiting up to ${TIMEOUT}s for producer to finish (expected ${EXPECTED} messages)"

producer_id=$(docker compose ps -aq producer)
if [ -z "$producer_id" ]; then
    echo "FAIL: producer container not found"
    docker compose ps -a
    exit 1
fi

state="unknown"
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    state=$(docker inspect "$producer_id" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    if [ "$state" = "exited" ]; then
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ "$state" != "exited" ]; then
    echo "FAIL: producer did not exit within ${TIMEOUT}s (last status: $state)"
    docker compose ps -a
    exit 1
fi

producer_exit=$(docker inspect "$producer_id" --format '{{.State.ExitCode}}')
if [ "$producer_exit" != "0" ]; then
    echo "FAIL: producer exited with code $producer_exit"
    docker compose logs producer
    exit 1
fi
echo "smoke: producer exited cleanly after ${ELAPSED}s"

# Allow consumers a couple of seconds to drain the last batch they read.
sleep 3

extract_ids() {
    docker compose logs "$1" 2>/dev/null | grep -oE 'id=[0-9]+-[0-9]+' | sort -u
}

A=$(extract_ids consumer-a)
B=$(extract_ids consumer-b)
C=$(extract_ids consumer-c)

count_a=$(printf '%s\n' "$A" | grep -c . || true)
count_b=$(printf '%s\n' "$B" | grep -c . || true)
count_c=$(printf '%s\n' "$C" | grep -c . || true)

echo "smoke: counts — a=${count_a} b=${count_b} c=${count_c} (expected ${EXPECTED} each)"

if [ "$count_a" -ne "$EXPECTED" ] || [ "$count_b" -ne "$EXPECTED" ] || [ "$count_c" -ne "$EXPECTED" ]; then
    echo "FAIL: not every group received ${EXPECTED} messages"
    echo "--- consumer-a IDs ---"; printf '%s\n' "$A"
    echo "--- consumer-b IDs ---"; printf '%s\n' "$B"
    echo "--- consumer-c IDs ---"; printf '%s\n' "$C"
    exit 1
fi

if [ "$A" != "$B" ] || [ "$B" != "$C" ]; then
    echo "FAIL: consumer groups did not receive the same set of IDs"
    diff <(printf '%s\n' "$A") <(printf '%s\n' "$B") || true
    diff <(printf '%s\n' "$B") <(printf '%s\n' "$C") || true
    exit 1
fi

echo "PASS: all three consumer groups received the same ${EXPECTED} messages — multi-group fanout demonstrated."
exit 0
