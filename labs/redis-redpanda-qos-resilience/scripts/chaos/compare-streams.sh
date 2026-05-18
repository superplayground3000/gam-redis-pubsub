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

# Pull source event_ids from app.events (key field "event_id").
src_tmp=$(mktemp)
reg_tmp=$(mktemp)
trap 'rm -f "$src_tmp" "$reg_tmp"' EXIT

src_len=$(redc "$REDIS_CENTRAL_PORT" XLEN app.events | tr -d '\r' || echo 0)
reg_len=$(redc "$REDIS_REGION_PORT" XLEN region-events 2>/dev/null | tr -d '\r' || echo 0)

# XRANGE returns lines: id then field/value pairs. Extract event_id values.
redc "$REDIS_CENTRAL_PORT" XRANGE app.events - + | \
  awk 'prev=="event_id" {print; prev=""} {prev=$0}' > "$src_tmp"

redc "$REDIS_REGION_PORT" XRANGE region-events - + 2>/dev/null | \
  awk 'prev=="event_id" {print; prev=""} {prev=$0}' > "$reg_tmp" || true

# missing in region: source ids not in region
missing=$(comm -23 <(sort -u "$src_tmp") <(sort -u "$reg_tmp") | wc -l)
# extra in region: region ids not in source (shouldn't happen normally)
extra=$(comm -13 <(sort -u "$src_tmp") <(sort -u "$reg_tmp") | wc -l)
# duplicates in region: region entries with duplicate event_id
dups=$(sort "$reg_tmp" | uniq -d | wc -l)

echo "source app.events XLEN     : $src_len  (unique event_ids: $(sort -u "$src_tmp" | wc -l))"
echo "region region-events XLEN  : $reg_len  (unique event_ids: $(sort -u "$reg_tmp" | wc -l))"
echo "missing in region (loss)   : $missing"
echo "extra in region            : $extra"
echo "duplicate event_ids region : $dups"
