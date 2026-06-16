# Region-side CDC Latency Calculator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a region-side Go service that measures CDC propagation latency (`sink_ts − writer_ts`) from a sidecar Redis stream and periodically writes a p50/p95/p99 JSON report, and consolidate all lab Go programs into one image built from one Dockerfile + a `go.work` workspace.

**Architecture:** The sink Connect leg emits a best-effort `cdc:latency` record (op, kv_key, writer_ts, sink_ts) to region Redis after each create/update SET. A new `latency-calculator` Deployment (region-Redis-only) consumes that stream via `XRANGE`, keeps a rolling time window, and writes an atomic JSON report to a volume. All five Go programs (writer, verifier, elector, dashboard, latency-calculator) ship in one image whose default entrypoint is `sleep infinity`; each manifest overrides `command:`.

**Tech Stack:** Go 1.25, `github.com/redis/go-redis/v9`, Redpanda Connect (Bloblang), Helm, Docker (BuildKit), Alpine.

**Spec:** `docs/superpowers/specs/2026-06-16-redis-cdc-le-region-latency-calculator-design.md`

**Working directory for all paths below:** `redis-cdc-le-k8s/`

---

## File Structure

**New — `redis-cdc-le-k8s/latency-calculator/` (Go module `latency-calculator`):**
- `percentile.go` / `percentile_test.go` — nearest-rank percentile + `Stats` summary.
- `window.go` / `window_test.go` — `Sample` type, rolling window, negative-drop counter.
- `stream.go` / `stream_test.go` — parse a stream entry's fields into a `Sample`.
- `report.go` / `report_test.go` — report structs, `BuildReport`, atomic file write.
- `consumer.go` — go-redis `XRANGE` cursor consumer (no unit test; live-Redis, lab-tested — matches the existing `verifier/redis.go` convention).
- `main.go` — env config + ticker loop + signal handling.
- `go.mod` / `go.sum`.

**New at lab root:**
- `go.work` / `go.work.sum` — workspace over all five modules.
- `Dockerfile` — single multi-binary image.
- `chart/templates/latency-calculator.yaml` — gated Deployment.

**Modified:**
- `chart/files/connect/cdc-reverse.yaml` — sink latency XADD.
- `chart/values.yaml` — `images.app`, remove per-component image refs, add `latencyCalculator` block + `resources.latencyCalculator`.
- `chart/templates/writer.yaml`, `verifier-job.yaml`, `dashboard.yaml`, `connect-source.yaml`, `connect-sink.yaml` — `command:` overrides + `images.app`.
- `scripts/build-images.sh` — single image build/load/push.
- `README.md`, `chart/templates/NOTES.txt`, `docs/nats-jetstream-and-redis-kv-message-flow.md` — docs.

**Deleted:** `writer/Dockerfile`, `verifier/Dockerfile`, `elector/Dockerfile`, `dashboard/Dockerfile`.

---

## Task 1: Percentile + Stats

**Files:**
- Create: `redis-cdc-le-k8s/latency-calculator/percentile.go`
- Test: `redis-cdc-le-k8s/latency-calculator/percentile_test.go`

- [ ] **Step 1: Write the failing test**

`latency-calculator/percentile_test.go`:
```go
package main

import "testing"

func TestPercentileNearestRank(t *testing.T) {
	s := []int64{10, 20, 30, 40, 50}
	cases := []struct {
		p    float64
		want int64
	}{{50, 30}, {95, 50}, {99, 50}, {0, 10}}
	for _, c := range cases {
		if got := Percentile(s, c.p); got != c.want {
			t.Errorf("Percentile(p=%v)=%d want %d", c.p, got, c.want)
		}
	}
}

func TestSummarizeEmpty(t *testing.T) {
	if got := Summarize(nil); got != (Stats{}) {
		t.Errorf("Summarize(nil)=%+v want zero", got)
	}
}

func TestSummarizeSingle(t *testing.T) {
	got := Summarize([]int64{42})
	want := Stats{Count: 1, MinMs: 42, MaxMs: 42, MeanMs: 42, P50Ms: 42, P95Ms: 42, P99Ms: 42}
	if got != want {
		t.Errorf("Summarize([42])=%+v want %+v", got, want)
	}
}

func TestSummarizeN2P99IsMax(t *testing.T) {
	got := Summarize([]int64{90, 10}) // unsorted input
	if got.Count != 2 || got.MinMs != 10 || got.MaxMs != 90 || got.MeanMs != 50 {
		t.Fatalf("basic stats wrong: %+v", got)
	}
	if got.P50Ms != 10 || got.P99Ms != 90 {
		t.Errorf("N=2 p50=%d (want 10) p99=%d (want 90=max)", got.P50Ms, got.P99Ms)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd redis-cdc-le-k8s/latency-calculator && go test ./... 2>&1 | head`
Expected: build failure — `undefined: Percentile` / `Summarize` / `Stats`.

- [ ] **Step 3: Write the implementation**

`latency-calculator/percentile.go`:
```go
// Nearest-rank percentile and per-bucket summary statistics.
package main

import (
	"math"
	"sort"
)

// Stats is the summary block emitted for each report bucket (overall / per-op).
type Stats struct {
	Count  int     `json:"count"`
	MinMs  int64   `json:"min_ms"`
	MaxMs  int64   `json:"max_ms"`
	MeanMs float64 `json:"mean_ms"`
	P50Ms  int64   `json:"p50_ms"`
	P95Ms  int64   `json:"p95_ms"`
	P99Ms  int64   `json:"p99_ms"`
}

// Percentile returns the nearest-rank percentile (p in [0,100]) of an
// ascending-sorted slice. Empty slice returns 0.
func Percentile(sorted []int64, p float64) int64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	rank := int(math.Ceil(p / 100 * float64(n)))
	if rank < 1 {
		rank = 1
	}
	if rank > n {
		rank = n
	}
	return sorted[rank-1]
}

// Summarize computes count/min/max/mean and p50/p95/p99 over latencies (any order).
func Summarize(latencies []int64) Stats {
	n := len(latencies)
	if n == 0 {
		return Stats{}
	}
	s := append([]int64(nil), latencies...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	var sum int64
	for _, v := range s {
		sum += v
	}
	return Stats{
		Count:  n,
		MinMs:  s[0],
		MaxMs:  s[n-1],
		MeanMs: float64(sum) / float64(n),
		P50Ms:  Percentile(s, 50),
		P95Ms:  Percentile(s, 95),
		P99Ms:  Percentile(s, 99),
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd redis-cdc-le-k8s/latency-calculator && go test ./...`
Expected: PASS (`ok  latency-calculator`).

- [ ] **Step 5: Commit**

```bash
cd redis-cdc-le-k8s
git add latency-calculator/percentile.go latency-calculator/percentile_test.go
git commit -m "latency-calculator: nearest-rank percentile + Stats summary"
```

---

## Task 2: Rolling window + negative-drop

**Files:**
- Create: `redis-cdc-le-k8s/latency-calculator/window.go`
- Test: `redis-cdc-le-k8s/latency-calculator/window_test.go`

- [ ] **Step 1: Write the failing test**

`latency-calculator/window_test.go`:
```go
package main

import "testing"

func TestAddDropsNegative(t *testing.T) {
	w := NewWindow(60_000)
	w.Add(Sample{Op: "create", LatencyMs: -5, SinkTs: 1000})
	w.Add(Sample{Op: "create", LatencyMs: 7, SinkTs: 1000})
	if w.DroppedNegative() != 1 {
		t.Errorf("droppedNegative=%d want 1", w.DroppedNegative())
	}
	if len(w.Samples()) != 1 || w.Samples()[0].LatencyMs != 7 {
		t.Errorf("samples=%+v want one positive", w.Samples())
	}
}

func TestEvictBySinkTs(t *testing.T) {
	w := NewWindow(1000) // 1s window
	w.Add(Sample{Op: "update", LatencyMs: 1, SinkTs: 9500})
	w.Add(Sample{Op: "update", LatencyMs: 2, SinkTs: 8000})
	w.Evict(10000) // cutoff = 9000
	if len(w.Samples()) != 1 || w.Samples()[0].SinkTs != 9500 {
		t.Errorf("after evict samples=%+v want only sinkTs=9500", w.Samples())
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd redis-cdc-le-k8s/latency-calculator && go test ./... 2>&1 | head`
Expected: build failure — `undefined: NewWindow` / `Sample`.

- [ ] **Step 3: Write the implementation**

`latency-calculator/window.go`:
```go
// Rolling time window of latency samples, evicted by event (sink) time.
package main

// Sample is one create/update apply observed via the cdc:latency stream.
type Sample struct {
	Op        string // "create" | "update"
	LatencyMs int64  // sink_ts - writer_ts
	SinkTs    int64  // unix millis, the eviction key
}

// Window holds the in-memory rolling set of samples plus a cumulative
// negative-latency drop counter (negatives are clock-skew artifacts).
type Window struct {
	windowMs        int64
	samples         []Sample
	droppedNegative int
}

func NewWindow(windowMs int64) *Window { return &Window{windowMs: windowMs} }

// Add stores a sample, dropping (and counting) any with negative latency.
func (w *Window) Add(s Sample) {
	if s.LatencyMs < 0 {
		w.droppedNegative++
		return
	}
	w.samples = append(w.samples, s)
}

// Evict removes samples whose SinkTs is older than nowMs - windowMs.
func (w *Window) Evict(nowMs int64) {
	cutoff := nowMs - w.windowMs
	kept := w.samples[:0]
	for _, s := range w.samples {
		if s.SinkTs >= cutoff {
			kept = append(kept, s)
		}
	}
	w.samples = kept
}

func (w *Window) Samples() []Sample      { return w.samples }
func (w *Window) DroppedNegative() int   { return w.droppedNegative }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd redis-cdc-le-k8s/latency-calculator && go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd redis-cdc-le-k8s
git add latency-calculator/window.go latency-calculator/window_test.go
git commit -m "latency-calculator: rolling window with negative-drop"
```

---

## Task 3: Stream-entry parsing

**Files:**
- Create: `redis-cdc-le-k8s/latency-calculator/stream.go`
- Test: `redis-cdc-le-k8s/latency-calculator/stream_test.go`

- [ ] **Step 1: Write the failing test**

`latency-calculator/stream_test.go`:
```go
package main

import "testing"

func TestParseSampleOK(t *testing.T) {
	got, err := ParseSample(map[string]string{
		"op": "update", "kv_key": "k", "writer_ts": "100", "sink_ts": "150",
	})
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := Sample{Op: "update", LatencyMs: 50, SinkTs: 150}
	if got != want {
		t.Errorf("ParseSample=%+v want %+v", got, want)
	}
}

func TestParseSampleErrors(t *testing.T) {
	cases := map[string]map[string]string{
		"bad op":      {"op": "delete", "writer_ts": "1", "sink_ts": "2"},
		"missing sts": {"op": "create", "writer_ts": "1"},
		"nonnumeric":  {"op": "create", "writer_ts": "abc", "sink_ts": "2"},
	}
	for name, f := range cases {
		if _, err := ParseSample(f); err == nil {
			t.Errorf("%s: expected error, got nil", name)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd redis-cdc-le-k8s/latency-calculator && go test ./... 2>&1 | head`
Expected: build failure — `undefined: ParseSample`.

- [ ] **Step 3: Write the implementation**

`latency-calculator/stream.go`:
```go
// Parse a cdc:latency stream entry's field map into a Sample.
package main

import (
	"fmt"
	"strconv"
)

// ParseSample converts XRANGE entry fields into a Sample. Only create/update
// are expected (the sink emits no latency record for delete/rename).
func ParseSample(fields map[string]string) (Sample, error) {
	op := fields["op"]
	if op != "create" && op != "update" {
		return Sample{}, fmt.Errorf("unexpected op %q", op)
	}
	wts, err := strconv.ParseInt(fields["writer_ts"], 10, 64)
	if err != nil {
		return Sample{}, fmt.Errorf("writer_ts %q: %w", fields["writer_ts"], err)
	}
	sts, err := strconv.ParseInt(fields["sink_ts"], 10, 64)
	if err != nil {
		return Sample{}, fmt.Errorf("sink_ts %q: %w", fields["sink_ts"], err)
	}
	return Sample{Op: op, LatencyMs: sts - wts, SinkTs: sts}, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd redis-cdc-le-k8s/latency-calculator && go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd redis-cdc-le-k8s
git add latency-calculator/stream.go latency-calculator/stream_test.go
git commit -m "latency-calculator: parse cdc:latency stream entries"
```

---

## Task 4: Report build + atomic write

**Files:**
- Create: `redis-cdc-le-k8s/latency-calculator/report.go`
- Test: `redis-cdc-le-k8s/latency-calculator/report_test.go`

- [ ] **Step 1: Write the failing test**

`latency-calculator/report_test.go`:
```go
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestBuildReportShape(t *testing.T) {
	w := NewWindow(60_000)
	w.Add(Sample{Op: "create", LatencyMs: 10, SinkTs: 1000})
	w.Add(Sample{Op: "create", LatencyMs: 20, SinkTs: 1000})
	w.Add(Sample{Op: "update", LatencyMs: 30, SinkTs: 1000})
	w.Add(Sample{Op: "create", LatencyMs: -1, SinkTs: 1000}) // dropped
	cfg := ConfigMeta{IntervalSec: 10, WindowSec: 60, Stream: "cdc:latency"}

	rep := BuildReport(w, 1_700_000_000_000, cfg)

	if rep.Overall.Count != 3 || rep.Overall.DroppedNegative != 1 {
		t.Errorf("overall count=%d dropped=%d want 3,1", rep.Overall.Count, rep.Overall.DroppedNegative)
	}
	if rep.ByOp["create"].Count != 2 || rep.ByOp["update"].Count != 1 {
		t.Errorf("by_op counts wrong: %+v", rep.ByOp)
	}
	if rep.Window.DurationSec != 60 || rep.Config.Stream != "cdc:latency" {
		t.Errorf("meta wrong: window=%+v config=%+v", rep.Window, rep.Config)
	}
	if rep.GeneratedAt == "" || rep.Window.Start == "" || rep.Window.End == "" {
		t.Errorf("timestamps empty: %+v", rep)
	}
}

func TestWriteReportAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latency-report.json")
	rep := BuildReport(NewWindow(60_000), 1_700_000_000_000, ConfigMeta{WindowSec: 60})
	if err := WriteReportAtomic(path, rep); err != nil {
		t.Fatalf("write: %v", err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var back Report
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if back.Window.DurationSec != 60 {
		t.Errorf("round-trip lost data: %+v", back)
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("temp file should not remain")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd redis-cdc-le-k8s/latency-calculator && go test ./... 2>&1 | head`
Expected: build failure — `undefined: BuildReport` / `ConfigMeta` / `Report` / `WriteReportAtomic`.

- [ ] **Step 3: Write the implementation**

`latency-calculator/report.go`:
```go
// Report structs, builder, and atomic JSON file writer.
package main

import (
	"encoding/json"
	"os"
	"time"
)

type WindowMeta struct {
	Start       string `json:"start"`
	End         string `json:"end"`
	DurationSec int    `json:"duration_sec"`
}

type ConfigMeta struct {
	IntervalSec int    `json:"interval_sec"`
	WindowSec   int    `json:"window_sec"`
	Stream      string `json:"stream"`
}

// OverallStats embeds the per-bucket Stats and adds the cumulative drop counter.
type OverallStats struct {
	Stats
	DroppedNegative int `json:"dropped_negative"`
}

type Report struct {
	GeneratedAt string           `json:"generated_at"`
	Window      WindowMeta       `json:"window"`
	Config      ConfigMeta       `json:"config"`
	Overall     OverallStats     `json:"overall"`
	ByOp        map[string]Stats `json:"by_op"`
}

func msToRFC3339(ms int64) string {
	return time.UnixMilli(ms).UTC().Format(time.RFC3339)
}

// BuildReport summarizes the window's current samples as of nowMs.
func BuildReport(w *Window, nowMs int64, cfg ConfigMeta) Report {
	all := w.Samples()
	overall := make([]int64, 0, len(all))
	byOp := map[string][]int64{"create": nil, "update": nil}
	for _, s := range all {
		overall = append(overall, s.LatencyMs)
		byOp[s.Op] = append(byOp[s.Op], s.LatencyMs)
	}
	return Report{
		GeneratedAt: msToRFC3339(nowMs),
		Window: WindowMeta{
			Start:       msToRFC3339(nowMs - int64(cfg.WindowSec)*1000),
			End:         msToRFC3339(nowMs),
			DurationSec: cfg.WindowSec,
		},
		Config:  cfg,
		Overall: OverallStats{Stats: Summarize(overall), DroppedNegative: w.DroppedNegative()},
		ByOp: map[string]Stats{
			"create": Summarize(byOp["create"]),
			"update": Summarize(byOp["update"]),
		},
	}
}

// WriteReportAtomic writes r as pretty JSON via a same-directory temp file +
// rename, so readers never observe a partial file.
func WriteReportAtomic(path string, r Report) error {
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd redis-cdc-le-k8s/latency-calculator && go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd redis-cdc-le-k8s
git add latency-calculator/report.go latency-calculator/report_test.go
git commit -m "latency-calculator: report build + atomic write"
```

---

## Task 5: Consumer + main + go.mod (wire-up)

**Files:**
- Create: `redis-cdc-le-k8s/latency-calculator/consumer.go`
- Create: `redis-cdc-le-k8s/latency-calculator/main.go`
- Create: `redis-cdc-le-k8s/latency-calculator/go.mod`

Note: `consumer.go` and `main.go` do live Redis I/O and process wiring — no unit tests, matching the existing `verifier/redis.go` / `verifier/main.go` convention. They are exercised by the lab run in Task 13.

- [ ] **Step 1: Create `go.mod`**

`latency-calculator/go.mod`:
```
module latency-calculator

go 1.25.0

require github.com/redis/go-redis/v9 v9.19.0

require (
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/dgryski/go-rendezvous v0.0.0-20200823014737-9f7001d12a5f // indirect
)
```

- [ ] **Step 2: Write `consumer.go`**

`latency-calculator/consumer.go`:
```go
// go-redis XRANGE cursor consumer for the cdc:latency sidecar stream.
package main

import (
	"context"
	"log"

	"github.com/redis/go-redis/v9"
)

type Consumer struct {
	rdb    *redis.Client
	stream string
	lastID string
}

func NewConsumer(rdb *redis.Client, stream string) *Consumer {
	return &Consumer{rdb: rdb, stream: stream, lastID: "0-0"}
}

// Seek moves the cursor to the current stream tail so only NEW entries are read
// (cold start). A missing stream leaves the cursor at 0-0 (reads future entries).
func (c *Consumer) Seek(ctx context.Context) error {
	msgs, err := c.rdb.XRevRangeN(ctx, c.stream, "+", "-", 1).Result()
	if err != nil {
		return err
	}
	if len(msgs) > 0 {
		c.lastID = msgs[0].ID
	}
	return nil
}

// Poll drains all parseable samples after the cursor, advancing it. Entries that
// fail to parse are logged and skipped (best-effort telemetry).
func (c *Consumer) Poll(ctx context.Context) ([]Sample, error) {
	var out []Sample
	for {
		msgs, err := c.rdb.XRangeN(ctx, c.stream, "("+c.lastID, "+", 1000).Result()
		if err != nil {
			return out, err
		}
		if len(msgs) == 0 {
			break
		}
		for _, m := range msgs {
			c.lastID = m.ID
			f := make(map[string]string, len(m.Values))
			for k, v := range m.Values {
				if s, ok := v.(string); ok {
					f[k] = s
				}
			}
			s, err := ParseSample(f)
			if err != nil {
				log.Printf("skip entry %s: %v", m.ID, err)
				continue
			}
			out = append(out, s)
		}
		if len(msgs) < 1000 {
			break
		}
	}
	return out, nil
}
```

- [ ] **Step 3: Write `main.go`**

`latency-calculator/main.go`:
```go
// latency-calculator: consume the region cdc:latency stream, keep a rolling
// window, and periodically write a p50/p95/p99 JSON report. Region-Redis only.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func env(k, def string) string {
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
		log.Printf("WARN: %s=%q not an int, using %d", k, os.Getenv(k), def)
	}
	return def
}

func main() {
	addr := env("REGION_ADDR", "redis-region:6379")
	stream := env("STREAM", "cdc:latency")
	windowSec := envInt("WINDOW_SEC", 60)
	intervalSec := envInt("INTERVAL_SEC", 10)
	reportPath := env("REPORT_PATH", "/reports/latency-report.json")

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	rdb := redis.NewClient(&redis.Options{Addr: addr})
	defer rdb.Close()

	cons := NewConsumer(rdb, stream)
	if err := cons.Seek(ctx); err != nil {
		log.Printf("seek (continuing from 0-0): %v", err)
	}
	win := NewWindow(int64(windowSec) * 1000)
	cfg := ConfigMeta{IntervalSec: intervalSec, WindowSec: windowSec, Stream: stream}

	log.Printf("latency-calculator: addr=%s stream=%s window=%ds interval=%ds report=%s",
		addr, stream, windowSec, intervalSec, reportPath)

	ticker := time.NewTicker(time.Duration(intervalSec) * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Print("shutting down")
			return
		case t := <-ticker.C:
			samples, err := cons.Poll(ctx)
			if err != nil {
				log.Printf("poll: %v", err)
				continue
			}
			for _, s := range samples {
				win.Add(s)
			}
			nowMs := t.UnixMilli()
			win.Evict(nowMs)
			rep := BuildReport(win, nowMs, cfg)
			if err := WriteReportAtomic(reportPath, rep); err != nil {
				log.Printf("write report: %v", err)
				continue
			}
			log.Printf("report: count=%d p50=%d p95=%d p99=%d dropped_neg=%d",
				rep.Overall.Count, rep.Overall.P50Ms, rep.Overall.P95Ms,
				rep.Overall.P99Ms, rep.Overall.DroppedNegative)
		}
	}
}
```

- [ ] **Step 4: Resolve deps and build**

Run:
```bash
cd redis-cdc-le-k8s/latency-calculator
go mod tidy
go build ./...
go test ./...
go vet ./...
```
Expected: `go mod tidy` writes `go.sum` (locally); build and tests PASS; vet clean.

**Important:** `go.sum` is **gitignored repo-wide** (root `.gitignore` has `go.sum`) — every module regenerates it at build time and it is NEVER committed. Do not `git add` any `go.sum` (git will refuse an ignored path). The same applies to `go.work.sum` (see Task 6).

- [ ] **Step 5: Commit**

```bash
cd redis-cdc-le-k8s
git add latency-calculator/consumer.go latency-calculator/main.go latency-calculator/go.mod
git commit -m "latency-calculator: redis consumer + main wiring"
```

---

## Task 6: `go.work` workspace

**Files:**
- Create: `redis-cdc-le-k8s/go.work` (committed)
- Create: `redis-cdc-le-k8s/go.work.sum` (generated locally, **gitignored** — not committed)
- Modify: root `.gitignore`

- [ ] **Step 1: Initialize the workspace**

Run:
```bash
cd redis-cdc-le-k8s
go work init ./writer ./verifier ./elector ./dashboard ./latency-calculator
```
This creates `go.work`. Verify its contents match:
```
go 1.25.0

use (
	./writer
	./verifier
	./elector
	./dashboard
	./latency-calculator
)
```
If the `go` directive differs (e.g. `go 1.25`), leave whatever `go work init` produced — it must be ≥ every module's version.

- [ ] **Step 2: Sync and build across the workspace**

Run:
```bash
cd redis-cdc-le-k8s
go work sync
go build ./...
go test ./...
```
Expected: `go.work.sum` is created locally; all five modules build; all tests PASS.

- [ ] **Step 3: Gitignore `go.work.sum`** (consistent with the repo's gitignored `go.sum`)

Append to the **root** `.gitignore` (the file at repo root, under its `# Go` section):
```
go.work.sum
```
Verify it is ignored: `git check-ignore redis-cdc-le-k8s/go.work.sum` prints the path.

- [ ] **Step 4: Commit**

```bash
cd redis-cdc-le-k8s
git add go.work ../.gitignore
git commit -m "redis-cdc-le-k8s: add go.work over all five Go modules (go.work.sum gitignored)"
```

---

## Task 7: Single consolidated Dockerfile

**Files:**
- Create: `redis-cdc-le-k8s/Dockerfile`
- Delete: `writer/Dockerfile`, `verifier/Dockerfile`, `elector/Dockerfile`, `dashboard/Dockerfile`

- [ ] **Step 1: Write `Dockerfile` (lab root)**

`redis-cdc-le-k8s/Dockerfile`:
```dockerfile
# syntax=docker/dockerfile:1.7
# Single image for ALL lab Go programs. Default entrypoint idles on `sleep
# infinity`; each k8s manifest overrides `command:` to run a specific binary.
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
# go.sum / go.work.sum are gitignored repo-wide and never copied in; -mod=mod lets
# `go build` download deps and (re)generate the sums in-layer, mirroring how the
# old per-module Dockerfiles relied on `go mod download` to regenerate go.sum.
ENV GOFLAGS=-mod=mod
# Workspace + all module sources (BuildKit cache mounts handle module/build cache).
COPY go.work ./
COPY writer/ ./writer/
COPY verifier/ ./verifier/
COPY elector/ ./elector/
COPY dashboard/ ./dashboard/
COPY latency-calculator/ ./latency-calculator/
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    for app in writer verifier elector dashboard latency-calculator; do \
      CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/$app ./$app; \
    done

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
# Union of the runtime deps the separate images needed: tini (elector PID1),
# wget (writer/initContainer probes), ca-certificates (all).
RUN apk add --no-cache ca-certificates tini wget \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/ /usr/local/bin/
# Idle by default; manifests MUST set `command:` to run a real binary.
ENTRYPOINT ["sleep", "infinity"]
```

- [ ] **Step 2: Build the image**

Run:
```bash
cd redis-cdc-le-k8s
DOCKER_BUILDKIT=1 docker build -t redis-rrcs/cdc-apps:dev .
```
Expected: build succeeds.

- [ ] **Step 3: Verify binaries and idle entrypoint**

Run:
```bash
docker run --rm --entrypoint ls redis-rrcs/cdc-apps:dev -1 /usr/local/bin
```
Expected: lists `dashboard elector latency-calculator verifier writer`.

Run:
```bash
timeout 3 docker run --rm redis-rrcs/cdc-apps:dev; echo "rc=$?"
```
Expected: `rc=124` (still running on `sleep infinity` until the timeout kills it).

- [ ] **Step 4: Delete the per-component Dockerfiles**

Run:
```bash
cd redis-cdc-le-k8s
git rm writer/Dockerfile verifier/Dockerfile elector/Dockerfile dashboard/Dockerfile
```

- [ ] **Step 5: Commit**

```bash
cd redis-cdc-le-k8s
git add Dockerfile
git commit -m "redis-cdc-le-k8s: single multi-binary Dockerfile (sleep infinity entrypoint)"
```

---

## Task 8: `build-images.sh` single-image refactor

**Files:**
- Modify: `redis-cdc-le-k8s/scripts/build-images.sh`

- [ ] **Step 1: Replace the per-component image refs and build/load/push blocks**

Replace the block that defines `WRITER_IMG`…`ELECTOR_IMG` and the `build_one … "${ELECTOR_IMG}"` calls, the `kind load` block, and the `docker push` block with a single-image version. The final body (from the `prefix=` line to EOF) becomes:

```bash
# Single consolidated image holding every Go binary. REGISTRY (if set) prefixes
# the local name; must match values images.registry so the chart pulls what we built.
prefix=""
[[ -n "${REGISTRY}" ]] && prefix="${REGISTRY%/}/"
APP_IMG="${prefix}redis-rrcs/cdc-apps:${TAG}"

echo "[build] ${APP_IMG} (BASE_REGISTRY='${BASE_REGISTRY}')"
DOCKER_BUILDKIT=1 docker build --build-arg "BASE_REGISTRY=${BASE_REGISTRY}" -t "${APP_IMG}" .

if (( KIND )); then
  echo "[kind] loading image into cluster '${KIND_NAME}'"
  kind load docker-image "${APP_IMG}" --name "${KIND_NAME}"
fi

if (( PUSH )); then
  if [[ -z "${REGISTRY}" ]]; then
    echo "[push] --push requires --registry=<ref>" >&2
    exit 2
  fi
  echo "[push] pushing to ${REGISTRY}"
  docker push "${APP_IMG}"
else
  echo "[push] skipped (no --push). Built locally:"
  echo "  ${APP_IMG}"
fi
```

Also update the header comment (line 2) from:
```bash
# Builds the writer, verifier, dashboard and elector images. Push and kind-load are opt-in.
```
to:
```bash
# Builds the single consolidated app image (writer/verifier/elector/dashboard/latency-calculator). Push and kind-load are opt-in.
```

Note: the `cd "${LAB_DIR}"` already at the top means the `docker build .` context is the lab root (where the Dockerfile and go.work live). The old `build_one()` function is no longer used — remove its definition.

- [ ] **Step 2: Smoke-test the script**

Run:
```bash
cd redis-cdc-le-k8s
bash -n scripts/build-images.sh && scripts/build-images.sh --help
scripts/build-images.sh   # build-only
docker images | grep redis-rrcs/cdc-apps
```
Expected: syntax OK; help prints; one `redis-rrcs/cdc-apps:dev` image present.

- [ ] **Step 3: Commit**

```bash
cd redis-cdc-le-k8s
git add scripts/build-images.sh
git commit -m "redis-cdc-le-k8s: build-images.sh builds single consolidated image"
```

---

## Task 9: `values.yaml` — shared image, latencyCalculator block

**Files:**
- Modify: `redis-cdc-le-k8s/chart/values.yaml`

- [ ] **Step 1: Add `app` to the `images` block**

Find the `images:` block (around line 21) and add an `app:` ref under it:
```yaml
images:
  registry: ""              # prepended to every image ref. "" => use ref as-is.
  app: redis-rrcs/cdc-apps:dev   # single image for ALL Go programs (command: per workload)
  pullPolicy: IfNotPresent  # global default; public images need this on kind.
```
(Leave `pullSecrets` / other existing keys untouched.)

- [ ] **Step 2: Remove the four per-component `image:` refs**

In each component block, delete only the `image:` line (keep `pullPolicy` and everything else):
- `elector:` — remove `image: redis-rrcs/elector:dev`
- `writer:` — remove `image: redis-rrcs/writer:dev`
- `dashboard:` — remove `image: redis-rrcs/dashboard:dev`
- `verifier:` — remove `image: redis-rrcs/verifier:dev`

After this, e.g. the `elector:` block reads:
```yaml
elector:
  pullPolicy: ""            # "" => inherit images.pullPolicy
```

- [ ] **Step 3: Add the `latencyCalculator` block**

Add a new top-level block (place it right after the `verifier:` block):
```yaml
latencyCalculator:
  enabled: false           # off by default, like other optional components
  pullPolicy: ""           # "" => inherit images.pullPolicy
  # Sidecar stream the sink writes to and the calculator reads. These exist even
  # when enabled=false, because the sink emits the stream unconditionally so
  # enabling the calculator later still finds data.
  stream: "cdc:latency"
  # Rate-dependent: set to at least ~2x the peak XADD rate per intervalSec so the
  # approximate MAXLEN ~ trim cannot evict entries before the calculator reads
  # them (lost samples only, never lost CDC).
  streamMaxLen: 50000
  windowSec: 60            # rolling window for percentiles
  intervalSec: 10          # report write cadence
  reportPath: /reports/latency-report.json
  persistence:
    enabled: false         # false => emptyDir at /reports; true => PVC
    size: 1Gi
    storageClass: ""
```

- [ ] **Step 4: Add `resources.latencyCalculator`**

In the `resources:` block, add an entry mirroring the shape of `resources.writer` (find the existing block to copy the exact field style). Add:
```yaml
  latencyCalculator:
    requests:
      cpu: 25m
      memory: 32Mi
    limits:
      cpu: 250m
      memory: 128Mi
```

- [ ] **Step 5: Verify the chart still renders**

Run:
```bash
cd redis-cdc-le-k8s
helm template t chart >/dev/null && echo OK
```
Expected: `OK` (templates referencing `.Values.*.image` are updated in Tasks 10–12; if `helm template` errors on a missing `.image`, that is expected until those tasks land — proceed and re-run at Task 12).

- [ ] **Step 6: Commit**

```bash
cd redis-cdc-le-k8s
git add chart/values.yaml
git commit -m "redis-cdc-le-k8s: values use single images.app + latencyCalculator block"
```

---

## Task 10: `command:` overrides on existing Go workloads

**Files:**
- Modify: `redis-cdc-le-k8s/chart/templates/writer.yaml`
- Modify: `redis-cdc-le-k8s/chart/templates/verifier-job.yaml`
- Modify: `redis-cdc-le-k8s/chart/templates/dashboard.yaml`
- Modify: `redis-cdc-le-k8s/chart/templates/connect-source.yaml`
- Modify: `redis-cdc-le-k8s/chart/templates/connect-sink.yaml`

- [ ] **Step 1: writer.yaml**

In the `writer` container, change the image line and add `command:` immediately after `imagePullPolicy:`. Replace:
```yaml
        - name: writer
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.writer.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.writer.pullPolicy) }}
          env:
```
with:
```yaml
        - name: writer
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.images.app) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.writer.pullPolicy) }}
          command: ["/usr/local/bin/writer"]
          env:
```

- [ ] **Step 2: verifier-job.yaml**

Replace:
```yaml
        - name: verifier
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.verifier.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.verifier.pullPolicy) }}
          args:
```
with:
```yaml
        - name: verifier
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.images.app) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.verifier.pullPolicy) }}
          command: ["/usr/local/bin/verifier"]
          args:
```

- [ ] **Step 3: dashboard.yaml**

Replace:
```yaml
        - name: dashboard
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.dashboard.image) }}
```
with (add `imagePullPolicy` if it was on the next line already — keep it; insert `command:` after the image/pullPolicy lines, before `env:`):
```yaml
        - name: dashboard
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.images.app) }}
          command: ["/usr/local/bin/dashboard"]
```
Verify with `sed -n` that `command:` sits directly above the `env:` / `- name: CENTRAL_ADDR` block and after any `imagePullPolicy:` line.

- [ ] **Step 4: connect-source.yaml — elector sidecar keeps tini**

In the `- name: elector` container, replace:
```yaml
        - name: elector
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.elector.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.elector.pullPolicy) }}
          env:
```
with:
```yaml
        - name: elector
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.images.app) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.elector.pullPolicy) }}
          command: ["/sbin/tini", "--", "/usr/local/bin/elector"]
          env:
```

- [ ] **Step 5: connect-sink.yaml — elector sidecar keeps tini**

Apply the identical change as Step 4 to the `- name: elector` container in `connect-sink.yaml` (same old→new replacement).

- [ ] **Step 6: Verify rendering + command presence**

Run:
```bash
cd redis-cdc-le-k8s
helm template t chart --set verifier.run=true | grep -E "command:|/usr/local/bin/|/sbin/tini" | sort -u
```
Expected: shows `/usr/local/bin/writer`, `/usr/local/bin/verifier`, `/usr/local/bin/dashboard`, and `/sbin/tini -- /usr/local/bin/elector` (twice — source + sink).

- [ ] **Step 7: Commit**

```bash
cd redis-cdc-le-k8s
git add chart/templates/writer.yaml chart/templates/verifier-job.yaml chart/templates/dashboard.yaml chart/templates/connect-source.yaml chart/templates/connect-sink.yaml
git commit -m "redis-cdc-le-k8s: command: overrides on all Go workloads (shared image)"
```

---

## Task 11: Sink latency XADD (`cdc-reverse.yaml`)

**Files:**
- Modify: `redis-cdc-le-k8s/chart/files/connect/cdc-reverse.yaml`

- [ ] **Step 1: Replace the create/update branch processors**

In the `switch` list, replace the existing create/update branch:
```yaml
        - check: meta("op") == "create" || meta("op") == "update"
          processors:
            - redis:
                url: {{ include "rrcs.redis.region.url" . }}
                kind: simple
                command: set
                args_mapping: 'root = [ meta("kv_key"), meta("body") ]'
            - metric:
                type: counter
                name: cdc_apply
                labels:
                  op: '${! meta("op") }'
```
with (XADD-first so the `catch` only ever clears telemetry errors — a `catch`
after the SET would swallow a real SET failure and silently ACK a lost apply):
```yaml
        - check: meta("op") == "create" || meta("op") == "update"
          processors:
            # Best-effort latency telemetry, emitted BEFORE the SET. ts-bearing
            # bodies only (verifier-injected events without ts are skipped).
            - try:
                - switch:
                    - check: meta("body").parse_json().ts.or(0) > 0
                      processors:
                        - redis:
                            url: {{ include "rrcs.redis.region.url" . }}
                            kind: simple
                            command: xadd
                            args_mapping: |
                              root = [
                                {{ .Values.latencyCalculator.stream | quote }},
                                "MAXLEN", "~", {{ .Values.latencyCalculator.streamMaxLen | quote }}, "*",
                                "op", meta("op"),
                                "kv_key", meta("kv_key"),
                                "writer_ts", meta("body").parse_json().ts.string(),
                                "sink_ts", now().ts_unix_milli().string()
                              ]
            - catch:
                - log:
                    level: WARN
                    message: 'latency xadd failed (best-effort, ignored): ${! error() }'
            # Authoritative apply. NOT wrapped — a SET failure must nack/redeliver.
            - redis:
                url: {{ include "rrcs.redis.region.url" . }}
                kind: simple
                command: set
                args_mapping: 'root = [ meta("kv_key"), meta("body") ]'
            - metric:
                type: counter
                name: cdc_apply
                labels:
                  op: '${! meta("op") }'
```

- [ ] **Step 2: Render the sink config and sanity-check it**

Run:
```bash
cd redis-cdc-le-k8s
helm template t chart \
  --set latencyCalculator.stream=cdc:latency \
  --set latencyCalculator.streamMaxLen=50000 \
  | sed -n '/cdc-reverse.yaml/,/cdc_rename.lua\|---/p' | grep -nE "xadd|MAXLEN|sink_ts|command: set|catch:" | head
```
Expected: shows the `xadd` command, `MAXLEN`, `sink_ts`, the `catch:`, and `command: set` — confirming the rendered order is xadd → catch → set.

- [ ] **Step 3: Lint the rendered sink config in the connect image**

Render just the cdc-reverse config to a file and lint it (stub Helm-only includes that lint can't resolve):
```bash
cd redis-cdc-le-k8s
helm template t chart > /tmp/all.yaml
# Extract the connect-sink configmap's cdc-reverse.yaml content into /tmp/cdc-reverse.yaml
# (the ConfigMap data key 'cdc-reverse.yaml'), then:
docker run --rm -v /tmp/cdc-reverse.yaml:/c.yaml hpdevelop/connect:4.92.0-claudefix lint /c.yaml; echo "LINT=$?"
```
Expected: `LINT=0`. If extraction is awkward, instead copy the rendered block into a minimal `input: { generate: {...} } / pipeline / output: { drop: {} }` harness and lint that — the goal is to confirm the `try`/`catch`/`switch`/`redis xadd` block parses.

- [ ] **Step 4: Commit**

```bash
cd redis-cdc-le-k8s
git add chart/files/connect/cdc-reverse.yaml
git commit -m "redis-cdc-le-k8s: sink emits best-effort cdc:latency XADD (xadd-first, catch-isolated)"
```

---

## Task 12: latency-calculator chart template

**Files:**
- Create: `redis-cdc-le-k8s/chart/templates/latency-calculator.yaml`

- [ ] **Step 1: Write the template**

`chart/templates/latency-calculator.yaml`:
```yaml
{{- if .Values.latencyCalculator.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "latency-calculator") }}
  labels:
    app: latency-calculator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: latency-calculator
  template:
    metadata:
      labels:
        {{- include "rrcs.podLabels" (dict "root" $ "app" "latency-calculator") | nindent 8 }}
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      containers:
        - name: latency-calculator
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.images.app) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.latencyCalculator.pullPolicy) }}
          command: ["/usr/local/bin/latency-calculator"]
          env:
            - name: REGION_ADDR
              value: {{ include "rrcs.redis.region.hostPort" . | quote }}
            - name: STREAM
              value: {{ .Values.latencyCalculator.stream | quote }}
            - name: WINDOW_SEC
              value: {{ .Values.latencyCalculator.windowSec | quote }}
            - name: INTERVAL_SEC
              value: {{ .Values.latencyCalculator.intervalSec | quote }}
            - name: REPORT_PATH
              value: {{ .Values.latencyCalculator.reportPath | quote }}
          volumeMounts:
            - name: reports
              mountPath: /reports
          resources:
            {{- toYaml .Values.resources.latencyCalculator | nindent 12 }}
      volumes:
        - name: reports
          {{- if .Values.latencyCalculator.persistence.enabled }}
          persistentVolumeClaim:
            claimName: {{ include "rrcs.name" (dict "root" $ "base" "latency-calculator-reports") }}
          {{- else }}
          emptyDir: {}
          {{- end }}
{{- if .Values.latencyCalculator.persistence.enabled }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "latency-calculator-reports") }}
  labels:
    app: latency-calculator
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: {{ .Values.latencyCalculator.persistence.size | quote }}
  {{- with .Values.latencyCalculator.persistence.storageClass }}
  storageClassName: {{ . | quote }}
  {{- end }}
{{- end }}
{{- end }}
```

Note: the `reports` volume mounts at `/reports` in BOTH persistence modes — there is no code path where `/reports` is unmounted (a default-off install still gets a writable `emptyDir`).

- [ ] **Step 2: Verify both persistence modes render**

Run:
```bash
cd redis-cdc-le-k8s
echo "== disabled (no output) =="; helm template t chart | grep -c "app: latency-calculator" || true
echo "== enabled, emptyDir =="; helm template t chart --set latencyCalculator.enabled=true | grep -E "emptyDir|/usr/local/bin/latency-calculator|mountPath: /reports"
echo "== enabled, PVC =="; helm template t chart --set latencyCalculator.enabled=true --set latencyCalculator.persistence.enabled=true | grep -E "PersistentVolumeClaim|persistentVolumeClaim|/reports"
```
Expected: disabled → `0`; emptyDir mode → shows emptyDir + command + mountPath; PVC mode → shows the PVC and claim and `/reports` mount.

- [ ] **Step 3: Full lint**

Run:
```bash
cd redis-cdc-le-k8s
helm lint chart
helm template t chart --set latencyCalculator.enabled=true >/dev/null && echo OK
```
Expected: lint passes; `OK`.

- [ ] **Step 4: Commit**

```bash
cd redis-cdc-le-k8s
git add chart/templates/latency-calculator.yaml
git commit -m "redis-cdc-le-k8s: latency-calculator Deployment template (gated, /reports volume)"
```

---

## Task 13: Docs + end-to-end lab verification

**Files:**
- Modify: `redis-cdc-le-k8s/README.md`
- Modify: `redis-cdc-le-k8s/chart/templates/NOTES.txt`
- Modify: `redis-cdc-le-k8s/docs/nats-jetstream-and-redis-kv-message-flow.md`

- [ ] **Step 1: README — add a "Latency calculator" section + note the build change**

Add a short section after the existing component descriptions:
```markdown
## Latency calculator (optional)

The sink leg emits a best-effort `cdc:latency` record (`op,kv_key,writer_ts,sink_ts`)
to **region** Redis after each create/update. Enable the region-side calculator to
turn that into a rolling p50/p95/p99 report:

```bash
helm upgrade ... --set latencyCalculator.enabled=true
kubectl -n <ns> exec deploy/<prefix>latency-calculator -- cat /reports/latency-report.json
```

`latency_ms = sink_ts - writer_ts`. Only create/update are measured (delete/rename
carry no body/ts). A persistently rising `dropped_negative` indicates central/region
clock drift (NTP), not a CDC bug.

### One image for all Go programs

`writer`, `verifier`, `elector`, `dashboard`, and `latency-calculator` are built
into a single image (`redis-rrcs/cdc-apps`) from one root `Dockerfile` + `go.work`.
Its entrypoint is `sleep infinity`; every workload sets `command:` to pick its
binary. Build with `scripts/build-images.sh [--kind --kind-name=...]`.
```

- [ ] **Step 2: NOTES.txt — warn about the command: requirement**

Append to `chart/templates/NOTES.txt`:
```
All Go components share one image ({{ .Values.images.app }}) whose default
entrypoint is `sleep infinity`. Each workload overrides `command:` to run its
binary. If you add a new Go workload, you MUST set `command:` or the pod will idle.
```

- [ ] **Step 3: message-flow doc — note the sidecar stream**

Add a short paragraph to `docs/nats-jetstream-and-redis-kv-message-flow.md` describing the `cdc:latency` sidecar stream: written by the sink after each create/update SET, carrying `writer_ts`/`sink_ts`, consumed only by the optional region-side calculator, and never affecting the applied KV value (so the convergence verifier is unaffected).

- [ ] **Step 4: Build the consolidated image into kind and run the full verifier**

Run:
```bash
cd redis-cdc-le-k8s
scripts/build-images.sh --kind --kind-name=cdc
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh
```
Expected: `verify-cdc.sh` exits 0 (dedup + per-op + idempotent-replay all pass) — confirming the value bytes are unchanged by the latency XADD, every component resolves its binary via `command:`, and the elector tini wrapper / failover still works.

- [ ] **Step 5: Exercise the calculator end-to-end**

Run (in the kind lab, after the chart is up with the writer producing load):
```bash
NS=cdc-k8s
helm upgrade cdc chart -n $NS --reuse-values --set latencyCalculator.enabled=true
# drive some create/update load via the writer (set a rate), then:
kubectl -n $NS exec deploy/$(kubectl -n $NS get deploy -l app=latency-calculator -o jsonpath='{.items[0].metadata.name}') -- cat /reports/latency-report.json
```
Expected: a JSON report with non-zero `overall.count` and populated `by_op.create`/`by_op.update` percentiles. Confirm the region `cdc:latency` stream exists:
```bash
kubectl -n $NS exec deploy/<region-redis> -- redis-cli XLEN cdc:latency
```
Expected: a positive length.

- [ ] **Step 6: Commit**

```bash
cd redis-cdc-le-k8s
git add README.md chart/templates/NOTES.txt docs/nats-jetstream-and-redis-kv-message-flow.md
git commit -m "redis-cdc-le-k8s: docs for latency calculator + single-image build"
```

---

## Done-when checklist

- [ ] `go build ./...` and `go test ./...` pass under the workspace (5 modules).
- [ ] `docker build .` produces `redis-rrcs/cdc-apps` containing all 5 binaries; bare run idles on `sleep infinity`.
- [ ] `helm template` shows every Go workload setting `command:`; elector keeps `/sbin/tini -- /usr/local/bin/elector` on both legs.
- [ ] Rendered `cdc-reverse.yaml` lints in the connect image; order is xadd → catch → set.
- [ ] `verify-cdc.sh` still exits 0 (value bytes unchanged; failover intact).
- [ ] With `latencyCalculator.enabled=true`, `/reports/latency-report.json` shows non-zero per-op percentiles.
