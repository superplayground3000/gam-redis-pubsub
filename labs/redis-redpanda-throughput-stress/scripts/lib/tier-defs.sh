#!/usr/bin/env bash
# Tier knobs for the throughput-stress lab. Sourced by stress-run.sh.

# Default tiers (override via --tiers=5000,50000)
DEFAULT_TIERS=(5000 10000 20000 30000 40000 50000)

# Default modes (override via --modes=batch,single)
DEFAULT_MODES=(batch single)

# Achieved-rate floor as fraction of target.
# Rate-floor rationale:
# - 5k tier: 0.85 (loose) — 16 workers + adaptive batch=500 = wait contention
#   on the shared limiter at low rates; achievable is ~85-90%. A proper fix is
#   per-worker adaptive depth; deferred to a future tuning pass.
# - 10k+ tiers: 0.90-0.95 — writer ramp matches limiter capacity at these rates.
declare -A TIER_RATE_MIN_PCT=(
  [5000]=0.85
  [10000]=0.95
  [20000]=0.90
  [30000]=0.90
  [40000]=0.90
  [50000]=0.90
)

# Per-tier p99 sync-latency ceiling (ms).
# Empty string = no ceiling (calibration mode); collector treats <=0 as "skip p99 gate".
# After the first full-matrix run, edit these to commit real ceilings.
declare -A TIER_P99_MS=(
  [5000]=""
  [10000]=""
  [20000]=""
  [30000]=""
  [40000]=""
  [50000]=""
)

# Run windows (env-overridable)
DURATION_S="${DURATION_S:-30}"
WARMUP_S="${WARMUP_S:-5}"
DRAIN_S="${DRAIN_S:-10}"
