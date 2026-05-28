#!/usr/bin/env bash
# Tier knobs for the throughput-stress lab. Sourced by stress-run.sh.

# Default tiers (override via --tiers=5000,50000)
DEFAULT_TIERS=(5000 10000 20000 30000 40000 50000)

# Default modes (override via --modes=batch,single)
DEFAULT_MODES=(batch single)

# Achieved-rate floor as fraction of target.
# Rate-floor rationale (calibrated 2026-05-26 from a full-matrix run on
# 32-core / 122 GiB host; see commit message):
# - 5k & 10k tiers: 0.85 (loose) — 16 workers + adaptive batch=500 creates
#   wait contention on the shared limiter at low rates; achievable is ~89-94%.
#   A proper fix is per-worker adaptive depth; deferred to a future tuning pass.
# - 20k-40k tiers: 0.90 — writer ramp matches limiter capacity here; pipeline
#   sustains rate cleanly until ~40k where receiver lag starts trimming.
# - 50k: 0.90 — aspirational; pipeline tops out around 40-45k on this host.
#   Both modes lose 40-50% of messages at 50k; the FAIL here is the lab's
#   "where does it top out?" signal, not a regression.
declare -A TIER_RATE_MIN_PCT=(
  [5000]=0.85
  [10000]=0.85
  [20000]=0.90
  [30000]=0.90
  [40000]=0.90
  [50000]=0.90
)

# Per-tier p99 sync-latency ceiling (ms).
# Calibrated 2026-05-26 from a full-matrix run on a 32-core / 122 GiB host.
# Heuristic: ceiling = round_up_to_100ms(max(p99_batch, p99_single) * 1.25),
# with floor 100ms to avoid flapping on noise.
# Tiers where one mode failed verdict use the passing mode's p99 only.
# Tier breakdown (observed p99 ms, 2026-05-28 final matrix after sink bumps).
# Some tiers skip the p99 gate because either p99 is too unstable
# across matrix runs or missing/trim is the meaningful failure signal:
#
#   5k:  batch=14,   single=1     -> ceil 600  (loose; legacy stable)
#   10k: batch=14,   single=1     -> ceil 800  (stable post-sink-bump)
#   20k: batch=876,  single=2     -> p99 SKIPPED (batch swings 14-876 across
#                                                  consecutive matrices)
#   30k: batch=363,  single=20    -> ceil 600  (stable)
#   40k: batch=2181 (trim 1.28M), single=8775 (trim 1.29M)
#        p99 SKIPPED -- the bumped sink now overruns the regional MAXLEN=2M
#        at 40k BOTH modes; the trim is the real failure signal, p99 is noise.
#   50k: HOST CEILING tier (both modes FAIL by design); p99 gate skipped.
#        batch=695k missing, single=583k missing.
#        The lab tops out around 30k batch / 30k single loss-free on this host.
#        See spec amendment 2026-05-28 and RESEARCH.md "And then: 50k declared
#        as host ceiling".
#
# IMPORTANT — p99 has substantial warm-up-dependent variance. The numbers
# above assume a full sequential matrix run (default `bash scripts/stress-run.sh`)
# where earlier tiers warm up the JetStream consumer + Connect-sink in-flight
# buffer. Single-tier reruns from cold can see p99 10-100x higher (e.g., a
# 30k batch rerun observed 1921ms vs the matrix's 15ms). If you re-run a
# single tier and the p99 gate fails, re-run the full matrix instead.
# Empty string = no ceiling; collector treats <=0 as "skip p99 gate".
declare -A TIER_P99_MS=(
  [5000]=600
  [10000]=800
  [20000]=""
  [30000]=600
  [40000]=""
  [50000]=""
)

# Run windows (env-overridable)
DURATION_S="${DURATION_S:-30}"
WARMUP_S="${WARMUP_S:-5}"
DRAIN_S="${DRAIN_S:-30}"
