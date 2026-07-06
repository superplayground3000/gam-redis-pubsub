#!/usr/bin/env bash
# lib.sh — shared env defaults + helpers for the by-key-prefix-split-topic lab.
# Sourced by verify-prefix-split.sh and the sub-scripts. All knobs are env-overridable
# (DESIGN §12). Nothing here mutates state; helpers only.

# ---- paths ----
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$LAB/../.." && pwd)"

# ---- cluster / release ----
KIND_NAME="${KIND_NAME:-cdc}"
NS="${NS:-cdc-k8s}"
RELEASE="${RELEASE:-cdc}"

# ---- images (preflight asserts these exist locally) ----
CONNECT_IMAGE="${CONNECT_IMAGE:-hpdevelop/connect:4.92.0-claudefix}"
APP_IMAGE="${APP_IMAGE:-redis-rrcs/cdc-apps:dev}"
TOXIPROXY_IMAGE="${TOXIPROXY_IMAGE:-ghcr.io/shopify/toxiproxy:2.9.0}"
NATSBOX_IMAGE="${NATSBOX_IMAGE:-natsio/nats-box:0.14.5}"

# ---- workload ----
PREFIXES="${PREFIXES:-prefix-a,prefix-b,prefix-c,prefix-d}"
# DESIGN fixed RATE/TARGET=8000. Measurement (this session) showed this single-node
# kind stack caps AGGREGATE apply at ~4.8k msg/s, and — decisively — bypassing
# toxiproxy gave the SAME number, so the ceiling is the single-node NATS-JetStream +
# connect-pull + region-redis path, NOT the delay tool. It even ANTI-SCALES (1 sink
# ~6.4k/s, 4 sinks ~4.8k/s aggregate): per-consumer throughput degrades as consumers
# are added to one NATS server. Recorded as a finding (DESIGN §0-4). To isolate the
# real property (delay-vs-split) with margin BELOW that ceiling, the demonstration
# runs at 4000/target 3000; S5 pushes to 6000 to exhibit the ceiling.
RATE="${RATE:-4000}"
RATE_HIGH="${RATE_HIGH:-6000}"
WORKERS="${WORKERS:-16}"
KEY_SPACE_SIZE="${KEY_SPACE_SIZE:-50000}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-200}"
MAX_RATE="${MAX_RATE:-20000}"
SINK_REPLICAS="${SINK_REPLICAS:-1}"

# ---- delay injection ----
TOXIC_LAT_MS="${TOXIC_LAT_MS:-185}"
TOXIC_JITTER_MS="${TOXIC_JITTER_MS:-15}"

# ---- consumer ----
MAX_ACK_PENDING="${MAX_ACK_PENDING:-1024}"
MAX_ACK_PENDING_TUNED="${MAX_ACK_PENDING_TUNED:-8192}"

# ---- scenario rhythm ----
WARMUP_S="${WARMUP_S:-60}"
MEASURE_S="${MEASURE_S:-300}"
DRAIN_TIMEOUT_S="${DRAIN_TIMEOUT_S:-300}"
SCRAPE_INTERVAL_S="${SCRAPE_INTERVAL_S:-5}"
TARGET="${TARGET:-3000}"   # demonstration goal line (below the ~4.8k infra ceiling; see RATE note)

# ---- goal / stream ----
STREAM="${STREAM:-KV_CDC}"
NATS_URL="nats://lab-nats:4222"
NATS_ADMIN_CREDS="/etc/nats-creds/admin/user.creds"

# base listener port; prefix i -> 4223+i
TOX_BASE_PORT="${TOX_BASE_PORT:-4223}"

# comma list -> bash array PREFIX_ARR
IFS=',' read -r -a PREFIX_ARR <<< "$PREFIXES"

# port for prefix at index i
tox_port() { echo $(( TOX_BASE_PORT + $1 )); }

# ---- kubectl / exec helpers ----
kc() { kubectl -n "$NS" "$@"; }

# run a command inside the toolbox pod (nats CLI + curl + jq)
tb() { kc exec deploy/lab-toolbox -- "$@"; }

# nats admin CLI via toolbox
natsadm() { tb nats --server "$NATS_URL" --creds "$NATS_ADMIN_CREDS" "$@"; }

# toxiproxy admin API via toolbox (path starts with /)
tox_api() { local method="$1"; shift; local path="$1"; shift; tb curl -sf -X "$method" "http://lab-toxiproxy:8474${path}" "$@"; }

# retry a command up to $1 times, sleeping 3s between tries
retry() { local n="$1"; shift; local i=0; until "$@"; do i=$((i+1)); [ "$i" -ge "$n" ] && return 1; sleep 3; done; return 0; }

# block until the toolbox can reach the toxiproxy admin API (proves both pods up + net path)
wait_toxiproxy() { retry 30 tb curl -sf -m 4 http://lab-toxiproxy:8474/version >/dev/null 2>&1; }

# log a mutating command + its exit status to commands.log (RUN_DIR must be set)
logcmd() {
  local desc="$1"; shift
  echo "+ $desc :: $*" >> "${RUN_DIR:-/dev/null}/commands.log" 2>/dev/null || true
  "$@"; local rc=$?
  echo "  exit=$rc" >> "${RUN_DIR:-/dev/null}/commands.log" 2>/dev/null || true
  return $rc
}

# scrape a prometheus counter sum from a Connect/writer :port/metrics endpoint (via toolbox curl).
# $1=host:port $2=metric-name-with-optional-label-filter (grep pattern). Sums all matching series values.
prom_sum() {
  local hp="$1" pat="$2"
  tb curl -sf "http://${hp}/metrics" 2>/dev/null \
    | awk -v pat="$pat" '$0 ~ pat && $1 !~ /#/ {s+=$NF} END{printf "%.0f", s+0}'
}

echo_env() {
  cat <<EOF
[lib] NS=$NS RELEASE=$RELEASE KIND=$KIND_NAME
[lib] PREFIXES=$PREFIXES RATE=$RATE/$RATE_HIGH WORKERS=$WORKERS KEYSPACE=$KEY_SPACE_SIZE
[lib] TOXIC=${TOXIC_LAT_MS}±${TOXIC_JITTER_MS}ms MAXACK=$MAX_ACK_PENDING/$MAX_ACK_PENDING_TUNED
[lib] WARMUP=${WARMUP_S}s MEASURE=${MEASURE_S}s DRAIN<=${DRAIN_TIMEOUT_S}s SCRAPE=${SCRAPE_INTERVAL_S}s
[lib] images: $CONNECT_IMAGE | $APP_IMAGE | $TOXIPROXY_IMAGE
EOF
}
