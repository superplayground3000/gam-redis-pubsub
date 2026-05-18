#!/usr/bin/env bash
# Stops connect-source for DOWNTIME_S seconds, then restarts.
# Demonstrates that Redis Stream PEL holds unacked entries while connect-source
# is gone — under ALO and EOE, region catches up after restart with no loss.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
drill connect-source "connect-source (forward leg)"
