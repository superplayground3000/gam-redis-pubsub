#!/usr/bin/env bash
# Start writer traffic so custom counters fire on both legs, then hold briefly.
set -euo pipefail
w="http://localhost:${WRITER_PORT:-18081}"
# Worker loop is gated on a non-empty State.Epoch(); /rate alone sets the target
# rate but workers stay parked until /reset assigns an epoch (see
# labs/by-key-prefix-split-topic/scripts/verify-prefix-split.sh for precedent).
curl -fsS -XPOST "$w/reset" -d "{\"Epoch\":\"drive-$(date +%s)\"}" && echo
curl -fsS -XPOST "$w/rate" -d '{"Rate":50}' && echo
echo "driving traffic for ${1:-45}s..."
sleep "${1:-45}"
curl -fsS -XPOST "$w/rate" -d '{"Rate":0}' && echo "stopped"
