#!/usr/bin/env bash
# Stops connect-sink for DOWNTIME_S seconds, then restarts.
# JetStream durable consumer "region-writer" preserves the position; under ALO
# and EOE the sink replays everything missed. Under AMO, in-flight messages are
# lost.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
drill connect-sink "connect-sink (reverse leg)"
