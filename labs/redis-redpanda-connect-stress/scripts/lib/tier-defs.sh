#!/usr/bin/env bash
# Tier SLOs and run-window knobs. Sourced by stress-run.sh.

# Default tiers (override via --tiers=10,1000 on stress-run.sh)
DEFAULT_TIERS=(10 1000 10000)

# Default modes (override via --modes=...)
DEFAULT_MODES=(throughput latency chaos)

# Latency p99 SLO (ms) per tier
declare -A TIER_P99_MS=(
  [10]=200
  [1000]=1000
  [10000]=5000
)

# Achieved-rate floor as fraction of target
declare -A TIER_RATE_MIN_PCT=(
  [10]=0.95
  [1000]=0.95
  [10000]=0.90
)

# Run windows (env-overridable)
DURATION_S="${DURATION_S:-30}"
WARMUP_S="${WARMUP_S:-5}"
DRAIN_S="${DRAIN_S:-10}"

# Chaos parameters
CHAOS_DOWN_S="${CHAOS_DOWN_S:-8}"
# Chaos kicks in at sustain_mid by default
chaos_at_s() { echo $(( DURATION_S / 2 )); }

# Returns "true" if profile is amo (allows missing messages)
allow_missing_for_profile() {
  case "$1" in
    amo) echo "true" ;;
    *)   echo "false" ;;
  esac
}
