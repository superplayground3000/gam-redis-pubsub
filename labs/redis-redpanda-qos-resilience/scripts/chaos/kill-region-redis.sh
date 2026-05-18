#!/usr/bin/env bash
# Stops the region Redis for DOWNTIME_S seconds, then restarts.
# Under ALO/EOE: connect-sink fails its writes, nacks, NATS redelivers — region
# catches up after restart. Under AMO: those nacked messages are dropped.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
drill redis-region "region-redis (sink-side store)"
