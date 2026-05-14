#!/bin/sh
# cluster-init: form the 3-master Redis Cluster, then pick one hash tag per shard
# whose CRC16 lands inside that shard's slot range. Writes /shared/tags.json and
# /shared/cluster-ready, then exits 0.

set -eu

SHARED=/shared
mkdir -p "$SHARED"
# cluster-init runs as root (redis:7.4-alpine has no USER); open the bind-mounted
# dir so the non-root client containers can append to measurements.jsonl.
chmod 0777 "$SHARED"
# Clean stale state from a previous run (a fresh `up` reuses the bind-mount).
rm -f "$SHARED/cluster-ready" "$SHARED/proxies-ready" "$SHARED/tags.json" "$SHARED/measurements.jsonl"

NODES="redis-a:6001 redis-b:6002 redis-c:6003"

echo "[cluster-init] waiting for redis nodes..."
for hp in $NODES; do
  h=${hp%:*}; p=${hp#*:}
  attempts=60
  until redis-cli -h "$h" -p "$p" -t 2 ping 2>/dev/null | grep -q PONG; do
    attempts=$((attempts - 1))
    if [ "$attempts" -le 0 ]; then
      echo "[cluster-init] FAIL: $hp not reachable" >&2
      exit 1
    fi
    sleep 1
  done
  echo "[cluster-init]   $hp is up"
done

echo "[cluster-init] checking cluster state..."
state=$(redis-cli -h redis-a -p 6001 cluster info 2>/dev/null | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r')
if [ "$state" = "ok" ]; then
  echo "[cluster-init] cluster already initialized"
else
  echo "[cluster-init] creating cluster (3 masters, no replicas)..."
  # `yes yes` answers the interactive "OK?" prompt from redis-cli.
  yes yes | redis-cli --cluster create \
    redis-a:6001 redis-b:6002 redis-c:6003 \
    --cluster-replicas 0
fi

# Block until cluster_state:ok
echo "[cluster-init] waiting for cluster_state:ok..."
attempts=30
state=""
while [ "$attempts" -gt 0 ]; do
  state=$(redis-cli -h redis-a -p 6001 cluster info 2>/dev/null | awk -F: '/^cluster_state:/{print $2}' | tr -d '\r')
  if [ "$state" = "ok" ]; then break; fi
  attempts=$((attempts - 1))
  sleep 1
done
if [ "$state" != "ok" ]; then
  echo "[cluster-init] FAIL: cluster did not reach ok state (last: '$state')" >&2
  exit 1
fi
echo "[cluster-init] cluster is OK"

# --- discover slot ranges per master ---
#
# CLUSTER NODES line format (one space-separated record per node):
#   <id> <addr> <flags> <master/-> <ping_sent> <pong_recv> <epoch> <link> <slot_range>...
# Where <addr> is "ip:port@bus_port[,hostname]". The 3rd field is something like
# "myself,master" or "master" — both contain "master".
NODES_OUT=$(redis-cli -h redis-a -p 6001 cluster nodes)
echo "[cluster-init] CLUSTER NODES output:"
echo "$NODES_OUT" | sed 's/^/  /'

# Return space-separated slot ranges for the master whose addr starts with the given hostport.
# We use the hostport string from --cluster create (e.g. "redis-a:6001") for matching.
slots_for() {
  needle=$1
  echo "$NODES_OUT" | awk -v want="$needle" '
    {
      # strip a trailing ",..." (hostname) from the address field
      addr = $2
      sub(/[,@].*$/, "", addr)  # strip from first @ or , (handles both ip:port@bus and ip:port,hostname)
      # match either prefix
      if (index($0, "master") == 0) next
      if (addr != want) next
      out = ""
      for (i = 9; i <= NF; i++) {
        # skip migration markers like [slot->-nodeid] / [slot-<-nodeid]
        if ($i ~ /^\[/) continue
        out = out " " $i
      }
      print substr(out, 2)
    }
  '
}

SLOTS_A=$(slots_for "redis-a:6001")
SLOTS_B=$(slots_for "redis-b:6002")
SLOTS_C=$(slots_for "redis-c:6003")

# Fall back: addresses in CLUSTER NODES are often the resolved IP, not the original
# hostport. If our hostport match failed, look up each node's IP via DNS and try again.
if [ -z "$SLOTS_A" ] || [ -z "$SLOTS_B" ] || [ -z "$SLOTS_C" ]; then
  IP_A=$(getent hosts redis-a | awk '{print $1}' | head -n1)
  IP_B=$(getent hosts redis-b | awk '{print $1}' | head -n1)
  IP_C=$(getent hosts redis-c | awk '{print $1}' | head -n1)
  [ -z "$SLOTS_A" ] && SLOTS_A=$(slots_for "$IP_A:6001")
  [ -z "$SLOTS_B" ] && SLOTS_B=$(slots_for "$IP_B:6002")
  [ -z "$SLOTS_C" ] && SLOTS_C=$(slots_for "$IP_C:6003")
fi

echo "[cluster-init] redis-a owns slots: $SLOTS_A"
echo "[cluster-init] redis-b owns slots: $SLOTS_B"
echo "[cluster-init] redis-c owns slots: $SLOTS_C"

if [ -z "$SLOTS_A" ] || [ -z "$SLOTS_B" ] || [ -z "$SLOTS_C" ]; then
  echo "[cluster-init] FAIL: could not determine slot ranges per master" >&2
  exit 1
fi

# --- find one hash tag per shard ---
in_range() {
  s=$1
  shift
  for r in "$@"; do
    case "$r" in
      *-*)
        lo=${r%-*}; hi=${r#*-}
        if [ "$s" -ge "$lo" ] && [ "$s" -le "$hi" ]; then return 0; fi
        ;;
      *)
        # single-slot range like "100"
        if [ "$s" -eq "$r" ]; then return 0; fi
        ;;
    esac
  done
  return 1
}

TAG_A=""; TAG_B=""; TAG_C=""
for i in $(seq 0 999); do
  slot=$(redis-cli -h redis-a -p 6001 cluster keyslot "stream:{t${i}}" 2>/dev/null | tr -d '\r')
  [ -z "$slot" ] && continue
  if [ -z "$TAG_A" ] && in_range "$slot" $SLOTS_A; then TAG_A="t${i}"; fi
  if [ -z "$TAG_B" ] && in_range "$slot" $SLOTS_B; then TAG_B="t${i}"; fi
  if [ -z "$TAG_C" ] && in_range "$slot" $SLOTS_C; then TAG_C="t${i}"; fi
  if [ -n "$TAG_A" ] && [ -n "$TAG_B" ] && [ -n "$TAG_C" ]; then break; fi
done

if [ -z "$TAG_A" ] || [ -z "$TAG_B" ] || [ -z "$TAG_C" ]; then
  echo "[cluster-init] FAIL: could not find hash tags for all 3 shards" >&2
  exit 1
fi
echo "[cluster-init] chose tags: redis-a={$TAG_A} redis-b={$TAG_B} redis-c={$TAG_C}"

# --- write tags.json + ready sentinel ---
cat > "$SHARED/tags.json" <<EOF
{
  "redis-a": "$TAG_A",
  "redis-b": "$TAG_B",
  "redis-c": "$TAG_C"
}
EOF

touch "$SHARED/cluster-ready"
echo "[cluster-init] done; signaled /shared/cluster-ready"
