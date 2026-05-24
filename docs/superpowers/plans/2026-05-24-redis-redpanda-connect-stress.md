# redis-redpanda-connect-stress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained Docker Compose lab under `labs/redis-redpanda-connect-stress/` that stress-tests the Redis→Redpanda Connect→NATS JetStream→Redpanda Connect→Redis pipeline at 10 / 1 000 / 10 000 msg/s tiers across three modes (throughput, latency, chaos), with per-container CPU/mem caps so the host stays interactive.

**Architecture:** Fork the existing `labs/redis-redpanda-qos-resilience/` lab. Replace the live WebSocket dashboard with a one-shot `collector` binary; rewrite the writer with a live `POST /rate` HTTP endpoint and a token-bucket limiter; add a bash harness (`scripts/stress-run.sh`) that iterates `tiers × modes`, calls `/rate`, runs the collector, and emits per-tier JSON reports plus a stdout summary table. Connect YAMLs are copied verbatim — the writer matches their expected XADD field layout (`value`, `event_id`, `key`, `pattern`, `t_send_ms`).

**Tech Stack:** Go 1.23, `github.com/redis/go-redis/v9`, `github.com/google/uuid`, `github.com/prometheus/client_golang`, `golang.org/x/time/rate`, `github.com/HdrHistogram/hdrhistogram-go`, Docker Compose v2, Bash, Redpanda Connect 4.92.0, NATS 2.10, Redis 7.4.

**Skill convention:** This plan follows the `research-lab` skill conventions (self-contained `labs/{slug}/` directory with `docker-compose.yml`, `README.md`, `RESEARCH.md`, Go components). The skill is the implementation guidance for *how* the lab should be shaped; the tasks below are the concrete steps.

**Spec reference:** `docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md` (commit `1fda395`).

---

## File map

```
labs/redis-redpanda-connect-stress/
├── README.md                                    # Task 24
├── RESEARCH.md                                  # Task 25
├── docker-compose.yml                           # Task 18
├── .env.example                                 # Task 19
├── .gitignore                                   # Task 1
├── connect/                                     # Task 2 (copy from parent)
│   ├── alo-forward.yaml
│   ├── alo-reverse.yaml
│   ├── amo-forward.yaml
│   ├── amo-reverse.yaml
│   ├── eoe-forward.yaml
│   └── eoe-reverse.yaml
├── writer/
│   ├── Dockerfile                               # Task 3
│   ├── go.mod                                   # Task 3
│   ├── payload.go        + payload_test.go      # Task 4
│   ├── limiter.go        + limiter_test.go      # Task 5
│   ├── counters.go                              # Task 6
│   ├── worker.go                                # Task 6
│   ├── http.go                                  # Task 7
│   └── main.go                                  # Task 8
├── collector/
│   ├── Dockerfile                               # Task 9
│   ├── go.mod                                   # Task 9
│   ├── latency.go        + latency_test.go      # Task 10
│   ├── verdict.go        + verdict_test.go      # Task 11
│   ├── report.go         + report_test.go       # Task 12
│   ├── redis.go                                 # Task 13
│   ├── scrapers.go                              # Task 14
│   ├── nats.go                                  # Task 15
│   ├── snapshot.go                              # Task 16
│   └── main.go                                  # Task 17
├── scripts/
│   ├── stress-run.sh                            # Task 22
│   ├── lib/
│   │   └── tier-defs.sh                         # Task 20
│   └── chaos/
│       └── kill-connect-sink.sh                 # Task 21
└── reports/
    └── .gitkeep                                 # Task 1
```

All Go code lives in `package main` per component (writer is one binary, collector is another). Test files live alongside source.

---

## Task 1: Scaffold lab directory

**Files:**
- Create: `labs/redis-redpanda-connect-stress/.gitignore`
- Create: `labs/redis-redpanda-connect-stress/reports/.gitkeep`
- Create: `labs/redis-redpanda-connect-stress/connect/.gitkeep` (replaced in Task 2)
- Create: `labs/redis-redpanda-connect-stress/scripts/chaos/.gitkeep`
- Create: `labs/redis-redpanda-connect-stress/scripts/lib/.gitkeep`
- Create: `labs/redis-redpanda-connect-stress/writer/.gitkeep`
- Create: `labs/redis-redpanda-connect-stress/collector/.gitkeep`

- [ ] **Step 1: Create directory tree**

Run:
```bash
mkdir -p labs/redis-redpanda-connect-stress/{connect,writer,collector,scripts/lib,scripts/chaos,reports}
touch labs/redis-redpanda-connect-stress/{reports,connect,scripts/chaos,scripts/lib,writer,collector}/.gitkeep
```

- [ ] **Step 2: Write `.gitignore`**

Write `labs/redis-redpanda-connect-stress/.gitignore`:
```
reports/*.json
.env
```

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/
git commit -m "redis-redpanda-connect-stress: scaffold directory layout"
```

Expected: commit succeeds; `git status` clean.

---

## Task 2: Copy connect YAMLs from parent lab

**Files:**
- Create: `labs/redis-redpanda-connect-stress/connect/{alo,amo,eoe}-{forward,reverse}.yaml` (six files copied verbatim)

The parent's YAMLs expect XADD entries with fields `value`, `event_id`, `key`, `pattern`, `t_send_ms`. The stress writer (Tasks 3–8) will match this exactly so the YAMLs work as-is.

- [ ] **Step 1: Copy all six YAMLs**

Run:
```bash
cp labs/redis-redpanda-qos-resilience/connect/{alo,amo,eoe}-forward.yaml \
   labs/redis-redpanda-connect-stress/connect/
cp labs/redis-redpanda-qos-resilience/connect/{alo,amo,eoe}-reverse.yaml \
   labs/redis-redpanda-connect-stress/connect/
rm labs/redis-redpanda-connect-stress/connect/.gitkeep
```

- [ ] **Step 2: Verify byte-identical copy**

Run:
```bash
diff -rq labs/redis-redpanda-qos-resilience/connect/ \
         labs/redis-redpanda-connect-stress/connect/
```

Expected: no output (no diffs).

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/connect/
git commit -m "redis-redpanda-connect-stress: copy connect YAMLs from parent lab"
```

---

## Task 3: Writer — go.mod and Dockerfile

**Files:**
- Create: `labs/redis-redpanda-connect-stress/writer/go.mod`
- Create: `labs/redis-redpanda-connect-stress/writer/Dockerfile`

- [ ] **Step 1: Write `go.mod`**

Write `labs/redis-redpanda-connect-stress/writer/go.mod`:
```
module writer

go 1.23

require (
	github.com/google/uuid v1.6.0
	github.com/redis/go-redis/v9 v9.7.0
	golang.org/x/time v0.7.0
)
```

(go.sum will be generated by `go mod tidy` in Task 8 once all source files exist.)

- [ ] **Step 2: Write `Dockerfile`**

Write `labs/redis-redpanda-connect-stress/writer/Dockerfile`:
```dockerfile
# syntax=docker/dockerfile:1.7
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
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

- [ ] **Step 3: Remove `.gitkeep` and commit**

```bash
rm labs/redis-redpanda-connect-stress/writer/.gitkeep
git add labs/redis-redpanda-connect-stress/writer/
git commit -m "redis-redpanda-connect-stress: writer go.mod and Dockerfile"
```

---

## Task 4: Writer — payload type (TDD)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/writer/payload.go`
- Test:   `labs/redis-redpanda-connect-stress/writer/payload_test.go`

- [ ] **Step 1: Write the failing test**

Write `labs/redis-redpanda-connect-stress/writer/payload_test.go`:
```go
package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestNewPayloadShapeAndFields(t *testing.T) {
	p := NewPayload(42, 200)
	if p.Seq != 42 {
		t.Errorf("Seq=%d, want 42", p.Seq)
	}
	if p.EventID == "" {
		t.Errorf("EventID is empty")
	}
	if p.TsNs == 0 {
		t.Errorf("TsNs is zero")
	}
	if len(p.Pad) != 200 {
		t.Errorf("Pad len=%d, want 200", len(p.Pad))
	}
}

func TestPayloadJSONRoundTrip(t *testing.T) {
	p := NewPayload(7, 50)
	b, err := p.JSON()
	if err != nil {
		t.Fatalf("JSON err: %v", err)
	}
	if !strings.Contains(string(b), `"seq":7`) {
		t.Errorf("missing seq field: %s", b)
	}
	var back Payload
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if back.EventID != p.EventID {
		t.Errorf("EventID mismatch")
	}
	if back.TsNs != p.TsNs {
		t.Errorf("TsNs mismatch")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd labs/redis-redpanda-connect-stress/writer && go test ./...`
Expected: FAIL — `undefined: NewPayload` (or build error).

- [ ] **Step 3: Write minimal implementation**

Write `labs/redis-redpanda-connect-stress/writer/payload.go`:
```go
package main

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Payload struct {
	EventID string `json:"event_id"`
	TsNs    int64  `json:"ts_ns"`
	Seq     int64  `json:"seq"`
	Pad     string `json:"pad"`
}

func NewPayload(seq int64, padBytes int) Payload {
	return Payload{
		EventID: uuid.NewString(),
		TsNs:    time.Now().UnixNano(),
		Seq:     seq,
		Pad:     strings.Repeat("x", padBytes),
	}
}

func (p Payload) JSON() ([]byte, error) {
	return json.Marshal(p)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd labs/redis-redpanda-connect-stress/writer && go mod tidy && go test ./...`
Expected: PASS — `ok  writer ...`

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/writer/payload.go \
        labs/redis-redpanda-connect-stress/writer/payload_test.go \
        labs/redis-redpanda-connect-stress/writer/go.sum
git commit -m "redis-redpanda-connect-stress: writer payload + tests"
```

---

## Task 5: Writer — rate limiter wrapper (TDD)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/writer/limiter.go`
- Test:   `labs/redis-redpanda-connect-stress/writer/limiter_test.go`

The limiter wraps `golang.org/x/time/rate.Limiter` so that the `/rate` HTTP handler can mutate the limit live. Burst is sized to `max(100, rate/10)` so warmup ramps don't starve workers.

- [ ] **Step 1: Write the failing test**

Write `labs/redis-redpanda-connect-stress/writer/limiter_test.go`:
```go
package main

import "testing"

func TestLimiterInitialZero(t *testing.T) {
	l := NewLimiter()
	if got := l.Current(); got != 0 {
		t.Errorf("Current=%d, want 0", got)
	}
}

func TestLimiterSetThenCurrent(t *testing.T) {
	l := NewLimiter()
	l.Set(500)
	if got := l.Current(); got != 500 {
		t.Errorf("Current=%d, want 500", got)
	}
	l.Set(0)
	if got := l.Current(); got != 0 {
		t.Errorf("Current=%d, want 0", got)
	}
}

func TestLimiterBurstScalesWithRate(t *testing.T) {
	l := NewLimiter()
	l.Set(50)
	if l.Burst() != 100 {
		t.Errorf("Burst=%d, want 100 (min floor)", l.Burst())
	}
	l.Set(10000)
	if l.Burst() != 1000 {
		t.Errorf("Burst=%d, want 1000 (rate/10)", l.Burst())
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd labs/redis-redpanda-connect-stress/writer && go test ./...`
Expected: FAIL — `undefined: NewLimiter`.

- [ ] **Step 3: Write minimal implementation**

Write `labs/redis-redpanda-connect-stress/writer/limiter.go`:
```go
package main

import (
	"context"
	"sync/atomic"

	"golang.org/x/time/rate"
)

type Limiter struct {
	r       *rate.Limiter
	current atomic.Int64
	burst   atomic.Int64
}

func NewLimiter() *Limiter {
	l := &Limiter{r: rate.NewLimiter(0, 100)}
	l.burst.Store(100)
	return l
}

func (l *Limiter) Set(rps int) {
	b := 100
	if rps/10 > b {
		b = rps / 10
	}
	l.r.SetLimit(rate.Limit(rps))
	l.r.SetBurst(b)
	l.current.Store(int64(rps))
	l.burst.Store(int64(b))
}

func (l *Limiter) Current() int64 { return l.current.Load() }
func (l *Limiter) Burst() int64   { return l.burst.Load() }

func (l *Limiter) WaitN(ctx context.Context, n int) error {
	return l.r.WaitN(ctx, n)
}
```

- [ ] **Step 4: Run tests**

Run: `cd labs/redis-redpanda-connect-stress/writer && go test ./...`
Expected: PASS — all three tests green.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/writer/limiter.go \
        labs/redis-redpanda-connect-stress/writer/limiter_test.go \
        labs/redis-redpanda-connect-stress/writer/go.sum
git commit -m "redis-redpanda-connect-stress: writer rate limiter + tests"
```

---

## Task 6: Writer — counters + worker pool

**Files:**
- Create: `labs/redis-redpanda-connect-stress/writer/counters.go`
- Create: `labs/redis-redpanda-connect-stress/writer/worker.go`

No unit tests here — these depend on a live Redis. They will be exercised end-to-end by the smoke verification in Task 26.

- [ ] **Step 1: Write `counters.go`**

Write `labs/redis-redpanda-connect-stress/writer/counters.go`:
```go
package main

import "sync/atomic"

type Counters struct {
	Sent     atomic.Int64
	Errors   atomic.Int64
	Inflight atomic.Int64
}

func (c *Counters) Reset() {
	c.Sent.Store(0)
	c.Errors.Store(0)
	c.Inflight.Store(0)
}
```

- [ ] **Step 2: Write `worker.go`**

Write `labs/redis-redpanda-connect-stress/writer/worker.go`:
```go
package main

import (
	"context"
	"log"
	"strconv"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID            int
	RDB           *redis.Client
	StreamKey     string
	StreamMaxLen  int64
	PipelineDepth int
	PayloadBytes  int
	KeySpaceSize  int64
	Lim           *Limiter
	Counters      *Counters
}

func (w *Worker) Run(ctx context.Context) {
	var seq int64
	base := int64(w.ID) << 40 // give each worker a high-bit prefix so seq numbers don't collide
	for {
		if err := w.Lim.WaitN(ctx, w.PipelineDepth); err != nil {
			return // context cancelled
		}
		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		for i := 0; i < w.PipelineDepth; i++ {
			seq++
			p := NewPayload(base|seq, w.PayloadBytes)
			body, _ := p.JSON()
			key := "stress:" + strconv.FormatInt((base|seq)%w.KeySpaceSize, 10)
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: map[string]any{
					"value":     string(body),
					"event_id":  p.EventID,
					"key":       key,
					"pattern":   "stress",
					"t_send_ms": p.TsNs / 1_000_000,
				},
			})
		}
		_, err := pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(w.PipelineDepth))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		} else {
			w.Counters.Sent.Add(int64(w.PipelineDepth))
		}
	}
}
```

- [ ] **Step 3: Verify package builds**

Run: `cd labs/redis-redpanda-connect-stress/writer && go build ./...`
Expected: no output (clean build).

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-connect-stress/writer/counters.go \
        labs/redis-redpanda-connect-stress/writer/worker.go
git commit -m "redis-redpanda-connect-stress: writer counters and worker pool"
```

---

## Task 7: Writer — HTTP server (handlers)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/writer/http.go`

Exposes `/healthz`, `/metrics`, `/rate`, `/reset` per spec §5.3. The `/metrics` output is hand-rolled Prometheus text format (no `prometheus/client_golang` dep — keeps the writer tiny).

- [ ] **Step 1: Write `http.go`**

Write `labs/redis-redpanda-connect-stress/writer/http.go`:
```go
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
)

type Server struct {
	Lim         *Limiter
	Counters    *Counters
	MaxRate     int
	HealthCheck func() bool
}

type rateReq struct {
	Rate int `json:"rate"`
}

func (s *Server) Register(mux *http.ServeMux) {
	mux.HandleFunc("/healthz", s.healthz)
	mux.HandleFunc("/metrics", s.metrics)
	mux.HandleFunc("/rate", s.rate)
	mux.HandleFunc("/reset", s.reset)
}

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	if s.HealthCheck() {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
		return
	}
	w.WriteHeader(http.StatusServiceUnavailable)
	fmt.Fprintln(w, "redis ping failed")
}

func (s *Server) metrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# TYPE stress_writer_sent_total counter\n")
	fmt.Fprintf(w, "stress_writer_sent_total %d\n", s.Counters.Sent.Load())
	fmt.Fprintf(w, "# TYPE stress_writer_errors_total counter\n")
	fmt.Fprintf(w, "stress_writer_errors_total %d\n", s.Counters.Errors.Load())
	fmt.Fprintf(w, "# TYPE stress_writer_rate_target gauge\n")
	fmt.Fprintf(w, "stress_writer_rate_target %d\n", s.Lim.Current())
	fmt.Fprintf(w, "# TYPE stress_writer_inflight_pipelines gauge\n")
	fmt.Fprintf(w, "stress_writer_inflight_pipelines %d\n", s.Counters.Inflight.Load())
}

func (s *Server) rate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var rq rateReq
	if err := json.NewDecoder(r.Body).Decode(&rq); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if rq.Rate < 0 || rq.Rate > s.MaxRate {
		http.Error(w, fmt.Sprintf("rate %d out of range [0,%d]", rq.Rate, s.MaxRate), http.StatusBadRequest)
		return
	}
	s.Lim.Set(rq.Rate)
	fmt.Fprintf(w, "rate set to %d\n", rq.Rate)
}

func (s *Server) reset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	s.Counters.Reset()
	fmt.Fprintln(w, "counters reset")
}
```

- [ ] **Step 2: Build check**

Run: `cd labs/redis-redpanda-connect-stress/writer && go build ./...`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/writer/http.go
git commit -m "redis-redpanda-connect-stress: writer HTTP handlers"
```

---

## Task 8: Writer — main wiring

**Files:**
- Create: `labs/redis-redpanda-connect-stress/writer/main.go`

- [ ] **Step 1: Write `main.go`**

Write `labs/redis-redpanda-connect-stress/writer/main.go`:
```go
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func main() {
	addr := envStr("REDIS_ADDR", "redis-central:6379")
	streamKey := envStr("STREAM_KEY", "app.events")
	streamMaxLen := envInt("STREAM_MAXLEN", 100_000)
	workers := envInt("WORKERS", 8)
	pipelineDepth := envInt("PIPELINE_DEPTH", 50)
	initialRate := envInt("INITIAL_RATE", 0)
	keySpaceSize := envInt("KEY_SPACE_SIZE", 100_000)
	payloadBytes := envInt("PAYLOAD_BYTES", 200)
	maxRate := envInt("MAX_RATE", 20_000)
	healthAddr := envStr("HEALTH_ADDR", ":8081")

	rdb := redis.NewClient(&redis.Options{Addr: addr, PoolSize: workers * 2})
	defer rdb.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lim := NewLimiter()
	lim.Set(initialRate)
	counters := &Counters{}

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		w := &Worker{
			ID: i, RDB: rdb,
			StreamKey:     streamKey,
			StreamMaxLen:  int64(streamMaxLen),
			PipelineDepth: pipelineDepth,
			PayloadBytes:  payloadBytes,
			KeySpaceSize:  int64(keySpaceSize),
			Lim:           lim,
			Counters:      counters,
		}
		wg.Add(1)
		go func() { defer wg.Done(); w.Run(ctx) }()
	}

	srv := &Server{
		Lim: lim, Counters: counters, MaxRate: maxRate,
		HealthCheck: func() bool {
			c, cf := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cf()
			return rdb.Ping(c).Err() == nil
		},
	}
	mux := http.NewServeMux()
	srv.Register(mux)

	httpSrv := &http.Server{Addr: healthAddr, Handler: mux}
	go func() {
		log.Printf("writer listening on %s", healthAddr)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("http server: %v", err)
		}
	}()

	sigC := make(chan os.Signal, 1)
	signal.Notify(sigC, syscall.SIGINT, syscall.SIGTERM)
	<-sigC
	log.Println("shutdown: draining")
	lim.Set(0)
	httpSrv.Shutdown(context.Background())
	cancel()
	wg.Wait()
}

func envStr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
```

- [ ] **Step 2: Tidy and test full package**

Run: `cd labs/redis-redpanda-connect-stress/writer && go mod tidy && go test ./...`
Expected: PASS — all unit tests still green.

- [ ] **Step 3: Container build check**

Run:
```bash
cd labs/redis-redpanda-connect-stress
docker build -t rrcs-writer:test ./writer
```
Expected: image built successfully.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-connect-stress/writer/main.go \
        labs/redis-redpanda-connect-stress/writer/go.sum
git commit -m "redis-redpanda-connect-stress: writer main wiring"
```

---

## Task 9: Collector — go.mod and Dockerfile

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/go.mod`
- Create: `labs/redis-redpanda-connect-stress/collector/Dockerfile`

- [ ] **Step 1: Write `go.mod`**

Write `labs/redis-redpanda-connect-stress/collector/go.mod`:
```
module collector

go 1.23

require (
	github.com/HdrHistogram/hdrhistogram-go v1.1.2
	github.com/redis/go-redis/v9 v9.7.0
)
```

- [ ] **Step 2: Write `Dockerfile`**

Write `labs/redis-redpanda-connect-stress/collector/Dockerfile`:
```dockerfile
# syntax=docker/dockerfile:1.7
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/collector .

FROM alpine:3.20
RUN apk add --no-cache wget ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/collector /usr/local/bin/collector
ENTRYPOINT ["/usr/local/bin/collector"]
```

- [ ] **Step 3: Remove .gitkeep and commit**

```bash
rm labs/redis-redpanda-connect-stress/collector/.gitkeep
git add labs/redis-redpanda-connect-stress/collector/
git commit -m "redis-redpanda-connect-stress: collector go.mod and Dockerfile"
```

---

## Task 10: Collector — latency parser + hdrhistogram (TDD)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/latency.go`
- Test:   `labs/redis-redpanda-connect-stress/collector/latency_test.go`

Parses `ts_ns` out of the JSON `value` field of an `XRANGE` entry, computes `now - ts_ns`, and feeds the result into an HDR histogram.

- [ ] **Step 1: Write the failing test**

Write `labs/redis-redpanda-connect-stress/collector/latency_test.go`:
```go
package main

import (
	"testing"
	"time"
)

func TestExtractTsNsFromValue(t *testing.T) {
	body := `{"event_id":"abc","ts_ns":1700000000000000000,"seq":1,"pad":"xxxx"}`
	got, err := extractTsNs(body)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != 1700000000000000000 {
		t.Errorf("got %d, want 1700000000000000000", got)
	}
}

func TestExtractTsNsMissingField(t *testing.T) {
	if _, err := extractTsNs(`{"event_id":"abc"}`); err == nil {
		t.Errorf("expected error on missing ts_ns")
	}
}

func TestLatencyTrackerRecordAndPercentiles(t *testing.T) {
	lt := NewLatencyTracker()
	now := time.Now().UnixNano()
	// Record three samples at 10ms, 50ms, 200ms relative to now.
	lt.RecordAt(now-10*int64(time.Millisecond), now)
	lt.RecordAt(now-50*int64(time.Millisecond), now)
	lt.RecordAt(now-200*int64(time.Millisecond), now)
	s := lt.Summary()
	if s.Samples != 3 {
		t.Errorf("Samples=%d, want 3", s.Samples)
	}
	// p99 must be >= 200ms (highest sample)
	if s.P99Ms < 200 {
		t.Errorf("P99Ms=%.2f, want >= 200", s.P99Ms)
	}
	// p50 must be >= 10ms and <= 200ms
	if s.P50Ms < 10 || s.P50Ms > 200 {
		t.Errorf("P50Ms=%.2f, want in [10,200]", s.P50Ms)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd labs/redis-redpanda-connect-stress/collector && go test ./...`
Expected: FAIL — `undefined: extractTsNs` / `NewLatencyTracker`.

- [ ] **Step 3: Write minimal implementation**

Write `labs/redis-redpanda-connect-stress/collector/latency.go`:
```go
package main

import (
	"encoding/json"
	"fmt"

	"github.com/HdrHistogram/hdrhistogram-go"
)

func extractTsNs(value string) (int64, error) {
	var p struct {
		TsNs int64 `json:"ts_ns"`
	}
	if err := json.Unmarshal([]byte(value), &p); err != nil {
		return 0, err
	}
	if p.TsNs == 0 {
		return 0, fmt.Errorf("ts_ns missing or zero")
	}
	return p.TsNs, nil
}

type LatencyTracker struct {
	h *hdrhistogram.Histogram
}

func NewLatencyTracker() *LatencyTracker {
	// Range 1 microsecond .. 60 seconds, 3 significant figures.
	return &LatencyTracker{h: hdrhistogram.New(1, 60_000_000, 3)}
}

func (l *LatencyTracker) RecordAt(tsNs, nowNs int64) {
	dUs := (nowNs - tsNs) / 1_000
	if dUs < 1 {
		dUs = 1
	}
	_ = l.h.RecordValue(dUs)
}

type LatencySummary struct {
	P50Ms   float64 `json:"p50"`
	P95Ms   float64 `json:"p95"`
	P99Ms   float64 `json:"p99"`
	MaxMs   float64 `json:"max"`
	Samples int64   `json:"samples"`
}

func (l *LatencyTracker) Summary() LatencySummary {
	usToMs := func(us int64) float64 { return float64(us) / 1000.0 }
	return LatencySummary{
		P50Ms:   usToMs(l.h.ValueAtQuantile(50)),
		P95Ms:   usToMs(l.h.ValueAtQuantile(95)),
		P99Ms:   usToMs(l.h.ValueAtQuantile(99)),
		MaxMs:   usToMs(l.h.Max()),
		Samples: l.h.TotalCount(),
	}
}
```

- [ ] **Step 4: Run tests**

Run: `cd labs/redis-redpanda-connect-stress/collector && go mod tidy && go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/latency.go \
        labs/redis-redpanda-connect-stress/collector/latency_test.go \
        labs/redis-redpanda-connect-stress/collector/go.sum
git commit -m "redis-redpanda-connect-stress: collector latency tracker + tests"
```

---

## Task 11: Collector — verdict logic (TDD)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/verdict.go`
- Test:   `labs/redis-redpanda-connect-stress/collector/verdict_test.go`

Per spec §6.6: `rate_ok`, `missing_ok`, `latency_p99_ok`, `pass = all`.

- [ ] **Step 1: Write the failing test**

Write `labs/redis-redpanda-connect-stress/collector/verdict_test.go`:
```go
package main

import "testing"

func TestVerdictAllPass(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		Mode:            "latency",
		RateTarget:      1000,
		RateAchievedAvg: 998,
		Missing:         0,
		LatencyP99Ms:    500,
		SLO:             SLO{RateMinPct: 0.95, LatencyP99Ms: 1000, AllowMissing: false},
	})
	if !v.Pass {
		t.Errorf("expected pass, got %+v", v)
	}
}

func TestVerdictRateTooLow(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		Mode: "throughput", RateTarget: 1000, RateAchievedAvg: 800,
		Missing: 0, LatencyP99Ms: 0,
		SLO: SLO{RateMinPct: 0.95},
	})
	if v.Pass {
		t.Errorf("expected fail (rate)")
	}
	if v.Checks["rate_ok"] {
		t.Errorf("rate_ok should be false")
	}
}

func TestVerdictMissingNotAllowed(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		Mode: "throughput", RateTarget: 1000, RateAchievedAvg: 1000,
		Missing: 5, LatencyP99Ms: 0,
		SLO: SLO{RateMinPct: 0.95, AllowMissing: false},
	})
	if v.Pass {
		t.Errorf("expected fail (missing)")
	}
}

func TestVerdictMissingAllowedForAMO(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		Mode: "throughput", RateTarget: 1000, RateAchievedAvg: 1000,
		Missing: 50, LatencyP99Ms: 0,
		SLO: SLO{RateMinPct: 0.95, AllowMissing: true},
	})
	if !v.Pass {
		t.Errorf("expected pass (AMO allows missing)")
	}
}

func TestVerdictLatencyOnlyCheckedInLatencyAndChaosModes(t *testing.T) {
	in := VerdictInput{
		Mode: "throughput", RateTarget: 1000, RateAchievedAvg: 1000,
		Missing: 0, LatencyP99Ms: 9999,
		SLO: SLO{RateMinPct: 0.95, LatencyP99Ms: 1000},
	}
	if !ComputeVerdict(in).Pass {
		t.Errorf("throughput mode should ignore latency p99")
	}
	in.Mode = "latency"
	if ComputeVerdict(in).Pass {
		t.Errorf("latency mode should fail when p99 > SLO")
	}
	in.Mode = "chaos"
	if ComputeVerdict(in).Pass {
		t.Errorf("chaos mode should fail when p99 > SLO")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd labs/redis-redpanda-connect-stress/collector && go test ./...`
Expected: FAIL — `undefined: ComputeVerdict`.

- [ ] **Step 3: Write minimal implementation**

Write `labs/redis-redpanda-connect-stress/collector/verdict.go`:
```go
package main

type SLO struct {
	RateMinPct   float64 `json:"rate_min_pct"`
	LatencyP99Ms float64 `json:"latency_p99_ms"`
	AllowMissing bool    `json:"allow_missing"`
}

type VerdictInput struct {
	Mode            string
	RateTarget      int
	RateAchievedAvg float64
	Missing         int64
	LatencyP99Ms    float64
	SLO             SLO
}

type Verdict struct {
	Pass   bool            `json:"pass"`
	Checks map[string]bool `json:"checks"`
}

func ComputeVerdict(in VerdictInput) Verdict {
	checks := map[string]bool{}
	checks["rate_ok"] = float64(in.RateTarget) == 0 ||
		in.RateAchievedAvg/float64(in.RateTarget) >= in.SLO.RateMinPct
	checks["missing_ok"] = in.SLO.AllowMissing || in.Missing == 0
	if in.Mode == "latency" || in.Mode == "chaos" {
		checks["latency_p99_ok"] = in.LatencyP99Ms <= in.SLO.LatencyP99Ms
	}
	pass := true
	for _, ok := range checks {
		if !ok {
			pass = false
			break
		}
	}
	return Verdict{Pass: pass, Checks: checks}
}
```

- [ ] **Step 4: Run tests**

Run: `cd labs/redis-redpanda-connect-stress/collector && go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/verdict.go \
        labs/redis-redpanda-connect-stress/collector/verdict_test.go
git commit -m "redis-redpanda-connect-stress: collector verdict logic + tests"
```

---

## Task 12: Collector — report JSON writer (TDD)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/report.go`
- Test:   `labs/redis-redpanda-connect-stress/collector/report_test.go`

Defines the `Report` type matching spec §6.5. Test serializes a known Report and asserts the JSON shape.

- [ ] **Step 1: Write the failing test**

Write `labs/redis-redpanda-connect-stress/collector/report_test.go`:
```go
package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestReportJSONShape(t *testing.T) {
	r := Report{
		Tier: 1000, Mode: "latency", Profile: "alo",
		StartedAt:       time.Date(2026, 5, 24, 19, 12, 3, 0, time.UTC),
		DurationS:       30,
		RateTarget:      1000,
		RateAchievedAvg: 998.2,
		RateAchievedMin: 942.0,
		Sent:            30021,
		Errors:          0,
		Received:        30019,
		Missing:         2,
		MissingPct:      0.0067,
		Latency:         LatencySummary{P50Ms: 18.4, P95Ms: 47.2, P99Ms: 89.1, MaxMs: 211.3, Samples: 6044},
		Redis:           RedisStats{CentralXLenMax: 1247, RegionXLenFinal: 30019},
		NATS:            NATSStats{PendingMax: 980, Bytes: 7_320_000},
		Connect:         ConnectStats{SourceIn: 30021, SourceOut: 30021, SinkIn: 30021, SinkOut: 30019},
		Chaos:           nil,
		SLO:             SLO{RateMinPct: 0.95, LatencyP99Ms: 1000},
		Verdict:         Verdict{Pass: true, Checks: map[string]bool{"rate_ok": true, "missing_ok": true, "latency_p99_ok": true}},
	}
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(b)
	for _, want := range []string{
		`"tier": 1000`,
		`"mode": "latency"`,
		`"rate_achieved_avg": 998.2`,
		`"latency_ms": {`,
		`"chaos": null`,
		`"pass": true`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in:\n%s", want, s)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd labs/redis-redpanda-connect-stress/collector && go test ./...`
Expected: FAIL — types not defined.

- [ ] **Step 3: Write minimal implementation**

Write `labs/redis-redpanda-connect-stress/collector/report.go`:
```go
package main

import "time"

type RedisStats struct {
	CentralXLenMax  int64 `json:"central_xlen_max"`
	RegionXLenFinal int64 `json:"region_xlen_final"`
}

type NATSStats struct {
	PendingMax int64 `json:"pending_max"`
	Bytes      int64 `json:"bytes"`
}

type ConnectStats struct {
	SourceIn  int64 `json:"source_in"`
	SourceOut int64 `json:"source_out"`
	SinkIn    int64 `json:"sink_in"`
	SinkOut   int64 `json:"sink_out"`
}

type ChaosInfo struct {
	Action          string `json:"action"`
	DownAtS         int    `json:"down_at_s"`
	DurationS       int    `json:"duration_s"`
	RecoveryLagMax  int64  `json:"recovery_lag_max"`
}

type Report struct {
	Tier            int            `json:"tier"`
	Mode            string         `json:"mode"`
	Profile         string         `json:"profile"`
	StartedAt       time.Time      `json:"started_at"`
	DurationS       int            `json:"duration_s"`
	RateTarget      int            `json:"rate_target"`
	RateAchievedAvg float64        `json:"rate_achieved_avg"`
	RateAchievedMin float64        `json:"rate_achieved_min"`
	Sent            int64          `json:"sent"`
	Errors          int64          `json:"errors"`
	Received        int64          `json:"received"`
	Missing         int64          `json:"missing"`
	MissingPct      float64        `json:"missing_pct"`
	Latency         LatencySummary `json:"latency_ms"`
	Redis           RedisStats     `json:"redis"`
	NATS            NATSStats      `json:"nats"`
	Connect         ConnectStats   `json:"connect"`
	Chaos           *ChaosInfo     `json:"chaos"`
	SLO             SLO            `json:"slo"`
	Verdict         Verdict        `json:"verdict"`
}
```

- [ ] **Step 4: Run tests**

Run: `cd labs/redis-redpanda-connect-stress/collector && go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/report.go \
        labs/redis-redpanda-connect-stress/collector/report_test.go
git commit -m "redis-redpanda-connect-stress: collector report schema + tests"
```

---

## Task 13: Collector — Redis ops (XLEN, XRANGE, XTRIM)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/redis.go`

No unit tests — depends on live Redis. Exercised in Task 26 smoke verification.

- [ ] **Step 1: Write `redis.go`**

Write `labs/redis-redpanda-connect-stress/collector/redis.go`:
```go
package main

import (
	"context"

	"github.com/redis/go-redis/v9"
)

type StreamClient struct {
	rdb *redis.Client
}

func NewStreamClient(addr string) *StreamClient {
	return &StreamClient{rdb: redis.NewClient(&redis.Options{Addr: addr})}
}

func (s *StreamClient) Close() error { return s.rdb.Close() }

func (s *StreamClient) XLen(ctx context.Context, key string) (int64, error) {
	return s.rdb.XLen(ctx, key).Result()
}

func (s *StreamClient) Trim(ctx context.Context, key string) error {
	return s.rdb.XTrimMaxLen(ctx, key, 0).Err()
}

// XRangeSinceID returns stream entries strictly after `lastID` (use "0-0" for first call),
// up to count entries. Returns the new highest ID for the next call.
func (s *StreamClient) XRangeSinceID(ctx context.Context, key, lastID string, count int64) ([]redis.XMessage, string, error) {
	startExclusive := "(" + lastID
	msgs, err := s.rdb.XRangeN(ctx, key, startExclusive, "+", count).Result()
	if err != nil {
		return nil, lastID, err
	}
	newLast := lastID
	if len(msgs) > 0 {
		newLast = msgs[len(msgs)-1].ID
	}
	return msgs, newLast, nil
}
```

- [ ] **Step 2: Build check**

Run: `cd labs/redis-redpanda-connect-stress/collector && go build ./...`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/redis.go
git commit -m "redis-redpanda-connect-stress: collector Redis stream ops"
```

---

## Task 14: Collector — HTTP scrapers (writer, connect)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/scrapers.go`

Parses Prometheus text format for the writer/`stress_writer_*` metrics and Connect's `/metrics` (which uses standard Prometheus format).

- [ ] **Step 1: Write `scrapers.go`**

Write `labs/redis-redpanda-connect-stress/collector/scrapers.go`:
```go
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 2 * time.Second}

// scrapePromMetrics fetches a Prometheus text-format endpoint and returns
// a flat map of metric name -> first sample value seen. Histograms/summaries
// are NOT fully decoded — only the bare-name samples are kept.
func scrapePromMetrics(ctx context.Context, url string) (map[string]float64, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return parseProm(resp.Body)
}

func parseProm(r io.Reader) (map[string]float64, error) {
	out := map[string]float64{}
	scn := bufio.NewScanner(r)
	for scn.Scan() {
		line := strings.TrimSpace(scn.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// "name value" or "name{labels} value"
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		name := fields[0]
		if i := strings.IndexByte(name, '{'); i >= 0 {
			name = name[:i]
		}
		if _, dup := out[name]; dup {
			continue
		}
		v, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			continue
		}
		out[name] = v
	}
	return out, scn.Err()
}

// PostRate calls POST /rate {rate: n} on the writer.
func PostRate(ctx context.Context, writerURL string, n int) error {
	body, _ := json.Marshal(map[string]int{"rate": n})
	req, _ := http.NewRequestWithContext(ctx, "POST", writerURL+"/rate", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("rate %d: %s: %s", n, resp.Status, b)
	}
	return nil
}

// PostReset zeros writer counters.
func PostReset(ctx context.Context, writerURL string) error {
	req, _ := http.NewRequestWithContext(ctx, "POST", writerURL+"/reset", nil)
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("reset: %s", resp.Status)
	}
	return nil
}
```

- [ ] **Step 2: Build check**

Run: `cd labs/redis-redpanda-connect-stress/collector && go build ./...`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/scrapers.go
git commit -m "redis-redpanda-connect-stress: collector HTTP scrapers"
```

---

## Task 15: Collector — NATS /jsz scraper

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/nats.go`

The NATS monitoring endpoint `/jsz?streams=true&consumers=true` returns JSON. We pull `messages`, `bytes`, and the maximum `num_pending` across all consumers of the `APP_EVENTS` stream.

- [ ] **Step 1: Write `nats.go`**

Write `labs/redis-redpanda-connect-stress/collector/nats.go`:
```go
package main

import (
	"context"
	"encoding/json"
	"net/http"
)

type jszConsumer struct {
	NumPending int64 `json:"num_pending"`
}

type jszStream struct {
	Name      string `json:"name"`
	State     struct {
		Messages int64 `json:"messages"`
		Bytes    int64 `json:"bytes"`
	} `json:"state"`
	ConsumerDetail []jszConsumer `json:"consumer_detail"`
}

type jszAccountResp struct {
	AccountDetails []struct {
		StreamDetail []jszStream `json:"stream_detail"`
	} `json:"account_details"`
}

type NATSSnap struct {
	Messages   int64
	Bytes      int64
	MaxPending int64
}

func ScrapeJSZ(ctx context.Context, baseURL, streamName string) (NATSSnap, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET",
		baseURL+"/jsz?streams=true&consumers=true&accounts=true", nil)
	resp, err := httpClient.Do(req)
	if err != nil {
		return NATSSnap{}, err
	}
	defer resp.Body.Close()
	var ar jszAccountResp
	if err := json.NewDecoder(resp.Body).Decode(&ar); err != nil {
		return NATSSnap{}, err
	}
	var s NATSSnap
	for _, acc := range ar.AccountDetails {
		for _, st := range acc.StreamDetail {
			if st.Name != streamName {
				continue
			}
			s.Messages = st.State.Messages
			s.Bytes = st.State.Bytes
			for _, c := range st.ConsumerDetail {
				if c.NumPending > s.MaxPending {
					s.MaxPending = c.NumPending
				}
			}
		}
	}
	return s, nil
}
```

- [ ] **Step 2: Build check**

Run: `cd labs/redis-redpanda-connect-stress/collector && go build ./...`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/nats.go
git commit -m "redis-redpanda-connect-stress: collector NATS /jsz scraper"
```

---

## Task 16: Collector — snapshot ticker

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/snapshot.go`

Runs every 1 s during the sustain+drain window. Accumulates raw samples; final `Report` is computed by `Run()` in main.

- [ ] **Step 1: Write `snapshot.go`**

Write `labs/redis-redpanda-connect-stress/collector/snapshot.go`:
```go
package main

import (
	"context"
	"log"
	"time"
)

type Snapshot struct {
	At              time.Time
	WriterMetrics   map[string]float64
	ConnectSrc      map[string]float64
	ConnectSink     map[string]float64
	CentralXLen     int64
	RegionXLen      int64
	NATS            NATSSnap
}

type Sampler struct {
	WriterURL    string
	ConnectSrc   string
	ConnectSink  string
	NATSURL      string
	NATSStream   string
	Central      *StreamClient
	Region       *StreamClient
	Latency      *LatencyTracker
	LastRegionID string
}

// Tick takes a single snapshot AND pulls latency samples from region-events.
func (s *Sampler) Tick(ctx context.Context) Snapshot {
	now := time.Now()
	snap := Snapshot{At: now}
	c, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()

	if m, err := scrapePromMetrics(c, s.WriterURL+"/metrics"); err == nil {
		snap.WriterMetrics = m
	} else {
		log.Printf("scrape writer: %v", err)
	}
	if m, err := scrapePromMetrics(c, s.ConnectSrc+"/metrics"); err == nil {
		snap.ConnectSrc = m
	}
	if m, err := scrapePromMetrics(c, s.ConnectSink+"/metrics"); err == nil {
		snap.ConnectSink = m
	}
	if x, err := s.Central.XLen(c, "app.events"); err == nil {
		snap.CentralXLen = x
	}
	if x, err := s.Region.XLen(c, "region-events"); err == nil {
		snap.RegionXLen = x
	}
	if n, err := ScrapeJSZ(c, s.NATSURL, s.NATSStream); err == nil {
		snap.NATS = n
	}

	// Latency samples from region-events
	msgs, newLast, err := s.Region.XRangeSinceID(c, "region-events", s.LastRegionID, 200)
	if err == nil {
		nowNs := time.Now().UnixNano()
		for _, m := range msgs {
			v, ok := m.Values["value"].(string)
			if !ok {
				continue
			}
			ts, err := extractTsNs(v)
			if err != nil {
				continue
			}
			s.Latency.RecordAt(ts, nowNs)
		}
		s.LastRegionID = newLast
	}
	return snap
}

func (s *Sampler) Init() {
	if s.LastRegionID == "" {
		s.LastRegionID = "0-0"
	}
}
```

- [ ] **Step 2: Build check**

Run: `cd labs/redis-redpanda-connect-stress/collector && go build ./...`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/snapshot.go
git commit -m "redis-redpanda-connect-stress: collector snapshot ticker"
```

---

## Task 17: Collector — main lifecycle

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/main.go`

Orchestrates warmup → sustain → drain → report. For chaos mode, the harness stops/starts `connect-sink` externally via the kill script; the collector simply records the maximum `NATS.MaxPending` after the chaos point.

- [ ] **Step 1: Write `main.go`**

Write `labs/redis-redpanda-connect-stress/collector/main.go`:
```go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type RunConfig struct {
	Tier         int
	Mode         string
	Profile      string
	Duration     time.Duration
	Warmup       time.Duration
	Drain        time.Duration
	WriterURL    string
	RedisCentral string
	RedisRegion  string
	NATSURL      string
	NATSStream   string
	ConnectSrc   string
	ConnectSink  string
	ChaosAtS     float64
	ChaosDurS    int
	SLO          SLO
}

func main() {
	var (
		tier        = flag.Int("tier", 0, "target msg/s (required)")
		mode        = flag.String("mode", "throughput", "throughput|latency|chaos")
		profile     = flag.String("profile", "alo", "alo|amo|eoe")
		duration    = flag.Duration("duration", 30*time.Second, "sustain window")
		warmup      = flag.Duration("warmup", 5*time.Second, "warmup window")
		drain       = flag.Duration("drain", 10*time.Second, "drain window")
		out         = flag.String("out", "/reports/run.json", "report JSON path")
		writerURL   = flag.String("writer", "http://writer:8081", "writer URL")
		central     = flag.String("redis-central", "redis-central:6379", "")
		region      = flag.String("redis-region", "redis-region:6379", "")
		natsURL     = flag.String("nats", "http://nats:8222", "NATS monitoring URL")
		natsStream  = flag.String("nats-stream", "APP_EVENTS", "JetStream stream name")
		connectSrc  = flag.String("connect-src", "http://connect-source:4195", "")
		connectSink = flag.String("connect-sink", "http://connect-sink:4195", "")
		chaosAtS    = flag.Float64("chaos-at-s", 0, "seconds into sustain to record chaos lag (harness drives the kill)")
		chaosDur    = flag.Int("chaos-duration", 8, "outage seconds (recorded only)")
		sloRatePct  = flag.Float64("slo-rate-pct", 0.95, "")
		sloP99Ms    = flag.Float64("slo-p99-ms", 1000, "")
		sloAllowMiss = flag.Bool("slo-allow-missing", false, "")
	)
	flag.Parse()
	if *tier <= 0 {
		log.Fatal("--tier required (>0)")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		<-c
		cancel()
	}()

	cfg := RunConfig{
		Tier: *tier, Mode: *mode, Profile: *profile,
		Duration: *duration, Warmup: *warmup, Drain: *drain,
		WriterURL: *writerURL,
		RedisCentral: *central, RedisRegion: *region,
		NATSURL: *natsURL, NATSStream: *natsStream,
		ConnectSrc: *connectSrc, ConnectSink: *connectSink,
		ChaosAtS: *chaosAtS, ChaosDurS: *chaosDur,
		SLO: SLO{
			RateMinPct: *sloRatePct, LatencyP99Ms: *sloP99Ms,
			AllowMissing: *sloAllowMiss,
		},
	}

	r, err := Run(ctx, cfg)
	if err != nil {
		log.Fatalf("run failed: %v", err)
	}

	if err := writeJSON(*out, r); err != nil {
		log.Fatalf("write %s: %v", *out, err)
	}
	log.Printf("report written to %s; verdict.pass=%v", *out, r.Verdict.Pass)
	if !r.Verdict.Pass {
		os.Exit(1)
	}
}

func writeJSON(path string, v any) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func Run(ctx context.Context, cfg RunConfig) (Report, error) {
	central := NewStreamClient(cfg.RedisCentral)
	defer central.Close()
	region := NewStreamClient(cfg.RedisRegion)
	defer region.Close()

	// 1. Trim streams to zero so we measure only this tier's traffic.
	_ = central.Trim(ctx, "app.events")
	_ = region.Trim(ctx, "region-events")

	// 2. Reset writer counters.
	if err := PostReset(ctx, cfg.WriterURL); err != nil {
		return Report{}, err
	}

	// 3. Warmup at half rate.
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier/2); err != nil {
		return Report{}, err
	}
	sleep(ctx, cfg.Warmup)

	// 4. Sustain at full rate.
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier); err != nil {
		return Report{}, err
	}

	sampler := &Sampler{
		WriterURL: cfg.WriterURL, ConnectSrc: cfg.ConnectSrc,
		ConnectSink: cfg.ConnectSink, NATSURL: cfg.NATSURL,
		NATSStream: cfg.NATSStream,
		Central:    central, Region: region,
		Latency:    NewLatencyTracker(),
	}
	sampler.Init()

	startedAt := time.Now()
	sustainEnd := startedAt.Add(cfg.Duration)

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	var snaps []Snapshot
	// Sustain window
	for time.Now().Before(sustainEnd) {
		select {
		case <-ctx.Done():
			return Report{}, ctx.Err()
		case <-ticker.C:
			snaps = append(snaps, sampler.Tick(ctx))
		}
	}

	// 5. Drain.
	if err := PostRate(ctx, cfg.WriterURL, 0); err != nil {
		return Report{}, err
	}
	drainEnd := time.Now().Add(cfg.Drain)
	for time.Now().Before(drainEnd) {
		select {
		case <-ctx.Done():
			return Report{}, ctx.Err()
		case <-ticker.C:
			snaps = append(snaps, sampler.Tick(ctx))
		}
	}

	// 6. Final snapshot
	final := sampler.Tick(ctx)
	snaps = append(snaps, final)

	return buildReport(cfg, startedAt, snaps, sampler.Latency.Summary()), nil
}

func buildReport(cfg RunConfig, startedAt time.Time, snaps []Snapshot, lat LatencySummary) Report {
	r := Report{
		Tier: cfg.Tier, Mode: cfg.Mode, Profile: cfg.Profile,
		StartedAt: startedAt, DurationS: int(cfg.Duration.Seconds()),
		RateTarget: cfg.Tier,
		Latency:    lat,
		SLO:        cfg.SLO,
	}

	// Sent + errors are end-of-run values from the last snapshot.
	if len(snaps) > 0 {
		last := snaps[len(snaps)-1]
		r.Sent = int64(last.WriterMetrics["stress_writer_sent_total"])
		r.Errors = int64(last.WriterMetrics["stress_writer_errors_total"])
		r.Received = last.RegionXLen
		r.Redis.RegionXLenFinal = last.RegionXLen
		r.Connect.SourceIn = int64(last.ConnectSrc["input_received"])
		r.Connect.SourceOut = int64(last.ConnectSrc["output_sent"])
		r.Connect.SinkIn = int64(last.ConnectSink["input_received"])
		r.Connect.SinkOut = int64(last.ConnectSink["output_sent"])
		r.NATS.Bytes = last.NATS.Bytes
	}
	r.Missing = r.Sent - r.Received
	if r.Missing < 0 {
		r.Missing = 0
	}
	if r.Sent > 0 {
		r.MissingPct = float64(r.Missing) / float64(r.Sent) * 100.0
	}

	// Per-second sent deltas → achieved rate avg/min, central XLen max, NATS pending max.
	var minRate float64 = 1e18
	var sumRate, samples float64
	var lastSent int64
	var maxXLen, maxPending int64
	for i, snap := range snaps {
		sent := int64(snap.WriterMetrics["stress_writer_sent_total"])
		if i > 0 {
			delta := float64(sent - lastSent)
			if delta < 0 {
				delta = 0
			}
			sumRate += delta
			samples++
			if delta < minRate {
				minRate = delta
			}
		}
		lastSent = sent
		if snap.CentralXLen > maxXLen {
			maxXLen = snap.CentralXLen
		}
		if snap.NATS.MaxPending > maxPending {
			maxPending = snap.NATS.MaxPending
		}
	}
	if samples > 0 {
		r.RateAchievedAvg = sumRate / samples
		r.RateAchievedMin = minRate
	}
	r.Redis.CentralXLenMax = maxXLen
	r.NATS.PendingMax = maxPending

	if cfg.Mode == "chaos" && cfg.ChaosAtS > 0 {
		r.Chaos = &ChaosInfo{
			Action:         "kill-connect-sink",
			DownAtS:        int(cfg.ChaosAtS),
			DurationS:      cfg.ChaosDurS,
			RecoveryLagMax: maxPending,
		}
	}

	r.Verdict = ComputeVerdict(VerdictInput{
		Mode: cfg.Mode, RateTarget: cfg.Tier,
		RateAchievedAvg: r.RateAchievedAvg,
		Missing:         r.Missing,
		LatencyP99Ms:    r.Latency.P99Ms,
		SLO:             cfg.SLO,
	})
	return r
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

// avoid an unused-import error when only some build tags include strings
var _ = strings.TrimSpace
```

- [ ] **Step 2: Build, tidy, test**

Run:
```bash
cd labs/redis-redpanda-connect-stress/collector
go mod tidy
go test ./...
go build ./...
```
Expected: tests pass, build clean.

- [ ] **Step 3: Container build check**

Run:
```bash
cd labs/redis-redpanda-connect-stress
docker build -t rrcs-collector:test ./collector
```
Expected: image built successfully.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/main.go \
        labs/redis-redpanda-connect-stress/collector/go.sum
git commit -m "redis-redpanda-connect-stress: collector main lifecycle"
```

---

## Task 18: docker-compose.yml

**Files:**
- Create: `labs/redis-redpanda-connect-stress/docker-compose.yml`

Per spec §4 (architecture), §8 (resource caps), §9 (ports). NATS init creates `APP_EVENTS` with `--max-bytes=256MB`. Keyspace notifications are **off** on both Redis instances.

- [ ] **Step 1: Write `docker-compose.yml`**

Write `labs/redis-redpanda-connect-stress/docker-compose.yml`:
```yaml
name: redis-redpanda-connect-stress

services:
  redis-central:
    image: redis:7.4-alpine
    container_name: rrcs-redis-central
    command:
      - "redis-server"
      - "--notify-keyspace-events"
      - ""
      - "--appendonly"
      - "no"
      - "--save"
      - ""
    ports:
      - "${REDIS_CENTRAL_PORT:-17379}:6379"
    deploy:
      resources:
        limits: { cpus: "2.0", memory: "512m" }
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rrcs]

  redis-region:
    image: redis:7.4-alpine
    container_name: rrcs-redis-region
    command:
      - "redis-server"
      - "--notify-keyspace-events"
      - ""
      - "--appendonly"
      - "no"
      - "--save"
      - ""
    ports:
      - "${REDIS_REGION_PORT:-17380}:6379"
    deploy:
      resources:
        limits: { cpus: "2.0", memory: "512m" }
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rrcs]

  nats:
    image: nats:2.10-alpine
    container_name: rrcs-nats
    command: ["-js", "-sd", "/data", "-m", "8222"]
    ports:
      - "${NATS_CLIENT_PORT:-17222}:4222"
      - "${NATS_MON_PORT:-17322}:8222"
    deploy:
      resources:
        limits: { cpus: "2.0", memory: "1g" }
    volumes:
      - nats-data:/data
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8222/healthz"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rrcs]

  nats-init:
    image: natsio/nats-box:0.14.5
    container_name: rrcs-nats-init
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
            --max-bytes 256MB \
            --max-msgs=-1 \
            --max-msg-size=1MB \
            --dupe-window 5m \
            --defaults
        fi
        nats --server nats://nats:4222 stream info APP_EVENTS
    networks: [rrcs]

  connect-source:
    image: hpdevelop/connect:4.92.0-claudefix
    container_name: rrcs-connect-source
    depends_on:
      redis-central: { condition: service_healthy }
      nats-init: { condition: service_completed_successfully }
    volumes:
      - ./connect/${PROFILE_QOS:-alo}-forward.yaml:/connect.yaml:ro
    command: ["run", "/connect.yaml"]
    ports:
      - "${CONNECT_SRC_PORT:-17195}:4195"
    deploy:
      resources:
        limits: { cpus: "2.0", memory: "1g" }
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4195/ready"]
      interval: 2s
      timeout: 2s
      retries: 30
    networks: [rrcs]

  connect-sink:
    image: hpdevelop/connect:4.92.0-claudefix
    container_name: rrcs-connect-sink
    depends_on:
      redis-region: { condition: service_healthy }
      nats-init: { condition: service_completed_successfully }
    volumes:
      - ./connect/${PROFILE_QOS:-alo}-reverse.yaml:/connect.yaml:ro
    command: ["run", "/connect.yaml"]
    ports:
      - "${CONNECT_SINK_PORT:-17196}:4195"
    deploy:
      resources:
        limits: { cpus: "2.0", memory: "1g" }
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4195/ready"]
      interval: 2s
      timeout: 2s
      retries: 30
    networks: [rrcs]

  writer:
    build: ./writer
    container_name: rrcs-writer
    depends_on:
      redis-central: { condition: service_healthy }
      connect-source: { condition: service_healthy }
    environment:
      REDIS_ADDR: redis-central:6379
      STREAM_KEY: app.events
      STREAM_MAXLEN: "${STREAM_MAXLEN:-100000}"
      WORKERS: "${WORKERS:-8}"
      PIPELINE_DEPTH: "${PIPELINE_DEPTH:-50}"
      INITIAL_RATE: "0"
      KEY_SPACE_SIZE: "${KEY_SPACE_SIZE:-100000}"
      PAYLOAD_BYTES: "${PAYLOAD_BYTES:-200}"
      MAX_RATE: "${MAX_RATE:-20000}"
      HEALTH_ADDR: ":8081"
    ports:
      - "${WRITER_PORT:-17081}:8081"
    deploy:
      resources:
        limits: { cpus: "2.0", memory: "256m" }
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8081/healthz"]
      interval: 2s
      timeout: 2s
      retries: 15
    networks: [rrcs]

  collector:
    build: ./collector
    container_name: rrcs-collector
    profiles: ["tools"]
    depends_on:
      writer: { condition: service_healthy }
      redis-central: { condition: service_healthy }
      redis-region: { condition: service_healthy }
      connect-source: { condition: service_healthy }
      connect-sink: { condition: service_healthy }
    volumes:
      - ./reports:/reports
    deploy:
      resources:
        limits: { cpus: "0.5", memory: "128m" }
    networks: [rrcs]

networks:
  rrcs:
    name: rrcs-net

volumes:
  nats-data:
```

The `collector` service uses `profiles: ["tools"]` so it is **not** started by a plain `docker compose up -d`. Instead, the harness invokes it via `docker compose --profile tools run --rm collector ...`.

- [ ] **Step 2: Validate compose file**

Run:
```bash
cd labs/redis-redpanda-connect-stress
docker compose config -q
```
Expected: no output (config is valid).

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/docker-compose.yml
git commit -m "redis-redpanda-connect-stress: docker-compose with resource caps"
```

---

## Task 19: .env.example

**Files:**
- Create: `labs/redis-redpanda-connect-stress/.env.example`

- [ ] **Step 1: Write `.env.example`**

Write `labs/redis-redpanda-connect-stress/.env.example`:
```
# QoS profile mounted into Connect: alo | amo | eoe
PROFILE_QOS=alo

# Writer tuning (lower on weaker hosts; may invalidate published SLOs)
WORKERS=8
PIPELINE_DEPTH=50
KEY_SPACE_SIZE=100000
PAYLOAD_BYTES=200
STREAM_MAXLEN=100000
MAX_RATE=20000

# Stress run knobs (consumed by scripts/stress-run.sh)
DURATION_S=30
WARMUP_S=5
DRAIN_S=10

# Host port overrides (defaults shown)
REDIS_CENTRAL_PORT=17379
REDIS_REGION_PORT=17380
NATS_CLIENT_PORT=17222
NATS_MON_PORT=17322
CONNECT_SRC_PORT=17195
CONNECT_SINK_PORT=17196
WRITER_PORT=17081
```

- [ ] **Step 2: Commit**

```bash
git add labs/redis-redpanda-connect-stress/.env.example
git commit -m "redis-redpanda-connect-stress: .env.example with all knobs"
```

---

## Task 20: scripts/lib/tier-defs.sh

**Files:**
- Create: `labs/redis-redpanda-connect-stress/scripts/lib/tier-defs.sh`

- [ ] **Step 1: Write the file**

Write `labs/redis-redpanda-connect-stress/scripts/lib/tier-defs.sh`:
```bash
#!/usr/bin/env bash
# Tier SLOs and run-window knobs. Sourced by stress-run.sh.

# Default tiers (override via --tiers=10,1000 on stress-run.sh)
DEFAULT_TIERS=(10 1000 10000)

# Default modes (override via --modes=...)
DEFAULT_MODES=(throughput latency chaos)

# Latency p99 SLO (ms) per tier
declare -A TIER_P99_MS=(
  [10]=200
  [1000]=1000
  [10000]=5000
)

# Achieved-rate floor as fraction of target
declare -A TIER_RATE_MIN_PCT=(
  [10]=0.95
  [1000]=0.95
  [10000]=0.90
)

# Run windows (env-overridable)
DURATION_S="${DURATION_S:-30}"
WARMUP_S="${WARMUP_S:-5}"
DRAIN_S="${DRAIN_S:-10}"

# Chaos parameters
CHAOS_DOWN_S="${CHAOS_DOWN_S:-8}"
# Chaos kicks in at sustain_mid by default
chaos_at_s() { echo $(( DURATION_S / 2 )); }

# Returns "true" if profile is amo (allows missing messages)
allow_missing_for_profile() {
  case "$1" in
    amo) echo "true" ;;
    *)   echo "false" ;;
  esac
}
```

- [ ] **Step 2: Make executable, sanity check syntax**

Run:
```bash
chmod +x labs/redis-redpanda-connect-stress/scripts/lib/tier-defs.sh
bash -n labs/redis-redpanda-connect-stress/scripts/lib/tier-defs.sh
```
Expected: no output (syntax OK).

- [ ] **Step 3: Remove .gitkeep and commit**

```bash
rm labs/redis-redpanda-connect-stress/scripts/lib/.gitkeep
git add labs/redis-redpanda-connect-stress/scripts/lib/tier-defs.sh
git commit -m "redis-redpanda-connect-stress: tier definitions and SLOs"
```

---

## Task 21: scripts/chaos/kill-connect-sink.sh

**Files:**
- Create: `labs/redis-redpanda-connect-stress/scripts/chaos/kill-connect-sink.sh`

- [ ] **Step 1: Write the file**

Write `labs/redis-redpanda-connect-stress/scripts/chaos/kill-connect-sink.sh`:
```bash
#!/usr/bin/env bash
# Stops connect-sink for DOWN_S seconds, then restarts it.
# Usage: kill-connect-sink.sh [DOWN_S]
set -euo pipefail

DOWN_S="${1:-8}"
CONTAINER="rrcs-connect-sink"

echo "[chaos] stopping ${CONTAINER} for ${DOWN_S}s"
docker stop "${CONTAINER}" >/dev/null
sleep "${DOWN_S}"
echo "[chaos] starting ${CONTAINER}"
docker start "${CONTAINER}" >/dev/null
echo "[chaos] done"
```

- [ ] **Step 2: Make executable, syntax check**

Run:
```bash
chmod +x labs/redis-redpanda-connect-stress/scripts/chaos/kill-connect-sink.sh
bash -n labs/redis-redpanda-connect-stress/scripts/chaos/kill-connect-sink.sh
```
Expected: no output.

- [ ] **Step 3: Remove .gitkeep and commit**

```bash
rm labs/redis-redpanda-connect-stress/scripts/chaos/.gitkeep
git add labs/redis-redpanda-connect-stress/scripts/chaos/kill-connect-sink.sh
git commit -m "redis-redpanda-connect-stress: kill-connect-sink chaos script"
```

---

## Task 22: scripts/stress-run.sh

**Files:**
- Create: `labs/redis-redpanda-connect-stress/scripts/stress-run.sh`

Top-level harness. Parses args, iterates tiers × modes, drives the writer via collector container, prints the summary table.

- [ ] **Step 1: Write `stress-run.sh`**

Write `labs/redis-redpanda-connect-stress/scripts/stress-run.sh`:
```bash
#!/usr/bin/env bash
# Top-level stress harness. See README for usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/tier-defs.sh"

PROFILE="${PROFILE_QOS:-alo}"
TIERS=("${DEFAULT_TIERS[@]}")
MODES=("${DEFAULT_MODES[@]}")

for arg in "$@"; do
  case "$arg" in
    --tiers=*)   IFS=',' read -r -a TIERS <<< "${arg#*=}";;
    --modes=*)   IFS=',' read -r -a MODES <<< "${arg#*=}";;
    --profile=*) PROFILE="${arg#*=}";;
    -h|--help)
      cat <<EOF
Usage: $0 [--tiers=10,1000,10000] [--modes=throughput,latency,chaos] [--profile=alo|amo|eoe]

Env overrides:
  DURATION_S=30  WARMUP_S=5  DRAIN_S=10  CHAOS_DOWN_S=8
EOF
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

# Boot the lab (idempotent).
echo "[boot] starting compose services (profile=${PROFILE})"
PROFILE_QOS="${PROFILE}" docker compose up -d --wait

run_one() {
  local tier="$1" mode="$2"
  local p99_ms="${TIER_P99_MS[$tier]}"
  local rate_min_pct="${TIER_RATE_MIN_PCT[$tier]}"
  local allow_missing
  allow_missing="$(allow_missing_for_profile "${PROFILE}")"
  local chaos_args=()
  if [[ "${mode}" == "chaos" ]]; then
    # Pre-flight: refuse if jetstream is already > 200MB
    local bytes
    bytes=$(curl -fs "http://127.0.0.1:${NATS_MON_PORT:-17322}/jsz?streams=true" \
            | python3 -c 'import json,sys; d=json.load(sys.stdin);
b=0
for a in d.get("account_details",[]):
 for s in a.get("stream_detail",[]):
  if s["name"]=="APP_EVENTS": b=s["state"]["bytes"]
print(b)')
    if (( bytes > 200*1024*1024 )); then
      echo "[abort] JetStream APP_EVENTS already at ${bytes} bytes (>200MB). Tear down (docker compose down -v) and retry." >&2
      exit 3
    fi
    chaos_args=(--chaos-at-s="$(chaos_at_s)" --chaos-duration="${CHAOS_DOWN_S}")
    # Schedule the kill in the background timed against sustain start.
    (
      sleep "${WARMUP_S}"
      sleep "$(chaos_at_s)"
      bash "${SCRIPT_DIR}/chaos/kill-connect-sink.sh" "${CHAOS_DOWN_S}"
    ) &
    chaos_pid=$!
  fi

  echo "[run] tier=${tier} mode=${mode} profile=${PROFILE}"
  local out="reports/${tier}-${mode}-${PROFILE}.json"
  PROFILE_QOS="${PROFILE}" docker compose --profile tools run --rm \
    -v "${LAB_DIR}/reports:/reports" \
    collector \
      --tier="${tier}" --mode="${mode}" --profile="${PROFILE}" \
      --duration="${DURATION_S}s" --warmup="${WARMUP_S}s" --drain="${DRAIN_S}s" \
      --out="/reports/${tier}-${mode}-${PROFILE}.json" \
      --slo-rate-pct="${rate_min_pct}" --slo-p99-ms="${p99_ms}" \
      --slo-allow-missing="${allow_missing}" \
      "${chaos_args[@]}" || true

  if [[ "${mode}" == "chaos" ]]; then
    wait "${chaos_pid}" 2>/dev/null || true
  fi
}

mkdir -p reports

for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    run_one "${tier}" "${mode}"
  done
done

# Render summary table.
echo
printf "%-9s %-12s %-15s %-9s %-9s %s\n" "tier" "mode" "rate_achieved" "missing" "p99 ms" "verdict"
printf -- "---------------------------------------------------------------------\n"
all_pass=true
for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    f="reports/${tier}-${mode}-${PROFILE}.json"
    [[ -f "$f" ]] || { printf "%-9s %-12s %-15s %-9s %-9s %s\n" "$tier" "$mode" "-" "-" "-" "MISSING"; all_pass=false; continue; }
    python3 - "$f" "$tier" "$mode" <<'PY'
import json,sys
path, tier, mode = sys.argv[1], sys.argv[2], sys.argv[3]
r = json.load(open(path))
ach = r.get("rate_achieved_avg", 0)
miss = r.get("missing", 0)
p99 = r.get("latency_ms", {}).get("p99", 0)
verdict = "PASS" if r.get("verdict", {}).get("pass") else "FAIL"
print(f"{tier:<9} {mode:<12} {ach:6.1f}/{tier:<8} {miss:<9} {p99:<9.1f} {verdict}")
PY
    py_rc=$?
    if [[ $py_rc -ne 0 ]]; then all_pass=false; fi
    pass=$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1]))["verdict"]["pass"] else 0)' "$f" 2>/dev/null || echo 0)
    [[ "$pass" == "1" ]] || all_pass=false
  done
done
printf -- "---------------------------------------------------------------------\n"

# Auto teardown for full-matrix run (all defaults, no args).
if [[ $# -eq 0 ]]; then
  echo "[teardown] docker compose down -v"
  docker compose down -v
fi

if $all_pass; then
  exit 0
fi
exit 1
```

- [ ] **Step 2: Make executable, syntax check**

Run:
```bash
chmod +x labs/redis-redpanda-connect-stress/scripts/stress-run.sh
bash -n labs/redis-redpanda-connect-stress/scripts/stress-run.sh
```
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/scripts/stress-run.sh
git commit -m "redis-redpanda-connect-stress: stress-run harness"
```

---

## Task 23: README.md

**Files:**
- Create: `labs/redis-redpanda-connect-stress/README.md`

- [ ] **Step 1: Write the README**

Write `labs/redis-redpanda-connect-stress/README.md`:
````markdown
# redis-redpanda-connect-stress

Stress-test harness for the Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis pipeline. Forked from [`../redis-redpanda-qos-resilience/`](../redis-redpanda-qos-resilience/); both labs can run side by side.

## What this demonstrates

Three QoS-aware behaviors at three throughput tiers (10, 1 000, 10 000 msg/s):

1. **Throughput** — pipeline sustains target rate end-to-end.
2. **Latency** — e2e p99 stays within a tier-specific SLO (200 ms / 1 s / 5 s).
3. **Chaos resilience** — a mid-run `connect-sink` kill does not violate QoS (zero loss under ALO/EOE; bounded loss under AMO).

See [`RESEARCH.md`](RESEARCH.md) for design rationale.

## Run it

```bash
cd labs/redis-redpanda-connect-stress
cp .env.example .env              # optional; defaults work
bash scripts/stress-run.sh        # full default matrix (3 tiers × 3 modes, alo)
```

Total time: ~7–10 min wall-clock for the full default matrix. Each per-tier run writes a JSON report to `reports/{tier}-{mode}-{profile}.json` and the harness prints a summary table at the end.

### Subset runs

```bash
# Single tier + single mode (no auto-teardown)
bash scripts/stress-run.sh --tiers=10000 --modes=chaos

# Multiple modes at one tier
bash scripts/stress-run.sh --tiers=1000 --modes=throughput,latency

# Different QoS profile
bash scripts/stress-run.sh --profile=eoe
```

### Knobs

| Env var       | Default | Effect                                        |
|---------------|---------|-----------------------------------------------|
| `DURATION_S`  | `30`    | sustain window per tier                       |
| `WARMUP_S`    | `5`     | half-rate warmup window                       |
| `DRAIN_S`     | `10`    | post-sustain drain window                     |
| `CHAOS_DOWN_S`| `8`     | how long `connect-sink` is stopped for chaos  |
| `PROFILE_QOS` | `alo`   | which Connect YAMLs are mounted               |
| `WORKERS`     | `8`     | writer goroutines                             |

## Ports (host)

| Service           | Host port | Notes                              |
|-------------------|-----------|------------------------------------|
| writer            | 17081     | `/healthz`, `/metrics`, `/rate`, `/reset` |
| redis-central     | 17379     | `redis-cli -p 17379`               |
| redis-region      | 17380     | `redis-cli -p 17380`               |
| nats (client)     | 17222     |                                    |
| nats (monitoring) | 17322     | `/jsz`, `/healthz`, `/varz`        |
| connect-source    | 17195     | `/ready`, `/metrics`               |
| connect-sink      | 17196     | `/ready`, `/metrics`               |

Coexists with `redis-multiregion-via-connect/` (15xxx) and `redis-redpanda-qos-resilience/` (16xxx).

## Resource caps

Every container has a hard CPU+memory limit; total ceiling is ~12.5 CPU and ~4.4 GiB RAM. On a 32-core / 122 GiB host this is <40% CPU and <4% RAM. Lower the caps in `docker-compose.yml` if running on a weaker host — but doing so may invalidate the published SLOs.

## Verifying the lab

```bash
# 1. Boot smoke
docker compose up -d --wait

# 2. Sanity tier
bash scripts/stress-run.sh --tiers=10 --modes=throughput

# 3. Mid tier with latency check
bash scripts/stress-run.sh --tiers=1000 --modes=throughput,latency

# 4. Full matrix
bash scripts/stress-run.sh
```

During the 10 k chaos run, in another shell, `uptime` should show 1-min load average < 16 on a 32-core host — confirming CPU caps are honored.

## Useful checks (between runs)

```bash
# Stream lengths
redis-cli -p 17379 XLEN app.events
redis-cli -p 17380 XLEN region-events

# JetStream
docker exec rrcs-nats nats stream info APP_EVENTS

# Writer live state
curl -s http://localhost:17081/metrics
curl -s -X POST -d '{"rate":0}' -H 'content-type: application/json' http://localhost:17081/rate
```

## Tear down

```bash
docker compose down -v
```

## Further reading

- [`RESEARCH.md`](RESEARCH.md) — design rationale, what stress proves, links to the design spec.
- [`../redis-redpanda-qos-resilience/`](../redis-redpanda-qos-resilience/) — the parent lab (per-key visibility, no stress).
- Design spec: `docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md`.
````

- [ ] **Step 2: Commit**

```bash
git add labs/redis-redpanda-connect-stress/README.md
git commit -m "redis-redpanda-connect-stress: README"
```

---

## Task 24: RESEARCH.md

**Files:**
- Create: `labs/redis-redpanda-connect-stress/RESEARCH.md`

- [ ] **Step 1: Write the RESEARCH.md**

Write `labs/redis-redpanda-connect-stress/RESEARCH.md`:
````markdown
# RESEARCH — redis-redpanda-connect-stress

## What stress proves

This lab demonstrates two things about Redpanda Connect that the parent `redis-redpanda-qos-resilience` lab cannot:

1. **Connect sustains real throughput.** The parent lab runs at 1 msg/s — enough to observe QoS semantics in human time, but not enough to surface throughput, batching, or backpressure behavior. This lab pushes 10 / 1 000 / 10 000 msg/s and verifies the pipeline keeps up.
2. **QoS guarantees hold under load.** The same chaos drill the parent uses (kill `connect-sink` for ~8 s) is run at every tier — including 10 k msg/s. At that rate, ~80 000 messages back up in JetStream during the outage. The lab verifies they all reach `region-events` after recovery (under ALO/EOE) within a bounded latency.

## Why a fork, not an extension

- The parent's WebSocket dashboard, per-key keyspace notifications, and last-value-per-key model all break at high throughput. Stripping them would gut the parent lab; forking lets each lab stay true to its purpose.
- The parent runs unbounded; this lab caps Redis streams, JetStream bytes, and every container's CPU+memory so a stress run cannot stutter the host.

## Why a wide key space + monotonic seq

At 10 k msg/s, the parent's 9-cycling-keys model results in ~1 111 writes/s per key — pure last-write-wins churn at Redis with no observability value. Wide key space (100 000 distinct keys) ensures no key is hammered; verification shifts from per-key last-value to **count match + sampled e2e latency**.

## Why live `POST /rate` instead of writer recreate

Recreating the writer container between tiers takes ~5 s × 9 = ~45 s of wasted wall-clock per matrix run, and the reconnect storm can interfere with the previous tier's drain (which would corrupt counts). A live HTTP rate endpoint lets the harness flip targets in <100 ms with zero connection churn.

## Why a one-shot collector instead of a live dashboard

Two reasons:

1. **Sampling rate**: at 10 k msg/s, a WebSocket-driven UI would either drop frames or flood the browser. The collector samples at 1 Hz — fast enough to catch backpressure, slow enough to never become the bottleneck.
2. **Reproducibility**: post-run JSON reports are diffable and storable. A live dashboard is a moment in time; a JSON file is a permanent artifact.

## Why `MAXLEN ~` and `--max-bytes`

A 30 s run at 10 k msg/s produces ~300 k messages × ~300 bytes = ~90 MB in Redis and ~120 MB in NATS. Across 9 runs that compounds. `XADD ... MAXLEN ~ 100000` and JetStream `--max-bytes=256MB` bound the storage so a runaway run can't fill the disk or push the host into swap.

## Verdict logic in one sentence

A run passes iff: achieved rate ≥ `slo.rate_min_pct × target`, missing messages = 0 (unless profile = AMO), and (for latency/chaos modes) p99 latency ≤ tier SLO.

## Pointers

- Design spec: [`../../docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md`](../../docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md)
- Parent lab RESEARCH: [`../redis-redpanda-qos-resilience/RESEARCH.md`](../redis-redpanda-qos-resilience/RESEARCH.md)
- Production architecture deep-dive that informed both labs: [`../../redis-redpanda-design-ptr/research.md`](../../redis-redpanda-design-ptr/research.md)
- Redpanda Connect docs: <https://docs.redpanda.com/redpanda-connect/about/>
- NATS JetStream concepts: <https://docs.nats.io/nats-concepts/jetstream>
- HDR Histogram: <https://github.com/HdrHistogram/hdrhistogram-go>
````

- [ ] **Step 2: Commit**

```bash
git add labs/redis-redpanda-connect-stress/RESEARCH.md
git commit -m "redis-redpanda-connect-stress: RESEARCH design rationale"
```

---

## Task 25: Hand-run smoke verification

**Files:** none (verification only)

Per spec §10. These are hand-run sanity checks confirming the whole lab boots and produces sensible output. They are documented in `README.md` but executed only by the developer / agent finishing this plan.

- [ ] **Step 1: Boot smoke**

Run:
```bash
cd labs/redis-redpanda-connect-stress
docker compose up -d --wait
```
Expected: every service health-checks green within ~30 s. `docker compose ps` shows `healthy` for redis-central, redis-region, nats, connect-source, connect-sink, writer.

If a healthcheck fails, inspect with `docker compose logs <service> --tail=50`.

- [ ] **Step 2: Sanity-tier run (≥1 PASS verdict)**

Run:
```bash
bash scripts/stress-run.sh --tiers=10 --modes=throughput
```
Expected: completes in ~50 s; summary table shows one row with `verdict=PASS`. `reports/10-throughput-alo.json` exists and contains:
- `rate_achieved_avg` close to 10
- `missing == 0`
- `latency_ms.p99` < 500 ms

- [ ] **Step 3: Mid-tier with latency check**

Run:
```bash
bash scripts/stress-run.sh --tiers=1000 --modes=throughput,latency
```
Expected: two rows, both `PASS`. `latency_ms.p99` in the `latency` JSON < 1 000 ms.

- [ ] **Step 4: Host stability spot check during 10 k chaos**

In one shell:
```bash
bash scripts/stress-run.sh --tiers=10000 --modes=chaos
```

In another shell during the run:
```bash
uptime
```
Expected: 1-min load average remains < 16 on a 32-core host. If it climbs above that, the resource caps are not being honored (Compose v2 sometimes silently ignores `deploy.resources.limits` on older versions — fix by upgrading Compose or moving limits under top-level `resources:` keys).

- [ ] **Step 5: Full matrix**

Run:
```bash
docker compose down -v        # clean slate
bash scripts/stress-run.sh
```
Expected: total wall-clock ≤ 10 min; nine rows in summary table; harness auto-teardown at end (`docker compose down -v` printed before exit). Exit code 0 if every verdict is PASS; non-zero otherwise.

- [ ] **Step 6: Final commit (if any logs / minor README tweaks emerged from verification)**

If any small adjustments were needed (e.g. README typo, missing field), commit them with:
```bash
git add labs/redis-redpanda-connect-stress/
git commit -m "redis-redpanda-connect-stress: smoke-verification cleanup"
```

If nothing changed, skip this step — the lab is complete.

---

## Self-review notes

The plan covers every spec section:

- §1 Goal → all tasks
- §2 Non-goals → Task 18 (no dashboard service), Task 4–8 (count-based verify, no per-key)
- §3 Directory layout → Task 1, file map at top of this plan
- §4 Architecture → Tasks 6, 16, 17 (writer→Redis→Connect→NATS→Connect→Redis flow); Task 18 wires the services together
- §5 Writer → Tasks 3–8
- §6 Collector → Tasks 9–17
- §6.6 Verdict logic → Task 11
- §7 Harness → Tasks 20–22
- §8 Resource governance → Task 18 (every service has `deploy.resources.limits`)
- §9 Ports → Task 18 (all 17xxx)
- §10 Verifying the lab → Task 25
- §11 Implementation skill → noted in header; tasks follow research-lab conventions
- §12 Out of scope → not implemented (correct)

No placeholders, no `TBD`, no "implement similar to…" references. All code blocks are complete. Method names checked for consistency across tasks: `NewPayload`/`Payload.JSON()`, `Limiter.Set`/`Current`/`Burst`/`WaitN`, `Counters.Sent`/`Errors`/`Inflight`/`Reset`, `Worker.Run`, `Server.Register`, `NewLatencyTracker`/`RecordAt`/`Summary`, `LatencySummary`, `ComputeVerdict`, `VerdictInput`/`Verdict`/`SLO`, `Report` with nested types, `NewStreamClient`/`XLen`/`Trim`/`XRangeSinceID`, `scrapePromMetrics`/`PostRate`/`PostReset`, `ScrapeJSZ`/`NATSSnap`, `Sampler`/`Snapshot`/`Tick`/`Init`, `Run`/`RunConfig`/`buildReport`. All consistent.

One subtle item: Task 17's `buildReport` references `last.WriterMetrics["stress_writer_sent_total"]`, `input_received`, `output_sent` — these names match what `scrapePromMetrics` will read from the writer's `/metrics` (Task 7) and from Redpanda Connect's standard Prom output. Connect emits `input_received` / `output_sent` / `output_error` per Connect 4.x docs.
