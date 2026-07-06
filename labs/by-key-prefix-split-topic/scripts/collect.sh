#!/usr/bin/env bash
# collect.sh <csv_path> <scenario> <duration_s>
# Samples raw CUMULATIVE counters every SCRAPE_INTERVAL_S into CSV (rates computed at
# plot time — DESIGN §5.6). A failed scrape writes NA for that field and continues;
# the collector never aborts the measurement. Scrapes all 4 prefix slots (idle ones
# read 0/absent -> NA). Run in the background by the entrypoint.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

CSV="$1"; SCEN="$2"; DUR="$3"
END=$(( $(date +%s) + DUR ))

# consumer JSON field (num_pending / num_ack_pending), NA on failure
cfield() { # $1=consumer $2=field
  local v
  v="$(natsadm consumer info "$STREAM" "$1" -j 2>/dev/null | grep -oE "\"$2\": *[0-9]+" | grep -oE '[0-9]+' | head -1)"
  echo "${v:-NA}"
}
# latency gauge in ms from latency-calculator, NA on failure. $1=quantile
lat_ms() {
  local v
  v="$(tb curl -sf http://lab-latency-calculator:8082/metrics 2>/dev/null \
       | awk -v q="quantile=\"$1\"" '$0 ~ /cdc_latency_seconds/ && $0 ~ q && $1 !~ /#/ {if($NF+0>m)m=$NF+0} END{if(m>0)printf "%.1f", m*1000; else print "NA"}')"
  echo "${v:-NA}"
}
# source-side consumer-group lag on app.events (via redis-cli in the redis pod)
src_lag() {
  local v
  v="$(kc exec deploy/lab-redis-central -- redis-cli XINFO GROUPS app.events 2>/dev/null \
       | awk '/^lag$/{getline; print $1; exit}')"
  echo "${v:-NA}"
}
na() { echo "${1:-NA}"; }

# header
echo "ts_epoch,scenario,writer_sent,writer_rate_target,apply_a,apply_b,apply_c,apply_d,pending_a,pending_b,pending_c,pending_d,ackp_a,ackp_b,ackp_c,ackp_d,p50_ms,p95_ms,p99_ms,unproc_total,source_lag" > "$CSV"

while [ "$(date +%s)" -lt "$END" ]; do
  ts="$(date +%s)"
  wsent="$(prom_sum lab-writer:8081 'cdc_writer_sent_total')";  wsent="${wsent:-NA}"
  wrate="$(tb curl -sf http://lab-writer:8081/metrics 2>/dev/null | awk '$1=="cdc_writer_rate_target"{print $2}')"; wrate="${wrate:-NA}"

  declare -a AP PEND ACKP
  unproc=0; unproc_seen=0
  for idx in 0 1 2 3; do
    p="${PREFIX_ARR[$idx]:-}"
    if [ -n "$p" ]; then
      a="$(prom_sum "lab-sink-${p}:4195" 'cdc_apply')"; AP[$idx]="${a:-0}"
      u="$(prom_sum "lab-sink-${p}:4195" 'cdc_unprocessable')"; if [ -n "$u" ]; then unproc=$((unproc+u)); unproc_seen=1; fi
      PEND[$idx]="$(cfield "cdc_sink_${p}" num_pending)"
      ACKP[$idx]="$(cfield "cdc_sink_${p}" num_ack_pending)"
    else
      AP[$idx]=NA; PEND[$idx]=NA; ACKP[$idx]=NA
    fi
  done
  [ "$unproc_seen" = 1 ] || unproc=NA

  p50="$(lat_ms 0.5)"; p95="$(lat_ms 0.95)"; p99="$(lat_ms 0.99)"
  lag="$(src_lag)"

  echo "${ts},${SCEN},${wsent},${wrate},${AP[0]},${AP[1]},${AP[2]},${AP[3]},${PEND[0]},${PEND[1]},${PEND[2]},${PEND[3]},${ACKP[0]},${ACKP[1]},${ACKP[2]},${ACKP[3]},${p50},${p95},${p99},${unproc},${lag}" >> "$CSV"
  sleep "$SCRAPE_INTERVAL_S"
done
