#!/usr/bin/env bash
# lib.sh — shared helpers for labs/robustness-test phases. SOURCED, not executed.
# Callers set -euo pipefail themselves. Oracle style mirrors scripts/verify-failover.sh
# (pure redis-cli membership over kubectl exec).

NS="${RRCS_NS:-cdc-k8s}"
RELEASE="${RRCS_RELEASE:-cdc}"
PREFIX="${RRCS_PREFIX:-lab-}"
CONNECT_IMAGE="${CONNECT_IMAGE:-hpdevelop/connect:v4.92.0-batch-nats}"
STREAM="app.events"

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
SRC_DEPLOY="deploy/${PREFIX}connect-source"
SINK_DEPLOY="deploy/${PREFIX}connect-sink"
SRC_LEASE="${PREFIX}connect-source-elector"
SINK_LEASE="${PREFIX}connect-sink-elector"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
holder() { kubectl -n "$NS" get lease "$1" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
now_ms() { date +%s%3N; }
log() { echo "[$(basename "$0" .sh)] $*"; }
die() { echo "[$(basename "$0" .sh)] FAIL: $*" >&2; exit 1; }

# xadd_batch <runid> <n> <keyspace> — XADD n valid create events whose region keys
# are lb:robust:<keyspace>:{run:<runid>:k<i>} (same field set verify-failover.sh uses).
xadd_batch() {
  local runid="$1" n="$2" ks="$3" i ts cmds
  ts="$(now_ms)"; cmds="$(mktemp)"
  for (( i=1; i<=n; i++ )); do
    echo "XADD $STREAM * event_id ${ks}-${runid}-${i} op create type string kv_key lb:robust:${ks}:{run:${runid}:k${i}} ts ${ts} body v${i}"
  done > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null \
    || { local rc=$?; rm -f "$cmds"; return "$rc"; }
  rm -f "$cmds"
}

# region_count <runid> <keyspace> — how many of the batch's keys exist in region KV
region_count() { rr --scan --pattern "lb:robust:${2}:{run:${1}:k*}" 2>/dev/null | grep -c . || true; }

# wait_region_full <runid> <keyspace> <n> <timeout_s> — poll until count>=n or
# timeout; echoes final count. Zero-loss oracle: caller asserts final==n.
# (Deliberately NOT a stability heuristic: redelivery after a kill can stall up
# to ackWait=30s, which a short stable-reads break would misread as loss.)
wait_region_full() {
  local runid="$1" ks="$2" n="$3" timeout="$4" deadline cur=0
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    cur="$(region_count "$runid" "$ks")"
    (( cur >= n )) && break
    sleep 5
  done
  echo "$cur"
}

# wait_new_holder <lease> <old_holder> <timeout_s> — echoes the new holder, or
# returns 1 on timeout.
wait_new_holder() {
  local lease="$1" old="$2" timeout="$3" deadline h
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    h="$(holder "$lease")"
    if [[ -n "$h" && "$h" != "$old" ]]; then echo "$h"; return 0; fi
    sleep 2
  done
  return 1
}
