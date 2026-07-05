#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d --build redis nats nats-init connect prometheus alertmanager alert-sink grafana
echo "lab up. grafana=http://localhost:${GRAFANA_PORT:-13000}  prometheus=http://localhost:${PROM_PORT:-19090}"
