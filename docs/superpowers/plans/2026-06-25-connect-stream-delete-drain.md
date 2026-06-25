# Connect Stream-Delete Drain Lab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained docker-compose lab proving that when `DELETE /streams/<id>` tears down a Redpanda Connect streams-mode pipeline mid-flight, no message is acked-without-apply (lost).

**Architecture:** A Go `controller` drives NATS JetStream + one Redpanda Connect (streams mode) + Redis. It seeds a pull consumer, publishes N distinct keyed messages, POSTs a pipeline that `SET kv:<i>`/`INCR applied:<i>` after a per-message `sleep`, fires `DELETE /streams` while a cohort is in-flight, re-POSTs a fresh stream to drain the remainder, then reconciles the `applied:*` ledger against `1..N` and the consumer's final ack state into a PASS/FAIL verdict.

**Tech Stack:** Go 1.25, `nats.go` + `nats.go/jetstream`, `redis/go-redis/v9`, `stretchr/testify`; docker-compose; Redpanda Connect `hpdevelop/connect:4.92.0-claudefix`; `nats:2.10-alpine`; `redis:7.4-alpine`.

**Spec:** `docs/superpowers/specs/2026-06-25-connect-stream-delete-drain-design.md`
**Research:** `labs/connect-stream-delete-drain/RESEARCH.md`

---

## File Structure

```
labs/connect-stream-delete-drain/
  docker-compose.yml              # 4 services, named net, healthchecks, ports ≥15000
  .env.example                    # every knob documented
  README.md
  RESEARCH.md                     # already written
  connect/
    observability.yaml            # streams-mode boot config (http/logger/metrics)
    pipeline.tmpl.yaml            # stream config template, __SLEEP_MS__/__THREADS__ placeholders
  controller/
    go.mod  go.sum
    Dockerfile
    main.go                       # Run(): orchestration + verdict print + exit code
    config.go    config_test.go   # env → Config (pure)
    render.go    render_test.go   # template substitution (pure)
    reconcile.go reconcile_test.go# ledger+consumer → Verdict (pure, CORE)
    arm.go       arm_test.go      # DELETE arm predicate (pure)
    connectrest.go connectrest_test.go # Connect streams REST client (httptest)
    jetstream.go                  # nats/jetstream client (integration)
    sink.go                       # redis ledger reader (integration)
  scripts/
    smoke-test.sh                 # bring up stack, run controller, assert verdict.pass
```

The four pure/httptest units (`config`, `render`, `reconcile`, `arm`, `connectrest`) are unit-tested. The two network clients (`jetstream`, `sink`) and `main` orchestration are thin and validated end-to-end by `smoke-test.sh` — they are intentionally not mock-tested.

---

## Task 1: Scaffold the lab skeleton

**Files:**
- Create: `labs/connect-stream-delete-drain/controller/go.mod`
- Create: `labs/connect-stream-delete-drain/connect/observability.yaml`
- Create: `labs/connect-stream-delete-drain/connect/pipeline.tmpl.yaml`
- Create: `labs/connect-stream-delete-drain/.env.example`
- Create: `labs/connect-stream-delete-drain/docker-compose.yml`
- Create: `labs/connect-stream-delete-drain/controller/Dockerfile`

- [ ] **Step 1: Create the controller Go module**

`controller/go.mod`:

```
module connect-stream-delete-drain/controller

go 1.25.0

require (
	github.com/nats-io/nats.go v1.38.0
	github.com/redis/go-redis/v9 v9.19.0
	github.com/stretchr/testify v1.11.1
)
```

- [ ] **Step 2: Create the Connect streams boot config**

`connect/observability.yaml` (identical shape to the parent lab — REST API on 4195):

```yaml
http:
  address: 0.0.0.0:4195
  enabled: true
logger:
  level: INFO
  format: json
  add_timestamp: true
metrics:
  prometheus:
    use_histogram_timing: true
```

- [ ] **Step 3: Create the pipeline template** (`__SLEEP_MS__` / `__THREADS__` / `__MAX_ACK_PENDING__` substituted by the controller — the streams REST API does NOT expand env vars)

`connect/pipeline.tmpl.yaml`:

```yaml
input:
  nats_jetstream:
    urls: ["nats://nats:4222"]
    stream: CDC
    durable: sink
    bind: true
    # max_ack_pending on a bind:true pull consumer is likely inert (server-side
    # consumer owns the flow-control bound), but is passed through for symmetry
    # with the consumer config and to document the intent.
    max_ack_pending: __MAX_ACK_PENDING__
pipeline:
  threads: __THREADS__
  processors:
    # Stash i into metadata BEFORE any redis processor: the redis processor
    # REPLACES message content with the Redis reply, so after the SET below
    # `this` is "OK" and i is gone. Every later write reads meta("i").
    - mapping: 'meta i = this.i.string()'
    - sleep:
        duration: __SLEEP_MS__ms
    - redis:
        url: redis://redis:6379
        command: set
        args_mapping: 'root = [ "kv:" + meta("i"), meta("i") ]'
    - redis:
        url: redis://redis:6379
        command: incr
        args_mapping: 'root = [ "applied:" + meta("i") ]'
output:
  reject_errored:
    drop: {}
```

- [ ] **Step 4: Create `.env.example`** (every knob documented)

```bash
# Profile selector: deterministic (wide sleep, precise cohort) | throughput (firehose)
PROFILE=deterministic
# Number of distinct messages (keys kv:1..kv:N)
MSG_COUNT=60
# Publish rate, msgs/s; 0 = burst as fast as possible
PUBLISH_RATE=0
# Per-message pipeline sleep (ms) = the in-flight window
SLEEP_MS=200
# Connect pipeline.threads (consumer concurrency)
PIPELINE_THREADS=1
# JetStream consumer ack_wait; un-acked in-flight msgs redeliver after this
ACK_WAIT=5s
# deterministic: fire DELETE after this fraction of N is applied
ARM_FRACTION=0.3
# throughput: fire DELETE once at least this many messages have been dispatched
# from NATS into Connect (i.e. NATS undelivered backlog has dropped by ARM_INFLIGHT).
# Condition: NumPending <= N - ARM_INFLIGHT && num_ack_pending >= MIN_INFLIGHT.
ARM_INFLIGHT=200
# Minimum messages that must be simultaneously in-flight inside Connect
# (num_ack_pending >= MIN_INFLIGHT) — bounded by PIPELINE_THREADS — for a DELETE
# to count as landing mid-flight. Default 1 works for deterministic (threads=1).
# For throughput with PIPELINE_THREADS=8, recommend MIN_INFLIGHT=4 so the DELETE
# provably lands over a real multi-message cohort, not a transient single message.
MIN_INFLIGHT=1
# JetStream consumer max_ack_pending bound
MAX_ACK_PENDING=1000
# Service addresses (compose-internal DNS)
NATS_URL=nats://nats:4222
REDIS_ADDR=redis:6379
CONNECT_ADDR=http://connect:4195
```

- [ ] **Step 5: Create `docker-compose.yml`**

```yaml
name: connect-stream-delete-drain
networks:
  lab:
    driver: bridge
services:
  nats:
    image: nats:2.10-alpine
    command: ["-js", "-m", "8222"]
    ports: ["15422:4222"]
    networks: [lab]
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8222/healthz"]
      interval: 2s
      timeout: 3s
      retries: 40
  redis:
    image: redis:7.4-alpine
    command: ["redis-server", "--save", "", "--appendonly", "no"]
    ports: ["16379:6379"]
    networks: [lab]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 3s
      retries: 40
  connect:
    image: hpdevelop/connect:4.92.0-claudefix
    command: ["streams", "-o", "/etc/connect/observability.yaml"]
    volumes:
      - ./connect/observability.yaml:/etc/connect/observability.yaml:ro
    ports: ["14195:4195"]
    networks: [lab]
    healthcheck:
      # /ready returns 200 even with zero streams. If the image lacks wget,
      # Task 12 swaps this for `condition: service_started` — the controller's
      # own waitConnectReady() poll is the authoritative gate either way.
      test: ["CMD-SHELL", "wget -qO- http://localhost:4195/ready || exit 1"]
      interval: 2s
      timeout: 3s
      retries: 40
  controller:
    build: ./controller
    env_file: [.env]
    networks: [lab]
    ports: ["18080:18080"]
    depends_on:
      nats: { condition: service_healthy }
      redis: { condition: service_healthy }
      connect: { condition: service_healthy }
    volumes:
      - ./connect/pipeline.tmpl.yaml:/etc/connect/pipeline.tmpl.yaml:ro
```

- [ ] **Step 6: Create the controller `Dockerfile`** (multi-stage, non-root)

```dockerfile
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/controller .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/controller /controller
USER nonroot:nonroot
ENTRYPOINT ["/controller"]
```

- [ ] **Step 7: Commit**

```bash
cd labs/connect-stream-delete-drain
git add controller/go.mod connect/ .env.example docker-compose.yml controller/Dockerfile
git commit -m "feat(connect-drain): scaffold compose stack + connect configs"
```

---

## Task 2: Config from environment (pure)

**Files:**
- Create: `controller/config.go`
- Test: `controller/config_test.go`

- [ ] **Step 1: Write the failing test**

`controller/config_test.go`:

```go
package main

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestLoadConfigDefaults(t *testing.T) {
	cfg := LoadConfig(func(string) string { return "" })
	require.Equal(t, "deterministic", cfg.Profile)
	require.Equal(t, 60, cfg.MsgCount)
	require.Equal(t, 200, cfg.SleepMS)
	require.Equal(t, 1, cfg.PipelineThreads)
	require.Equal(t, 5*time.Second, cfg.AckWait)
	require.InDelta(t, 0.3, cfg.ArmFraction, 1e-9)
	require.Equal(t, "source_leg", cfg.StreamID)
}

func TestLoadConfigOverrides(t *testing.T) {
	env := map[string]string{
		"PROFILE": "throughput", "MSG_COUNT": "20000", "SLEEP_MS": "25",
		"PIPELINE_THREADS": "8", "ACK_WAIT": "7s", "ARM_INFLIGHT": "250",
		"PUBLISH_RATE": "5000", "MAX_ACK_PENDING": "2000",
	}
	cfg := LoadConfig(func(k string) string { return env[k] })
	require.Equal(t, "throughput", cfg.Profile)
	require.Equal(t, 20000, cfg.MsgCount)
	require.Equal(t, 25, cfg.SleepMS)
	require.Equal(t, 8, cfg.PipelineThreads)
	require.Equal(t, 7*time.Second, cfg.AckWait)
	require.Equal(t, 250, cfg.ArmInflight)
	require.Equal(t, 5000, cfg.PublishRate)
	require.Equal(t, 2000, cfg.MaxAckPending)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd controller && go test ./... -run TestLoadConfig`
Expected: FAIL — `undefined: LoadConfig`.

- [ ] **Step 3: Write minimal implementation**

`controller/config.go`:

```go
package main

import (
	"strconv"
	"time"
)

type Config struct {
	Profile         string
	MsgCount        int
	PublishRate     int
	SleepMS         int
	PipelineThreads int
	AckWait         time.Duration
	ArmFraction     float64
	ArmInflight     int
	MaxAckPending   int
	// MinInflight is the minimum number of messages that must be simultaneously
	// in-flight inside Connect (num_ack_pending) for a DELETE to count as landing
	// mid-flight. Bounded by PIPELINE_THREADS. Default 1; raise to e.g. 4 with
	// PIPELINE_THREADS=8 for a stronger throughput proof.
	MinInflight int
	NATSURL     string
	RedisAddr   string
	ConnectAddr string
	StreamID    string
	HealthAddr  string
}

func LoadConfig(get func(string) string) Config {
	return Config{
		Profile:         str(get, "PROFILE", "deterministic"),
		MsgCount:        num(get, "MSG_COUNT", 60),
		PublishRate:     num(get, "PUBLISH_RATE", 0),
		SleepMS:         num(get, "SLEEP_MS", 200),
		PipelineThreads: num(get, "PIPELINE_THREADS", 1),
		AckWait:         dur(get, "ACK_WAIT", 5*time.Second),
		ArmFraction:     flt(get, "ARM_FRACTION", 0.3),
		ArmInflight:     num(get, "ARM_INFLIGHT", 200),
		MaxAckPending:   num(get, "MAX_ACK_PENDING", 1000),
		MinInflight:     num(get, "MIN_INFLIGHT", 1),
		NATSURL:         str(get, "NATS_URL", "nats://nats:4222"),
		RedisAddr:       str(get, "REDIS_ADDR", "redis:6379"),
		ConnectAddr:     str(get, "CONNECT_ADDR", "http://connect:4195"),
		StreamID:        str(get, "STREAM_ID", "source_leg"),
		HealthAddr:      str(get, "HEALTH_ADDR", ":18080"),
	}
}

func str(get func(string) string, k, def string) string {
	if v := get(k); v != "" {
		return v
	}
	return def
}
func num(get func(string) string, k string, def int) int {
	if v := get(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
func flt(get func(string) string, k string, def float64) float64 {
	if v := get(k); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}
func dur(get func(string) string, k string, def time.Duration) time.Duration {
	if v := get(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd controller && go test ./... -run TestLoadConfig`
Expected: PASS (run `go mod tidy` first if deps not yet downloaded).

- [ ] **Step 5: Commit**

```bash
git add controller/config.go controller/config_test.go controller/go.sum
git commit -m "feat(connect-drain): controller env config"
```

---

## Task 3: Pipeline template rendering (pure)

**Files:**
- Create: `controller/render.go`
- Test: `controller/render_test.go`

- [ ] **Step 1: Write the failing test**

`controller/render_test.go`:

```go
package main

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRenderPipeline(t *testing.T) {
	tmpl := "threads: __THREADS__\nduration: __SLEEP_MS__ms\nmax_ack_pending: __MAX_ACK_PENDING__\n"
	out := RenderPipeline(tmpl, 200, 4, 1000)
	require.Equal(t, "threads: 4\nduration: 200ms\nmax_ack_pending: 1000\n", out)
	require.False(t, strings.Contains(out, "__"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd controller && go test ./... -run TestRenderPipeline`
Expected: FAIL — `undefined: RenderPipeline`.

- [ ] **Step 3: Write minimal implementation**

`controller/render.go`:

```go
package main

import (
	"strconv"
	"strings"
)

// RenderPipeline substitutes the literal __SLEEP_MS__ / __THREADS__ / __MAX_ACK_PENDING__
// placeholders. We substitute in the controller (not via env interpolation) because the
// streams REST API does NOT expand environment variables in POSTed configs.
func RenderPipeline(tmpl string, sleepMS, threads, maxAckPending int) string {
	return strings.NewReplacer(
		"__SLEEP_MS__", itoa(sleepMS),
		"__THREADS__", itoa(threads),
		"__MAX_ACK_PENDING__", itoa(maxAckPending),
	).Replace(tmpl)
}

func itoa(n int) string { return strconv.Itoa(n) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd controller && go test ./... -run TestRenderPipeline`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add controller/render.go controller/render_test.go
git commit -m "feat(connect-drain): pipeline template rendering"
```

---

## Task 4: Reconcile ledger → Verdict (pure, CORE)

**Files:**
- Create: `controller/reconcile.go`
- Test: `controller/reconcile_test.go`

- [ ] **Step 1: Write the failing test**

`controller/reconcile_test.go`:

```go
package main

import (
	"testing"

	"github.com/stretchr/testify/require"
)

// all keys applied exactly once, consumer drained, DELETE landed mid-flight → PASS
func TestReconcileCleanDrain(t *testing.T) {
	applied := map[int]int{1: 1, 2: 1, 3: 1}
	v := Reconcile("deterministic", 3, 2, applied, ConsumerState{0, 0})
	require.True(t, v.Verdict.Pass)
	require.Empty(t, v.Lost)
	require.Equal(t, 0, v.DupCount)
	require.True(t, v.Drained)
}

// some keys applied twice (redelivery) → still PASS, dup_count counted
func TestReconcileDuplicatesPass(t *testing.T) {
	applied := map[int]int{1: 1, 2: 2, 3: 2}
	v := Reconcile("deterministic", 3, 2, applied, ConsumerState{0, 0})
	require.True(t, v.Verdict.Pass)
	require.Equal(t, 2, v.DupCount)
}

// a missing key with a drained consumer = acked-but-not-applied → FAIL, listed
func TestReconcileLossFails(t *testing.T) {
	applied := map[int]int{1: 1, 2: 0, 3: 1}
	v := Reconcile("deterministic", 3, 2, applied, ConsumerState{0, 0})
	require.False(t, v.Verdict.Pass)
	require.Equal(t, []int{2}, v.Lost)
}

// consumer not drained → FAIL (cannot conclude conservation)
func TestReconcileNotDrainedFails(t *testing.T) {
	applied := map[int]int{1: 1, 2: 1, 3: 1}
	v := Reconcile("deterministic", 3, 2, applied, ConsumerState{NumPending: 1})
	require.False(t, v.Verdict.Pass)
	require.False(t, v.Drained)
}

// DELETE never landed mid-flight → inconclusive → FAIL
func TestReconcileInconclusiveFails(t *testing.T) {
	applied := map[int]int{1: 1, 2: 1, 3: 1}
	v := Reconcile("deterministic", 3, 0, applied, ConsumerState{0, 0})
	require.False(t, v.Verdict.Pass)
}

// Lost serializes as [] not null when empty
func TestReconcileLostNeverNil(t *testing.T) {
	v := Reconcile("deterministic", 1, 1, map[int]int{1: 1}, ConsumerState{0, 0})
	require.NotNil(t, v.Lost)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd controller && go test ./... -run TestReconcile`
Expected: FAIL — `undefined: Reconcile` / `ConsumerState`.

- [ ] **Step 3: Write minimal implementation**

`controller/reconcile.go`:

```go
package main

import "sort"

// ConsumerState is the JetStream pull-consumer's ack oracle at quiescence.
type ConsumerState struct {
	NumPending    uint64 // messages not yet delivered
	NumAckPending int    // delivered-but-not-acked (in-flight)
}

type Verdict struct {
	Profile          string `json:"profile"`
	N                int    `json:"n"`
	InflightAtDelete int    `json:"inflight_at_delete"`
	Lost             []int  `json:"lost"`
	DupCount         int    `json:"dup_count"`
	Drained          bool   `json:"drained"`
	Verdict          struct {
		Pass bool `json:"pass"`
	} `json:"verdict"`
}

// Reconcile classifies every index 1..n from the applied-counter ledger.
//   applied[i] == 0 (drained)  -> LOST (acked-without-apply): the failure
//   applied[i] >= 2            -> redelivered duplicate (safe, counted)
// PASS requires: zero lost AND consumer fully drained AND DELETE landed mid-flight.
func Reconcile(profile string, n, inflightAtDelete int, applied map[int]int, cs ConsumerState) Verdict {
	lost := make([]int, 0)
	dup := 0
	for i := 1; i <= n; i++ {
		c := applied[i]
		if c == 0 {
			lost = append(lost, i)
		} else if c > 1 {
			dup += c - 1
		}
	}
	sort.Ints(lost)

	drained := cs.NumPending == 0 && cs.NumAckPending == 0
	v := Verdict{
		Profile:          profile,
		N:                n,
		InflightAtDelete: inflightAtDelete,
		Lost:             lost,
		DupCount:         dup,
		Drained:          drained,
	}
	v.Verdict.Pass = len(lost) == 0 && drained && inflightAtDelete > 0
	return v
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd controller && go test ./... -run TestReconcile`
Expected: PASS (6 cases).

- [ ] **Step 5: Commit**

```bash
git add controller/reconcile.go controller/reconcile_test.go
git commit -m "feat(connect-drain): reconcile ledger into PASS/FAIL verdict"
```

---

## Task 5: DELETE arm predicate (pure)

**Files:**
- Create: `controller/arm.go`
- Test: `controller/arm_test.go`

- [ ] **Step 1: Write the failing test**

`controller/arm_test.go`:

```go
package main

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestArmedDeterministic(t *testing.T) {
	in := ArmInput{Profile: "deterministic", N: 100, ArmFraction: 0.3}
	in.AppliedDistinct = 29
	require.False(t, Armed(in))
	// fraction met but no in-flight cohort: must not fire (inconclusive guard)
	in.AppliedDistinct = 30
	require.False(t, Armed(in))
	// fraction met AND in-flight cohort present: fires
	in.NumAckPending = 1
	require.True(t, Armed(in))
}

func TestArmedThroughput(t *testing.T) {
	// ARM_INFLIGHT=200, N=1000: fires when NumPending <= 800 (>=200 dispatched)
	// and at least one message is in-flight (NumAckPending > 0).
	in := ArmInput{Profile: "throughput", ArmInflight: 200, N: 1000}

	// Not enough dispatched yet (only 100 delivered so pending=900>800)
	in.NumPending = 900
	in.NumAckPending = 5
	require.False(t, Armed(in))

	// Enough dispatched (pending=800 == N-ArmInflight) but nothing in-flight: don't fire
	in.NumPending = 800
	in.NumAckPending = 0
	require.False(t, Armed(in))

	// Enough dispatched and work is in-flight: fires
	in.NumPending = 800
	in.NumAckPending = 5
	require.True(t, Armed(in))

	// Far into processing, still fires as long as something is in-flight
	in.NumPending = 0
	in.NumAckPending = 3
	require.True(t, Armed(in))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd controller && go test ./... -run TestArmed`
Expected: FAIL — `undefined: ArmInput` / `Armed`.

- [ ] **Step 3: Write minimal implementation**

`controller/arm.go`:

```go
package main

// ArmInput is the per-poll snapshot used to decide when to fire the DELETE.
type ArmInput struct {
	Profile         string
	N               int
	ArmFraction     float64
	ArmInflight     int
	// MinInflight is the minimum num_ack_pending required for the arm condition to
	// fire. Default 1. Raise (e.g. 4) with PIPELINE_THREADS=8 to require a real
	// multi-message cohort simultaneously in-flight inside Connect.
	MinInflight     int
	AppliedDistinct int // count of distinct kv:* keys applied so far
	NumAckPending   int // consumer delivered-but-not-acked
	NumPending      int // messages not yet delivered to consumer (NATS backlog)
}

// Armed reports whether a meaningful in-flight cohort exists to DELETE into.
//
// For throughput: fires when the undelivered NATS backlog (NumPending) drops below
// N-ArmInflight (at least ArmInflight messages have been handed to Connect) AND
// NumAckPending >= MinInflight (a real cohort of at least MinInflight messages is
// simultaneously inside Connect's pipeline). Using >= MinInflight instead of > 0
// proves the DELETE lands over a real cohort, not a transient single message.
//
// For deterministic: fires when a fraction of messages have been applied and at
// least MinInflight messages are simultaneously in-flight (NumAckPending >=
// MinInflight). With the default MinInflight=1 this is identical to the prior
// NumAckPending > 0 behavior.
func Armed(in ArmInput) bool {
	minInFlight := in.MinInflight
	if minInFlight < 1 {
		minInFlight = 1
	}
	if in.Profile == "throughput" {
		// NumPending counts messages NATS hasn't yet delivered. When it drops to
		// N - ArmInflight, at least ArmInflight messages have been dispatched to
		// Connect — a large cohort is mid-firehose. We also require a real cohort
		// of >= MinInflight messages inside Connect's pipeline right now.
		return in.NumPending <= in.N-in.ArmInflight && in.NumAckPending >= minInFlight
	}
	return in.NumAckPending >= minInFlight && float64(in.AppliedDistinct) >= in.ArmFraction*float64(in.N)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd controller && go test ./... -run TestArmed`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add controller/arm.go controller/arm_test.go
git commit -m "feat(connect-drain): DELETE arm predicate"
```

---

## Task 6: Connect streams REST client (httptest)

**Files:**
- Create: `controller/connectrest.go`
- Test: `controller/connectrest_test.go`

- [ ] **Step 1: Write the failing test**

`controller/connectrest_test.go`:

```go
package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestPostSendsYAMLContentType(t *testing.T) {
	got := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- r.Header.Get("Content-Type")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	c := newConnectClient(srv.URL)
	require.NoError(t, c.PostStream(context.Background(), "x", "in: {}"))
	require.Equal(t, "application/x-yaml", <-got)
}

func TestDeleteTreats404AsSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()
	require.NoError(t, newConnectClient(srv.URL).DeleteStream(context.Background(), "x"))
}

func TestPostNon2xxIsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	require.Error(t, newConnectClient(srv.URL).PostStream(context.Background(), "x", "in: {}"))
}

func TestReadyTrueOn200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/ready", r.URL.Path)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	require.True(t, newConnectClient(srv.URL).Ready(context.Background()))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd controller && go test ./... -run 'TestPost|TestDelete|TestReady'`
Expected: FAIL — `undefined: newConnectClient`.

- [ ] **Step 3: Write minimal implementation**

`controller/connectrest.go`:

```go
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"strings"
	"time"
)

type connectClient struct {
	base string
	hc   *http.Client
}

func newConnectClient(base string) *connectClient {
	return &connectClient{base: strings.TrimRight(base, "/"), hc: &http.Client{Timeout: 5 * time.Second}}
}

func (c *connectClient) PostStream(ctx context.Context, id, configYAML string) error {
	u := fmt.Sprintf("%s/streams/%s", c.base, neturl.PathEscape(id))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewBufferString(configYAML))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-yaml")
	return c.do(req)
}

func (c *connectClient) DeleteStream(ctx context.Context, id string) error {
	u := fmt.Sprintf("%s/streams/%s", c.base, neturl.PathEscape(id))
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, u, nil)
	if err != nil {
		return err
	}
	return c.do(req)
}

func (c *connectClient) Ready(ctx context.Context) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/ready", nil)
	if err != nil {
		return false
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func (c *connectClient) do(req *http.Request) error {
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if req.Method == http.MethodDelete && resp.StatusCode == http.StatusNotFound {
		return nil // idempotent: already absent
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s -> %d: %s", req.Method, req.URL.Path, resp.StatusCode, string(body))
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd controller && go test ./... -run 'TestPost|TestDelete|TestReady'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add controller/connectrest.go controller/connectrest_test.go
git commit -m "feat(connect-drain): Connect streams REST client"
```

---

## Task 7: JetStream client (integration)

**Files:**
- Create: `controller/jetstream.go`

This wraps `nats.go/jetstream`: setup (clean epoch), publish with `Nats-Msg-Id`, and consumer info polling. No unit test — exercised by the smoke test.

- [ ] **Step 1: Write the implementation**

`controller/jetstream.go`:

```go
package main

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	streamName   = "CDC"
	subject      = "cdc.kv"
	consumerName = "sink"
)

type jsClient struct {
	nc  *nats.Conn
	js  jetstream.JetStream
	con jetstream.Consumer
}

func dialJetStream(ctx context.Context, url string) (*jsClient, error) {
	nc, err := nats.Connect(url, nats.Timeout(5*time.Second), nats.MaxReconnects(-1))
	if err != nil {
		return nil, err
	}
	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, err
	}
	return &jsClient{nc: nc, js: js}, nil
}

// setup deletes any prior stream (clean epoch) then creates the stream and a
// durable pull consumer bound to a small ack_wait so un-acked msgs redeliver fast.
func (c *jsClient) setup(ctx context.Context, ackWait time.Duration, maxAckPending int) error {
	_ = c.js.DeleteStream(ctx, streamName) // ignore not-found
	st, err := c.js.CreateStream(ctx, jetstream.StreamConfig{
		Name:     streamName,
		Subjects: []string{subject},
		Storage:  jetstream.FileStorage,
	})
	if err != nil {
		return fmt.Errorf("create stream: %w", err)
	}
	con, err := st.CreateOrUpdateConsumer(ctx, jetstream.ConsumerConfig{
		Durable:       consumerName,
		FilterSubject: subject,
		AckPolicy:     jetstream.AckExplicitPolicy,
		AckWait:       ackWait,
		MaxAckPending: maxAckPending,
	})
	if err != nil {
		return fmt.Errorf("create consumer: %w", err)
	}
	c.con = con
	return nil
}

// publish emits n messages {"i":k} with header Nats-Msg-Id=k for dedup, at rate
// msgs/s (0 = burst).
func (c *jsClient) publish(ctx context.Context, n, rate int) error {
	var tick <-chan time.Time
	if rate > 0 {
		t := time.NewTicker(time.Second / time.Duration(rate))
		defer t.Stop()
		tick = t.C
	}
	for k := 1; k <= n; k++ {
		if tick != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-tick:
			}
		}
		body := []byte(fmt.Sprintf(`{"i":%d}`, k))
		if _, err := c.js.Publish(ctx, subject, body, jetstream.WithMsgID(strconv.Itoa(k))); err != nil {
			return fmt.Errorf("publish %d: %w", k, err)
		}
	}
	return nil
}

func (c *jsClient) consumerState(ctx context.Context) (ConsumerState, error) {
	info, err := c.con.Info(ctx)
	if err != nil {
		return ConsumerState{}, err
	}
	return ConsumerState{NumPending: info.NumPending, NumAckPending: info.NumAckPending}, nil
}

func (c *jsClient) close() { c.nc.Close() }
```

- [ ] **Step 2: Verify it builds**

Run: `cd controller && go build ./...`
Expected: builds clean (run `go mod tidy` to pull `nats.go`).

- [ ] **Step 3: Commit**

```bash
git add controller/jetstream.go controller/go.mod controller/go.sum
git commit -m "feat(connect-drain): JetStream setup/publish/consumer-info client"
```

---

## Task 8: Redis ledger reader (integration)

**Files:**
- Create: `controller/sink.go`

- [ ] **Step 1: Write the implementation**

`controller/sink.go`:

```go
package main

import (
	"context"
	"strconv"

	"github.com/redis/go-redis/v9"
)

type sinkReader struct{ rdb *redis.Client }

func newSinkReader(addr string) *sinkReader {
	return &sinkReader{rdb: redis.NewClient(&redis.Options{Addr: addr})}
}

// flush clears the destination so re-runs start from a clean ledger.
func (s *sinkReader) flush(ctx context.Context) error { return s.rdb.FlushDB(ctx).Err() }

// readLedger returns applied[i] = value of applied:<i> (0 if absent) for i in 1..n.
func (s *sinkReader) readLedger(ctx context.Context, n int) (map[int]int, error) {
	pipe := s.rdb.Pipeline()
	cmds := make([]*redis.StringCmd, n+1)
	for i := 1; i <= n; i++ {
		cmds[i] = pipe.Get(ctx, "applied:"+strconv.Itoa(i))
	}
	if _, err := pipe.Exec(ctx); err != nil && err != redis.Nil {
		return nil, err
	}
	out := make(map[int]int, n)
	for i := 1; i <= n; i++ {
		v, err := cmds[i].Int()
		if err == redis.Nil {
			out[i] = 0
			continue
		}
		if err != nil {
			return nil, err
		}
		out[i] = v
	}
	return out, nil
}

// distinctApplied counts keys kv:* currently present (cheap arm-progress proxy).
func (s *sinkReader) distinctApplied(ctx context.Context) (int, error) {
	var n int
	iter := s.rdb.Scan(ctx, 0, "kv:*", 1000).Iterator()
	for iter.Next(ctx) {
		n++
	}
	return n, iter.Err()
}

func (s *sinkReader) close() error { return s.rdb.Close() }
```

- [ ] **Step 2: Verify it builds**

Run: `cd controller && go build ./...`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add controller/sink.go
git commit -m "feat(connect-drain): redis ledger reader"
```

---

## Task 9: Orchestration in main.go

**Files:**
- Create: `controller/main.go`

- [ ] **Step 1: Write the implementation**

`controller/main.go`:

```go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	cfg := LoadConfig(os.Getenv)
	if err := run(cfg); err != nil {
		log.Fatalf("run: %v", err)
	}
}

func run(cfg Config) error {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	tmpl, err := os.ReadFile("/etc/connect/pipeline.tmpl.yaml")
	if err != nil {
		return fmt.Errorf("read template: %w", err)
	}
	pipeline := RenderPipeline(string(tmpl), cfg.SleepMS, cfg.PipelineThreads, cfg.MaxAckPending)

	connect := newConnectClient(cfg.ConnectAddr)
	if err := waitConnectReady(ctx, connect); err != nil {
		return err
	}
	// Clean slate: delete any leftover stream from a previous run (idempotent; 404 is OK).
	if err := connect.DeleteStream(ctx, cfg.StreamID); err != nil {
		return fmt.Errorf("pre-run cleanup: %w", err)
	}

	sink := newSinkReader(cfg.RedisAddr)
	defer sink.close()
	if err := sink.flush(ctx); err != nil {
		return fmt.Errorf("flush redis: %w", err)
	}

	js, err := dialJetStream(ctx, cfg.NATSURL)
	if err != nil {
		return err
	}
	defer js.close()
	if err := js.setup(ctx, cfg.AckWait, cfg.MaxAckPending); err != nil {
		return err
	}

	log.Printf("publishing %d messages (rate=%d)", cfg.MsgCount, cfg.PublishRate)
	if err := js.publish(ctx, cfg.MsgCount, cfg.PublishRate); err != nil {
		return err
	}

	log.Printf("POST stream %q", cfg.StreamID)
	if err := connect.PostStream(ctx, cfg.StreamID, pipeline); err != nil {
		return err
	}

	inflightAtDelete, err := armAndDelete(ctx, cfg, connect, sink, js)
	if err != nil {
		return err
	}

	log.Printf("re-POST stream %q (new leader drains remainder)", cfg.StreamID)
	if err := connect.PostStream(ctx, cfg.StreamID, pipeline); err != nil {
		return err
	}

	if err := waitQuiescent(ctx, js); err != nil {
		return err
	}

	applied, err := sink.readLedger(ctx, cfg.MsgCount)
	if err != nil {
		return err
	}
	cs, err := js.consumerState(ctx)
	if err != nil {
		return err
	}

	v := Reconcile(cfg.Profile, cfg.MsgCount, inflightAtDelete, applied, cs)
	out, _ := json.Marshal(v)
	fmt.Printf("RESULT_JSON %s\n", out)
	if !v.Verdict.Pass {
		return fmt.Errorf("VERDICT FAIL: lost=%v drained=%v inflight_at_delete=%d",
			v.Lost, v.Drained, v.InflightAtDelete)
	}
	log.Printf("VERDICT PASS: n=%d dup=%d inflight_at_delete=%d", v.N, v.DupCount, inflightAtDelete)
	return nil
}

func waitConnectReady(ctx context.Context, c *connectClient) error {
	for i := 0; i < 60; i++ {
		if c.Ready(ctx) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return fmt.Errorf("connect not ready after 60s")
}

// armAndDelete polls until the arm predicate fires, then does a SECOND confirm-poll
// after a short delay to verify the cohort is still stably parked (not draining
// away in the gap between the first poll and the DELETE reaching Connect). Only after
// both polls show NumAckPending >= MinInflight does it fire the DELETE.
//
// confirmDelay = max(20ms, min(SLEEP_MS/4, 100ms)) — long enough to detect a
// draining cohort, short enough to stay inside the sleep window.
//
// inflight_at_delete is set from the SECOND (confirm) poll — the value closest
// to the actual DELETE moment and conservative (may be slightly lower).
func armAndDelete(ctx context.Context, cfg Config, connect *connectClient, sink *sinkReader, js *jsClient) (int, error) {
	// Compute confirm-poll delay: SLEEP_MS/4, clamped to [20ms, 100ms].
	confirmDelay := time.Duration(cfg.SleepMS/4) * time.Millisecond
	if confirmDelay < 20*time.Millisecond {
		confirmDelay = 20 * time.Millisecond
	}
	if confirmDelay > 100*time.Millisecond {
		confirmDelay = 100 * time.Millisecond
	}

	deadline := time.After(2 * time.Minute)
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-deadline:
			return 0, fmt.Errorf("arm condition never met")
		case <-tick.C:
		}
		cs, err := js.consumerState(ctx)
		if err != nil {
			return 0, err
		}
		distinct, err := sink.distinctApplied(ctx)
		if err != nil {
			return 0, err
		}
		in := ArmInput{
			Profile: cfg.Profile, N: cfg.MsgCount, ArmFraction: cfg.ArmFraction,
			ArmInflight: cfg.ArmInflight, MinInflight: cfg.MinInflight,
			AppliedDistinct: distinct,
			NumAckPending:   cs.NumAckPending, NumPending: int(cs.NumPending),
		}
		if !Armed(in) {
			continue
		}

		// First poll armed. Wait confirmDelay, then confirm the cohort is still
		// stably parked (not draining away in the gap before DELETE arrives).
		log.Printf("ARMED (first poll): distinct=%d num_pending=%d num_ack_pending=%d; confirming in %s...",
			distinct, cs.NumPending, cs.NumAckPending, confirmDelay)
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-time.After(confirmDelay):
		}

		cs2, err := js.consumerState(ctx)
		if err != nil {
			return 0, err
		}
		// Build confirm input: reuse the same backlog/distinct snapshot (unchanged
		// during confirmDelay) but refresh NumAckPending/NumPending from cs2.
		in2 := in
		in2.NumAckPending = cs2.NumAckPending
		in2.NumPending = int(cs2.NumPending)
		if !Armed(in2) {
			// Cohort drained below MinInflight between first and confirm poll:
			// the sleep window closed before DELETE would land. Keep polling.
			log.Printf("CONFIRM FAILED: num_ack_pending dropped to %d (< min_inflight=%d); re-arming...",
				cs2.NumAckPending, cfg.MinInflight)
			continue
		}

		// Confirm poll still shows a parked cohort — fire DELETE immediately.
		log.Printf("ARMED (confirmed): num_ack_pending=%d (was %d) -> DELETE",
			cs2.NumAckPending, cs.NumAckPending)
		if err := connect.DeleteStream(ctx, cfg.StreamID); err != nil {
			return 0, err
		}
		// Return the SECOND poll's count: closest to the DELETE moment and
		// conservative (avoids inflating inflight_at_delete with a transient peak).
		return cs2.NumAckPending, nil
	}
}

// waitQuiescent waits for num_pending==0 && num_ack_pending==0, stable across 3
// consecutive polls (the parent lab's lesson: lag drops before the ack lands).
func waitQuiescent(ctx context.Context, js *jsClient) error {
	deadline := time.After(3 * time.Minute)
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	stable := 0
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline:
			return fmt.Errorf("never quiesced")
		case <-tick.C:
		}
		cs, err := js.consumerState(ctx)
		if err != nil {
			return err
		}
		if cs.NumPending == 0 && cs.NumAckPending == 0 {
			if stable++; stable >= 3 {
				return nil
			}
		} else {
			stable = 0
		}
	}
}
```

- [ ] **Step 2: Verify build + all unit tests**

Run: `cd controller && go build ./... && go test ./...`
Expected: build clean, all unit tests PASS.

- [ ] **Step 3: Commit**

```bash
git add controller/main.go
git commit -m "feat(connect-drain): orchestration — publish, arm+DELETE, drain, reconcile"
```

---

## Task 10: Smoke test asserts the property

**Files:**
- Create: `scripts/smoke-test.sh`

- [ ] **Step 1: Write the smoke test**

`scripts/smoke-test.sh`:

```bash
#!/usr/bin/env bash
# Brings up the stack, runs the controller once, asserts the verdict is PASS.
# Asserts the PROPERTY (zero acked-without-apply loss across a mid-flight DELETE),
# not mere liveness.
set -euo pipefail
cd "$(dirname "$0")/.."

cp -n .env.example .env 2>/dev/null || true

cleanup() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[smoke] building + starting stack..."
docker compose up -d --build nats redis connect

echo "[smoke] running controller..."
# controller exits non-zero on VERDICT FAIL; capture its logs
set +e
docker compose run --rm controller >controller.out 2>&1
rc=$?
set -e
cat controller.out

if [ $rc -ne 0 ]; then
  echo "[smoke] FAIL: controller exited $rc"
  exit 1
fi

if ! grep -q '"verdict":{"pass":true}' controller.out; then
  echo "[smoke] FAIL: verdict not pass"
  exit 1
fi

echo "[smoke] PASS: no acked-without-apply loss across mid-flight DELETE"
rm -f controller.out
```

- [ ] **Step 2: Make executable and run**

Run:
```bash
chmod +x scripts/smoke-test.sh
./scripts/smoke-test.sh
```
Expected: ends with `[smoke] PASS: ...` and exit 0. The printed `RESULT_JSON` shows `inflight_at_delete > 0`, `lost:[]`, `verdict:{pass:true}`, and a non-zero `dup_count` (the at-least-once redelivery cost is expected and reported).

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke-test.sh
git commit -m "test(connect-drain): smoke test asserts zero-loss verdict"
```

---

## Task 11: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

`README.md`:

````markdown
# connect-stream-delete-drain

Does deleting a Redpanda Connect streams-mode pipeline mid-flight (the teardown
the leader elector runs on handover) lose messages? This lab answers it in
isolation: NATS JetStream → one Connect (streams mode) → Redis, with a controller
that fires `DELETE /streams` while a batch is in-flight and reconciles a per-key
ledger.

## Property

When `DELETE /streams/<id>` tears down the pipeline while messages are fetched
but not yet applied to Redis, **no message is acked-without-apply (lost)**. Each
in-flight message is either drained-and-applied or left un-acked and healed by
JetStream redelivery (a duplicate, absorbed by idempotent `SET`).

- `applied:<i> == 0` with a drained consumer → **LOST** (the failure).
- `applied:<i> >= 2` → redelivered duplicate (reported, not a failure).

## Run

```bash
cp .env.example .env
./scripts/smoke-test.sh          # deterministic profile, asserts verdict PASS
```

High-throughput run (DELETE mid-firehose):

```bash
# edit .env: PROFILE=throughput MSG_COUNT=20000 PUBLISH_RATE=5000 \
#            SLEEP_MS=25 PIPELINE_THREADS=8 ARM_INFLIGHT=200
docker compose run --rm controller
```

## Knobs

See `.env.example`. Key ones: `PROFILE`, `MSG_COUNT`, `SLEEP_MS` (in-flight
window), `PIPELINE_THREADS`, `ACK_WAIT` (redelivery healing), `ARM_FRACTION` /
`ARM_INFLIGHT` (when DELETE fires).

## Ports

NATS 15422, Redis 16379, Connect 14195, controller health 18080.

## Verdict

`RESULT_JSON {profile, n, inflight_at_delete, lost[], dup_count, drained,
verdict:{pass}}`. PASS requires zero loss, a fully drained consumer, and a
non-zero in-flight cohort at DELETE time (else the run is inconclusive and FAILs).

See `RESEARCH.md` for the full design and the relationship to `redis-cdc-le-k8s`.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(connect-drain): lab README"
```

---

## Task 12: Validate end-to-end

**Files:** none (validation + targeted fixes only)

- [ ] **Step 1: Run the research-lab validator**

Run:
```bash
bash /home/hp/.claude/skills/research-lab/scripts/validate_lab.sh labs/connect-stream-delete-drain
```
Expected: exit 0.

- [ ] **Step 2: If the connect healthcheck fails (image lacks `wget`)**

Diagnose: `docker compose logs connect`; `docker inspect --format '{{json .State.Health}}' <connect-cid>`.
Fix: in `docker-compose.yml`, change the `connect` service to `healthcheck` using whatever the image ships (`busybox wget`, `curl`, or a TCP probe). If none exists, replace the controller's `depends_on.connect` with `condition: service_started` — `waitConnectReady()` in `main.go` is the authoritative readiness gate regardless. Re-run Step 1.

- [ ] **Step 3: If `inflight_at_delete == 0` (DELETE didn't land mid-flight)**

The run FAILs as inconclusive by design. Widen the window: raise `SLEEP_MS`, lower `ARM_FRACTION`, or lower `PIPELINE_THREADS` in `.env` so a cohort is reliably in-flight when the arm fires. Re-run.

- [ ] **Step 4: Confirm clean teardown**

Run: `docker ps -a | grep connect-stream-delete-drain; docker volume ls | grep connect-stream-delete-drain`
Expected: no leftover containers or volumes. `git status` clean of `controller.out` / `.env`.

- [ ] **Step 5: Final commit (only if fixes were needed)**

```bash
git add -A labs/connect-stream-delete-drain
git commit -m "fix(connect-drain): finalize healthcheck/window per validation"
```

---

## Self-Review notes

- **Spec coverage:** topology (Task 1) · wire contract incl. metadata-stash fix (Task 1 template) · experiment sequence (Tasks 7–9) · PASS bar incl. inconclusive-FAIL + 3-poll quiescence (Tasks 4, 9) · all knobs (Task 2 / `.env.example`) · throughput profile (Tasks 2, 5, README) · `validate_lab.sh` gate (Task 12). Phase-2 k8s verifier is intentionally absent (out of scope).
- **Type consistency:** `Config`, `ConsumerState{NumPending uint64, NumAckPending int}`, `Verdict` (nested `Verdict.Pass`), `ArmInput`, `newConnectClient`/`PostStream`/`DeleteStream`/`Ready`, `dialJetStream`/`setup`/`publish`/`consumerState`, `newSinkReader`/`readLedger`/`distinctApplied`/`flush` are used identically across Tasks 4–10.
- **Provider routing:** per the user's subagent-routing rule, when executing, code-quality / final review should go to Codex (cross-model) — the implementer may stay on Claude (small, single-module lab).
```
