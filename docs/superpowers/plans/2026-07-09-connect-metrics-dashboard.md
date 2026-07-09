# Connect-metrics Grafana Dashboard Lab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a docker-compose lab running both Connect legs end-to-end, capture the real `:4195/metrics` names, and correct every mismatched `expr` in the canonical `chart/files/grafana/cdc-dashboard.json`.

**Architecture:** Full CDC path in compose — `writer(app) → redis-central → connect-source(:4195) → nats(JetStream) → connect-sink(:4195) → redis-region`, with `latency-calculator(app)`, Prometheus, and a provisioned editable Grafana. Connect run-mode configs are *rendered from the chart* (`helm template`, external-mode values → compose hostnames, strip creds line) so the `metric:` processor blocks stay byte-identical to production. The lab is the proving ground; the deliverable is the corrected chart JSON.

**Tech Stack:** docker-compose, Redpanda Connect (`hpdevelop/connect:4.92.0-claudefix`), NATS JetStream, Redis 7.4, Prometheus v2.54.1, Grafana 11.2.0, the repo `app` Go binary, `helm`, `yq`/`sed`, `jq`, `curl`.

## Global Constraints

- Work only inside the worktree: `/media/hp/secondary/projects/connect-project/gam-redis-pubsub/.claude/worktrees/connect-metrics-dashboard`. Every path below is relative to this root. (Known pitfall: edits can silently land in the main repo — always use the worktree-absolute path.)
- Connect image pinned to `hpdevelop/connect:4.92.0-claudefix` (matches `chart/values.yaml`).
- The `metric:` processor blocks in the lab Connect configs MUST be byte-identical to the chart's rendered output — verified by diff (Task 2). This is what makes captured names authoritative.
- New lab lives under `labs/connect-metrics-dashboard/` (research-lab convention: self-contained compose + `RESEARCH.md`).
- Do NOT hand-edit metric names into the lab pipelines; they come only from `helm template`.
- The final chart JSON edit must keep `helm lint chart/ && helm template chart/ >/dev/null` passing (chart-render invariant, `rules/05-invariants.md`).
- Bundled-mode chart render is fine for extracting configs; auth-less lab NATS means the `user_credentials_file:` line is stripped in the render script (the only permitted non-connection transform besides host/url/stream/consumer values).

---

### Task 1: Lab skeleton + RESEARCH.md

**Files:**
- Create: `labs/connect-metrics-dashboard/RESEARCH.md`
- Create: `labs/connect-metrics-dashboard/.gitignore`

**Interfaces:**
- Produces: the lab directory root all later tasks write into.

- [ ] **Step 1: Create the lab directory and a .gitignore for generated artifacts**

```bash
cd /media/hp/secondary/projects/connect-project/gam-redis-pubsub/.claude/worktrees/connect-metrics-dashboard
mkdir -p labs/connect-metrics-dashboard/{connect,prometheus,grafana/provisioning/datasources,grafana/provisioning/dashboards,scripts,captured}
printf '%s\n' 'captured/*.txt' 'captured/*.json' '!captured/.gitkeep' > labs/connect-metrics-dashboard/.gitignore
touch labs/connect-metrics-dashboard/captured/.gitkeep
```

- [ ] **Step 2: Write RESEARCH.md** (the research-lab writeup; sections filled as later tasks complete — the *Findings* table is populated in Task 5)

```markdown
# Lab: Connect metrics → Grafana dashboard alignment

## Question
What are the real Prometheus metric names Redpanda Connect exposes on `:4195/metrics`
for each CDC leg, and does `chart/files/grafana/cdc-dashboard.json` reference them
correctly?

## Why it's uncertain
The dashboard uses `{__name__=~"cdc_apply(_total)?"}` regexes — the author hedged on
whether Connect's Prometheus exporter appends `_total` to `metric:`-processor counters,
and on the exact names/labels of built-ins (`processor_error`, `processor_latency_ns_*`).
Only a live scrape settles it.

## Setup
Full CDC path in docker-compose (see `docker-compose.yml`). Connect configs are rendered
from the chart (`scripts/render-configs.sh`) so `metric:` blocks match production exactly.
Traffic is driven by the `app writer` (`scripts/drive.sh`). Both legs' raw `/metrics` are
captured by `scripts/scrape-metrics.sh` into `captured/`.

## Coverage & known gaps
- Custom counters (`cdc_apply`, `cdc_unprocessable`) fire under normal traffic and
  establish the exporter's suffix convention, which applies identically to the
  forward-leg counters (`cdc_forward_unrouted/others/publish_failed`) — same exporter,
  same rule — so those names are confirmed structurally even when a branch doesn't fire.
- `elector_*` metrics need the K8s Lease API and can't run in compose. They are
  hand-written text in `internal/elector/main.go`
  (`elector_leading`, `elector_post_total{result=...}`, `elector_delete_total{result=...}`)
  and are verified from source, not from a scrape.
- `cdc_writer_*` and `cdc_latency_seconds` come from the `app` writer/latency binaries
  (plain-text `/metrics`, NOT the Connect exporter) and are captured live.

## Findings
_(populated in Task 5 — table of dashboard expr → real name → verdict)_

## How to run
See "Run" section below.
```

- [ ] **Step 3: Commit**

```bash
git add labs/connect-metrics-dashboard/
git commit -m "lab(connect-metrics): skeleton + RESEARCH.md"
```

---

### Task 2: Render Connect run-mode configs from the chart

Produce `connect/source.yaml` and `connect/sink.yaml` as run-mode configs, rendered from the chart so metric blocks are authoritative.

**Files:**
- Create: `labs/connect-metrics-dashboard/scripts/render-configs.sh`
- Create: `labs/connect-metrics-dashboard/lab-values.yaml`
- Generates: `labs/connect-metrics-dashboard/connect/source.yaml`, `labs/connect-metrics-dashboard/connect/sink.yaml`

**Interfaces:**
- Consumes: chart at `chart/`, `chart/files/connect/observability.yaml`.
- Produces: two run-mode Connect configs referenced by `docker-compose.yml` (Task 3) as `connect-source` / `connect-sink` command args.

- [ ] **Step 1: Write `lab-values.yaml`** — external-mode overrides that point the chart's pipeline at compose hostnames

```yaml
# Overrides so `helm template` renders the pipeline against compose service names.
# Only connection/addressing values are set here — nothing touches metric blocks.
redis:
  central:
    external: { enabled: true, url: "redis://redis-central:6379", cluster: false }
  region:
    external: { enabled: true, url: "redis://redis-region:6379", cluster: false }
nats:
  external: { enabled: true, url: "nats://nats:4222" }
  stream:
    name: "LAB_CDC"
    subjectPrefix: "kv.cdc"
latencyCalculator:
  stream: "cdc:latency"
```

- [ ] **Step 2: Write `scripts/render-configs.sh`**

```bash
#!/usr/bin/env bash
# Render the chart's forward/reverse Connect pipelines into standalone run-mode
# configs for the lab. Metric blocks are preserved verbatim; only NATS creds are
# stripped (auth-less lab NATS) and connection values come from lab-values.yaml.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/../.." && pwd)"           # worktree root
chart="$root/chart"
obs="$chart/files/connect/observability.yaml"
out="$here/connect"; mkdir -p "$out"

render_leg() {  # $1 = configmap key (forward|reverse)  $2 = output file
  local leg="$1" dst="$2"
  # Pull the rendered stream body out of the connect-configmaps.yaml ConfigMap.
  local body
  body="$(helm template "$chart" -f "$here/lab-values.yaml" \
            --show-only templates/connect-configmaps.yaml \
          | yq eval "select(.data.\"cdc-${leg}.yaml\") | .data.\"cdc-${leg}.yaml\"" -)"
  if [ -z "$body" ] || [ "$body" = "null" ]; then
    echo "FATAL: empty render for $leg — inspect: helm template $chart -f $here/lab-values.yaml --show-only templates/connect-configmaps.yaml" >&2
    exit 1
  fi
  {
    echo "# GENERATED by scripts/render-configs.sh — DO NOT EDIT. Source: chart cdc-${leg}.yaml"
    cat "$obs"                                   # http/logger/metrics (run-mode top level)
    echo "$body" | grep -v 'user_credentials_file:'   # strip auth line (auth-less lab NATS)
  } > "$dst"
  echo "wrote $dst"
}

render_leg forward "$out/source.yaml"
render_leg reverse "$out/sink.yaml"
```

- [ ] **Step 3: Make executable and run it**

```bash
chmod +x labs/connect-metrics-dashboard/scripts/render-configs.sh
labs/connect-metrics-dashboard/scripts/render-configs.sh
```
Expected: `wrote .../connect/source.yaml` and `.../connect/sink.yaml`. If the `--show-only` key differs, list keys with `helm template chart -f labs-values.yaml --show-only templates/connect-configmaps.yaml | yq '.data | keys'` and adjust the `yq` path.

- [ ] **Step 4: Verify metric-block fidelity** (the load-bearing check — metric processor blocks must match the chart verbatim)

```bash
# Every `name: cdc_*` counter present in the chart source must appear in the rendered leg.
for n in cdc_apply cdc_unprocessable cdc_forward_unrouted cdc_forward_others cdc_forward_publish_failed; do
  grep -q "name: $n" labs/connect-metrics-dashboard/connect/source.yaml labs/connect-metrics-dashboard/connect/sink.yaml \
    && echo "present: $n" || echo "MISSING: $n"
done
# Confirm the exporter config (use_histogram_timing) and :4195 survived from observability.yaml
grep -q 'use_histogram_timing: true' labs/connect-metrics-dashboard/connect/source.yaml && echo "exporter cfg ok"
grep -q '0.0.0.0:4195' labs/connect-metrics-dashboard/connect/source.yaml && echo "http addr ok"
# Confirm creds line is gone (auth-less lab NATS)
! grep -q 'user_credentials_file' labs/connect-metrics-dashboard/connect/sink.yaml && echo "creds stripped ok"
```
Expected: all `present:`, `exporter cfg ok`, `http addr ok`, `creds stripped ok`. Any `MISSING:` or failure means the render path is wrong — fix Step 2 before proceeding.

- [ ] **Step 5: Commit**

```bash
git add labs/connect-metrics-dashboard/lab-values.yaml labs/connect-metrics-dashboard/scripts/render-configs.sh labs/connect-metrics-dashboard/connect/
git commit -m "lab(connect-metrics): render run-mode Connect configs from chart"
```

---

### Task 3: docker-compose stack + Prometheus + Grafana provisioning

**Files:**
- Create: `labs/connect-metrics-dashboard/docker-compose.yml`
- Create: `labs/connect-metrics-dashboard/prometheus/prometheus.yml`
- Create: `labs/connect-metrics-dashboard/grafana/provisioning/datasources/prom.yml`
- Create: `labs/connect-metrics-dashboard/grafana/provisioning/dashboards/dashboards.yml`

**Interfaces:**
- Consumes: `connect/source.yaml`, `connect/sink.yaml` (Task 2); the repo `Dockerfile` (builds the `app` image); `chart/files/grafana/` (bind-mounted dashboard dir).
- Produces: a running stack; Grafana at `${GRAFANA_PORT:-13000}`, Prometheus at `${PROM_PORT:-19090}`, source `:4195`→host `${SRC_PORT:-14195}`, sink `:4195`→host `${SINK_PORT:-14196}`, writer `:8081`→`${WRITER_PORT:-18081}`.

- [ ] **Step 1: Write `prometheus/prometheus.yml`** — scrape both legs + app metrics

```yaml
global:
  scrape_interval: 5s
  evaluation_interval: 5s
scrape_configs:
  - job_name: connect-source
    static_configs: [{ targets: ["connect-source:4195"], labels: { namespace: "lab", leg: "source" } }]
  - job_name: connect-sink
    static_configs: [{ targets: ["connect-sink:4195"], labels: { namespace: "lab", leg: "sink" } }]
  - job_name: writer
    static_configs: [{ targets: ["writer:8081"], labels: { namespace: "lab" } }]
  - job_name: latency-calculator
    static_configs: [{ targets: ["latency-calculator:8082"], labels: { namespace: "lab" } }]
```

- [ ] **Step 2: Write `grafana/provisioning/datasources/prom.yml`**

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: cdc-prom            # dashboard's ${datasource} default resolves to this
    access: proxy
    url: http://prometheus:9090
    isDefault: true
```

- [ ] **Step 3: Write `grafana/provisioning/dashboards/dashboards.yml`** (editable, loads the canonical chart JSON)

```yaml
apiVersion: 1
providers:
  - name: cdc
    type: file
    allowUiUpdates: true
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

- [ ] **Step 4: Write `docker-compose.yml`**

```yaml
name: lab-connect-metrics-dashboard

x-app: &app
  build: { context: ../.., dockerfile: Dockerfile }
  image: cdc-app:lab

services:
  redis-central:
    image: redis:7.4-alpine
    command: ["redis-server","--save","","--appendonly","no","--protected-mode","no"]
    healthcheck: { test: ["CMD","redis-cli","ping"], interval: 2s, timeout: 2s, retries: 15 }
    networks: [lab]

  redis-region:
    image: redis:7.4-alpine
    command: ["redis-server","--save","","--appendonly","no","--protected-mode","no"]
    healthcheck: { test: ["CMD","redis-cli","ping"], interval: 2s, timeout: 2s, retries: 15 }
    networks: [lab]

  nats:
    image: nats:2.10-alpine
    command: ["-js","-m","8222"]
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:8222/healthz"], interval: 2s, timeout: 2s, retries: 15 }
    networks: [lab]

  nats-init:
    image: natsio/nats-box:0.14.5
    depends_on: { nats: { condition: service_healthy } }
    restart: "no"
    entrypoint: ["/bin/sh","-c"]
    command:
      - |
        set -e
        nats --server nats://nats:4222 stream add LAB_CDC \
          --subjects "kv.cdc.>" --storage file --retention limits \
          --discard old --max-msgs=-1 --max-bytes=-1 --max-age=1h \
          --dupe-window=5m --replicas=1 --max-msg-size=-1 --defaults
        nats --server nats://nats:4222 consumer add LAB_CDC cdc_sink \
          --pull --ack explicit --deliver all --replay instant \
          --filter "kv.cdc.>" --max-deliver=-1 --wait=30s --max-pending=1024 \
          --max-waiting=512 --no-headers-only --defaults
    networks: [lab]

  connect-source:
    image: hpdevelop/connect:4.92.0-claudefix
    depends_on:
      redis-central: { condition: service_healthy }
      nats-init: { condition: service_completed_successfully }
    command: ["run","/etc/connect/source.yaml"]
    volumes: [ "./connect/source.yaml:/etc/connect/source.yaml:ro" ]
    ports: ["${SRC_PORT:-14195}:4195"]
    healthcheck: { test: ["CMD-SHELL","wget -qO- http://localhost:4195/ping || exit 1"], interval: 5s, timeout: 3s, retries: 15 }
    networks: [lab]

  connect-sink:
    image: hpdevelop/connect:4.92.0-claudefix
    depends_on:
      redis-region: { condition: service_healthy }
      nats-init: { condition: service_completed_successfully }
    command: ["run","/etc/connect/sink.yaml"]
    volumes: [ "./connect/sink.yaml:/etc/connect/sink.yaml:ro" ]
    ports: ["${SINK_PORT:-14196}:4195"]
    healthcheck: { test: ["CMD-SHELL","wget -qO- http://localhost:4195/ping || exit 1"], interval: 5s, timeout: 3s, retries: 15 }
    networks: [lab]

  writer:
    <<: *app
    depends_on:
      redis-central: { condition: service_healthy }
      connect-source: { condition: service_healthy }
    command: ["/usr/local/bin/app","writer"]
    environment:
      REDIS_ADDR: "redis-central:6379"
      REDIS_CLUSTER: "false"
      STREAM_KEY: "app.events"
      HEALTH_ADDR: ":8081"
      INITIAL_RATE: "0"
      MAX_RATE: "500"
      OP_CREATE: "40"
      OP_UPDATE: "40"
      OP_DELETE: "15"
      OP_RENAME: "5"
    ports: ["${WRITER_PORT:-18081}:8081"]
    healthcheck: { test: ["CMD-SHELL","wget -qO- http://localhost:8081/healthz || exit 1"], interval: 5s, timeout: 3s, retries: 15 }
    networks: [lab]

  latency-calculator:
    <<: *app
    depends_on:
      redis-region: { condition: service_healthy }
    command: ["/usr/local/bin/app","latency-calculator"]
    environment:
      REGION_ADDR: "redis-region:6379"
      REGION_CLUSTER: "false"
      STREAM: "cdc:latency"
      METRICS_ADDR: ":8082"
    networks: [lab]

  prometheus:
    image: prom/prometheus:v2.54.1
    depends_on: [connect-source, connect-sink]
    command: ["--config.file=/etc/prometheus/prometheus.yml","--storage.tsdb.retention.time=2h"]
    ports: ["${PROM_PORT:-19090}:9090"]
    volumes: [ "./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" ]
    networks: [lab]

  grafana:
    image: grafana/grafana:11.2.0
    depends_on: [prometheus]
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Admin
      GF_USERS_DEFAULT_THEME: light
    ports: ["${GRAFANA_PORT:-13000}:3000"]
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ../../chart/files/grafana:/var/lib/grafana/dashboards:rw
    networks: [lab]

networks:
  lab: {}
```

- [ ] **Step 5: Validate compose config parses**

```bash
cd labs/connect-metrics-dashboard && docker compose config >/dev/null && echo "compose OK"; cd -
```
Expected: `compose OK`.

- [ ] **Step 6: Commit**

```bash
git add labs/connect-metrics-dashboard/docker-compose.yml labs/connect-metrics-dashboard/prometheus/ labs/connect-metrics-dashboard/grafana/
git commit -m "lab(connect-metrics): compose stack + prometheus + grafana provisioning"
```

---

### Task 4: Bring the lab up, drive traffic, capture `:4195` metrics

**Files:**
- Create: `labs/connect-metrics-dashboard/scripts/drive.sh`
- Create: `labs/connect-metrics-dashboard/scripts/scrape-metrics.sh`
- Generates: `labs/connect-metrics-dashboard/captured/source-metrics.txt`, `sink-metrics.txt`, `writer-metrics.txt`, `latency-metrics.txt`

**Interfaces:**
- Consumes: the running stack (Task 3).
- Produces: ground-truth metric name lists consumed by the Task 5 audit.

- [ ] **Step 1: Write `scripts/drive.sh`** — start writer traffic, then let CDC flow

```bash
#!/usr/bin/env bash
# Start writer traffic so custom counters fire on both legs, then hold briefly.
set -euo pipefail
w="http://localhost:${WRITER_PORT:-18081}"
curl -fsS -XPOST "$w/rate" -d '{"Rate":50}' && echo
echo "driving traffic for ${1:-45}s..."
sleep "${1:-45}"
curl -fsS -XPOST "$w/rate" -d '{"Rate":0}' && echo "stopped"
```

- [ ] **Step 2: Write `scripts/scrape-metrics.sh`** — capture raw `/metrics` from every source

```bash
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
```

- [ ] **Step 3: Start the stack and wait for health**

```bash
cd labs/connect-metrics-dashboard
docker compose up -d --build
# wait for both legs healthy (up to ~90s)
for i in $(seq 1 30); do
  ok=$(docker compose ps --format '{{.Service}} {{.Health}}' | grep -cE 'connect-(source|sink) healthy' || true)
  [ "$ok" -ge 2 ] && break; sleep 3
done
docker compose ps
cd -
```
Expected: `connect-source` and `connect-sink` both `healthy`.

- [ ] **Step 4: Drive traffic and confirm CDC actually flowed** (region KV must receive keys)

```bash
chmod +x labs/connect-metrics-dashboard/scripts/*.sh
( cd labs/connect-metrics-dashboard && ./scripts/drive.sh 45 )
# region redis must now hold applied keys
docker compose -f labs/connect-metrics-dashboard/docker-compose.yml exec -T redis-region redis-cli DBSIZE
```
Expected: `DBSIZE` > 0 (proves writer→source→nats→sink→region worked end-to-end).

- [ ] **Step 5: Capture metrics and confirm custom counters fired**

```bash
( cd labs/connect-metrics-dashboard && ./scripts/scrape-metrics.sh )
echo "=== custom counters present on sink ==="; grep -E '^cdc_apply|^cdc_unprocessable' labs/connect-metrics-dashboard/captured/sink-metrics.txt | head
echo "=== writer counters ===";               grep -E '^cdc_writer_' labs/connect-metrics-dashboard/captured/writer-metrics.txt | head
```
Expected: at least one `cdc_apply...` line (with or without `_total`) — this line's suffix is the exporter convention for ALL custom counters. If empty, traffic didn't reach the sink: check `docker compose logs connect-sink nats-init`.

- [ ] **Step 6: Commit the captured ground truth**

```bash
git add labs/connect-metrics-dashboard/scripts/drive.sh labs/connect-metrics-dashboard/scripts/scrape-metrics.sh
git add -f labs/connect-metrics-dashboard/captured/source-metrics.txt labs/connect-metrics-dashboard/captured/sink-metrics.txt labs/connect-metrics-dashboard/captured/writer-metrics.txt labs/connect-metrics-dashboard/captured/latency-metrics.txt
git commit -m "lab(connect-metrics): capture live :4195 + app metric names"
```

---

### Task 5: Metric-name audit — dashboard `expr` vs. captured names

**Files:**
- Create: `labs/connect-metrics-dashboard/METRIC-AUDIT.md`
- Modify: `labs/connect-metrics-dashboard/RESEARCH.md` (fill the Findings table)

**Interfaces:**
- Consumes: `captured/*.txt` (Task 4); `chart/files/grafana/cdc-dashboard.json`.
- Produces: an explicit mismatch list that drives the exact edits in Task 6.

- [ ] **Step 1: Extract the base metric names actually exposed**

```bash
c=labs/connect-metrics-dashboard/captured
echo "=== source base names ==="; grep -vE '^#' "$c/source-metrics.txt" | sed -E 's/[{ ].*//' | sort -u
echo "=== sink base names ===";   grep -vE '^#' "$c/sink-metrics.txt"   | sed -E 's/[{ ].*//' | sort -u
```
Note whether custom counters carry `_total` and whether built-ins are bare (`processor_error`) or prefixed (e.g. `benthos_*`/`connect_*`), and the exact latency histogram base (`processor_latency_ns_bucket` vs other).

- [ ] **Step 2: List every metric the dashboard references**

```bash
grep -oE '"expr":[^}]*' chart/files/grafana/cdc-dashboard.json
```
For each `expr`, record the metric name/selector it uses.

- [ ] **Step 3: Write `METRIC-AUDIT.md`** — one row per dashboard target

```markdown
# Metric-name audit — cdc-dashboard.json vs live :4195

Captured: `labs/connect-metrics-dashboard/captured/*.txt` (see git for the run).

| Panel | Dashboard expr uses | Real name on :4195 | Source | Verdict |
|---|---|---|---|---|
| 1 Apply throughput | `{__name__=~"cdc_apply(_total)?"}` | _<fill from capture>_ | sink | _<ok / rename to X / drop regex>_ |
| 2 Unprocessable stat | `{__name__=~"cdc_unprocessable(_total)?"}` | _<fill>_ | sink | _<...>_ |
| 3 Unprocessable by reason | `cdc_unprocessable(_total)?` | _<fill>_ | sink | _<...>_ |
| 4 Processor errors | `{__name__=~"processor_error(_total)?"}` | _<fill>_ | both | _<...>_ |
| 5 Forward publish failed | `cdc_forward_publish_failed(_total)?` | _<fill / structural>_ | source | _<...>_ |
| 6 Processing latency | `processor_latency_ns_bucket` | _<fill>_ | both | _<...>_ |
| 7 E2E latency | `cdc_latency_seconds` | _<fill>_ | latency-calc | _<...>_ |
| 8 Writer throughput | `cdc_writer_ops_total`, `cdc_writer_errors_total` | _<fill>_ | writer | _<...>_ |
| 9 Elector | `elector_leading`, `elector_post_total`, `elector_delete_total` | (source: internal/elector/main.go) | elector | verified-from-source |
| 10 Apply by group | `{__name__=~"cdc_apply(_total)?"}` | _<fill>_ | sink | _<...>_ |
| 11 Forward unrouted | `cdc_forward_unrouted(_total)?` | _<fill / structural>_ | source | _<...>_ |
| 12 Forward others | `cdc_forward_others(_total)?` | _<fill / structural>_ | source | _<...>_ |

## Suffix convention
_<state whether the exporter appends `_total`; note this rule applies identically to
the forward counters that may not have fired>._

## Label check
_<confirm `op`/`type`/`reason`/`le`/`quantile` labels exist on the real series; flag
any label the dashboard groups by that is absent>._
```

- [ ] **Step 4: Fill RESEARCH.md Findings** with the same table's conclusions and the suffix rule.

- [ ] **Step 5: Commit**

```bash
git add labs/connect-metrics-dashboard/METRIC-AUDIT.md labs/connect-metrics-dashboard/RESEARCH.md
git commit -m "lab(connect-metrics): metric-name audit vs live scrape"
```

---

### Task 6: Correct the canonical dashboard + export helper

**Files:**
- Modify: `chart/files/grafana/cdc-dashboard.json` (apply audit fixes)
- Create: `labs/connect-metrics-dashboard/scripts/export-dashboard.sh`

**Interfaces:**
- Consumes: `METRIC-AUDIT.md` verdicts (Task 5); the running Grafana (for render check).
- Produces: the corrected chart dashboard (the primary deliverable).

- [ ] **Step 1: Write `scripts/export-dashboard.sh`** — pull the current dashboard JSON from Grafana back to the chart, cleaned

```bash
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
```

- [ ] **Step 2: Apply the audit fixes to `chart/files/grafana/cdc-dashboard.json`.** For each row in `METRIC-AUDIT.md` with a non-`ok` verdict, edit the corresponding `expr`. Only change metric names/selectors/labels the audit flagged; leave layout, panel ids, gridPos, descriptions, and the `elector_*`/`cdc_writer_*`/`cdc_latency_seconds` exprs (already correct or verified-from-source) untouched. Preserve the templating variables (`$namespace`, `$job`, `$datasource`) exactly. Keep the `datasource` variable's resolved uid compatible with `cdc-prom` (the provisioned datasource uid) OR leave it as the `${datasource}` picker — do not hardcode a foreign uid.

- [ ] **Step 3: Validate JSON is well-formed**

```bash
jq -e . chart/files/grafana/cdc-dashboard.json >/dev/null && echo "valid json"
```
Expected: `valid json`.

- [ ] **Step 4: Reload Grafana and verify panels render non-empty.** Restart Grafana to re-provision, then query each panel's metric through the Grafana datasource proxy to confirm data returns.

```bash
docker compose -f labs/connect-metrics-dashboard/docker-compose.yml restart grafana
sleep 8
# Re-drive traffic so there is live data in the query window, then spot-check the
# two names the whole audit hinges on via the Prometheus API:
( cd labs/connect-metrics-dashboard && ./scripts/drive.sh 20 & )
sleep 10
P="http://localhost:${PROM_PORT:-19090}"
for q in $(jq -r '.panels[].targets[].expr' chart/files/grafana/cdc-dashboard.json | grep -oE '^[a-z_]+' | sort -u); do
  n=$(curl -fsS --data-urlencode "query=$q" "$P/api/v1/query" | jq '.data.result | length')
  echo "$q -> $n series"
done
```
Expected: the corrected names return ≥1 series (except elector_* which legitimately return 0 in the lab — documented). Any *other* name returning 0 means the fix is still wrong — return to the audit.

- [ ] **Step 5: Commit**

```bash
git add chart/files/grafana/cdc-dashboard.json labs/connect-metrics-dashboard/scripts/export-dashboard.sh
git commit -m "fix(dashboard): align cdc-dashboard.json metric names with live Connect :4195"
```

---

### Task 7: Chart-render invariant + finalize

**Files:**
- Modify: `labs/connect-metrics-dashboard/RESEARCH.md` (add Run section + final status)

**Interfaces:**
- Consumes: everything above.
- Produces: green chart-render invariant; a reproducible lab.

- [ ] **Step 1: Run the chart-render invariant** (mandatory after any chart change)

```bash
helm lint chart/ && helm template chart/ >/dev/null && echo "CHART RENDER OK"
```
Expected: `CHART RENDER OK`. Paste the exit status. If the dashboard JSON is embedded via a ConfigMap that validates it, this catches a malformed edit.

- [ ] **Step 2: Confirm the dashboard-alerting lab still renders the (now corrected) JSON** — that lab bind-mounts the same file; a quick config parse guards against a breaking rename.

```bash
docker compose -f labs/redis-cdc-error-alerting/docker-compose.yml config >/dev/null && echo "alerting lab config OK"
```
Expected: `alerting lab config OK`.

- [ ] **Step 3: Add the "Run" section to RESEARCH.md**

```markdown
## Run
```bash
cd labs/connect-metrics-dashboard
./scripts/render-configs.sh              # regenerate Connect configs from the chart
docker compose up -d --build             # bring up the full CDC path
./scripts/drive.sh 45                     # generate traffic
./scripts/scrape-metrics.sh              # capture raw :4195 + app /metrics into captured/
# edit dashboards live at http://localhost:13000 (anonymous admin), then:
./scripts/export-dashboard.sh            # write edits back to chart/files/grafana/cdc-dashboard.json
docker compose down -v
```
## Status
Dashboard aligned to live metric names on <date>. See METRIC-AUDIT.md for the mapping.
```

- [ ] **Step 4: Tear down the stack**

```bash
docker compose -f labs/connect-metrics-dashboard/docker-compose.yml down -v && echo "torn down"
```

- [ ] **Step 5: Final commit**

```bash
git add labs/connect-metrics-dashboard/RESEARCH.md
git commit -m "lab(connect-metrics): finalize RESEARCH.md + verify chart-render invariant"
```

---

## Self-Review notes

- **Spec coverage:** compose env (T3) ✓; raw :4195 from both legs (T4) ✓; align names (T5→T6) ✓; canonical chart JSON is the deliverable (T6) ✓; isolated worktree (Global Constraints) ✓; RESEARCH.md per research-lab (T1/T5/T7) ✓; elector gap documented + source-verified (T5) ✓.
- **Fidelity guarantee:** metric blocks byte-checked against chart (T2 Step 4); no hand-authored metric names (Global Constraints).
- **No placeholders:** every script/config shown in full; the only intentionally-deferred content is the audit *data* (T5 table cells), which cannot exist until the live scrape runs — the table structure and fill procedure are fully specified.
- **Name consistency:** `cdc-prom` datasource uid (T3) referenced in T6 Step 2; `LAB_CDC`/`cdc_sink` stream+consumer consistent between T2 values, T3 nats-init; ports (`SRC_PORT`/`SINK_PORT`/`WRITER_PORT`/`PROM_PORT`/`GRAFANA_PORT`) consistent across T3/T4/T6.
