# redis-redpanda-connect-stress v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v1 collector's 1-Hz polling sampler with a streaming `XREAD BLOCK` consumer that is the source of truth for both end-to-end latency and received-message count, add profile-aware pipeline quiescence + post-run NATS purge so the full 9-run matrix completes without aborting, and surface `trimmed` / `quiescence_timeout` diagnostics so the verdict reflects pipeline behavior rather than the lab's own measurement methodology.

**Architecture:** Two new collector files (`receiver.go` for the streaming consumer; `quiescence.go` for profile-aware drain detection), modifications to `snapshot.go` (drop latency duties), `main.go` (receiver lifecycle, `buildReport` signature, `readFinalRegionXLen` helper), `report.go` (three new fields), and `stress-run.sh` (NATS purge + summary column). No changes to writer, Connect YAMLs, docker-compose, or any pipeline-under-test surface.

**Tech Stack:** Go 1.25 (module already pinned), `github.com/redis/go-redis/v9` (XREAD with BLOCK), `github.com/HdrHistogram/hdrhistogram-go` (reused from v1), `golang.org/x/time/rate` (unchanged), standard library `net/http` + `net/http/httptest` for quiescence tests, Docker Compose v2, Bash for the harness.

**Skill convention:** Follows `research-lab` skill (self-contained `labs/{slug}/` with `docker-compose.yml`, `README.md`, `RESEARCH.md`, Go components). The lab structure is unchanged; v2 only modifies the collector and harness.

**Spec reference:** `docs/superpowers/specs/2026-05-25-redis-redpanda-connect-stress-v2-design.md` (head commit `0748482`).

---

## File map

```
labs/redis-redpanda-connect-stress/
├── collector/
│   ├── receiver.go            NEW — streaming consumer (Task 2-4)
│   ├── receiver_test.go       NEW — payload-parse + counter tests (Task 4)
│   ├── quiescence.go          NEW — waitForPipelineQuiescence (Task 5-6)
│   ├── quiescence_test.go     NEW — profile-aware tests with fakes (Task 5-6)
│   ├── snapshot.go            MOD — shrink Sampler (Task 7)
│   ├── main.go                MOD — lifecycle + readFinalRegionXLen + buildReport (Task 8-10)
│   └── report.go              MOD — add 3 fields (Task 1)
├── scripts/
│   └── stress-run.sh          MOD — NATS purge + summary column (Task 11)
├── README.md                  MOD — document new fields (Task 12)
└── RESEARCH.md                MOD — explain v2 measurement model (Task 13)
```

All Go code lives in `package main` of the `collector` module. Test files use the same package so they can call package-private helpers.

---

## Task 1: Add three new fields to `Report` (TDD)

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/collector/report.go`
- Modify: `labs/redis-redpanda-connect-stress/collector/report_test.go`

Adds `ReceivedErrors`, `Trimmed`, `QuiescenceTimeout` to the Report struct so later tasks can populate them. Doing this first means every later task can refer to the final struct.

- [ ] **Step 1: Extend `TestReportJSONShape` to assert the new fields**

In `report_test.go`, modify the existing test struct-literal to set the three new fields, and add three new substrings to the `for _, want := range []string{...}` block:

```go
		ReceivedErrors:    7,
		Trimmed:           225000,
		QuiescenceTimeout: false,
```

(insert these lines in the struct literal, before the closing `}` of the `Report{}` constructor, after `Verdict: ...`)

And in the wants slice add:

```go
		`"received_errors": 7`,
		`"trimmed": 225000`,
		`"quiescence_timeout": false`,
```

- [ ] **Step 2: Run test, confirm it fails**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -run TestReportJSONShape ./...
```

Expected: FAIL — `unknown field ReceivedErrors in struct literal`.

- [ ] **Step 3: Add fields to `Report` struct**

In `report.go`, find the `type Report struct { ... }` block. Add these three fields immediately before the closing `}` of the struct:

```go
	ReceivedErrors    int64 `json:"received_errors"`
	Trimmed           int64 `json:"trimmed"`
	QuiescenceTimeout bool  `json:"quiescence_timeout"`
```

- [ ] **Step 4: Run test, confirm it passes**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -run TestReportJSONShape ./...
```

Expected: PASS.

- [ ] **Step 5: Run full collector test suite to confirm no regressions**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -race ./...
```

Expected: all existing tests still PASS (11 from v1).

- [ ] **Step 6: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/report.go \
        labs/redis-redpanda-connect-stress/collector/report_test.go
git commit -m "redis-redpanda-connect-stress v2: report fields (received_errors, trimmed, quiescence_timeout)"
```

---

## Task 2: Create `Receiver` type + accessors (TDD)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/receiver.go`
- Create: `labs/redis-redpanda-connect-stress/collector/receiver_test.go`

Receiver type with three accessors. The `Run` method is added in Task 3; this task only establishes the type so its public API is settled.

- [ ] **Step 1: Write the failing test**

Create `labs/redis-redpanda-connect-stress/collector/receiver_test.go`:

```go
package main

import "testing"

func TestNewReceiverInitialState(t *testing.T) {
	r := NewReceiver("redis-region:6379", "region-events")
	defer r.Close()
	if c := r.Count(); c != 0 {
		t.Errorf("Count()=%d, want 0", c)
	}
	if e := r.Errors(); e != 0 {
		t.Errorf("Errors()=%d, want 0", e)
	}
	s := r.Latency()
	if s.Samples != 0 {
		t.Errorf("Latency().Samples=%d, want 0", s.Samples)
	}
}
```

- [ ] **Step 2: Run test, confirm it fails**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -run TestNewReceiverInitialState ./...
```

Expected: FAIL — `undefined: NewReceiver`.

- [ ] **Step 3: Implement `receiver.go` with type + accessors only (no Run yet)**

Create `labs/redis-redpanda-connect-stress/collector/receiver.go`:

```go
package main

import (
	"sync/atomic"

	"github.com/redis/go-redis/v9"
)

// Receiver runs a streaming XREAD consumer against region-events.
// It is the source of truth for received-count and end-to-end latency in v2.
//
// Run is the single goroutine that mutates lastID and latency. The atomic
// counters (received, errCount) are race-safe for concurrent reads via the
// accessors; latency must be read only after Run has returned (caller
// enforces this via sync.WaitGroup — see lifecycle in main.go).
type Receiver struct {
	rdb      *redis.Client
	stream   string
	latency  *LatencyTracker
	received atomic.Int64
	errCount atomic.Int64
	lastID   string // touched only by Run() goroutine
}

func NewReceiver(addr, stream string) *Receiver {
	return &Receiver{
		rdb:     redis.NewClient(&redis.Options{Addr: addr}),
		stream:  stream,
		latency: NewLatencyTracker(),
	}
}

func (r *Receiver) Count() int64                { return r.received.Load() }
func (r *Receiver) Errors() int64               { return r.errCount.Load() }
func (r *Receiver) Latency() LatencySummary     { return r.latency.Summary() }
func (r *Receiver) Close() error                { return r.rdb.Close() }
```

- [ ] **Step 4: Run test, confirm it passes**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -run TestNewReceiverInitialState ./...
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/receiver.go \
        labs/redis-redpanda-connect-stress/collector/receiver_test.go
git commit -m "redis-redpanda-connect-stress v2: Receiver type + accessors"
```

---

## Task 3: Receiver `processStreams` helper + tests (TDD)

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/collector/receiver.go`
- Modify: `labs/redis-redpanda-connect-stress/collector/receiver_test.go`

Extracts the per-message handling into a package-private helper so we can unit-test counter and latency-recording behavior with synthetic `[]redis.XStream` values, no Redis needed.

- [ ] **Step 1: Write the failing test**

In `receiver_test.go`, append:

```go
import (
	"encoding/json"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func makeXStream(stream string, msgs []redis.XMessage) []redis.XStream {
	return []redis.XStream{{Stream: stream, Messages: msgs}}
}

func makePayload(t *testing.T, tsNs int64) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{
		"event_id": "abc",
		"ts_ns":    tsNs,
		"seq":      int64(1),
		"pad":      "xxxx",
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestReceiverProcessStreamsCountsAndAdvancesLastID(t *testing.T) {
	r := NewReceiver("127.0.0.1:0", "region-events")
	defer r.Close()
	now := time.Now().UnixNano()
	msgs := []redis.XMessage{
		{ID: "1-0", Values: map[string]any{"value": makePayload(t, now-50_000_000)}},
		{ID: "1-1", Values: map[string]any{"value": makePayload(t, now-20_000_000)}},
		{ID: "2-0", Values: map[string]any{"value": makePayload(t, now-10_000_000)}},
	}
	r.processStreams(makeXStream("region-events", msgs), now)
	if c := r.Count(); c != 3 {
		t.Errorf("Count()=%d, want 3", c)
	}
	if r.lastID != "2-0" {
		t.Errorf("lastID=%q, want %q", r.lastID, "2-0")
	}
	if s := r.Latency(); s.Samples != 3 {
		t.Errorf("Latency().Samples=%d, want 3", s.Samples)
	}
}

func TestReceiverProcessStreamsCountsBadPayloadButSkipsLatency(t *testing.T) {
	r := NewReceiver("127.0.0.1:0", "region-events")
	defer r.Close()
	now := time.Now().UnixNano()
	msgs := []redis.XMessage{
		{ID: "1-0", Values: map[string]any{"value": "not json"}},        // bad payload
		{ID: "1-1", Values: map[string]any{"other": "no value field"}},  // missing field
		{ID: "1-2", Values: map[string]any{"value": makePayload(t, now-30_000_000)}}, // valid
	}
	r.processStreams(makeXStream("region-events", msgs), now)
	if c := r.Count(); c != 3 {
		t.Errorf("Count()=%d, want 3 (all three messages counted regardless of payload)", c)
	}
	if s := r.Latency(); s.Samples != 1 {
		t.Errorf("Latency().Samples=%d, want 1 (only the valid payload recorded)", s.Samples)
	}
}
```

- [ ] **Step 2: Run tests, confirm they fail**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -run TestReceiverProcessStreams ./...
```

Expected: FAIL — `r.processStreams undefined`.

- [ ] **Step 3: Implement `processStreams` in `receiver.go`**

Add this method to `receiver.go` (after the accessors):

```go
// processStreams folds one or more XStream results into the receiver's state.
// Each message increments the received counter regardless of payload validity;
// the latency tracker is only updated when the payload parses and yields a ts_ns.
// lastID is advanced to the highest message ID seen.
//
// Exported-style (lowercase) only because it's invoked from Run; package-private
// tests call it directly with synthetic XStreams to avoid needing a live Redis.
func (r *Receiver) processStreams(streams []redis.XStream, nowNs int64) {
	for _, st := range streams {
		for _, msg := range st.Messages {
			if v, ok := msg.Values["value"].(string); ok {
				if ts, err := extractTsNs(v); err == nil {
					r.latency.RecordAt(ts, nowNs)
				}
			}
			r.received.Add(1)
			r.lastID = msg.ID
		}
	}
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -race -run TestReceiverProcessStreams ./...
```

Expected: both tests PASS, race detector clean.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/receiver.go \
        labs/redis-redpanda-connect-stress/collector/receiver_test.go
git commit -m "redis-redpanda-connect-stress v2: Receiver.processStreams + tests"
```

---

## Task 4: Receiver `Run` method (XREAD BLOCK loop)

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/collector/receiver.go`

The Run method depends on live Redis, so no unit test — it's covered by the smoke verification in Task 13.

- [ ] **Step 1: Add `Run` to `receiver.go`**

Add the following after `processStreams` in `receiver.go` (also add `"context"`, `"errors"`, `"time"` to the imports):

```go
import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
)
```

(replace the existing import block — the only previous imports were `sync/atomic` and the redis package)

Then append the Run method:

```go
// Run drives the XREAD BLOCK loop. Returns when ctx is cancelled.
// The caller must call this via a goroutine wrapped in sync.WaitGroup so
// accessors (Count, Errors, Latency) can be read race-safely after wg.Wait().
func (r *Receiver) Run(ctx context.Context) {
	r.lastID = "0-0"
	for {
		if ctx.Err() != nil {
			return
		}
		res, err := r.rdb.XRead(ctx, &redis.XReadArgs{
			Streams: []string{r.stream, r.lastID},
			Block:   250 * time.Millisecond,
			Count:   1000,
		}).Result()
		if err != nil {
			if errors.Is(err, redis.Nil) || errors.Is(err, context.DeadlineExceeded) {
				continue
			}
			if ctx.Err() != nil {
				return
			}
			r.errCount.Add(1)
			time.Sleep(50 * time.Millisecond)
			continue
		}
		r.processStreams(res, time.Now().UnixNano())
	}
}
```

- [ ] **Step 2: Verify the package builds**

```bash
cd labs/redis-redpanda-connect-stress/collector && go build ./...
```

Expected: no output (clean build).

- [ ] **Step 3: Run all tests, verify still pass**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -race ./...
```

Expected: all tests PASS (existing 11 + 1 receiver init + 2 receiver processStreams = 14).

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/receiver.go
git commit -m "redis-redpanda-connect-stress v2: Receiver.Run XREAD BLOCK loop"
```

---

## Task 5: `quiescence.go` — ALO/EOE branch (TDD)

**Files:**
- Create: `labs/redis-redpanda-connect-stress/collector/quiescence.go`
- Create: `labs/redis-redpanda-connect-stress/collector/quiescence_test.go`

The `waitForPipelineQuiescence` function is tested against a fake `*StreamClient` and an `httptest.Server` mocking `/jsz`. This task implements the function and tests the ALO/EOE branch.

- [ ] **Step 1: Write the failing test**

Create `labs/redis-redpanda-connect-stress/collector/quiescence_test.go`:

```go
package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// jszServer returns a test server that responds with the given consumer pending value.
func jszServer(t *testing.T, pending *atomic.Int64) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/jsz", func(w http.ResponseWriter, r *http.Request) {
		// Minimal JSZ shape matching nats.go's parser.
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{
		  "account_details": [{
		    "stream_detail": [{
		      "name": "APP_EVENTS",
		      "state": {"messages": 0, "bytes": 0},
		      "consumer_detail": [{"num_pending": ` + itoa(pending.Load()) + `}]
		    }]
		  }]
		}`))
	})
	return httptest.NewServer(mux)
}

func itoa(n int64) string {
	// Tiny helper to keep the inline JSON readable.
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+(n%10))) + digits
		n /= 10
	}
	if neg {
		digits = "-" + digits
	}
	return digits
}

func TestWaitQuiescenceAloReturnsFalseWhenBothQueuesDrain(t *testing.T) {
	central := newFakeStreamClient(t)
	central.setXLen("app.events", 5) // start non-empty
	pending := &atomic.Int64{}
	pending.Store(3) // start non-empty
	srv := jszServer(t, pending)
	defer srv.Close()

	// In another goroutine drain both queues after a short delay.
	go func() {
		time.Sleep(400 * time.Millisecond)
		central.setXLen("app.events", 0)
		pending.Store(0)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	timedOut := waitForPipelineQuiescence(ctx, "alo", central, srv.URL, "APP_EVENTS", 2*time.Second)
	if timedOut {
		t.Errorf("expected quiescence (timedOut=false), got true")
	}
}

func TestWaitQuiescenceAloReturnsTrueWhenSourceStuck(t *testing.T) {
	central := newFakeStreamClient(t)
	central.setXLen("app.events", 100) // stays non-empty
	pending := &atomic.Int64{}
	pending.Store(0)
	srv := jszServer(t, pending)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	timedOut := waitForPipelineQuiescence(ctx, "alo", central, srv.URL, "APP_EVENTS", 500*time.Millisecond)
	if !timedOut {
		t.Errorf("expected timeout, got quiescence")
	}
}

func TestWaitQuiescenceAloReturnsTrueWhenSinkStuck(t *testing.T) {
	central := newFakeStreamClient(t)
	central.setXLen("app.events", 0)
	pending := &atomic.Int64{}
	pending.Store(50) // stays non-empty
	srv := jszServer(t, pending)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	timedOut := waitForPipelineQuiescence(ctx, "alo", central, srv.URL, "APP_EVENTS", 500*time.Millisecond)
	if !timedOut {
		t.Errorf("expected timeout, got quiescence")
	}
}
```

Also create the fake-StreamClient helper at the bottom of `quiescence_test.go`:

```go
// fakeStreamClient is a test-only stand-in for *StreamClient. The real type wraps
// a redis.Client; the fake just stores XLEN values in a map so tests can set
// them without spinning up Redis. It implements only the methods quiescence
// actually calls (XLen).
type fakeStreamClient struct {
	t    *testing.T
	lens map[string]int64
}

func newFakeStreamClient(t *testing.T) *fakeStreamClient {
	return &fakeStreamClient{t: t, lens: map[string]int64{}}
}

func (f *fakeStreamClient) setXLen(stream string, n int64) { f.lens[stream] = n }

func (f *fakeStreamClient) XLen(ctx context.Context, key string) (int64, error) {
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	return f.lens[key], nil
}
```

Note: `waitForPipelineQuiescence` takes a *StreamClient*, not the fake. To make the function usable with both, define a small interface in the same file. Update Task 5 step 3 below to define this interface.

- [ ] **Step 2: Run tests, confirm they fail**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -run TestWaitQuiescence ./...
```

Expected: FAIL — `undefined: waitForPipelineQuiescence` (or interface mismatch).

- [ ] **Step 3: Implement `quiescence.go` (ALO/EOE branch only — AMO is added in Task 6)**

Create `labs/redis-redpanda-connect-stress/collector/quiescence.go`:

```go
package main

import (
	"context"
	"log"
	"time"
)

// xlenReader is the minimal subset of *StreamClient used by waitForPipelineQuiescence.
// Defining it as an interface lets quiescence_test.go pass a fake without a real Redis.
type xlenReader interface {
	XLen(ctx context.Context, key string) (int64, error)
}

// waitForPipelineQuiescence polls every 250 ms until either the profile-specific
// quiescence condition holds for one poll, or the deadline elapses.
// Returns true if the deadline fired (the pipeline did not quiesce in time),
// false if quiescence was observed.
//
// Profile conditions (spec §6.3.1):
//   alo, eoe: XLEN(app.events) == 0 AND ScrapeJSZ.MaxPending == 0
//   amo:      XLEN(app.events) == 0 only — added in next task
func waitForPipelineQuiescence(
	ctx context.Context,
	profile string,
	central xlenReader,
	natsURL, natsStream string,
	deadline time.Duration,
) (timedOut bool) {
	end := time.Now().Add(deadline)
	for {
		if ctx.Err() != nil {
			return true
		}
		if time.Now().After(end) {
			log.Printf("WARN: pipeline did not quiesce within %s (profile=%s)", deadline, profile)
			return true
		}
		sourceOK := false
		if x, err := central.XLen(ctx, "app.events"); err == nil && x == 0 {
			sourceOK = true
		}
		sinkOK := true // for ALO/EOE this is overridden below
		if profile == "alo" || profile == "eoe" {
			sinkOK = false
			if snap, err := ScrapeJSZ(ctx, natsURL, natsStream); err == nil && snap.MaxPending == 0 {
				sinkOK = true
			}
		}
		if sourceOK && sinkOK {
			return false
		}
		select {
		case <-ctx.Done():
			return true
		case <-time.After(250 * time.Millisecond):
		}
	}
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -race -run TestWaitQuiescence ./...
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/quiescence.go \
        labs/redis-redpanda-connect-stress/collector/quiescence_test.go
git commit -m "redis-redpanda-connect-stress v2: waitForPipelineQuiescence ALO/EOE branch + tests"
```

---

## Task 6: `quiescence.go` — AMO branch + tests

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/collector/quiescence_test.go`

The ALO/EOE implementation already covers AMO correctly because the `if profile == "alo" || profile == "eoe"` branch leaves `sinkOK=true` for any other profile string. But we MUST add explicit tests to lock that behavior in.

- [ ] **Step 1: Write the failing tests for AMO**

In `quiescence_test.go`, append:

```go
func TestWaitQuiescenceAmoSkipsPendingCheck(t *testing.T) {
	central := newFakeStreamClient(t)
	central.setXLen("app.events", 0)
	pending := &atomic.Int64{}
	pending.Store(9999) // would stall ALO/EOE; AMO must ignore.
	srv := jszServer(t, pending)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	timedOut := waitForPipelineQuiescence(ctx, "amo", central, srv.URL, "APP_EVENTS", 500*time.Millisecond)
	if timedOut {
		t.Errorf("expected quiescence for AMO with high pending, got timeout")
	}
}

func TestWaitQuiescenceAmoStillRequiresSourceDrain(t *testing.T) {
	central := newFakeStreamClient(t)
	central.setXLen("app.events", 7) // stays non-empty
	pending := &atomic.Int64{}
	pending.Store(0)
	srv := jszServer(t, pending)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	timedOut := waitForPipelineQuiescence(ctx, "amo", central, srv.URL, "APP_EVENTS", 500*time.Millisecond)
	if !timedOut {
		t.Errorf("expected AMO to time out on stuck source, got quiescence")
	}
}
```

- [ ] **Step 2: Run tests, confirm they pass already**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -race -run TestWaitQuiescenceAmo ./...
```

Expected: both new AMO tests PASS without further code changes (the AMO branch was implicitly correct in Task 5).

- [ ] **Step 3: Run all quiescence tests**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -race -run TestWaitQuiescence ./...
```

Expected: 5 PASS (3 from Task 5 + 2 from this task).

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/quiescence_test.go
git commit -m "redis-redpanda-connect-stress v2: explicit AMO quiescence tests"
```

---

## Task 7: Shrink `Sampler` in `snapshot.go`

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/collector/snapshot.go`

Removes the now-duplicate latency duties. After this task, the snapshot loop only scrapes metrics + XLen + JSZ; the receiver owns latency.

- [ ] **Step 1: Show current `Sampler` struct for reference**

Read `labs/redis-redpanda-connect-stress/collector/snapshot.go` to see the current shape. The current struct includes `Latency *LatencyTracker` and `LastRegionID string` fields, and `Tick` calls `XRangeSinceID` + `extractTsNs`. Both are being removed.

- [ ] **Step 2: Replace `Sampler` struct definition**

In `snapshot.go`, find:

```go
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
```

Replace with:

```go
type Sampler struct {
	WriterURL   string
	ConnectSrc  string
	ConnectSink string
	NATSURL     string
	NATSStream  string
	Central     *StreamClient
	Region      *StreamClient
}
```

- [ ] **Step 3: Remove the latency-sampling block from `Tick`**

In the same file, find the block at the end of `Tick`:

```go
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
```

Replace with:

```go
	return snap
}
```

(Delete every line from `// Latency samples from region-events` down to and including the closing `}` of the if-block, leaving only `return snap` and the function closing brace.)

- [ ] **Step 4: Delete `Init` method**

The current `snapshot.go` defines:

```go
func (s *Sampler) Init() {
	if s.LastRegionID == "" {
		s.LastRegionID = "0-0"
	}
}
```

Delete it entirely. The receiver does its own initialization.

- [ ] **Step 5: Remove unused imports**

After the edits, `snapshot.go` no longer needs `time` if it was imported only for `Tick`'s `time.Now()` call inside the deleted block. Verify by running:

```bash
cd labs/redis-redpanda-connect-stress/collector && go vet ./...
```

If vet flags unused imports, remove them. (Note: `time` is still needed for `context.WithTimeout(ctx, 1500*time.Millisecond)` earlier in `Tick`, so keep it.)

- [ ] **Step 6: Run full test suite**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -race ./...
```

Expected: all tests PASS. The build will fail in `main.go` references to `sampler.Init()` and `Sampler{Latency: ...}` — Task 8/9 will fix those. Run `go build ./...` separately to confirm the package compiles even if `main.go` is temporarily broken; if it doesn't, that's OK — Tasks 8/9 fix `main.go`.

Actually, we need the build to be green between tasks. The safest move: this task is paired with Task 8 (lifecycle rewrite). To keep this task committable on its own, do NOT delete `Init` here if `main.go` still calls it; instead leave Init as a no-op:

Revise Step 4: replace `Init`'s body with a comment-only no-op:

```go
// Init is a deprecated no-op kept for v1-compatibility during the v2 receiver
// migration (Task 9 in the v2 plan removes the last call site, after which
// this method can be deleted entirely).
func (s *Sampler) Init() {}
```

Same for `LastRegionID`: removing the field will break `sampler.LastRegionID = "0-0"` in main.go. Solution: also leave a no-op accessor or — simpler — defer the actual struct change to Task 9. **Revise this task's Step 2:** replace ONLY the field set with this transitional shape (keep Latency/LastRegionID temporarily as unused fields):

```go
type Sampler struct {
	WriterURL    string
	ConnectSrc   string
	ConnectSink  string
	NATSURL      string
	NATSStream   string
	Central      *StreamClient
	Region       *StreamClient
	Latency      *LatencyTracker // DEPRECATED — removed in Task 9 after main.go stops setting it
	LastRegionID string          // DEPRECATED — same
}
```

The Tick body removal in Step 3 is safe to do now: nothing else reads `s.Latency` or `s.LastRegionID`. After Task 9 rewrites the lifecycle (removing the two field-set lines), Task 9 can also delete the fields and Init in a follow-up step.

**Revised Step 2 + Step 4 + Step 5 above. Step 3 (remove latency block from Tick) stands.**

- [ ] **Step 7: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/snapshot.go
git commit -m "redis-redpanda-connect-stress v2: snapshot Tick drops latency duties (fields deprecated)"
```

---

## Task 8: `readFinalRegionXLen` helper in `main.go` (TDD)

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/collector/main.go`
- Modify: `labs/redis-redpanda-connect-stress/collector/quiescence_test.go` (test lives alongside the helper for now; can be moved)

Per spec §6.4, this helper retries XLen on transient failure and falls back to the last snapshot's RegionXLen value. The fake from Task 5 needs an error-returning variant.

- [ ] **Step 1: Extend the fake to return errors on demand**

In `quiescence_test.go`, modify `fakeStreamClient` to support a configurable error:

```go
type fakeStreamClient struct {
	t    *testing.T
	lens map[string]int64
	err  error // when set, XLen returns this error instead of looking up lens
}

func (f *fakeStreamClient) setError(err error) { f.err = err }

func (f *fakeStreamClient) XLen(ctx context.Context, key string) (int64, error) {
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	if f.err != nil {
		return 0, f.err
	}
	return f.lens[key], nil
}
```

Add a new test file `labs/redis-redpanda-connect-stress/collector/final_xlen_test.go`:

```go
package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestReadFinalRegionXLenSuccessOnFirstTry(t *testing.T) {
	f := newFakeStreamClient(t)
	f.setXLen("region-events", 12345)
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	got := readFinalRegionXLen(ctx, f, nil)
	if got != 12345 {
		t.Errorf("got %d, want 12345", got)
	}
}

func TestReadFinalRegionXLenFallsBackToLastSnap(t *testing.T) {
	f := newFakeStreamClient(t)
	f.setError(errors.New("redis down"))
	snaps := []Snapshot{
		{RegionXLen: 100},
		{RegionXLen: 7777}, // last snapshot — should be used as fallback
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	got := readFinalRegionXLen(ctx, f, snaps)
	if got != 7777 {
		t.Errorf("got %d, want 7777 (fallback to last snap)", got)
	}
}

func TestReadFinalRegionXLenReturnsZeroWhenNoFallback(t *testing.T) {
	f := newFakeStreamClient(t)
	f.setError(errors.New("redis down"))
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	got := readFinalRegionXLen(ctx, f, nil)
	if got != 0 {
		t.Errorf("got %d, want 0 (no snaps to fall back to)", got)
	}
}
```

- [ ] **Step 2: Run tests, confirm they fail**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -run TestReadFinalRegionXLen ./...
```

Expected: FAIL — `undefined: readFinalRegionXLen`.

- [ ] **Step 3: Implement `readFinalRegionXLen` in `main.go`**

Add at the bottom of `main.go` (above any existing helper functions):

```go
// readFinalRegionXLen returns XLEN("region-events") with bounded retries.
// On persistent failure it falls back to the last snapshot's RegionXLen so
// that a transient Redis hiccup at end-of-run never corrupts the trimmed
// math by leaving finalRegionXLen at zero. The fallback value is at most
// one snapshot tick (~1s) stale. See spec §6.4.
func readFinalRegionXLen(ctx context.Context, region xlenReader, snaps []Snapshot) int64 {
	const attempts = 3
	var lastErr error
	for i := 0; i < attempts; i++ {
		if x, err := region.XLen(ctx, "region-events"); err == nil {
			return x
		} else {
			lastErr = err
		}
		if ctx.Err() != nil {
			break
		}
		select {
		case <-ctx.Done():
		case <-time.After(100 * time.Millisecond):
		}
	}
	log.Printf("WARN: final XLEN(region-events) failed after %d attempts: %v; falling back to last snapshot", attempts, lastErr)
	if len(snaps) > 0 {
		return snaps[len(snaps)-1].RegionXLen
	}
	return 0
}
```

Ensure `main.go`'s import block includes `"context"`, `"log"`, `"time"` (most are already there from existing code).

- [ ] **Step 4: Run tests, confirm they pass**

```bash
cd labs/redis-redpanda-connect-stress/collector && go test -race -run TestReadFinalRegionXLen ./...
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/main.go \
        labs/redis-redpanda-connect-stress/collector/quiescence_test.go \
        labs/redis-redpanda-connect-stress/collector/final_xlen_test.go
git commit -m "redis-redpanda-connect-stress v2: readFinalRegionXLen helper + tests"
```

---

## Task 9: Receiver lifecycle wiring + buildReport signature

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/collector/main.go`
- Modify: `labs/redis-redpanda-connect-stress/collector/snapshot.go` (final cleanup of deprecated fields)

This is the integration task. It rewrites the `Run` function to add receiver lifecycle steps, updates `buildReport`'s signature and body, and finally removes the deprecated `Latency`/`LastRegionID` Sampler fields. No unit tests (integration is covered by smoke verification in Task 14). After this task, the binary is fully v2.

- [ ] **Step 1: Read the existing `Run` function**

Open `labs/redis-redpanda-connect-stress/collector/main.go`. Identify these sections:
1. The Sampler construction (currently sets `Latency: NewLatencyTracker()` and calls `sampler.Init()`)
2. The PostReset / PostRate / sustain-ticker / drain-ticker sequence
3. The call to `buildReport(cfg, startedAt, snaps, sampler.Latency.Summary())`

- [ ] **Step 2: Rewrite `Run` to add receiver + quiescence + final-XLen**

Replace the existing `Run` function body with the following. This is the canonical v2 lifecycle from spec §6:

```go
func Run(ctx context.Context, cfg RunConfig) (Report, error) {
	central := NewStreamClient(cfg.RedisCentral)
	defer central.Close()
	region := NewStreamClient(cfg.RedisRegion)
	defer region.Close()

	// 1+2. Trim streams to zero so we measure only this tier's traffic.
	if err := central.Trim(ctx, "app.events"); err != nil {
		return Report{}, fmt.Errorf("trim app.events: %w", err)
	}
	if err := region.Trim(ctx, "region-events"); err != nil {
		return Report{}, fmt.Errorf("trim region-events: %w", err)
	}

	// 3. Reset writer counters.
	if err := PostReset(ctx, cfg.WriterURL); err != nil {
		return Report{}, err
	}

	// Best-effort pause writer on any return path.
	defer func() {
		c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = PostRate(c, cfg.WriterURL, 0)
	}()

	// 4-6. Start the receiver — single goroutine, joined via WaitGroup.
	receiver := NewReceiver(cfg.RedisRegion, "region-events")
	defer receiver.Close()
	receiverCtx, cancelRecv := context.WithCancel(ctx)
	defer cancelRecv() // safety net; explicit cancel below is the live path

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		receiver.Run(receiverCtx)
	}()

	// 7. Warmup at half rate.
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier/2); err != nil {
		return Report{}, err
	}
	sleep(ctx, cfg.Warmup)

	// 8. Sustain at full rate.
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier); err != nil {
		return Report{}, err
	}

	sampler := &Sampler{
		WriterURL: cfg.WriterURL, ConnectSrc: cfg.ConnectSrc,
		ConnectSink: cfg.ConnectSink, NATSURL: cfg.NATSURL,
		NATSStream: cfg.NATSStream,
		Central:    central, Region: region,
	}

	startedAt := time.Now()
	sustainEnd := startedAt.Add(cfg.Duration)

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	var snaps []Snapshot
	for time.Now().Before(sustainEnd) {
		select {
		case <-ctx.Done():
			return Report{}, ctx.Err()
		case <-ticker.C:
			snaps = append(snaps, sampler.Tick(ctx))
		}
	}

	// 9. Drain.
	if err := PostRate(ctx, cfg.WriterURL, 0); err != nil {
		return Report{}, err
	}
	// 10. drain ticker loop.
	drainEnd := time.Now().Add(cfg.Drain)
	for time.Now().Before(drainEnd) {
		select {
		case <-ctx.Done():
			return Report{}, ctx.Err()
		case <-ticker.C:
			snaps = append(snaps, sampler.Tick(ctx))
		}
	}

	// 11. Pipeline quiescence (profile-aware).
	quiescenceTimedOut := waitForPipelineQuiescence(
		ctx, cfg.Profile, central, cfg.NATSURL, cfg.NATSStream, 10*time.Second)

	// 12. Tail-flush window for the receiver.
	sleep(ctx, 500*time.Millisecond)

	// Final tick to capture post-drain snapshot fields (Sent, Errors, Connect, NATS.Bytes).
	final := sampler.Tick(ctx)
	snaps = append(snaps, final)

	// 13. Cancel receiver; 14. wait for it to fully exit.
	cancelRecv()
	wg.Wait()

	// 15. Synchronized end-of-run XLEN cut for trimmed math.
	finalRegionXLen := readFinalRegionXLen(ctx, region, snaps)

	// 16. Build report.
	return buildReport(cfg, startedAt, snaps, receiver, finalRegionXLen, quiescenceTimedOut), nil
}
```

Add `"sync"` and `"fmt"` to the imports if not already present.

- [ ] **Step 3: Update `buildReport` signature and body**

Find the existing `buildReport` function:

```go
func buildReport(cfg RunConfig, startedAt time.Time, snaps []Snapshot, lat LatencySummary) Report {
```

Replace its signature with:

```go
func buildReport(
	cfg RunConfig,
	startedAt time.Time,
	snaps []Snapshot,
	receiver *Receiver,
	finalRegionXLen int64,
	quiescenceTimedOut bool,
) Report {
```

In its body, find the block:

```go
	r := Report{
		Tier: cfg.Tier, Mode: cfg.Mode, Profile: cfg.Profile,
		StartedAt: startedAt, DurationS: int(cfg.Duration.Seconds()),
		RateTarget: cfg.Tier,
		Latency:    lat,
		SLO:        cfg.SLO,
	}
```

Replace with:

```go
	r := Report{
		Tier: cfg.Tier, Mode: cfg.Mode, Profile: cfg.Profile,
		StartedAt: startedAt, DurationS: int(cfg.Duration.Seconds()),
		RateTarget: cfg.Tier,
		Latency:    receiver.Latency(),
		SLO:        cfg.SLO,
	}
```

Then find the v1 block that reads from the last snapshot:

```go
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
```

Replace with:

```go
	// Sent + errors + Connect + NATS.Bytes are end-of-run values from the last snapshot.
	// Received is sourced from the streaming receiver, not the snapshot XLEN — receiver
	// is untainted by region-events MAXLEN trimming.
	r.Received = receiver.Count()
	r.ReceivedErrors = receiver.Errors()
	r.QuiescenceTimeout = quiescenceTimedOut
	r.Redis.RegionXLenFinal = finalRegionXLen
	r.Trimmed = r.Received - r.Redis.RegionXLenFinal
	if r.Trimmed < 0 {
		r.Trimmed = 0
	}
	if len(snaps) > 0 {
		last := snaps[len(snaps)-1]
		r.Sent = int64(last.WriterMetrics["stress_writer_sent_total"])
		r.Errors = int64(last.WriterMetrics["stress_writer_errors_total"])
		r.Connect.SourceIn = int64(last.ConnectSrc["input_received"])
		r.Connect.SourceOut = int64(last.ConnectSrc["output_sent"])
		r.Connect.SinkIn = int64(last.ConnectSink["input_received"])
		r.Connect.SinkOut = int64(last.ConnectSink["output_sent"])
		r.NATS.Bytes = last.NATS.Bytes
	}
```

The rest of `buildReport` (Missing/MissingPct computation, sustain-window rate avg/min, max XLen / pending, chaos block, ComputeVerdict) is unchanged.

- [ ] **Step 4: Remove deprecated fields from `Sampler` and delete `Init`**

In `snapshot.go`, delete:

```go
	Latency      *LatencyTracker // DEPRECATED — removed in Task 9 after main.go stops setting it
	LastRegionID string          // DEPRECATED — same
```

And delete the `func (s *Sampler) Init() {}` no-op.

The Sampler struct should now look like:

```go
type Sampler struct {
	WriterURL   string
	ConnectSrc  string
	ConnectSink string
	NATSURL     string
	NATSStream  string
	Central     *StreamClient
	Region      *StreamClient
}
```

- [ ] **Step 5: Build, vet, test**

```bash
cd labs/redis-redpanda-connect-stress/collector
go vet ./...
go build ./...
go test -race ./...
```

Expected: vet clean, build clean, all tests PASS (existing v1 tests + Task 1-8 new tests = ~20 tests).

- [ ] **Step 6: Commit**

```bash
git add labs/redis-redpanda-connect-stress/collector/main.go \
        labs/redis-redpanda-connect-stress/collector/snapshot.go
git commit -m "redis-redpanda-connect-stress v2: wire receiver lifecycle into Run; buildReport signature"
```

---

## Task 10: Docker rebuild verification

**Files:** none (validation only)

After Task 9, the binary is fully v2. Verify the container builds cleanly before touching the harness.

- [ ] **Step 1: Rebuild the collector image**

```bash
cd labs/redis-redpanda-connect-stress
docker compose build --no-cache collector
```

Expected: image built successfully, no Go compilation errors.

- [ ] **Step 2: Verify the binary's flags are unchanged**

```bash
docker compose run --rm collector --help 2>&1 | head -30
```

Expected: same flag list as v1 (no harness-side changes yet, so flag stability matters).

---

## Task 11: Harness — NATS purge + trimmed column

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/scripts/stress-run.sh`

Two changes: purge `APP_EVENTS` after each per-tier collector exit, and add a `trimmed` column to the summary table.

- [ ] **Step 1: Add NATS purge after each collector run**

In `stress-run.sh`, find the `run_one` function. After the `wait "${chaos_pid}"` block (and its `chaos_rc` check), and AFTER the `docker compose run --rm ... collector ...` block, insert:

```bash
  # Purge JetStream so the next run starts hermetic. Non-fatal — if NATS
  # is unreachable the next run's pre-flight will catch a genuinely-broken
  # state. The collector's pipeline-quiescence (spec §6.3) ensures no
  # in-flight messages are lost by purging now.
  docker exec rrcs-nats nats --server nats://nats:4222 stream purge APP_EVENTS -f >/dev/null 2>&1 \
    || echo "[purge] WARN: nats stream purge APP_EVENTS failed (continuing)" >&2
```

Position: this MUST come after the chaos_pid wait and after the collector finishes; in the existing code that is just before the closing `}` of `run_one`.

- [ ] **Step 2: Add `trimmed` column to the summary table renderer**

Find this block in `stress-run.sh`:

```bash
printf "%-9s %-12s %-15s %-9s %-9s %s\n" "tier" "mode" "rate_achieved" "missing" "p99 ms" "verdict"
printf -- "---------------------------------------------------------------------\n"
```

Replace with:

```bash
printf "%-9s %-12s %-15s %-9s %-9s %-9s %s\n" "tier" "mode" "rate_achieved" "missing" "trimmed" "p99 ms" "verdict"
printf -- "-------------------------------------------------------------------------------\n"
```

Find the Python heredoc that renders each row:

```bash
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
```

Replace with:

```bash
    python3 - "$f" "$tier" "$mode" <<'PY'
import json,sys
path, tier, mode = sys.argv[1], sys.argv[2], sys.argv[3]
r = json.load(open(path))
ach = r.get("rate_achieved_avg", 0)
miss = r.get("missing", 0)
trim = r.get("trimmed", 0)
p99 = r.get("latency_ms", {}).get("p99", 0)
verdict = "PASS" if r.get("verdict", {}).get("pass") else "FAIL"
print(f"{tier:<9} {mode:<12} {ach:6.1f}/{tier:<8} {miss:<9} {trim:<9} {p99:<9.1f} {verdict}")
PY
```

Also find the MISSING-row print:

```bash
      printf "%-9s %-12s %-15s %-9s %-9s %s\n" "$tier" "$mode" "-" "-" "-" "MISSING"
```

Replace with:

```bash
      printf "%-9s %-12s %-15s %-9s %-9s %-9s %s\n" "$tier" "$mode" "-" "-" "-" "-" "MISSING"
```

(One extra `-` and `%-9s` for the new trimmed column.)

- [ ] **Step 3: Syntax check**

```bash
bash -n labs/redis-redpanda-connect-stress/scripts/stress-run.sh
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-connect-stress/scripts/stress-run.sh
git commit -m "redis-redpanda-connect-stress v2: harness NATS purge + trimmed column"
```

---

## Task 12: README.md update

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/README.md`

Document the three new report fields and what `trimmed=N` means at 10k tier.

- [ ] **Step 1: Add a v2 changes section after the "Known limitations" section**

Open `labs/redis-redpanda-connect-stress/README.md`. Find the existing `## Known limitations` section. Immediately AFTER its content (before the next `##` heading), insert:

```markdown
## v2 measurement model

As of 2026-05-25 the collector samples differently from v1. The pipeline under test is unchanged.

- **`received` is now untainted by MAXLEN trimming.** The collector runs a streaming `XREAD BLOCK` consumer on `region-events` for the entire run. Every message that arrives is counted, even if it is later trimmed away when the stream exceeds 100 000 entries. At 10 k tier × 30 s, expect `received ≈ 300 000`.
- **`trimmed` is a new diagnostic field.** It equals `received − XLEN(region-events)` clamped to ≥0 — the number of messages that were delivered but trimmed by `MAXLEN ~ 100000`. At 10 k tier, expect `trimmed ≈ 225 000` (the older entries). At 10 and 1000 tiers, `trimmed = 0` because production volume stays under the cap.
- **`missing` now reflects real in-transit loss.** Computed as `sent − received`, both untainted by trim. For ALO/EOE under any tier or mode, expect `missing = 0`. For AMO chaos drills, expect `missing > 0` (the AMO loss mode under test, allowed by `slo.allow_missing=true`).
- **`latency_ms.*` is now true per-message e2e latency.** v1's polling-window bias is gone. At 10 k throughput, expect sub-second P99 (real pipeline propagation), not the 4–35 s figures v1 reported.
- **`received_errors`** counts transient XREAD failures from the streaming receiver. In a healthy run it is 0. A non-zero value tells operators that some samples may have been missed; it is not part of the verdict.
- **`quiescence_timeout`** is `true` if the post-drain pipeline-quiescence wait (10 s deadline) did not see both source (`XLEN(app.events)==0`) and sink (`NATS num_pending==0` for ALO/EOE only) drain in time. A healthy run reports `false`.

Between every tier run the harness now runs `nats stream purge APP_EVENTS` so accumulated bytes never trip the 200 MB pre-flight. The 256 MB stream cap is still a ceiling for in-flight bytes within one run.
```

- [ ] **Step 2: Update the "Useful checks (between runs)" section**

Find the existing block under `## Useful checks (between runs)`. Add this at the end of its code block:

```bash
# v2 report fields — what to look for in reports/{tier}-{mode}-{profile}.json
jq '.received, .trimmed, .missing, .latency_ms.p99, .quiescence_timeout' reports/10000-throughput-alo.json
```

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-connect-stress/README.md
git commit -m "redis-redpanda-connect-stress v2: README documents new report fields"
```

---

## Task 13: RESEARCH.md update

**Files:**
- Modify: `labs/redis-redpanda-connect-stress/RESEARCH.md`

Explain the v2 measurement-vs-pipeline distinction.

- [ ] **Step 1: Append a v2 section**

Open `labs/redis-redpanda-connect-stress/RESEARCH.md`. At the END of the file (before the "## Pointers" section if present, otherwise after the last paragraph), insert:

```markdown
## v2 measurement-vs-pipeline distinction

The first v1 full-matrix run on 2026-05-25 revealed that three of the lab's "failures" were measurement artifacts, not pipeline failures:

1. **Latency P99 was polling-window-biased.** v1 sampled 200 messages/s from `XRANGE`; at 10 k msg/s that captured ~2 % of messages and the reported `now − ts_ns` was inflated by up to one polling window (~1 s). v2's streaming `XREAD BLOCK` consumer reads every message at line rate, so `latency_ms.p99` now reflects true e2e propagation.
2. **`missing` confused MAXLEN trim with loss.** v1 computed `missing = sent − XLEN(region-events)`. The region stream has `MAXLEN ~ 100000`; at 10 k × 30 s, 200 k older entries were trimmed by design. v1 reported them as "missing" and failed the verdict. v2 sources `received` from the streaming consumer (untainted) and surfaces `trimmed` separately so operators can see the storage decision didn't lose messages.
3. **NATS state survived across matrix runs.** v1 ran 9 tier×mode combinations against the same persistent `nats-data` volume; the 256 MB JetStream cap accumulated bytes until the 10 k chaos run aborted on the 200 MB pre-flight. v2's harness purges `APP_EVENTS` after every run so each tier starts hermetic.

The pipeline under test (writer → connect-source → JetStream → connect-sink → region Redis) is byte-identical between v1 and v2. The only changes are in the measurement layer (collector) and the harness's between-run hygiene.

### Why a streaming consumer (not just a bigger XRANGE)

A pollthat samples 1 000 messages/s instead of 200 would still miss 90 % of messages at 10 k msg/s, and its reported "latency" would still include polling-window bias. The streaming model is the only one that observes *every* message at arrival time, which is both the right metric and a side benefit: the same consumer that records latency also provides the trim-free `received` count.

### Why profile-aware quiescence

The amo-reverse leg uses an ephemeral, deliver-new, `ack_wait: 2s`, `auto_replay_nacks: false` consumer. `num_pending` is meaningless for that consumer (it's recreated each connect-sink restart and ignores backlog by design — that's how AMO loses messages). v2's pipeline-quiescence wait checks `XLEN(app.events) == 0` for all profiles plus `NATS num_pending == 0` only for ALO/EOE; AMO falls through to `slo.allow_missing=true` so any unconsumed backlog at end-of-run is accepted as the modeled loss.
```

- [ ] **Step 2: Commit**

```bash
git add labs/redis-redpanda-connect-stress/RESEARCH.md
git commit -m "redis-redpanda-connect-stress v2: RESEARCH documents measurement-vs-pipeline distinction"
```

---

## Task 14: Smoke verification

**Files:** none (validation only)

Hand-run the same checklist as v1, plus a 10k chaos check that v1 couldn't complete.

- [ ] **Step 1: Boot the lab fresh**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress
docker compose down -v >/dev/null 2>&1 || true
docker compose up -d --wait
```

Expected: every service health-checks green within ~30 s.

- [ ] **Step 2: Sanity tier (10 msg/s throughput)**

```bash
bash scripts/stress-run.sh --tiers=10 --modes=throughput
```

Expected output (summary table row):
- `rate_achieved ≈ 9.5-10.0/10`
- `missing = 0`
- `trimmed = 0`
- `p99` well under 1000 ms (down from v1's 4–9 s polling artifact)
- `verdict = PASS`

Inspect `reports/10-throughput-alo.json` and verify the three new fields exist:
```bash
jq '.received_errors, .trimmed, .quiescence_timeout' reports/10-throughput-alo.json
```
Expected: `0`, `0`, `false`.

- [ ] **Step 3: Mid tier + latency mode (1000 msg/s)**

```bash
bash scripts/stress-run.sh --tiers=1000 --modes=throughput,latency
```

Expected: both rows `verdict = PASS`. `latency` mode's `p99 < 1000 ms` (the SLO that v1 always failed). `trimmed = 0`.

- [ ] **Step 4: 10k throughput**

```bash
bash scripts/stress-run.sh --tiers=10000 --modes=throughput
```

Expected:
- `rate_achieved ≈ 9000-10000/10000`
- `missing = 0` (the v1 false-positive is gone)
- `trimmed ≈ 200000-225000` (the diagnostic that v1 silently misclassified as loss)
- `verdict = PASS`

- [ ] **Step 5: 10k chaos (the v1 ABORT case)**

```bash
bash scripts/stress-run.sh --tiers=10000 --modes=chaos
```

Expected: completes without ABORT (v1 aborted here due to NATS byte accumulation; v2's purge prevents it). Verdict should PASS for ALO with `missing = 0`, `trimmed ≈ 225000`, `recovery_lag_max > 0` in the chaos block.

- [ ] **Step 6: Full matrix**

```bash
docker compose down -v
bash scripts/stress-run.sh
```

Expected: all 9 rows complete; full summary table renders with the `trimmed` column; auto-teardown at end. Aggregate exit code 0 if every verdict is PASS.

- [ ] **Step 7: If verification surfaces minor issues, commit fixes**

```bash
git add labs/redis-redpanda-connect-stress/
git commit -m "redis-redpanda-connect-stress v2: smoke-verification cleanup"
```

If nothing needed adjusting, skip this step.

---

## Self-review notes

**Spec coverage:**
- §1 Goal → all tasks
- §2 v1 flaws being fixed → A: Tasks 2-4 + 7 (streaming consumer); B: Tasks 1, 8, 9 (trimmed + buildReport); C: Tasks 5, 6, 11 (quiescence + purge)
- §3 Non-goals → respected (no writer/Connect/compose changes)
- §4 Architecture → Tasks 7 + 9 (snapshot shrinks; receiver added)
- §5 Streaming consumer → Tasks 2, 3, 4
- §6 Lifecycle → Task 9 (Run rewrite); steps 11/15/16 covered by Tasks 5+8+9
- §6.3 Profile-aware quiescence → Tasks 5+6 (ALO/EOE + AMO branches with tests)
- §6.4 Synchronized cut + readFinalRegionXLen → Task 8
- §7 Report semantics → Task 1 (fields) + Task 9 (buildReport)
- §8 Snapshot loop changes → Task 7 (deprecated) + Task 9 (final removal)
- §9 Harness change → Task 11 (purge + summary column)
- §10 Summary table → Task 11
- §11 File map → matches all task files
- §12 Testing approach → Tasks 1, 3, 5, 6, 8 (unit) + Task 14 (smoke)
- §13 Risks → addressed (receiver back-pressure left as-is per spec; NATS purge timing covered by §6.3 quiescence)
- §14 Out of scope → not implemented (correct)

No placeholders, no "implement later", no "similar to Task N" references. All code blocks complete.

**Type consistency check (manually verified across tasks):**
- `Receiver` struct: fields `rdb`, `stream`, `latency`, `received`, `errCount`, `lastID` (Tasks 2, 3, 4) — consistent.
- `Receiver` methods: `NewReceiver(addr, stream)`, `Count()`, `Errors()`, `Latency()`, `Close()`, `Run(ctx)`, `processStreams(streams, nowNs)` — consistent across Tasks 2-4 and 9.
- `xlenReader` interface (Task 5, 8): `XLen(ctx, key) (int64, error)` — `*StreamClient` from redis.go already satisfies this.
- `waitForPipelineQuiescence(ctx, profile, central, natsURL, natsStream, deadline) (timedOut bool)` — signature matches in Tasks 5, 6, 9.
- `readFinalRegionXLen(ctx, region, snaps) int64` — matches Tasks 8 and 9.
- `buildReport(cfg, startedAt, snaps, receiver, finalRegionXLen, quiescenceTimedOut) Report` — matches Tasks 9 (signature) and the Report struct from Task 1.
- `Report.ReceivedErrors`, `.Trimmed`, `.QuiescenceTimeout` — defined in Task 1, referenced in Task 9.
- `Sampler` struct: Task 7 deprecates `Latency`/`LastRegionID`; Task 9 deletes them. `main.go` in Task 9 constructs Sampler without those fields.

**Test order:** TDD tasks (1, 3, 5, 6, 8) each follow write-test → run-failing → implement → run-passing → commit. Integration tasks (4 for Run, 7 for shrink, 9 for wiring, 11 for harness) rely on Task 14 smoke verification.

**Spec→test backlinks:**
- §6.3.1 ALO/EOE condition → `TestWaitQuiescenceAloReturnsFalseWhenBothQueuesDrain`, `TestWaitQuiescenceAloReturnsTrueWhenSourceStuck`, `TestWaitQuiescenceAloReturnsTrueWhenSinkStuck` (Task 5)
- §6.3.1 AMO condition → `TestWaitQuiescenceAmoSkipsPendingCheck`, `TestWaitQuiescenceAmoStillRequiresSourceDrain` (Task 6)
- §6.4 fallback semantics → `TestReadFinalRegionXLenFallsBackToLastSnap`, `TestReadFinalRegionXLenReturnsZeroWhenNoFallback` (Task 8)
- §5.2 message counting independent of payload validity → `TestReceiverProcessStreamsCountsBadPayloadButSkipsLatency` (Task 3)
- §7 new fields JSON tags → existing `TestReportJSONShape` extended (Task 1)
