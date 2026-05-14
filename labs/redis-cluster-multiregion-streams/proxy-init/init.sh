#!/bin/sh
# proxy-init: configure each region's toxiproxy with 3 proxies, one per upstream
# Redis shard. Latency toxic per direction simulates WAN RTT.

set -eu

SHARED=/shared
LATENCY_LOCAL_MS=${LATENCY_LOCAL_MS:-1}
LATENCY_MID_MS=${LATENCY_MID_MS:-100}
LATENCY_FAR_MS=${LATENCY_FAR_MS:-500}

mkdir -p "$SHARED"
rm -f "$SHARED/proxies-ready"

# Wait for each toxiproxy admin endpoint
for tp in toxiproxy-a toxiproxy-b toxiproxy-c; do
  attempts=60
  until curl -s -f "http://$tp:8474/version" > /dev/null 2>&1; do
    attempts=$((attempts - 1))
    if [ "$attempts" -le 0 ]; then
      echo "[proxy-init] FAIL: $tp admin not reachable" >&2
      exit 1
    fi
    sleep 1
  done
  echo "[proxy-init]   $tp admin up"
done

# Idempotent: delete any pre-existing proxy with this name, then re-create.
configure_proxy() {
  tp_host=$1; proxy_name=$2; listen_port=$3; upstream=$4; latency_ms=$5

  curl -s -X DELETE "http://$tp_host:8474/proxies/$proxy_name" >/dev/null 2>&1 || true

  http_code=$(curl -s -o /tmp/resp -w '%{http_code}' \
    -X POST "http://$tp_host:8474/proxies" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$proxy_name\",\"listen\":\"0.0.0.0:$listen_port\",\"upstream\":\"$upstream\",\"enabled\":true}")
  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "[proxy-init] FAIL: creating proxy $proxy_name on $tp_host (HTTP $http_code): $(cat /tmp/resp)" >&2
    exit 1
  fi

  if [ "$latency_ms" -gt 0 ]; then
    for stream in upstream downstream; do
      http_code=$(curl -s -o /tmp/resp -w '%{http_code}' \
        -X POST "http://$tp_host:8474/proxies/$proxy_name/toxics" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"latency_${stream}\",\"type\":\"latency\",\"stream\":\"${stream}\",\"attributes\":{\"latency\":$latency_ms,\"jitter\":0}}")
      if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "[proxy-init] FAIL: adding $stream latency to $proxy_name on $tp_host (HTTP $http_code): $(cat /tmp/resp)" >&2
        exit 1
      fi
    done
  fi
  echo "[proxy-init]   $tp_host :$listen_port -> $upstream  (latency ${latency_ms}ms each way)"
}

# region A: local=a, mid=b, far=c
configure_proxy toxiproxy-a r-to-a 6001 redis-a:6001 "$LATENCY_LOCAL_MS"
configure_proxy toxiproxy-a r-to-b 6002 redis-b:6002 "$LATENCY_MID_MS"
configure_proxy toxiproxy-a r-to-c 6003 redis-c:6003 "$LATENCY_FAR_MS"

# region B: mid=a, local=b, far=c
configure_proxy toxiproxy-b r-to-a 6001 redis-a:6001 "$LATENCY_MID_MS"
configure_proxy toxiproxy-b r-to-b 6002 redis-b:6002 "$LATENCY_LOCAL_MS"
configure_proxy toxiproxy-b r-to-c 6003 redis-c:6003 "$LATENCY_FAR_MS"

# region C: far=a, mid=b, local=c
configure_proxy toxiproxy-c r-to-a 6001 redis-a:6001 "$LATENCY_FAR_MS"
configure_proxy toxiproxy-c r-to-b 6002 redis-b:6002 "$LATENCY_MID_MS"
configure_proxy toxiproxy-c r-to-c 6003 redis-c:6003 "$LATENCY_LOCAL_MS"

touch "$SHARED/proxies-ready"
echo "[proxy-init] done; signaled /shared/proxies-ready"
