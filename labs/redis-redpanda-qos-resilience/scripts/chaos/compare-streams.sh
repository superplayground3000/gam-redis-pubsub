#!/usr/bin/env bash
# Compares app.events (central) vs region-events (region) by event_id.
# Reports:
#   - XLEN of each
#   - count of source ids NOT present in region (lost)
#   - count of region ids NOT present in source (impossible unless replay; sanity)
#   - count of region entries that share an event_id with another (duplicates)
set -euo pipefail

REDIS_CENTRAL_PORT="${REDIS_CENTRAL_PORT:-16379}"
REDIS_REGION_PORT="${REDIS_REGION_PORT:-16380}"

_container_for_port() {
  case "$1" in
    "$REDIS_CENTRAL_PORT") echo "rrqr-redis-central" ;;
    "$REDIS_REGION_PORT")  echo "rrqr-redis-region" ;;
    *) echo "" ;;
  esac
}

redc() {
  local port="$1"; shift
  if command -v redis-cli >/dev/null 2>&1; then
    redis-cli -h 127.0.0.1 -p "$port" "$@"
  else
    local c
    c=$(_container_for_port "$port")
    [ -n "$c" ] || { echo "no container for port $port" >&2; return 1; }
    docker exec -i "$c" redis-cli "$@"
  fi
}

src_raw=$(mktemp)
reg_raw=$(mktemp)
src_sorted=$(mktemp)
reg_sorted=$(mktemp)
reg_dedup=$(mktemp)
trap 'rm -f "$src_raw" "$reg_raw" "$src_sorted" "$reg_sorted" "$reg_dedup"' EXIT

src_len=$(redc "$REDIS_CENTRAL_PORT" XLEN app.events | tr -d '\r' || echo 0)
reg_len=$(redc "$REDIS_REGION_PORT" XLEN region-events 2>/dev/null | tr -d '\r' || echo 0)

# XRANGE non-TTY output is one token per line. event_id values are the line
# immediately following "event_id". tr -d '\r' guards against CRs from
# docker-exec piping.
redc "$REDIS_CENTRAL_PORT" XRANGE app.events - + | tr -d '\r' | \
  awk 'prev=="event_id" {print; prev=""} {prev=$0}' > "$src_raw"

redc "$REDIS_REGION_PORT" XRANGE region-events - + 2>/dev/null | tr -d '\r' | \
  awk 'prev=="event_id" {print; prev=""} {prev=$0}' > "$reg_raw" || true

# LC_ALL=C: byte-order collation. comm requires the same ordering its inputs
# were sorted with — locale-sensitive sort breaks comm under most distro
# defaults. Force C here for both sort and comm.
LC_ALL=C sort -u "$src_raw" -o "$src_sorted"
LC_ALL=C sort    "$reg_raw" -o "$reg_sorted"
LC_ALL=C uniq    "$reg_sorted" > "$reg_dedup"

src_unique=$(wc -l < "$src_sorted" | tr -d ' ')
reg_unique=$(wc -l < "$reg_dedup"  | tr -d ' ')
dups=$(LC_ALL=C uniq -d < "$reg_sorted" | wc -l | tr -d ' ')
missing=$(LC_ALL=C comm -23 "$src_sorted" "$reg_dedup" | wc -l | tr -d ' ')
extra=$(LC_ALL=C comm -13 "$src_sorted" "$reg_dedup" | wc -l | tr -d ' ')

echo "source app.events XLEN     : $src_len  (unique event_ids: $src_unique)"
echo "region region-events XLEN  : $reg_len  (unique event_ids: $reg_unique)"
echo "missing in region (loss)   : $missing"
echo "extra in region            : $extra"
echo "duplicate event_ids region : $dups"
