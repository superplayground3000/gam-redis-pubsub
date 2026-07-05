# redis-cdc-error-alerting lab

Validates the `redis-cdc-le-k8s` chart's Grafana dashboard + `CDCUnprocessableMessages`
Prometheus alert by running a distilled Connect sink pipeline (same metric names) fed by
a Go traffic generator. The chart's `cdc-alerts.yaml` and `cdc-dashboard.json` are
bind-mounted, so the lab tests exactly what ships.

## Run

```bash
scripts/run-lab.sh            # build + up
scripts/verify-alert.sh       # automated proof (healthy → poison → recovery); exits 0 on PASS
```

Grafana: http://localhost:${GRAFANA_PORT:-13000} (admin/admin) · Prometheus: http://localhost:${PROM_PORT:-19090}

See `RESEARCH.md` for the metric taxonomy and how the alert maps to "unprocessable".
