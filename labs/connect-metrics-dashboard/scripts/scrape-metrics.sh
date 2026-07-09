#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; out="$here/captured"; mkdir -p "$out"
curl -fsS "http://localhost:${SRC_PORT:-14195}/metrics"    > "$out/source-metrics.txt"
curl -fsS "http://localhost:${SINK_PORT:-14196}/metrics"   > "$out/sink-metrics.txt"
curl -fsS "http://localhost:${WRITER_PORT:-18081}/metrics" > "$out/writer-metrics.txt"
# latency-calculator has no host port mapping; scrape via prometheus federation-free proxy:
docker compose -f "$here/docker-compose.yml" exec -T prometheus \
  wget -qO- "http://latency-calculator:8082/metrics" > "$out/latency-metrics.txt" || true
echo "captured:"; wc -l "$out"/*.txt
