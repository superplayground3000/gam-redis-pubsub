#!/usr/bin/env bash
# ensure-consumers.sh — (re)create one durable pull consumer per prefix on KV_CDC,
# mirroring nats-init's flags (DESIGN F6/§5.4), and delete the chart's default
# cdc_sink (nobody binds it; its num_pending would only grow and pollute reads).
# Idempotent: removes then re-adds each consumer so MAX_ACK_PENDING changes between
# scenarios take effect cleanly. Call during a scenario reset (writer at 0, drained).
#   MAX_ACK_PENDING is the scenario knob.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

# drop the unused default consumer if present (ignore error if already gone)
natsadm consumer rm "$STREAM" cdc_sink -f >/dev/null 2>&1 || true

for p in "${PREFIX_ARR[@]}"; do
  name="cdc_sink_${p}"
  # recreate for a clean, known max-ack-pending
  natsadm consumer rm "$STREAM" "$name" -f >/dev/null 2>&1 || true
  natsadm consumer add "$STREAM" "$name" --pull \
    --filter "kv.cdc.${p}.>" --ack explicit --deliver all --replay instant \
    --wait 30s --max-pending "$MAX_ACK_PENDING" --max-deliver=-1 \
    --no-headers-only --defaults >/dev/null
  echo "[consumers] $name filter=kv.cdc.${p}.> max_ack_pending=$MAX_ACK_PENDING"
done
