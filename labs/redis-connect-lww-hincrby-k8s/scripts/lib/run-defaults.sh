# shellcheck shell=bash
# Run-window defaults for the LWW lab (env-overridable). Sourced, not executed.
: "${DURATION_S:=30}"
: "${WARMUP_S:=5}"
: "${DRAIN_S:=10}"
: "${RATE:=5000}"
# Default ladder stays at/under the writer's MAX_RATE (values.yaml writer.env
# MAX_RATE=20000); a tier above MAX_RATE would be silently capped by the writer
# and report a misleading rate. Raise both together to push higher.
: "${SWEEP_TIERS:=5000,10000,20000}"
