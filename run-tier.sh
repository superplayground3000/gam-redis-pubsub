#!/usr/bin/env bash
# Usage: ./scripts/run-tier.sh {smoke|stress|scale}
#   smoke  = 10,000 events
#   stress = 100,000 events
#   scale  = 1,000,000 events
#
# Workflow:
#   1) Bring up the stack (idempotent).
#   2) FLUSHALL every edge so the run starts clean.
#   3) Reset the central stream and consumer group.
#   4) Push N events via loadgen.
#   5) Run validator until all edges converge to N and value-parity passes.

set -euo pipefail
cd "$(dirname "$0")/.."

TIER="${1:-smoke}"
case "$TIER" in
  smoke)  COUNT=10000   ; TIMEOUT=120  ; SAMPLE=500  ;;
  stress) COUNT=100000  ; TIMEOUT=300  ; SAMPLE=2000 ;;
  scale)  COUNT=1000000 ; TIMEOUT=1800 ; SAMPLE=5000 ;;
  *) echo "usage: $0 {smoke|stress|scale}" ; exit 1 ;;
esac

echo "================================================================"
echo " Tier: $TIER   events=$COUNT   timeout=${TIMEOUT}s   sample=$SAMPLE"
echo "================================================================"

echo "[step 1/5] starting stack..."
docker compose up -d redis-central redis-edge-1 redis-edge-2 redis-edge-3 relay

echo "[step 2/5] waiting for healthchecks..."
for c in rf-central rf-edge-1 rf-edge-2 rf-edge-3; do
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo none)" = "healthy" ]; do
    sleep 1
  done
  echo "   $c: healthy"
done

echo "[step 3/5] cleaning edge state + central stream..."
for c in rf-edge-1 rf-edge-2 rf-edge-3; do
  docker exec "$c" redis-cli FLUSHALL >/dev/null
done
docker exec rf-central redis-cli DEL events >/dev/null
docker exec rf-central redis-cli XADD events '*' op set key __init__ value seed >/dev/null
docker exec rf-central redis-cli DEL events >/dev/null
# Restart relay so it picks up the recreated stream cleanly.
docker compose restart relay >/dev/null
sleep 2

echo "[step 4/5] producing $COUNT events..."
START=$(date +%s)
docker compose --profile tools run --rm loadgen \
  python loadgen.py --count "$COUNT" --batch 1000

echo "[step 5/5] validating convergence..."
docker compose --profile tools run --rm loadgen \
  python validate.py --count "$COUNT" --timeout "$TIMEOUT" --sample "$SAMPLE"

ELAPSED=$(( $(date +%s) - START ))
echo
echo "================================================================"
echo " Tier '$TIER' complete. wall-clock=${ELAPSED}s"
echo "================================================================"
