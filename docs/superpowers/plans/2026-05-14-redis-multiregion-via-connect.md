# Redis Multiregion via Redpanda Connect — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a docker-compose lab under `labs/redis-multiregion-via-connect/` that propagates KV writes from a central Redis to a region Redis through a Redpanda Connect → NATS JetStream → Redpanda Connect bridge, with a live web dashboard that visualizes per-key state and SET-to-SET propagation delay.

**Architecture:** A Go writer performs atomic `MULTI/SET/XADD/EXEC` on central Redis (9 keys across 3 patterns). `connect-forward` reads the stream and publishes each entry to NATS JetStream subject `app.events.<pattern>` with `Nats-Msg-Id` set to a producer UUID. `connect-reverse` consumes the JetStream subject and `SET`s the value into region Redis. A Go dashboard `PSUBSCRIBE`s keyspace events on *both* Redises, parses `t_send_ms` from each value, computes `delta_ms = now() - t_send_ms`, and streams events to the browser over a WebSocket.

**Tech Stack:** docker-compose v2; `redis:7.4-alpine`; `nats:2.10-alpine`; `natsio/nats-box:0.14.5`; `docker.redpanda.com/redpandadata/connect:4.45.1`; Go 1.23 (`go-redis/v9`, `google/uuid`, `gorilla/websocket`); plain HTML/JS dashboard.

---

## File structure

```
labs/redis-multiregion-via-connect/
├── RESEARCH.md                       (already exists)
├── README.md                         (Task 7)
├── docker-compose.yml                (Task 2)
├── .env.example                      (Task 1)
├── .gitignore                        (Task 1)
├── connect/
│   ├── forward.yaml                  (Task 3)
│   └── reverse.yaml                  (Task 3)
├── writer/
│   ├── Dockerfile                    (Task 4)
│   ├── go.mod                        (Task 4)
│   ├── go.sum                        (Task 4 — `go mod tidy`)
│   └── main.go                       (Task 4)
├── dashboard/
│   ├── Dockerfile                    (Task 5)
│   ├── go.mod                        (Task 5)
│   ├── go.sum                        (Task 5 — `go mod tidy`)
│   ├── main.go                       (Task 5)
│   └── static/
│       └── index.html                (Task 5)
└── scripts/
    └── smoke-test.sh                 (Task 6)
```

Each Go module is independent (own `go.mod`) — they share no Go code. The two Connect YAMLs are mounted into the same image with different `command` args.

---

## Task 1: Scaffold lab dir, .env.example, .gitignore

**Files:**
- Create: `labs/redis-multiregion-via-connect/.env.example`
- Create: `labs/redis-multiregion-via-connect/.gitignore`

- [ ] **Step 1: Confirm RESEARCH.md is in place**

```bash
test -f labs/redis-multiregion-via-connect/RESEARCH.md && echo "ok"
```
Expected: `ok`

- [ ] **Step 2: Create `.env.example`**

```bash
# labs/redis-multiregion-via-connect/.env.example
# Writer
WRITE_INTERVAL_MS=1000

# Smoke-test tuning (host shell, NOT compose)
WAIT_FOR_FILL_S=12
PROBE_BUDGET_MS=3000
SETTLE_BUDGET_MS=5000
```

- [ ] **Step 3: Create `.gitignore`**

```
# editor / OS
*.swp
.DS_Store

# build artifacts (none expected to land in tree, but be defensive)
/writer/writer
/dashboard/dashboard
```

(`go.sum` is **not** gitignored — it must be committed.)

- [ ] **Step 4: Commit**

```bash
git add labs/redis-multiregion-via-connect/.env.example labs/redis-multiregion-via-connect/.gitignore labs/redis-multiregion-via-connect/RESEARCH.md
git commit -m "redis-multiregion-via-connect: scaffold lab dir and research doc"
```

---

## Task 2: docker-compose.yml

**Files:**
- Create: `labs/redis-multiregion-via-connect/docker-compose.yml`

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
name: redis-multiregion-via-connect

services:
  redis-central:
    image: redis:7.4-alpine
    container_name: rmvc-redis-central
    command:
      - "redis-server"
      - "--notify-keyspace-events"
      - "KEA"
      - "--appendonly"
      - "no"
      - "--save"
      - ""
    ports:
      - "15379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rmvc]

  redis-region:
    image: redis:7.4-alpine
    container_name: rmvc-redis-region
    command:
      - "redis-server"
      - "--notify-keyspace-events"
      - "KEA"
      - "--appendonly"
      - "no"
      - "--save"
      - ""
    ports:
      - "15380:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rmvc]

  nats:
    image: nats:2.10-alpine
    container_name: rmvc-nats
    command: ["-js", "-sd", "/data", "-m", "8222"]
    ports:
      - "15222:4222"
      - "18222:8222"
    volumes:
      - nats-data:/data
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8222/healthz"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rmvc]

  nats-init:
    image: natsio/nats-box:0.14.5
    container_name: rmvc-nats-init
    depends_on:
      nats: { condition: service_healthy }
    restart: "no"
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        if nats --server nats://nats:4222 stream info APP_EVENTS >/dev/null 2>&1; then
          echo "APP_EVENTS already exists"
        else
          nats --server nats://nats:4222 stream add APP_EVENTS \
            --subjects 'app.events.>' \
            --storage file \
            --replicas 1 \
            --retention limits \
            --discard old \
            --max-age 1h \
            --max-bytes=-1 \
            --max-msgs=-1 \
            --max-msg-size=1MB \
            --dupe-window 5m \
            --defaults
        fi
        nats --server nats://nats:4222 stream info APP_EVENTS
    networks: [rmvc]

  connect-forward:
    image: docker.redpanda.com/redpandadata/connect:4.45.1
    container_name: rmvc-connect-forward
    depends_on:
      redis-central: { condition: service_healthy }
      nats-init: { condition: service_completed_successfully }
    volumes:
      - ./connect/forward.yaml:/connect.yaml:ro
    command: ["run", "/connect.yaml"]
    ports:
      - "15195:4195"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4195/ready"]
      interval: 2s
      timeout: 2s
      retries: 30
    networks: [rmvc]

  connect-reverse:
    image: docker.redpanda.com/redpandadata/connect:4.45.1
    container_name: rmvc-connect-reverse
    depends_on:
      redis-region: { condition: service_healthy }
      nats-init: { condition: service_completed_successfully }
    volumes:
      - ./connect/reverse.yaml:/connect.yaml:ro
    command: ["run", "/connect.yaml"]
    ports:
      - "15196:4195"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4195/ready"]
      interval: 2s
      timeout: 2s
      retries: 30
    networks: [rmvc]

  writer:
    build: ./writer
    container_name: rmvc-writer
    depends_on:
      redis-central: { condition: service_healthy }
      connect-forward: { condition: service_healthy }
    environment:
      REDIS_ADDR: redis-central:6379
      STREAM_KEY: app.events
      WRITE_INTERVAL_MS: "1000"
      HEALTH_ADDR: ":8081"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8081/healthz"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rmvc]

  dashboard:
    build: ./dashboard
    container_name: rmvc-dashboard
    depends_on:
      redis-central: { condition: service_healthy }
      redis-region: { condition: service_healthy }
      connect-reverse: { condition: service_healthy }
    environment:
      CENTRAL_ADDR: redis-central:6379
      REGION_ADDR: redis-region:6379
      LISTEN_ADDR: ":8080"
    ports:
      - "15080:8080"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8080/healthz"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rmvc]

networks:
  rmvc:
    name: rmvc-net

volumes:
  nats-data:
```

- [ ] **Step 2: Sanity-check the compose file parses**

Run:
```bash
cd labs/redis-multiregion-via-connect && docker compose config -q
```
Expected: exits 0, prints nothing. (`writer` and `dashboard` references will work even though their Dockerfiles don't exist yet — `compose config` does not build.)

- [ ] **Step 3: Commit**

```bash
git add labs/redis-multiregion-via-connect/docker-compose.yml
git commit -m "redis-multiregion-via-connect: docker-compose with pinned images, healthchecks, ports >=15000"
```

---

## Task 3: Redpanda Connect configs

**Files:**
- Create: `labs/redis-multiregion-via-connect/connect/forward.yaml`
- Create: `labs/redis-multiregion-via-connect/connect/reverse.yaml`

- [ ] **Step 1: Write `connect/forward.yaml`**

```yaml
# Reads central Redis stream and publishes each entry to NATS JetStream.
# Each XADD entry has fields: event_id, key, value, pattern, t_send_ms.
# body_key=value -> message body is the JSON value string; the rest land as metadata.

http:
  address: 0.0.0.0:4195
  enabled: true

input:
  label: redis_source
  redis_streams:
    url: redis://redis-central:6379
    kind: simple
    streams: [app.events]
    consumer_group: propagator
    client_id: ${HOSTNAME:rpconnect-forward}
    body_key: value
    create_streams: true
    start_from_oldest: false
    commit_period: 200ms
    timeout: 500ms
    limit: 50
    auto_replay_nacks: true

pipeline:
  threads: 2
  processors:
    # Re-wrap the message as a JSON envelope so the reverse leg has key + value
    # without depending on NATS header passthrough behavior.
    - mapping: |
        let original_value = content().string()
        root = {
          "key":        meta("key").or("unknown"),
          "value":      $original_value,
          "event_id":   meta("event_id").or("unknown"),
          "pattern":    meta("pattern").or("unknown"),
          "t_send_ms":  meta("t_send_ms").or("0").number()
        }
        meta event_id = meta("event_id").or($original_value.hash("sha256").encode("hex"))
        meta pattern  = meta("pattern").or("unknown")

output:
  label: jetstream_sink
  nats_jetstream:
    urls: [nats://nats:4222]
    subject: app.events.${! meta("pattern") }
    headers:
      Nats-Msg-Id: ${! meta("event_id") }
      Content-Type: application/json
    max_in_flight: 256

logger:
  level: INFO
  format: json
  add_timestamp: true
```

- [ ] **Step 2: Write `connect/reverse.yaml`**

```yaml
# Consumes JetStream APP_EVENTS, extracts {key, value} from the JSON envelope,
# and SETs the value into region Redis.

http:
  address: 0.0.0.0:4195
  enabled: true

input:
  label: jetstream_source
  nats_jetstream:
    urls: [nats://nats:4222]
    subject: app.events.>
    durable: region-writer
    deliver: all
    ack_wait: 30s

pipeline:
  threads: 2
  processors:
    - mapping: |
        # Extract the inner value string; surface key as metadata.
        meta key = this.key
        root = this.value

output:
  label: redis_sink
  redis:
    url: redis://redis-region:6379
    command: set
    args_mapping: |
      root = [ meta("key"), content().string() ]
    max_in_flight: 64

logger:
  level: INFO
  format: json
  add_timestamp: true
```

- [ ] **Step 3: Validate YAML syntax**

```bash
cd labs/redis-multiregion-via-connect
python3 -c "import yaml; yaml.safe_load(open('connect/forward.yaml')); yaml.safe_load(open('connect/reverse.yaml')); print('ok')"
```
Expected: `ok`

- [ ] **Step 4: Commit**

```bash
git add labs/redis-multiregion-via-connect/connect/
git commit -m "redis-multiregion-via-connect: Redpanda Connect forward + reverse configs"
```

---

## Task 4: Writer service

**Files:**
- Create: `labs/redis-multiregion-via-connect/writer/go.mod`
- Create: `labs/redis-multiregion-via-connect/writer/main.go`
- Create: `labs/redis-multiregion-via-connect/writer/Dockerfile`
- Create: `labs/redis-multiregion-via-connect/writer/go.sum` (via `go mod tidy`)

- [ ] **Step 1: Write `writer/go.mod`**

```
module writer

go 1.23

require (
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.7.0
)
```

- [ ] **Step 2: Write `writer/main.go`**

```go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

type keyDef struct {
	Pattern string
	Key     string
}

var keys = []keyDef{
	{"company", "lb:company:employees:id:55688"},
	{"company", "lb:company:employees:id:55689"},
	{"company", "lb:company:employees:id:55690"},
	{"functions", "lb:functions:groups:id:89889"},
	{"functions", "lb:functions:groups:id:89890"},
	{"functions", "lb:functions:groups:id:89891"},
	{"general", "lb:general:items:id:9123"},
	{"general", "lb:general:items:id:9124"},
	{"general", "lb:general:items:id:9125"},
}

type valuePayload struct {
	V       int    `json:"v"`
	EventID string `json:"event_id"`
	TSendMs int64  `json:"t_send_ms"`
}

func main() {
	addr := getenv("REDIS_ADDR", "redis-central:6379")
	streamKey := getenv("STREAM_KEY", "app.events")
	intervalMs, err := strconv.Atoi(getenv("WRITE_INTERVAL_MS", "1000"))
	if err != nil || intervalMs <= 0 {
		log.Fatalf("invalid WRITE_INTERVAL_MS")
	}
	healthAddr := getenv("HEALTH_ADDR", ":8081")

	rdb := redis.NewClient(&redis.Options{Addr: addr})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Wait for Redis up to 30s.
	for i := 0; i < 30; i++ {
		if err := rdb.Ping(ctx).Err(); err == nil {
			break
		}
		time.Sleep(time.Second)
	}

	var ready atomic.Bool
	ready.Store(true)

	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
			if ready.Load() {
				w.WriteHeader(200)
				_, _ = w.Write([]byte("ok"))
				return
			}
			w.WriteHeader(500)
		})
		log.Printf("health listening on %s", healthAddr)
		if err := http.ListenAndServe(healthAddr, mux); err != nil {
			log.Printf("health server stopped: %v", err)
		}
	}()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sigs; cancel() }()

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	tick := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
	defer tick.Stop()

	log.Printf("writer started: addr=%s stream=%s interval=%dms keys=%d", addr, streamKey, intervalMs, len(keys))

	idx := 0
	for {
		select {
		case <-ctx.Done():
			ready.Store(false)
			log.Printf("shutting down")
			return
		case <-tick.C:
			k := keys[idx%len(keys)]
			idx++
			evID := uuid.NewString()
			nowMs := time.Now().UnixMilli()
			payload := valuePayload{V: rng.Intn(1_000_000), EventID: evID, TSendMs: nowMs}
			body, _ := json.Marshal(payload)

			pipe := rdb.TxPipeline()
			pipe.Set(ctx, k.Key, string(body), 0)
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: streamKey,
				Values: map[string]interface{}{
					"event_id":  evID,
					"key":       k.Key,
					"value":     string(body),
					"pattern":   k.Pattern,
					"t_send_ms": fmt.Sprintf("%d", nowMs),
				},
			})
			if _, err := pipe.Exec(ctx); err != nil {
				log.Printf("write error key=%s err=%v", k.Key, err)
				continue
			}
			log.Printf("wrote key=%s pattern=%s event_id=%s t_send_ms=%d", k.Key, k.Pattern, evID, nowMs)
		}
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
```

- [ ] **Step 3: Write `writer/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7

FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/writer .

FROM alpine:3.20
RUN apk add --no-cache wget ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/writer /usr/local/bin/writer
ENTRYPOINT ["/usr/local/bin/writer"]
```

- [ ] **Step 4: Generate `go.sum`**

```bash
cd labs/redis-multiregion-via-connect/writer
docker run --rm -v "$PWD":/src -w /src golang:1.23-alpine sh -c "go mod tidy"
```
Expected: produces `go.sum`, exits 0. (Running in a container avoids depending on a host Go toolchain.)

- [ ] **Step 5: Build the image to verify**

```bash
cd labs/redis-multiregion-via-connect
docker compose build writer
```
Expected: build succeeds, ends with `Successfully tagged ...` or equivalent.

- [ ] **Step 6: Commit**

```bash
git add labs/redis-multiregion-via-connect/writer/
git commit -m "redis-multiregion-via-connect: Go writer with MULTI SET+XADD"
```

---

## Task 5: Dashboard service

**Files:**
- Create: `labs/redis-multiregion-via-connect/dashboard/go.mod`
- Create: `labs/redis-multiregion-via-connect/dashboard/main.go`
- Create: `labs/redis-multiregion-via-connect/dashboard/static/index.html`
- Create: `labs/redis-multiregion-via-connect/dashboard/Dockerfile`
- Create: `labs/redis-multiregion-via-connect/dashboard/go.sum`

- [ ] **Step 1: Write `dashboard/go.mod`**

```
module dashboard

go 1.23

require (
	github.com/gorilla/websocket v1.5.3
	github.com/redis/go-redis/v9 v9.7.0
)
```

- [ ] **Step 2: Write `dashboard/main.go`**

```go
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"
)

//go:embed static/index.html
var indexHTML []byte

type event struct {
	Type    string `json:"type"`
	Side    string `json:"side"`
	Key     string `json:"key"`
	Value   string `json:"value"`
	TSendMs int64  `json:"t_send_ms"`
	NowMs   int64  `json:"now_ms"`
	DeltaMs int64  `json:"delta_ms"`
}

type hub struct {
	mu      sync.Mutex
	clients map[*websocket.Conn]struct{}
}

func newHub() *hub { return &hub{clients: map[*websocket.Conn]struct{}{}} }

func (h *hub) add(c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[c] = struct{}{}
}

func (h *hub) remove(c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[c]; ok {
		delete(h.clients, c)
		_ = c.Close()
	}
}

func (h *hub) broadcast(msg []byte) {
	h.mu.Lock()
	conns := make([]*websocket.Conn, 0, len(h.clients))
	for c := range h.clients {
		conns = append(conns, c)
	}
	h.mu.Unlock()
	for _, c := range conns {
		_ = c.SetWriteDeadline(time.Now().Add(2 * time.Second))
		if err := c.WriteMessage(websocket.TextMessage, msg); err != nil {
			h.remove(c)
		}
	}
}

func main() {
	centralAddr := getenv("CENTRAL_ADDR", "redis-central:6379")
	regionAddr := getenv("REGION_ADDR", "redis-region:6379")
	listen := getenv("LISTEN_ADDR", ":8080")

	central := redis.NewClient(&redis.Options{Addr: centralAddr})
	region := redis.NewClient(&redis.Options{Addr: regionAddr})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	for _, c := range []*redis.Client{central, region} {
		for i := 0; i < 30; i++ {
			if err := c.Ping(ctx).Err(); err == nil {
				break
			}
			time.Sleep(time.Second)
		}
		if err := c.ConfigSet(ctx, "notify-keyspace-events", "KEA").Err(); err != nil {
			log.Printf("config set notify-keyspace-events failed (continuing): %v", err)
		}
	}

	h := newHub()
	go subscribeKeyspace(ctx, central, "central", h)
	go subscribeKeyspace(ctx, region, "region", h)

	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		h.add(c)
		go func() {
			defer h.remove(c)
			for {
				if _, _, err := c.ReadMessage(); err != nil {
					return
				}
			}
		}()
	})

	srv := &http.Server{Addr: listen, Handler: mux}
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancelShutdown()
		_ = srv.Shutdown(shutdownCtx)
		cancel()
	}()

	log.Printf("dashboard listening on %s", listen)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func subscribeKeyspace(ctx context.Context, c *redis.Client, side string, h *hub) {
	const prefix = "__keyspace@0__:"
	sub := c.PSubscribe(ctx, prefix+"lb:*")
	defer func() { _ = sub.Close() }()
	ch := sub.Channel()
	log.Printf("subscribed keyspace events side=%s", side)
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			if msg.Payload != "set" {
				continue
			}
			if !strings.HasPrefix(msg.Channel, prefix) {
				continue
			}
			key := msg.Channel[len(prefix):]
			val, err := c.Get(ctx, key).Result()
			if err != nil {
				continue
			}
			var p struct {
				V       int    `json:"v"`
				TSendMs int64  `json:"t_send_ms"`
				EventID string `json:"event_id"`
			}
			_ = json.Unmarshal([]byte(val), &p)
			now := time.Now().UnixMilli()
			delta := now - p.TSendMs
			if delta < 0 {
				delta = 0
			}
			e := event{
				Type: "event", Side: side, Key: key, Value: val,
				TSendMs: p.TSendMs, NowMs: now, DeltaMs: delta,
			}
			b, _ := json.Marshal(e)
			h.broadcast(b)
		}
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
```

- [ ] **Step 3: Write `dashboard/static/index.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Redis Multiregion via Connect — Live</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         margin: 14px; background: #0e1117; color: #e6e6e6; }
  h1 { font-size: 16px; margin: 0 0 12px; color: #fff; }
  h2 { font-size: 13px; color: #b8c2cc; margin: 16px 0 6px; font-weight: 500; }
  table { border-collapse: collapse; width: 100%; font-size: 12px; }
  th, td { border-bottom: 1px solid #2a2f3a; padding: 4px 8px; text-align: left; }
  th { background: #161b22; color: #b8c2cc; font-weight: 500; }
  .stats { display: flex; gap: 12px; flex-wrap: wrap; }
  .card { background: #161b22; padding: 8px 12px; border-radius: 6px; min-width: 240px; }
  .card .name { font-size: 11px; color: #b8c2cc; text-transform: uppercase; letter-spacing: 0.04em; }
  .card .row { display: flex; gap: 14px; margin-top: 6px; }
  .card .metric { font-size: 14px; }
  .card .metric .label { color: #8b95a3; font-size: 10px; display: block; }
  .lat { font-weight: 600; }
  .lat.ok { color: #7ee787; } .lat.warn { color: #d29922; } .lat.bad { color: #f85149; }
  .side-central { color: #79c0ff; } .side-region { color: #d2a8ff; }
  #status { font-size: 11px; color: #8b95a3; margin-bottom: 8px; }
  #log-wrap { max-height: 48vh; overflow-y: auto; border: 1px solid #2a2f3a; border-radius: 6px; }
  code { background: #161b22; padding: 1px 4px; border-radius: 3px; font-size: 11px; }
</style>
</head>
<body>
<h1>Redis Multiregion via Connect — propagation delay</h1>
<div id="status">connecting…</div>

<h2>Per-pattern latency (region-side observations)</h2>
<div class="stats" id="stats"></div>

<h2>Live event stream</h2>
<div id="log-wrap">
  <table>
    <thead><tr><th>time</th><th>side</th><th>key</th><th>v</th><th>delta_ms</th></tr></thead>
    <tbody id="rows"></tbody>
  </table>
</div>

<h2>Latest value per key (central vs region)</h2>
<table>
  <thead><tr><th>key</th><th>central <code>v</code></th><th>region <code>v</code></th><th>last region delta_ms</th></tr></thead>
  <tbody id="ground-rows"></tbody>
</table>

<script>
const rows = document.getElementById("rows");
const groundRows = document.getElementById("ground-rows");
const stats = document.getElementById("stats");
const status = document.getElementById("status");

const latestByKey = {};
const samplesByPattern = {};

function patternOf(key) {
  if (key.startsWith("lb:company:")) return "company";
  if (key.startsWith("lb:functions:")) return "functions";
  if (key.startsWith("lb:general:")) return "general";
  return "other";
}

function percentile(arr, p) {
  if (!arr.length) return null;
  const s = [...arr].sort((a,b)=>a-b);
  return s[Math.min(s.length-1, Math.floor(s.length * p))];
}

function renderStats() {
  const html = [];
  for (const pat of ["company","functions","general"]) {
    const arr = samplesByPattern[pat] || [];
    const p50 = percentile(arr, 0.5);
    const p95 = percentile(arr, 0.95);
    const last = arr.length ? arr[arr.length-1] : null;
    html.push(`<div class="card">
      <div class="name">${pat}</div>
      <div class="row">
        <div class="metric"><span class="label">count</span>${arr.length}</div>
        <div class="metric"><span class="label">last</span>${last ?? "—"} ms</div>
        <div class="metric"><span class="label">p50</span>${p50 ?? "—"} ms</div>
        <div class="metric"><span class="label">p95</span>${p95 ?? "—"} ms</div>
      </div>
    </div>`);
  }
  stats.innerHTML = html.join("");
}

function renderGround() {
  const html = [];
  const keys = Object.keys(latestByKey).sort();
  for (const k of keys) {
    const r = latestByKey[k];
    html.push(`<tr><td>${k}</td><td class="side-central">${r.central?.v ?? "—"}</td><td class="side-region">${r.region?.v ?? "—"}</td><td>${r.lastDelta ?? "—"}</td></tr>`);
  }
  groundRows.innerHTML = html.join("");
}

function classifyLat(d) { if (d < 200) return "ok"; if (d < 1000) return "warn"; return "bad"; }

function append(e) {
  let v = "—";
  try { v = JSON.parse(e.value).v; } catch {}
  const ts = new Date(e.now_ms).toISOString().split("T")[1].replace("Z","");
  const cls = classifyLat(e.delta_ms);
  const tr = document.createElement("tr");
  tr.innerHTML = `<td>${ts}</td><td class="side-${e.side}">${e.side}</td><td>${e.key}</td><td>${v}</td><td class="lat ${cls}">${e.delta_ms}</td>`;
  rows.prepend(tr);
  while (rows.childElementCount > 100) rows.removeChild(rows.lastChild);

  if (!latestByKey[e.key]) latestByKey[e.key] = {};
  latestByKey[e.key][e.side] = { v };
  if (e.side === "region") {
    latestByKey[e.key].lastDelta = e.delta_ms;
    const pat = patternOf(e.key);
    if (!samplesByPattern[pat]) samplesByPattern[pat] = [];
    samplesByPattern[pat].push(e.delta_ms);
    if (samplesByPattern[pat].length > 200) samplesByPattern[pat].shift();
  }
  renderStats();
  renderGround();
}

let ws;
function connect() {
  ws = new WebSocket((location.protocol === "https:" ? "wss" : "ws") + "://" + location.host + "/ws");
  ws.onopen = () => { status.textContent = "live · " + new Date().toISOString(); };
  ws.onclose = () => { status.textContent = "disconnected, retrying…"; setTimeout(connect, 1500); };
  ws.onmessage = (m) => {
    try {
      const e = JSON.parse(m.data);
      if (e.type === "event") append(e);
    } catch {}
  };
}
connect();
renderStats();
renderGround();
</script>
</body>
</html>
```

- [ ] **Step 4: Write `dashboard/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7

FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/dashboard .

FROM alpine:3.20
RUN apk add --no-cache wget ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/dashboard /usr/local/bin/dashboard
ENTRYPOINT ["/usr/local/bin/dashboard"]
```

- [ ] **Step 5: Generate `go.sum`**

```bash
cd labs/redis-multiregion-via-connect/dashboard
docker run --rm -v "$PWD":/src -w /src golang:1.23-alpine sh -c "go mod tidy"
```
Expected: produces `go.sum`, exits 0.

- [ ] **Step 6: Build the image to verify**

```bash
cd labs/redis-multiregion-via-connect
docker compose build dashboard
```
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add labs/redis-multiregion-via-connect/dashboard/
git commit -m "redis-multiregion-via-connect: Go dashboard with keyspace-event WebSocket UI"
```

---

## Task 6: Smoke test

**Files:**
- Create: `labs/redis-multiregion-via-connect/scripts/smoke-test.sh`

The smoke test asserts the *property* (propagation), not just that containers started.

- [ ] **Step 1: Write `scripts/smoke-test.sh`**

```bash
#!/usr/bin/env bash
# Asserts: every produced KV write reaches region within budget.
#   1) wait for writer to populate all 9 keys in central
#   2) check region eventually has all 9
#   3) inject probe writes per pattern, measure SET-to-SET propagation
set -euo pipefail

REDIS_CENTRAL_PORT="${REDIS_CENTRAL_PORT:-15379}"
REDIS_REGION_PORT="${REDIS_REGION_PORT:-15380}"
DASHBOARD_PORT="${DASHBOARD_PORT:-15080}"
WAIT_FOR_FILL_S="${WAIT_FOR_FILL_S:-12}"
PROBE_BUDGET_MS="${PROBE_BUDGET_MS:-3000}"
SETTLE_BUDGET_MS="${SETTLE_BUDGET_MS:-5000}"

EXPECTED_KEYS=(
  "lb:company:employees:id:55688"
  "lb:company:employees:id:55689"
  "lb:company:employees:id:55690"
  "lb:functions:groups:id:89889"
  "lb:functions:groups:id:89890"
  "lb:functions:groups:id:89891"
  "lb:general:items:id:9123"
  "lb:general:items:id:9124"
  "lb:general:items:id:9125"
)

PROBES=(
  "lb:company:employees:id:55688|company"
  "lb:functions:groups:id:89889|functions"
  "lb:general:items:id:9123|general"
)

# Use Redis container's redis-cli so the host doesn't need it installed.
redc() {
  local port="$1"; shift
  if command -v redis-cli >/dev/null 2>&1; then
    redis-cli -h 127.0.0.1 -p "$port" "$@"
  else
    docker exec -i rmvc-redis-central redis-cli -p 6379 -h "$(_host_for_port "$port")" "$@"
  fi
}

# Map host port -> internal container
_host_for_port() {
  case "$1" in
    "$REDIS_CENTRAL_PORT") echo "redis-central" ;;
    "$REDIS_REGION_PORT")  echo "redis-region" ;;
    *) echo "127.0.0.1" ;;
  esac
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    # GNU date with %N (busybox 'date' may not have it; this fallback is best-effort)
    local s n
    s=$(date +%s)
    n=$(date +%N 2>/dev/null || echo "000000000")
    printf '%d%03d\n' "$s" "$((10#${n:0:3}))"
  fi
}

fail() { echo "FAIL: $*"; exit 1; }

echo "[1/5] waiting ${WAIT_FOR_FILL_S}s for writer to populate keys..."
sleep "$WAIT_FOR_FILL_S"

echo "[2/5] dashboard /healthz"
curl -sf "http://127.0.0.1:${DASHBOARD_PORT}/healthz" >/dev/null || fail "dashboard /healthz not 2xx"
echo "  ok"

echo "[3/5] all 9 keys present in central"
for k in "${EXPECTED_KEYS[@]}"; do
  v=$(redc "$REDIS_CENTRAL_PORT" GET "$k" || true)
  [ -n "$v" ] || fail "central missing $k after fill window"
done
echo "  ok"

echo "[4/5] all 9 keys eventually present in region (budget ${SETTLE_BUDGET_MS}ms)"
deadline=$(( $(now_ms) + SETTLE_BUDGET_MS ))
missing=()
while [ "$(now_ms)" -lt "$deadline" ]; do
  missing=()
  for k in "${EXPECTED_KEYS[@]}"; do
    v=$(redc "$REDIS_REGION_PORT" GET "$k" || true)
    [ -n "$v" ] || missing+=("$k")
  done
  [ "${#missing[@]}" -eq 0 ] && break
  sleep 0.2
done
[ "${#missing[@]}" -eq 0 ] || fail "region missing after settle: ${missing[*]}"
echo "  ok"

echo "[5/5] probe-write propagation per pattern (budget ${PROBE_BUDGET_MS}ms each)"
for entry in "${PROBES[@]}"; do
  key="${entry%|*}"
  pattern="${entry#*|}"
  probe_id="smoke-$(date +%s%N)-$RANDOM"
  t_send=$(now_ms)
  value="{\"v\":-1,\"event_id\":\"$probe_id\",\"t_send_ms\":$t_send}"
  redc "$REDIS_CENTRAL_PORT" SET "$key" "$value" >/dev/null
  redc "$REDIS_CENTRAL_PORT" XADD app.events '*' \
    event_id "$probe_id" \
    key "$key" \
    value "$value" \
    pattern "$pattern" \
    t_send_ms "$t_send" >/dev/null

  deadline=$(( t_send + PROBE_BUDGET_MS ))
  arrived=0
  while [ "$(now_ms)" -lt "$deadline" ]; do
    v=$(redc "$REDIS_REGION_PORT" GET "$key" || true)
    if [ -n "$v" ] && [[ "$v" == *"$probe_id"* ]]; then
      arrival=$(now_ms)
      echo "  probe pattern=$pattern key=$key delta=$((arrival - t_send))ms"
      arrived=1
      break
    fi
    sleep 0.02
  done
  [ "$arrived" -eq 1 ] || fail "probe $probe_id did not propagate within ${PROBE_BUDGET_MS}ms"
done

echo
echo "PROPERTY DEMONSTRATED:"
echo "  - 9/9 KV keys propagate central -> region."
echo "  - Per-pattern probe SET-to-SET propagation < ${PROBE_BUDGET_MS}ms."
echo "  - Dashboard live at http://127.0.0.1:${DASHBOARD_PORT}/"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x labs/redis-multiregion-via-connect/scripts/smoke-test.sh
```

- [ ] **Step 3: Lint with `bash -n` and `shellcheck` if available**

```bash
bash -n labs/redis-multiregion-via-connect/scripts/smoke-test.sh
command -v shellcheck >/dev/null && shellcheck labs/redis-multiregion-via-connect/scripts/smoke-test.sh || echo "(shellcheck unavailable, skipping)"
```
Expected: `bash -n` exits 0; shellcheck either runs cleanly or is skipped.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-multiregion-via-connect/scripts/smoke-test.sh
git commit -m "redis-multiregion-via-connect: smoke test asserts propagation property"
```

---

## Task 7: README.md

**Files:**
- Create: `labs/redis-multiregion-via-connect/README.md`

- [ ] **Step 1: Write `README.md`**

````markdown
# Redis Multiregion via Redpanda Connect

End-to-end demo: KV writes on a "central" Redis are propagated to a "region"
Redis through a **Redpanda Connect → NATS JetStream → Redpanda Connect** bridge.
A Go writer drives the central side; a live web dashboard shows per-key state
on both sides and measures SET-to-SET propagation delay.

See [`RESEARCH.md`](RESEARCH.md) for design and references.

## Architecture

```
writer (Go) ──MULTI: SET+XADD──▶ redis-central
                                        │
                          redis_streams │  body_key=value, group=propagator
                                        ▼
                                 connect-forward ──nats_jetstream──▶ NATS APP_EVENTS
                                                                        │
                                                                  subject app.events.>
                                                                  Nats-Msg-Id dedup
                                                                        ▼
                                                                 connect-reverse
                                                                        │
                                                                redis: SET key value
                                                                        ▼
                                                                  redis-region
                                                                        │
        dashboard (Go) ◀── PSUBSCRIBE __keyspace@0__:lb:* on BOTH redises
                          (computes delta_ms = now() − t_send_ms)
```

## Run

```bash
cd labs/redis-multiregion-via-connect
docker compose up -d --build
```

Then open <http://127.0.0.1:15080/>.

The writer cycles through 9 keys (3 patterns × 3 keys each) at 1 Hz. You should
see central-side entries appear immediately and region-side entries follow a
few hundred ms later.

## Smoke test

```bash
bash scripts/smoke-test.sh
```

Asserts the *property*: all 9 keys propagate to region, plus three probe writes
land within `PROBE_BUDGET_MS` (default 3000 ms).

## Tear down

```bash
docker compose down -v
```

## Ports (host)

| Service           | Host port | Notes                              |
|-------------------|-----------|------------------------------------|
| dashboard (HTTP)  | 15080     | live UI + WebSocket `/ws`          |
| redis-central     | 15379     | `redis-cli -p 15379`               |
| redis-region      | 15380     | `redis-cli -p 15380`               |
| nats              | 15222     | NATS client                        |
| nats monitoring   | 18222     | `/healthz`, `/varz`                |
| connect-forward   | 15195     | `/ready`, `/metrics`               |
| connect-reverse   | 15196     | `/ready`, `/metrics`               |

## Useful checks

```bash
# Central stream + group state
redis-cli -p 15379 XLEN app.events
redis-cli -p 15379 XINFO GROUPS app.events

# JetStream
docker exec rmvc-nats nats stream info APP_EVENTS

# Connect health
curl -s http://localhost:15195/ready
curl -s http://localhost:15196/ready

# Compare central vs region for one key
redis-cli -p 15379 GET lb:company:employees:id:55688
redis-cli -p 15380 GET lb:company:employees:id:55688
```

## Configuration knobs

| Env / setting               | Where                           | Default | Effect                                  |
|-----------------------------|---------------------------------|---------|-----------------------------------------|
| `WRITE_INTERVAL_MS`         | `writer` env                    | 1000    | writer tick period                      |
| `WAIT_FOR_FILL_S`           | `scripts/smoke-test.sh` env     | 12      | wait before checking writer output      |
| `PROBE_BUDGET_MS`           | `scripts/smoke-test.sh` env     | 3000    | per-probe propagation budget            |
| `--dupe-window 5m`          | `nats-init` command             | 5m      | JetStream dedup horizon                 |
| `commit_period: 200ms`      | `connect/forward.yaml`          | 200ms   | XACK flush cadence on central stream    |
| `max_in_flight: 256`        | `connect/forward.yaml`          | 256     | async JetStream publish parallelism     |
````

- [ ] **Step 2: Commit**

```bash
git add labs/redis-multiregion-via-connect/README.md
git commit -m "redis-multiregion-via-connect: README with run + tear-down + ports"
```

---

## Task 8: Validate end-to-end and iterate

**Files:**
- None — this is the validation gate.

- [ ] **Step 1: Run the lab validator**

```bash
bash /home/hp/.claude/skills/research-lab/scripts/validate_lab.sh labs/redis-multiregion-via-connect
```
Expected: exit 0. The validator runs `docker compose up`, checks healthchecks, then runs the smoke test.

- [ ] **Step 2: If validation fails, diagnose without masking**

Triage in this order (do **not** weaken healthchecks, lengthen timeouts beyond the listed budgets, or remove smoke assertions):

```bash
cd labs/redis-multiregion-via-connect
docker compose ps
docker compose logs --tail=200 connect-forward
docker compose logs --tail=200 connect-reverse
docker compose logs --tail=200 writer
docker compose logs --tail=200 dashboard
docker exec rmvc-redis-central redis-cli XLEN app.events
docker exec rmvc-redis-central redis-cli XINFO GROUPS app.events
docker exec rmvc-nats nats stream info APP_EVENTS
docker exec rmvc-nats nats consumer info APP_EVENTS region-writer 2>/dev/null || true
```

Common root causes (and the *real* fix, not a workaround):

| Symptom                                                          | Likely cause                                                 | Fix                                                                                 |
|------------------------------------------------------------------|--------------------------------------------------------------|-------------------------------------------------------------------------------------|
| `connect-reverse` logs `meta("key") was null` or empty SETs      | reverse mapping reading from wrong field                     | recheck `pipeline.processors.mapping` in `connect/reverse.yaml`                     |
| Region keys never appear                                         | JetStream subject mismatch                                   | confirm `subject: app.events.${! meta("pattern") }` and stream filter `app.events.>`|
| `nats-init` exits non-zero                                       | older nats CLI rejects a flag                                | run `docker exec rmvc-nats nats stream add --help` and align flags                  |
| Writer can't connect to Redis                                    | wrong service name / port                                    | confirm `REDIS_ADDR=redis-central:6379` (not `redis:6379`)                          |
| Dashboard shows central events but no region events              | reverse leg failing silently                                 | `curl http://localhost:15196/ready` and `docker compose logs connect-reverse`       |
| Healthcheck flaps for `connect-*`                                | `/ready` not exposed                                         | confirm `http.address: 0.0.0.0:4195` and `enabled: true` in both YAMLs              |

- [ ] **Step 3: After three failed attempts on the same root cause, escalate**

Invoke `superpowers:systematic-debugging` — do not keep trying ad-hoc fixes.

- [ ] **Step 4: When `validate_lab.sh` exits 0, tear down cleanly**

```bash
cd labs/redis-multiregion-via-connect
docker compose down -v
docker ps -a --filter "name=rmvc-" --format "{{.Names}}" | xargs -r docker rm -f
docker volume ls --filter "name=redis-multiregion-via-connect" --format "{{.Name}}" | xargs -r docker volume rm
```

- [ ] **Step 5: Final commit (if any fixes were made)**

```bash
git status
# If any iteration changes are uncommitted:
git add labs/redis-multiregion-via-connect/
git commit -m "redis-multiregion-via-connect: iteration fixes to pass validate_lab.sh"
```

---

## Self-review

**Spec coverage** (against `labs/redis-multiregion-via-connect/RESEARCH.md`):

| RESEARCH.md item                                                            | Implemented in                            |
|-----------------------------------------------------------------------------|-------------------------------------------|
| Property: SET-to-SET propagation with bounded delay                         | Task 6 smoke test + Task 5 dashboard      |
| Atomic `MULTI/SET/XADD/EXEC` on central                                     | Task 4 `writer/main.go`                   |
| 9 keys × 3 patterns                                                         | Task 4 `keys` table                       |
| `redis_streams` input → `nats_jetstream` output with `Nats-Msg-Id`          | Task 3 `connect/forward.yaml`             |
| `nats_jetstream` input → `redis` output `set`                               | Task 3 `connect/reverse.yaml`             |
| `duplicate_window=5m`                                                       | Task 2 `nats-init` command                |
| Dashboard `PSUBSCRIBE __keyspace@0__:lb:*` both Redises                     | Task 5 `subscribeKeyspace`                |
| `notify-keyspace-events KEA` on both Redises                                | Task 2 redis command args + Task 5 init   |
| All host ports ≥ 15000                                                      | Task 2 `ports` mappings                   |
| Healthchecks on every long-running service                                  | Task 2 every service block                |
| `depends_on: condition: service_healthy` / `service_completed_successfully` | Task 2 every consumer service             |
| No `:latest` image tags                                                     | Task 2 all `image:` lines pinned          |
| Smoke test asserts the *property*, not just liveness                        | Task 6 probe-write propagation block      |

**Placeholder scan:** none — every code block contains complete code.

**Type consistency:**
- Writer XADD field names: `event_id, key, value, pattern, t_send_ms` — match `body_key: value` and forward-pipeline `meta()` lookups.
- Forward pipeline JSON envelope keys: `key, value, event_id, pattern, t_send_ms` — match reverse pipeline `this.key` / `this.value`.
- Dashboard `valuePayload` struct uses `v / event_id / t_send_ms` — matches the JSON the writer marshals.
- Probe writes in smoke test use the *same* field names and JSON shape as the writer.

No issues found.

---

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-14-redis-multiregion-via-connect.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch with checkpoints.

**Which approach?**
