#!/usr/bin/env bash
# Export the live dashboard from Grafana to the canonical chart JSON, stripping
# runtime id/version/iteration so the git diff is meaningful.
set -euo pipefail
uid="cdc-sink-observability"
g="http://admin:admin@localhost:${GRAFANA_PORT:-13000}"
dst="$(cd "$(dirname "$0")/../../.." && pwd)/chart/files/grafana/cdc-dashboard.json"
curl -fsS "$g/api/dashboards/uid/$uid" \
  | jq '.dashboard | del(.id,.version,.iteration)' > "$dst"
echo "exported → $dst"
