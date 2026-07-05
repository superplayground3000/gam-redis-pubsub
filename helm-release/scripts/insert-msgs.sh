#!/usr/bin/env bash
# insert-msgs.sh — FORMS redis-cli XADD commands for each CDC op and the dedup
# test, and PRINTS them for you to copy-paste and run by hand. It does NOT execute
# anything (per lab-requirements: "scripts must just form commands").
#
# Override the target with REDIS_CLI (e.g. a kubectl exec wrapper) and IDs.
set -euo pipefail

REDIS_CLI="${REDIS_CLI:-redis-cli -h redis-central -p 6379}"
STREAM="${STREAM:-app.events}"
EMP_ID="${EMP_ID:-55688}"
GRP_ID="${GRP_ID:-89889}"
ITEM_ID="${ITEM_ID:-9123}"

uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "eid-$RANDOM-$RANDOM"; }
ts() { date +%s%3N; }

cat <<EOF
# ---- copy & run these by hand ----

# create a new item (general pattern)
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op create kv_key "lb:general:active:{items:${ITEM_ID}}" ts "$(ts)" body '{"id":"item-${ITEM_ID}","name":"widget"}'

# update an existing employee (company pattern)
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op update kv_key "lb:company:active:{employees:${EMP_ID}}" ts "$(ts)" body '{"id":"emp-${EMP_ID}","title":"staff"}'

# delete an employee
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op delete kv_key "lb:company:active:{employees:${EMP_ID}}" ts "$(ts)" body ''

# create a hash (profile) with multiple fields
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op create type hash kv_key "lb:hash:active:{profiles:${ITEM_ID}}" ts "$(ts)" body '{"name":"alice","tier":"free"}'

# merge-update several hash fields at once (name persists, tier overwritten, region added)
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op update type hash kv_key "lb:hash:active:{profiles:${ITEM_ID}}" ts "$(ts)" body '{"tier":"pro","region":"apac"}'

# delete the whole hash
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op delete type hash kv_key "lb:hash:active:{profiles:${ITEM_ID}}" ts "$(ts)" body ''

# standby->active rename (add-not-enabled-then-enable)
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op rename old_key "lb:company:standby:{employees:${EMP_ID}}" new_key "lb:company:active:{employees:${EMP_ID}}" ts "$(ts)" body '{"id":"emp-${EMP_ID}","enabled":true}'

# dedup test: SAME event_id five times -> JetStream stores ONE
#   (check with: nats stream info ${NATS_STREAM:-KV_CDC} | grep Messages)
EOF

DUP_EID="$(uuid)"
for i in 1 2 3 4 5; do
  echo "${REDIS_CLI} XADD ${STREAM} '*' event_id \"${DUP_EID}\" op update kv_key \"lb:general:active:{items:${ITEM_ID}}\" ts \"\$(date +%s%3N)\" body '{\"n\":${i}}'"
done
