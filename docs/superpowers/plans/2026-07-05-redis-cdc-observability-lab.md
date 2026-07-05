# CDC Observability — Validation Lab Implementation Plan (Plan 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A self-contained docker-compose lab that runs a distilled Redpanda Connect sink pipeline (same metric names as the chart) fed by a Go traffic generator, and an automated `verify-alert.sh` that proves the chart's `CDCUnprocessableMessages` alert fires on poison traffic, stays green on healthy traffic, clears on recovery, and the Grafana dashboard reflects it — all consuming the chart's single-source `cdc-alerts.yaml` and `cdc-dashboard.json` directly (no copies).

**Architecture:** `labs/redis-cdc-error-alerting/` compose stack: `redis` + `nats` (JetStream) + `nats-init` (stream+durable pull consumer) + `connect` (distilled sink, metrics on :4195) + `prometheus` (scrapes connect, loads the chart's alert file) + `alertmanager` (→ webhook) + `alert-sink` (Go, records fired alerts) + `grafana` (provisioned with the chart's dashboard) + `generator` (Go, healthy/poison/mixed traffic). The chart's alert and dashboard are **bind-mounted** from `../../chart/files/...`, so the lab validates exactly what ships.

**Tech Stack:** Docker Compose, Redpanda Connect `hpdevelop/connect:4.92.0-claudefix`, NATS JetStream, Redis, Prometheus, Alertmanager, Grafana, Go (nats.go), bash.

**Spec:** `docs/superpowers/specs/2026-07-04-redis-cdc-observability-alerting-design.md` (§"Validation lab")
**Depends on:** Plan 1 (merged) — `chart/files/prometheus/cdc-alerts.yaml`, `chart/files/grafana/cdc-dashboard.json`.

**Prerequisites:** Docker + Docker Compose v2, `curl`, `jq`. All paths below are relative to repo root `/media/hp/secondary/projects/gam-redis-pubsub`; the lab dir is `labs/redis-cdc-error-alerting/`.

---

## File Structure

```
labs/redis-cdc-error-alerting/
  docker-compose.yml
  .env.example
  README.md
  RESEARCH.md
  connect/config.yaml              # distilled sink pipeline (metrics on :4195)
  prometheus/prometheus.yml        # scrape connect (stamps namespace/job), loads chart alert file
  alertmanager/alertmanager.yml    # route → alert-sink webhook
  grafana/provisioning/datasources/prom.yml
  grafana/provisioning/dashboards/provider.yml
  alert-sink/{main.go,go.mod,Dockerfile}     # records fired alerts, GET /alerts
  generator/{main.go,go.mod,Dockerfile}      # publishes CDC envelopes (healthy/poison/mixed)
  scripts/run-lab.sh
  scripts/verify-alert.sh
```
Single-source bind mounts (in compose, relative to the lab dir):
- `../../chart/files/prometheus/cdc-alerts.yaml` → prometheus rules
- `../../chart/files/grafana` → grafana dashboards dir

---

## Task 1: Lab scaffold + compose skeleton (no app services yet)

**Files:** create `labs/redis-cdc-error-alerting/docker-compose.yml`, `.env.example`, `README.md`.

- [ ] **Step 1: Create `docker-compose.yml` with the infra services (redis, nats, nats-init)**

```yaml
name: lab-redis-cdc-error-alerting

# Validates the redis-cdc-le-k8s chart's Grafana dashboard + unprocessable-message
# alert. The chart's cdc-alerts.yaml and cdc-dashboard.json are bind-mounted (not
# copied) so the lab tests exactly what ships. See RESEARCH.md.

services:
  redis:
    image: redis:7.4-alpine
    command: ["redis-server", "--save", "", "--appendonly", "no"]
    healthcheck: { test: ["CMD","redis-cli","ping"], interval: 2s, timeout: 2s, retries: 15 }
    networks: [lab]

  nats:
    image: nats:2.10-alpine
    command: ["-js","-m","8222"]
    ports: ["${NATS_MONITOR_PORT:-18222}:8222"]
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
        echo "nats-init: stream + durable pull consumer created"
    networks: [lab]

networks:
  lab: {}
```

- [ ] **Step 2: Create `.env.example`**

```bash
# Host port overrides (avoid collisions with other labs). Copy to .env to customize.
NATS_MONITOR_PORT=18222
PROM_PORT=19090
ALERTMANAGER_PORT=19093
GRAFANA_PORT=13000
ALERT_SINK_PORT=19099
```

- [ ] **Step 3: Create `README.md` (short — RESEARCH.md carries the depth)**

```markdown
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
```

- [ ] **Step 4: Verify compose parses**

Run: `cd labs/redis-cdc-error-alerting && docker compose config >/dev/null && echo COMPOSE_OK`
Expected: `COMPOSE_OK`.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-cdc-error-alerting/docker-compose.yml labs/redis-cdc-error-alerting/.env.example labs/redis-cdc-error-alerting/README.md
git commit -m "feat(lab): scaffold redis-cdc-error-alerting compose (redis+nats+nats-init)"
```

---

## Task 2: Distilled Connect sink pipeline + service

**Files:** create `labs/redis-cdc-error-alerting/connect/config.yaml`; add the `connect` service to `docker-compose.yml`.

The pipeline mirrors the chart's `cdc-reverse.yaml` op-switch and the SAME metric names (`cdc_apply`, `cdc_unprocessable{reason}`), including the `else { null }` decode fix. Simplified for the lab: string-type SET only, redis `RENAME` instead of the Lua, no latency xadd, no content-log.

- [ ] **Step 1: Create `connect/config.yaml`**

```yaml
# Distilled sink pipeline (run mode). Same metric names as chart cdc-reverse.yaml.
http: { address: 0.0.0.0:4195, enabled: true }
metrics: { prometheus: {} }
logger: { level: INFO, format: json }

input:
  label: jetstream_source
  nats_jetstream:
    urls: ["nats://nats:4222"]
    stream: LAB_CDC
    durable: cdc_sink
    bind: true          # attach to the pre-created durable pull consumer (nats-init)

pipeline:
  threads: 1
  processors:
    - mapping: |
        meta op      = this.op
        meta type    = this.type.or("string")
        meta kv_key  = this.kv_key
        meta old_key = this.old_key
        meta new_key = this.new_key
        let is_encoded = (this.op == "create" || this.op == "update") && this.enc.or("") == "gzip:base64"
        # else { null } is REQUIRED: a let bound to an if-without-else leaves the var
        # undefined for delete/rename, and meta body = $decoded would then throw.
        let decoded = if this.op == "create" || this.op == "update" {
          if $is_encoded { this.body.decode("base64").decompress("gzip").catch(null) } else { this.body }
        } else { null }
        meta body = $decoded
        meta decode_failed = if $is_encoded && $decoded == null { "yes" } else { "no" }
    - switch:
        - check: meta("decode_failed") == "yes"
          processors:
            - metric: { type: counter, name: cdc_unprocessable, labels: { reason: decode_error } }
            - mapping: 'root = throw("decode_error")'
        - check: meta("op") == "create" || meta("op") == "update"
          processors:
            - redis: { url: "redis://redis:6379", command: set, args_mapping: 'root = [ meta("kv_key"), meta("body") ]' }
            - metric: { type: counter, name: cdc_apply, labels: { op: '${! meta("op") }', type: '${! meta("type") }' } }
        - check: meta("op") == "delete"
          processors:
            - redis: { url: "redis://redis:6379", command: del, args_mapping: 'root = [ meta("kv_key") ]' }
            - metric: { type: counter, name: cdc_apply, labels: { op: delete } }
        - check: meta("op") == "rename"
          processors:
            - redis: { url: "redis://redis:6379", command: rename, args_mapping: 'root = [ meta("old_key"), meta("new_key") ]' }
            - metric: { type: counter, name: cdc_apply, labels: { op: rename } }
        - processors:
            - metric: { type: counter, name: cdc_unprocessable, labels: { reason: unknown_op } }
            - mapping: 'root = throw("unknown op")'

output:
  reject_errored:
    drop: {}
```

- [ ] **Step 2: Lint the config against the pinned image**

Run: `cd labs/redis-cdc-error-alerting && docker run --rm -i hpdevelop/connect:4.92.0-claudefix lint /dev/stdin < connect/config.yaml && echo LINT_OK`
Expected: `LINT_OK` (exit 0).

- [ ] **Step 3: Add the `connect` service to `docker-compose.yml`** (insert before `networks:`)

```yaml
  connect:
    image: hpdevelop/connect:4.92.0-claudefix
    depends_on:
      redis: { condition: service_healthy }
      nats-init: { condition: service_completed_successfully }
    command: ["run","/etc/connect/config.yaml"]
    volumes:
      - ./connect/config.yaml:/etc/connect/config.yaml:ro
    healthcheck: { test: ["CMD","/redpanda-connect","echo","ok"], interval: 5s, timeout: 3s, retries: 10 }
    networks: [lab]
```
> Note: if the `echo` subcommand isn't present in this build, replace the healthcheck test with `["CMD-SHELL","wget -qO- http://localhost:4195/ping || exit 1"]`. Verify in Step 4.

- [ ] **Step 4: Bring up infra + connect and confirm /metrics exposes the counters**

Run:
```bash
cd labs/redis-cdc-error-alerting
docker compose up -d --build redis nats nats-init connect
sleep 8
docker compose exec -T connect wget -qO- http://localhost:4195/ping && echo " PING_OK"
docker run --rm --network container:$(docker compose ps -q connect) curlimages/curl -s http://localhost:4195/metrics | grep -E '^(cdc_|input_received|processor_error)' | head
```
Expected: `PING_OK`; `/metrics` reachable (cdc_* may be zero until traffic flows — that's fine; presence of the endpoint is what matters).

- [ ] **Step 5: Commit**

```bash
git add labs/redis-cdc-error-alerting/connect/config.yaml labs/redis-cdc-error-alerting/docker-compose.yml
git commit -m "feat(lab): distilled Connect sink pipeline + service (same metric names)"
```

---

## Task 3: Prometheus + Alertmanager (single-source alert mount)

**Files:** create `prometheus/prometheus.yml`, `alertmanager/alertmanager.yml`; add `prometheus` + `alertmanager` services.

- [ ] **Step 1: Create `prometheus/prometheus.yml`** (stamps `namespace`/`job` so the shared alert/dashboard scope correctly)

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
rule_files:
  - /etc/prometheus/rules/cdc-alerts.yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
scrape_configs:
  - job_name: cdc-connect-sink          # becomes the `job` label the alert/dashboard group by
    metrics_path: /metrics
    static_configs:
      - targets: ["connect:4195"]
        labels:
          namespace: lab-cdc            # stamps the `namespace` label the shared queries expect
```

- [ ] **Step 2: Create `alertmanager/alertmanager.yml`** (route everything to the webhook, no batching delay)

```yaml
route:
  receiver: alert-sink
  group_by: ["alertname","namespace","job","reason"]
  group_wait: 0s
  group_interval: 5s
  repeat_interval: 1m
receivers:
  - name: alert-sink
    webhook_configs:
      - url: http://alert-sink:9099/webhook
        send_resolved: true
```

- [ ] **Step 3: Add `prometheus` + `alertmanager` services to `docker-compose.yml`**

```yaml
  prometheus:
    image: prom/prometheus:v2.54.1
    depends_on: [connect]
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=2h
    ports: ["${PROM_PORT:-19090}:9090"]
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ../../chart/files/prometheus/cdc-alerts.yaml:/etc/prometheus/rules/cdc-alerts.yaml:ro
    networks: [lab]

  alertmanager:
    image: prom/alertmanager:v0.27.0
    command: ["--config.file=/etc/alertmanager/alertmanager.yml"]
    ports: ["${ALERTMANAGER_PORT:-19093}:9093"]
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    networks: [lab]
```

- [ ] **Step 4: Verify Prometheus loads the SHARED alert rule and scrapes connect**

Run:
```bash
cd labs/redis-cdc-error-alerting
docker compose up -d prometheus alertmanager
sleep 8
curl -s "http://localhost:${PROM_PORT:-19090}/api/v1/rules" | jq -e '[.data.groups[].rules[] | select(.name=="CDCUnprocessableMessages")] | length == 1'
curl -s "http://localhost:${PROM_PORT:-19090}/api/v1/targets" | jq -r '.data.activeTargets[] | "\(.labels.job) \(.labels.namespace) \(.health)"'
```
Expected: `true`; a target line `cdc-connect-sink lab-cdc up`.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-cdc-error-alerting/prometheus labs/redis-cdc-error-alerting/alertmanager labs/redis-cdc-error-alerting/docker-compose.yml
git commit -m "feat(lab): Prometheus (mounts chart alert rule) + Alertmanager → webhook"
```

---

## Task 4: `alert-sink` Go service (records fired alerts)

**Files:** create `alert-sink/main.go`, `alert-sink/go.mod`, `alert-sink/Dockerfile`; add `alert-sink` service.

- [ ] **Step 1: Create `alert-sink/go.mod`**

```
module alert-sink

go 1.23
```

- [ ] **Step 2: Create `alert-sink/main.go`**

```go
// alert-sink records alerts POSTed by Alertmanager and exposes them for the test
// script. GET /alerts returns the recorded firing alerts as JSON.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
)

type amAlert struct {
	Status string            `json:"status"`
	Labels map[string]string `json:"labels"`
}
type amPayload struct {
	Alerts []amAlert `json:"alerts"`
}

type store struct {
	mu   sync.Mutex
	seen []amAlert
}

func (s *store) add(a []amAlert) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seen = append(s.seen, a...)
}
func (s *store) snapshot() []amAlert {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]amAlert, len(s.seen))
	copy(out, s.seen)
	return out
}

func main() {
	s := &store{}
	http.HandleFunc("/webhook", func(w http.ResponseWriter, r *http.Request) {
		var p amPayload
		if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		s.add(p.Alerts)
		for _, a := range p.Alerts {
			log.Printf("alert %s status=%s reason=%s ns=%s job=%s",
				a.Labels["alertname"], a.Status, a.Labels["reason"], a.Labels["namespace"], a.Labels["job"])
		}
		w.WriteHeader(http.StatusNoContent)
	})
	http.HandleFunc("/alerts", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(s.snapshot())
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	log.Println("alert-sink listening on :9099")
	log.Fatal(http.ListenAndServe(":9099", nil))
}
```

- [ ] **Step 3: Create `alert-sink/Dockerfile`**

```dockerfile
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /alert-sink .

FROM alpine:3.20
RUN apk add --no-cache wget
COPY --from=build /alert-sink /alert-sink
EXPOSE 9099
ENTRYPOINT ["/alert-sink"]
```

- [ ] **Step 4: Add the `alert-sink` service to `docker-compose.yml`**

```yaml
  alert-sink:
    build: ./alert-sink
    ports: ["${ALERT_SINK_PORT:-19099}:9099"]
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:9099/healthz"], interval: 3s, timeout: 2s, retries: 10 }
    networks: [lab]
```
Also add `alert-sink: { condition: service_healthy }` under `alertmanager.depends_on` (create the `depends_on` block on the alertmanager service).

- [ ] **Step 5: Build & smoke-test the endpoints**

Run:
```bash
cd labs/redis-cdc-error-alerting
docker compose up -d --build alert-sink
sleep 5
curl -s "http://localhost:${ALERT_SINK_PORT:-19099}/alerts" | jq -e 'type=="array"'
curl -s -XPOST "http://localhost:${ALERT_SINK_PORT:-19099}/webhook" -d '{"alerts":[{"status":"firing","labels":{"alertname":"X","reason":"unknown_op"}}]}'
curl -s "http://localhost:${ALERT_SINK_PORT:-19099}/alerts" | jq -e 'length==1 and .[0].labels.alertname=="X"'
```
Expected: `true`, then `true`.

- [ ] **Step 6: Commit**

```bash
git add labs/redis-cdc-error-alerting/alert-sink labs/redis-cdc-error-alerting/docker-compose.yml
git commit -m "feat(lab): alert-sink service records Alertmanager webhooks"
```

---

## Task 5: `generator` Go service (healthy/poison/mixed traffic)

**Files:** create `generator/main.go`, `generator/go.mod`, `generator/Dockerfile`; add `generator` service.

Publishes CDC envelopes to `kv.cdc.<op>` on JetStream. Healthy = create/update/delete on managed keys. Poison = `unknown_op` (op outside the known set) + `decode_error` (create with `enc:"gzip:base64"` and a corrupt body). Mode/rate via env.

- [ ] **Step 1: Create `generator/go.mod`**

```
module generator

go 1.23

require github.com/nats-io/nats.go v1.37.0
```
(The implementer must run `go mod tidy` inside the build to populate `go.sum`; the Dockerfile does this.)

- [ ] **Step 2: Create `generator/main.go`**

```go
// generator publishes CDC envelopes to NATS JetStream subject kv.cdc.<op>.
// MODE=healthy|poison|mixed, RATE msgs/sec, DURATION seconds (0 = forever).
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strconv"
	"time"

	"github.com/nats-io/nats.go"
)

type envelope struct {
	EventID string `json:"event_id"`
	Op      string `json:"op"`
	Type    string `json:"type"`
	KVKey   string `json:"kv_key"`
	OldKey  string `json:"old_key"`
	NewKey  string `json:"new_key"`
	TS      string `json:"ts"`
	Enc     string `json:"enc,omitempty"`
	Body    string `json:"body,omitempty"`
}

func gzipB64(b []byte) string {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	_, _ = w.Write(b)
	_ = w.Close()
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	mode := env("MODE", "mixed")
	rate, _ := strconv.Atoi(env("RATE", "20"))
	dur, _ := strconv.Atoi(env("DURATION", "0"))
	url := env("NATS_URL", "nats://nats:4222")

	nc, err := nats.Connect(url, nats.Timeout(5*time.Second), nats.RetryOnFailedConnect(true), nats.MaxReconnects(-1))
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	js, err := nc.JetStream()
	if err != nil {
		log.Fatalf("jetstream: %v", err)
	}

	if rate < 1 {
		rate = 1
	}
	tick := time.NewTicker(time.Second / time.Duration(rate))
	defer tick.Stop()
	deadline := time.Time{}
	if dur > 0 {
		deadline = time.Now().Add(time.Duration(dur) * time.Second)
	}
	log.Printf("generator mode=%s rate=%d/s duration=%ds", mode, rate, dur)

	n := 0
	for range tick.C {
		if !deadline.IsZero() && time.Now().After(deadline) {
			log.Printf("generator done after %d msgs", n)
			return
		}
		e := next(mode, n)
		payload, _ := json.Marshal(e)
		subj := "kv.cdc." + e.Op
		msg := &nats.Msg{Subject: subj, Data: payload, Header: nats.Header{"Nats-Msg-Id": []string{e.EventID}}}
		if _, err := js.PublishMsg(msg); err != nil {
			log.Printf("publish %s: %v", subj, err)
		}
		n++
	}
}

// next builds the nth envelope for the given mode.
func next(mode string, n int) envelope {
	switch mode {
	case "healthy":
		return healthy(n)
	case "poison":
		return poison(n)
	default: // mixed: ~1 in 10 is poison
		if n%10 == 0 {
			return poison(n)
		}
		return healthy(n)
	}
}

func healthy(n int) envelope {
	key := fmt.Sprintf("k%d", n%50) // small keyspace so update/delete hit existing keys
	base := envelope{EventID: fmt.Sprintf("h-%d", n), Type: "string", KVKey: key, TS: strconv.FormatInt(time.Now().UnixMilli(), 10)}
	switch n % 3 {
	case 0:
		base.Op = "create"
		base.Enc = "gzip:base64"
		base.Body = gzipB64([]byte(fmt.Sprintf(`{"v":%d}`, n)))
	case 1:
		base.Op = "update"
		base.Enc = "gzip:base64"
		base.Body = gzipB64([]byte(fmt.Sprintf(`{"v":%d,"u":1}`, n)))
	default:
		base.Op = "delete"
	}
	return base
}

func poison(n int) envelope {
	base := envelope{EventID: fmt.Sprintf("p-%d", n), Type: "string", KVKey: fmt.Sprintf("poison%d", n), TS: strconv.FormatInt(time.Now().UnixMilli(), 10)}
	if rand.Intn(2) == 0 {
		// unknown_op: op outside create/update/delete/rename
		base.Op = "frobnicate"
	} else {
		// decode_error: create/update claiming gzip:base64 but body is not valid base64/gzip
		base.Op = "create"
		base.Enc = "gzip:base64"
		base.Body = "!!!this-is-not-base64-gzip!!!"
	}
	return base
}
```

- [ ] **Step 3: Create `generator/Dockerfile`** (runs `go mod tidy` to build `go.sum`)

```dockerfile
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go mod tidy && CGO_ENABLED=0 go build -o /generator .

FROM alpine:3.20
COPY --from=build /generator /generator
ENTRYPOINT ["/generator"]
```

- [ ] **Step 4: Add the `generator` service to `docker-compose.yml`** (default profile so it doesn't auto-run; the test script drives it with explicit MODE)

```yaml
  generator:
    build: ./generator
    depends_on:
      nats-init: { condition: service_completed_successfully }
    environment:
      NATS_URL: nats://nats:4222
      MODE: ${GEN_MODE:-mixed}
      RATE: ${GEN_RATE:-20}
      DURATION: ${GEN_DURATION:-0}
    profiles: ["gen"]     # not started by default `up`; run on demand via the test script
    networks: [lab]
```

- [ ] **Step 5: Build & smoke-test the generator against a healthy burst**

Run:
```bash
cd labs/redis-cdc-error-alerting
docker compose build generator
GEN_MODE=healthy GEN_RATE=30 GEN_DURATION=4 docker compose run --rm generator
# confirm the sink applied SETs to redis
docker compose exec -T redis redis-cli DBSIZE
```
Expected: generator logs "done after N msgs"; `DBSIZE` > 0 (keys applied).

- [ ] **Step 6: Commit**

```bash
git add labs/redis-cdc-error-alerting/generator labs/redis-cdc-error-alerting/docker-compose.yml
git commit -m "feat(lab): Go traffic generator (healthy/poison/mixed CDC envelopes)"
```

---

## Task 6: Grafana provisioning (single-source dashboard mount)

**Files:** create `grafana/provisioning/datasources/prom.yml`, `grafana/provisioning/dashboards/provider.yml`; add `grafana` service.

- [ ] **Step 1: Create `grafana/provisioning/datasources/prom.yml`**

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
```

- [ ] **Step 2: Create `grafana/provisioning/dashboards/provider.yml`**

```yaml
apiVersion: 1
providers:
  - name: cdc
    type: file
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

- [ ] **Step 3: Add the `grafana` service (mounts the chart's dashboard dir verbatim)**

```yaml
  grafana:
    image: grafana/grafana:11.2.0
    depends_on: [prometheus]
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Viewer
    ports: ["${GRAFANA_PORT:-13000}:3000"]
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ../../chart/files/grafana:/var/lib/grafana/dashboards:ro
    networks: [lab]
```

- [ ] **Step 4: Verify Grafana imports the shared dashboard and resolves the datasource**

Run:
```bash
cd labs/redis-cdc-error-alerting
docker compose up -d grafana
sleep 10
curl -s "http://admin:admin@localhost:${GRAFANA_PORT:-13000}/api/search?query=CDC%20Sink" | jq -e 'length>=1'
curl -s "http://admin:admin@localhost:${GRAFANA_PORT:-13000}/api/dashboards/uid/cdc-sink-observability" | jq -e '.dashboard.uid=="cdc-sink-observability"'
```
Expected: `true`, `true` (dashboard provisioned from the chart's file; `${datasource}` resolves to the provisioned Prometheus).

- [ ] **Step 5: Commit**

```bash
git add labs/redis-cdc-error-alerting/grafana labs/redis-cdc-error-alerting/docker-compose.yml
git commit -m "feat(lab): Grafana provisioned with the chart's single-source dashboard"
```

---

## Task 7: `run-lab.sh` + `verify-alert.sh` (the automated proof)

**Files:** create `scripts/run-lab.sh`, `scripts/verify-alert.sh` (both `chmod +x`).

- [ ] **Step 1: Create `scripts/run-lab.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d --build redis nats nats-init connect prometheus alertmanager alert-sink grafana
echo "lab up. grafana=http://localhost:${GRAFANA_PORT:-13000}  prometheus=http://localhost:${PROM_PORT:-19090}"
```

- [ ] **Step 2: Create `scripts/verify-alert.sh`**

```bash
#!/usr/bin/env bash
# Automated proof: healthy → no alert; poison → alert fires (both reasons) & webhook
# received; recovery (purge) → alert clears. Resolves metric names from /metrics
# first (no _total assumption). Exits 0 on PASS, 1 on FAIL.
set -uo pipefail
cd "$(dirname "$0")/.."
PROM="http://localhost:${PROM_PORT:-19090}"
SINK="http://localhost:${ALERT_SINK_PORT:-19099}"
ALERT="CDCUnprocessableMessages"

fail() { echo "FAIL: $*"; exit 1; }
psql() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result'; }
alert_state() { curl -s "$PROM/api/v1/alerts" | jq -r --arg a "$ALERT" '[.data.alerts[]|select(.labels.alertname==$a)]'; }

echo "== bring up =="
scripts/run-lab.sh >/dev/null
# wait for prometheus target up
for i in $(seq 1 30); do
  up=$(curl -s "$PROM/api/v1/targets" | jq -r '[.data.activeTargets[]|select(.labels.job=="cdc-connect-sink" and .health=="up")]|length')
  [ "$up" = "1" ] && break; sleep 2
done
[ "${up:-0}" = "1" ] || fail "connect target never came up"

echo "== resolve metric names from /metrics (no _total assumption) =="
metrics=$(docker run --rm --network "container:$(docker compose ps -q connect)" curlimages/curl -s http://localhost:4195/metrics)
echo "$metrics" | grep -qE '^cdc_apply(_total)?\{' || echo "  (cdc_apply not present yet — will appear after healthy traffic)"

echo "== PHASE 1: healthy → alert must stay inactive, cdc_apply must climb =="
GEN_MODE=healthy GEN_RATE=30 GEN_DURATION=15 docker compose run --rm generator >/dev/null
sleep 5
applied=$(psql 'sum(increase({__name__=~"cdc_apply(_total)?"}[2m]))' | jq -r 'if length>0 then .[0].value[1] else "0" end')
echo "  cdc_apply increase(2m)=$applied"
awk "BEGIN{exit !($applied > 0)}" || fail "healthy phase produced no cdc_apply increase"
firing=$(alert_state | jq -r '[.[]|select(.state=="firing")]|length')
[ "$firing" = "0" ] || fail "alert fired during healthy phase ($firing)"
echo "  OK: cdc_apply climbing, alert inactive"

echo "== PHASE 2: poison → alert must fire (both reasons) and webhook must receive it =="
GEN_MODE=poison GEN_RATE=20 GEN_DURATION=20 docker compose run -d --rm generator >/dev/null
ok=0
for i in $(seq 1 40); do    # up to ~2min
  st=$(alert_state)
  reasons=$(echo "$st" | jq -r '[.[]|select(.state=="firing")|.labels.reason]|sort|unique|join(",")')
  if echo "$reasons" | grep -q "decode_error" && echo "$reasons" | grep -q "unknown_op"; then ok=1; echo "  alert firing for reasons: $reasons"; break; fi
  sleep 3
done
[ "$ok" = "1" ] || fail "alert did not fire for both poison reasons in time (last: ${reasons:-none})"
# webhook received it
sink_ok=$(curl -s "$SINK/alerts" | jq -r --arg a "$ALERT" '[.[]|select(.labels.alertname==$a and .status=="firing")]|length')
[ "${sink_ok:-0}" -ge 1 ] || fail "alert-sink did not receive the firing alert"
echo "  OK: alert firing (both reasons) + webhook received ($sink_ok)"

echo "== PHASE 3: recovery → purge poison, alert must clear (~2m window) =="
docker compose exec -T nats-box true 2>/dev/null || true
docker run --rm --network "container:$(docker compose ps -q nats)" natsio/nats-box:0.14.5 \
  nats --server nats://localhost:4222 stream purge LAB_CDC -f >/dev/null 2>&1 || \
  docker compose run --rm --entrypoint sh nats-init -c 'nats --server nats://nats:4222 stream purge LAB_CDC -f' >/dev/null
cleared=0
for i in $(seq 1 60); do    # up to ~3min (window 2m + margin)
  firing=$(alert_state | jq -r '[.[]|select(.state=="firing")]|length')
  if [ "$firing" = "0" ]; then cleared=1; echo "  alert cleared after ~$((i*3))s"; break; fi
  sleep 3
done
[ "$cleared" = "1" ] || fail "alert did not clear within ~3min after purge"

echo "PASS: healthy-clean, poison-fires-both-reasons+webhook, recovery-clears"
```

- [ ] **Step 3: `chmod +x` both scripts**

Run: `chmod +x labs/redis-cdc-error-alerting/scripts/run-lab.sh labs/redis-cdc-error-alerting/scripts/verify-alert.sh && echo CHMOD_OK`

- [ ] **Step 4: Run the full proof end-to-end**

Run:
```bash
cd labs/redis-cdc-error-alerting
docker compose down -v 2>/dev/null || true
scripts/verify-alert.sh; echo "exit=$?"
```
Expected: ends with `PASS: ...` and `exit=0`. (Phase 3 takes ~2-3 min due to the 2m alert window.)

- [ ] **Step 5: Commit**

```bash
git add labs/redis-cdc-error-alerting/scripts
git commit -m "feat(lab): run-lab.sh + verify-alert.sh (healthy/poison/recovery proof)"
```

---

## Task 8: RESEARCH.md

**Files:** create `labs/redis-cdc-error-alerting/RESEARCH.md`.

- [ ] **Step 1: Write `RESEARCH.md`** covering: the topology diagram; the metric taxonomy (`cdc_apply`, `cdc_unprocessable{reason=unknown_op|decode_error}`, built-in `processor_error`); why the dedicated counter drives the alert while `processor_error` is dashboard-context; how the alert maps to "unprocessable" (nack + redeliver-forever under `maxDeliver=-1`, alert clears ~2m after the poison is purged); the single-source design (bind-mounting the chart's `cdc-alerts.yaml` and `cdc-dashboard.json`); and how to read each dashboard panel. Include the exact `verify-alert.sh` phases and what each asserts.

- [ ] **Step 2: Verify it references the real artifacts**

Run: `grep -qE "cdc_unprocessable|cdc-alerts.yaml|cdc-dashboard.json|maxDeliver" labs/redis-cdc-error-alerting/RESEARCH.md && echo DOC_OK`
Expected: `DOC_OK`.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-cdc-error-alerting/RESEARCH.md
git commit -m "docs(lab): RESEARCH.md — metric taxonomy, alert mapping, single-source design"
```

---

## Self-Review Notes (author)

- **Spec coverage:** distilled single-Connect sink (Task 2), redis+nats+nats-init (Task 1), prometheus stamping namespace/job + loading the SHARED alert (Task 3), alertmanager→webhook + alert-sink (Tasks 3-4), Go generator with BOTH poison reasons incl. the correct decode_error shape — create/update + enc:gzip:base64 + corrupt body (Task 5), Grafana with the SHARED dashboard (Task 6), verify-alert.sh healthy/poison/recovery that resolves metric names from /metrics first (Task 7), RESEARCH.md (Task 8). Single-source via bind mounts (Tasks 3, 6).
- **Placeholder scan:** none — all configs, Go, and scripts are complete.
- **Consistency:** metric names `cdc_apply`/`cdc_unprocessable` match Plan 1 and the pinned image (unsuffixed; queries use `(_total)?` regex). `namespace=lab-cdc`/`job=cdc-connect-sink` labels match what the shared dashboard/alert group by. Consumer `maxDeliver=-1`/`ackWait=30s` match the chart and the alert's 2m window coupling.
- **Known slow point:** Phase 3 recovery waits for the 2m alert window (single-source rule file, not shortened) — ~2-3 min; documented in the script and RESEARCH.md.
- **Env caveats to expect during execution:** `go.sum` is generated at build time via `go mod tidy` in the Dockerfiles; the connect healthcheck may need the `wget /ping` fallback noted in Task 2 Step 3.
