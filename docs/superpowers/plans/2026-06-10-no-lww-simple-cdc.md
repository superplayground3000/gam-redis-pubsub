# no-lww-simple-cdc Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `labs/no-lww-simple-cdc` Kubernetes/Helm lab — a fork of `labs/redis-connect-lww-multi-k8s` with the LWW fence removed — that propagates create/update/delete/rename through a single-source/single-sink Redpanda Connect relay (Redis Streams → NATS JetStream → Redis KV) and visualizes central-vs-region divergence.

**Architecture:** A Go writer dual-writes each op to central Redis KV *and* emits a CDC envelope to the `app.events` stream. One connect-source pod publishes to NATS JetStream on subject `<prefix>.<op>` with `Nats-Msg-Id` dedup. One connect-sink pod switches on `op` → `SET`/`DEL`/`EVAL`(rename Lua), no version fence. A Go verifier runs three order-insensitive checks (dedup, per-op-under-quiescence, idempotent replay). A Go dashboard shows central vs region KV live; an HTML report summarizes a run.

**Tech Stack:** Go 1.22 (writer/verifier/dashboard), Redpanda Connect 4.92.0, NATS JetStream 2.10, Redis 7.4, Helm 3, kind for validation.

**Spec:** `docs/superpowers/specs/2026-06-10-no-lww-simple-cdc-design.md`
**Source of truth for wire/pipeline:** `no-lww-simple-cdc/research-design.md`
**Functional requirements:** `no-lww-simple-cdc/lab-requirements.md`
**Parent lab (fork source):** `labs/redis-connect-lww-multi-k8s/`

---

## Conventions used in this plan

- All paths are relative to repo root `/media/hp/secondary/projects/gam-redis-pubsub` unless absolute.
- `$LAB` = `labs/no-lww-simple-cdc` (the new lab dir created in Phase 0).
- Go tests run from the module dir (e.g. `cd $LAB/writer && go test ./...`).
- "Forked unchanged" means the file is copied from the parent in Phase 0 and not edited.
- Commit after each task. Keep commits on `master` (repo convention — every sibling lab commits directly to master).
- Image names are kept identical to the parent (`redis-rrcs/writer|verifier|dashboard`) to avoid build-script churn; they are internal tags.

---

## Phase 0 — Fork & scaffold

### Task 0.1: Copy the parent lab into the new lab dir

**Files:**
- Create: `labs/no-lww-simple-cdc/` (copy of `labs/redis-connect-lww-multi-k8s/`)

- [ ] **Step 1: Copy the tree (excludes built binaries and git noise)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
cp -r labs/redis-connect-lww-multi-k8s labs/no-lww-simple-cdc
# Drop committed build artifacts that will be rebuilt
rm -f labs/no-lww-simple-cdc/verifier/verifier
find labs/no-lww-simple-cdc -name '*.test' -delete
```

- [ ] **Step 2: Verify the copy looks right**

Run: `ls labs/no-lww-simple-cdc && ls labs/no-lww-simple-cdc/chart/files/connect`
Expected: top-level dirs `chart dashboard docs scripts verifier writer` and connect files `lww-forward.yaml lww-reverse.yaml lww_set.lua`.

- [ ] **Step 3: Commit the raw fork**

```bash
git add labs/no-lww-simple-cdc
git commit -m "no-lww-simple-cdc: fork redis-connect-lww-multi-k8s (raw copy)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 0.2: Remove fence-specific files

**Files:**
- Delete: `$LAB/chart/files/connect/lww_set.lua`, `$LAB/chart/files/connect/lww-forward.yaml`, `$LAB/chart/files/connect/lww-reverse.yaml`
- Delete: `$LAB/scripts/proof-c.sh`, `$LAB/scripts/verify-lww.sh`
- Delete (verifier files replaced in Phase 4): `lww.go`, `lww_test.go`, `pods.go`, `pods_test.go`, `scrapers.go`, `main.go`, `redis.go`, `quiescence.go`, `report.go`
- Create: `$LAB/verifier/httpclient.go` (re-homes the shared `httpClient` var that lived in the deleted `scrapers.go`; `nats.go` — kept — uses it)
- Delete: `$LAB/RESEARCH.md`, `$LAB/README.md` (rewritten in Phase 7)

> Why delete `main.go`/`redis.go`/`quiescence.go`/`report.go` now (not just edit later): they are mutually dependent with the deleted `lww.go`/`scrapers.go`. Removing them up front and keeping **only** `nats.go` + the new `httpclient.go` lets the verifier package build incrementally as Phase 4 adds files, so each Phase 4 task's `go test` actually runs. `verifier/go.mod`, `verifier/go.sum`, `verifier/Dockerfile`, and `verifier/nats.go` are kept.

- [ ] **Step 1: Delete the fence/proof/multi-pod + to-be-replaced verifier files**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/no-lww-simple-cdc
git rm chart/files/connect/lww_set.lua chart/files/connect/lww-forward.yaml chart/files/connect/lww-reverse.yaml
git rm scripts/proof-c.sh scripts/verify-lww.sh
git rm verifier/lww.go verifier/lww_test.go verifier/pods.go verifier/pods_test.go verifier/scrapers.go
git rm verifier/main.go verifier/redis.go verifier/quiescence.go verifier/report.go
git rm RESEARCH.md README.md
```

- [ ] **Step 2: Add the shared httpClient var (keeps nats.go compiling)**

```go
// $LAB/verifier/httpclient.go
package main

import (
	"net/http"
	"time"
)

// httpClient is shared by ScrapeJSZ (nats.go). The parent declared it in
// scrapers.go, which this lab deletes (no per-pod scraping), so it lives here.
var httpClient = &http.Client{Timeout: 5 * time.Second}
```

- [ ] **Step 3: Verify the verifier package builds with just nats.go + httpclient.go**

Run: `cd $LAB/verifier && go build ./... 2>&1 | head; go vet ./...`
Expected: builds (a `package main` with no `func main` is fine for `go vet`/`go test`; `go build` of the binary is exercised again in Task 4.5). No `undefined: httpClient`.

- [ ] **Step 4: Commit the removals + httpclient.go**

```bash
git add -A
git commit -m "no-lww-simple-cdc: drop LWW fence, proofs, multi-pod scraping; rehome httpClient

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> The writer and dashboard remain compilable through Phases 1 and 5 except during their own unit-rewrite windows (see the execution note at the start of each phase).

---

## Phase 1 — Writer: 4-op dual-write CDC generator

The writer becomes a continuous 4-op CDC load generator. For each event it (1) applies the op to the central Redis KV and (2) `XADD`s a CDC envelope to `app.events`, in one pipeline. No version counter; multiple workers may target the same key.

**Module:** `$LAB/writer` (Go module `writer`, already has `go.mod` with `go-redis/v9` and `google/uuid`).

> **Phase execution note:** the writer is rewritten as a unit. Task 1.0 deletes the parent files that are being replaced (keeping `limiter.go`/`limiter_test.go`/`go.mod`/`go.sum`/`Dockerfile`), so the package builds incrementally and each task's `go test` runs cleanly. The binary (`go build ./...`) only links once `main.go` lands in Task 1.6 — that is the phase build gate.

### Task 1.0: Remove parent writer files to be replaced

**Files:**
- Delete: `$LAB/writer/payload.go`, `payload_test.go`, `worker.go`, `worker_test.go`, `counters.go`, `http.go`, `http_test.go`, `main.go`, `version.go`, `version_test.go`

- [ ] **Step 1: Delete them (keep limiter.go + limiter_test.go)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/no-lww-simple-cdc
git rm writer/payload.go writer/payload_test.go writer/worker.go writer/worker_test.go \
  writer/counters.go writer/http.go writer/http_test.go writer/main.go \
  writer/version.go writer/version_test.go
```

- [ ] **Step 2: Confirm what remains compiles (limiter only)**

Run: `cd $LAB/writer && go vet ./... 2>&1 | head`
Expected: clean (only `limiter.go` + its test remain; no `func main` is fine for `go vet`).

- [ ] **Step 3: Commit**

```bash
git commit -m "no-lww-simple-cdc: clear writer files for rewrite (keep limiter)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.1: Key patterns

**Files:**
- Create: `$LAB/writer/patterns.go`
- Test: `$LAB/writer/patterns_test.go`

- [ ] **Step 1: Write the failing test**

```go
// $LAB/writer/patterns_test.go
package main

import "testing"

func TestActiveKeyHashTagged(t *testing.T) {
	got := Patterns[0].ActiveKey(55688)
	want := "lb:company:active:{employees:55688}"
	if got != want {
		t.Fatalf("ActiveKey = %q, want %q", got, want)
	}
}

func TestStandbyKeyOnlyCompany(t *testing.T) {
	// Only the company/employees pattern has a standby->active rename flow.
	if Patterns[0].StandbyKey(55688) != "lb:company:standby:{employees:55688}" {
		t.Fatalf("company standby key wrong: %q", Patterns[0].StandbyKey(55688))
	}
	if Patterns[0].ActiveKey(1) == Patterns[0].StandbyKey(1) {
		t.Fatal("active and standby must differ")
	}
}

func TestAllThreePatternsPresent(t *testing.T) {
	if len(Patterns) != 3 {
		t.Fatalf("want 3 patterns, got %d", len(Patterns))
	}
	wants := []string{
		"lb:company:active:{employees:7}",
		"lb:funtions:active:{groups:7}",
		"lb:general:active:{items:7}",
	}
	for i, w := range wants {
		if got := Patterns[i].ActiveKey(7); got != w {
			t.Fatalf("pattern %d ActiveKey = %q, want %q", i, got, w)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd $LAB/writer && go test ./... -run TestActiveKeyHashTagged -v`
Expected: FAIL — `undefined: Patterns`.

- [ ] **Step 3: Write minimal implementation**

```go
// $LAB/writer/patterns.go
package main

import "fmt"

// Pattern is one of the three required key families. The hash tag is the
// {entity:id} segment so a multi-key rename Lua stays in a single Redis slot.
// "funtions" spelling is verbatim from lab-requirements.md and intentional.
type Pattern struct {
	Name   string // short label for metrics/state: company|funtions|general
	active string // fmt with one %d (the id)
	stby   string // standby fmt; only company uses it, "" for the rest
}

func (p Pattern) ActiveKey(id int64) string  { return fmt.Sprintf(p.active, id) }
func (p Pattern) StandbyKey(id int64) string { return fmt.Sprintf(p.stby, id) }
func (p Pattern) HasStandby() bool           { return p.stby != "" }

// Patterns is the fixed set from lab-requirements.md "Key naming pattern".
var Patterns = []Pattern{
	{Name: "company", active: "lb:company:active:{employees:%d}", stby: "lb:company:standby:{employees:%d}"},
	{Name: "funtions", active: "lb:funtions:active:{groups:%d}", stby: ""},
	{Name: "general", active: "lb:general:active:{items:%d}", stby: ""},
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd $LAB/writer && go test ./... -run 'TestActiveKey|TestStandby|TestAllThree' -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add labs/no-lww-simple-cdc/writer/patterns.go labs/no-lww-simple-cdc/writer/patterns_test.go
git commit -m "no-lww-simple-cdc: writer key patterns (3 families, hash-tagged)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.2: CDC event envelope

**Files:**
- Replace: `$LAB/writer/payload.go` (the parent's version-stamped payload)
- Test: `$LAB/writer/payload_test.go` (replace parent's)

- [ ] **Step 1: Write the failing test**

```go
// $LAB/writer/payload_test.go
package main

import (
	"encoding/json"
	"testing"
)

func TestCreateEventFields(t *testing.T) {
	e := NewCreateEvent("lb:general:active:{items:1}", 64)
	if e.Op != "create" || e.KvKey != "lb:general:active:{items:1}" {
		t.Fatalf("bad create event: %+v", e)
	}
	if e.EventID == "" || e.TsMs == 0 || e.Body == "" {
		t.Fatalf("missing event_id/ts/body: %+v", e)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(e.Body), &body); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
}

func TestDeleteEventEmptyBody(t *testing.T) {
	e := NewDeleteEvent("lb:company:active:{employees:2}")
	if e.Op != "delete" || e.Body != "" {
		t.Fatalf("delete must have empty body: %+v", e)
	}
}

func TestRenameEventKeys(t *testing.T) {
	e := NewRenameEvent("lb:company:standby:{employees:3}", "lb:company:active:{employees:3}", 32)
	if e.Op != "rename" || e.OldKey == "" || e.NewKey == "" || e.Body == "" {
		t.Fatalf("bad rename event: %+v", e)
	}
	if e.KvKey != "" {
		t.Fatalf("rename must not set kv_key: %+v", e)
	}
}

func TestStreamValuesOrderedSlice(t *testing.T) {
	// go-redis XADD must use an ordered slice, not a map (field order matters).
	e := NewCreateEvent("k", 8)
	vals := e.StreamValues()
	if len(vals)%2 != 0 {
		t.Fatalf("StreamValues must be key/value pairs, got %d elems", len(vals))
	}
	if vals[0] != "event_id" {
		t.Fatalf("first field must be event_id, got %v", vals[0])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd $LAB/writer && go test ./... -run TestCreateEventFields -v`
Expected: FAIL — `undefined: NewCreateEvent`.

- [ ] **Step 3: Write minimal implementation**

```go
// $LAB/writer/payload.go
package main

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Event is the CDC envelope. Per research-design §3, every field except body
// becomes Redpanda Connect metadata; body_key=body points at the JSON snapshot.
type Event struct {
	EventID string
	Op      string // create|update|delete|rename
	KvKey   string // create/update/delete
	OldKey  string // rename
	NewKey  string // rename
	TsMs    int64
	Body    string // JSON snapshot; "" for delete
}

func nowMs() int64 { return time.Now().UnixMilli() }

// snapshot builds a JSON body of roughly padBytes size for a key.
func snapshot(key string, padBytes int) string {
	b, _ := json.Marshal(map[string]any{
		"id":  key,
		"ts":  nowMs(),
		"pad": strings.Repeat("x", padBytes),
	})
	return string(b)
}

func NewCreateEvent(kvKey string, padBytes int) Event {
	return Event{EventID: uuid.NewString(), Op: "create", KvKey: kvKey, TsMs: nowMs(), Body: snapshot(kvKey, padBytes)}
}

func NewUpdateEvent(kvKey string, padBytes int) Event {
	return Event{EventID: uuid.NewString(), Op: "update", KvKey: kvKey, TsMs: nowMs(), Body: snapshot(kvKey, padBytes)}
}

func NewDeleteEvent(kvKey string) Event {
	return Event{EventID: uuid.NewString(), Op: "delete", KvKey: kvKey, TsMs: nowMs(), Body: ""}
}

func NewRenameEvent(oldKey, newKey string, padBytes int) Event {
	return Event{EventID: uuid.NewString(), Op: "rename", OldKey: oldKey, NewKey: newKey, TsMs: nowMs(), Body: snapshot(newKey, padBytes)}
}

// StreamValues returns the XADD field list as an ordered slice (NOT a map —
// go-redis loses field order with a map; the source pipeline reads these as
// metadata). body_key=body, so "body" carries the JSON snapshot.
func (e Event) StreamValues() []any {
	return []any{
		"event_id", e.EventID,
		"op", e.Op,
		"kv_key", e.KvKey,
		"old_key", e.OldKey,
		"new_key", e.NewKey,
		"ts", e.TsMs,
		"body", e.Body,
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd $LAB/writer && go test ./... -run 'TestCreateEvent|TestDeleteEvent|TestRenameEvent|TestStreamValues' -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add labs/no-lww-simple-cdc/writer/payload.go labs/no-lww-simple-cdc/writer/payload_test.go
git commit -m "no-lww-simple-cdc: writer CDC event envelope (4 ops, body_key)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.3: Per-op counters and run state

**Files:**
- Create: `$LAB/writer/counters.go` (was removed in Task 1.0)
- Create: `$LAB/writer/state.go` (replaces the removed `version.go`)
- Test: `$LAB/writer/state_test.go`

(`version.go`/`version_test.go` were already removed in Task 1.0 — no per-key version in no-LWW.)

- [ ] **Step 2: Write the failing test**

```go
// $LAB/writer/state_test.go
package main

import "testing"

func TestRunStateOpCountsAndKeys(t *testing.T) {
	s := NewRunState()
	s.SetEpoch("run-1")
	s.Record("create", "lb:general:active:{items:1}")
	s.Record("create", "lb:general:active:{items:2}")
	s.Record("delete", "lb:general:active:{items:1}")
	snap := s.Snapshot()
	if snap.Epoch != "run-1" {
		t.Fatalf("epoch = %q", snap.Epoch)
	}
	if snap.Ops["create"] != 2 || snap.Ops["delete"] != 1 {
		t.Fatalf("op counts wrong: %+v", snap.Ops)
	}
	if snap.DistinctKeys != 2 {
		t.Fatalf("distinct keys = %d, want 2", snap.DistinctKeys)
	}
}

func TestRunStateResetClearsCounts(t *testing.T) {
	s := NewRunState()
	s.SetEpoch("a")
	s.Record("create", "k")
	s.SetEpoch("b") // new epoch resets counts and keys
	snap := s.Snapshot()
	if snap.Ops["create"] != 0 || snap.DistinctKeys != 0 || snap.Epoch != "b" {
		t.Fatalf("epoch swap did not reset: %+v", snap)
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd $LAB/writer && go test ./... -run TestRunState -v`
Expected: FAIL — `undefined: NewRunState`.

- [ ] **Step 4: Write minimal implementation**

```go
// $LAB/writer/counters.go
package main

import "sync/atomic"

// Counters are process-lifetime totals exported on /metrics.
type Counters struct {
	Sent     atomic.Int64 // total events XADDed
	Errors   atomic.Int64
	Inflight atomic.Int64
	Created  atomic.Int64
	Updated  atomic.Int64
	Deleted  atomic.Int64
	Renamed  atomic.Int64
}

func (c *Counters) bump(op string) {
	switch op {
	case "create":
		c.Created.Add(1)
	case "update":
		c.Updated.Add(1)
	case "delete":
		c.Deleted.Add(1)
	case "rename":
		c.Renamed.Add(1)
	}
}
```

```go
// $LAB/writer/state.go
package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
)

// RunState tracks the current run epoch, per-op counts, and the set of distinct
// keys touched — surfaced on GET /state for the verifier and dashboard. Unlike
// the parent there is NO per-key version; keys may be touched by many workers.
type RunState struct {
	bootID string
	mu     sync.Mutex
	epoch  string
	ops    map[string]int64
	keys   map[string]struct{}
}

type StateSnapshot struct {
	BootID       string           `json:"boot_id"`
	Epoch        string           `json:"epoch"`
	Ops          map[string]int64 `json:"ops"`
	DistinctKeys int              `json:"distinct_keys"`
}

func NewRunState() *RunState {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return &RunState{bootID: hex.EncodeToString(b), ops: map[string]int64{}, keys: map[string]struct{}{}}
}

func (s *RunState) BootID() string { return s.bootID }

func (s *RunState) Epoch() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.epoch
}

// SetEpoch starts a fresh run: clears op counts and the key set.
func (s *RunState) SetEpoch(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.epoch = name
	s.ops = map[string]int64{}
	s.keys = map[string]struct{}{}
}

// Record tallies one applied op against a key.
func (s *RunState) Record(op, key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ops[op]++
	if key != "" {
		s.keys[key] = struct{}{}
	}
}

func (s *RunState) Snapshot() StateSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	ops := make(map[string]int64, len(s.ops))
	for k, v := range s.ops {
		ops[k] = v
	}
	return StateSnapshot{BootID: s.bootID, Epoch: s.epoch, Ops: ops, DistinctKeys: len(s.keys)}
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd $LAB/writer && go test ./... -run TestRunState -v`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add -A labs/no-lww-simple-cdc/writer
git commit -m "no-lww-simple-cdc: writer per-op counters + run state (no version counter)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.4: Worker — op selection + dual write

**Files:**
- Create: `$LAB/writer/worker.go` (was removed in Task 1.0)
- Test: `$LAB/writer/worker_test.go` (was removed in Task 1.0)

- [ ] **Step 1: Write the failing test (op picker is deterministic given a seed-free weighted table)**

```go
// $LAB/writer/worker_test.go
package main

import "testing"

func TestPickOpCoversAll(t *testing.T) {
	mix := OpMix{Create: 40, Update: 40, Delete: 10, Rename: 10}
	seen := map[string]bool{}
	for i := 0; i < 100000; i++ {
		seen[mix.pick(uint64(i))] = true
	}
	for _, op := range []string{"create", "update", "delete", "rename"} {
		if !seen[op] {
			t.Fatalf("op %q never picked", op)
		}
	}
}

func TestPickOpZeroWeightExcluded(t *testing.T) {
	mix := OpMix{Create: 1, Update: 0, Delete: 0, Rename: 0}
	for i := 0; i < 1000; i++ {
		if got := mix.pick(uint64(i)); got != "create" {
			t.Fatalf("only create has weight, got %q", got)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd $LAB/writer && go test ./... -run TestPickOp -v`
Expected: FAIL — `undefined: OpMix`.

- [ ] **Step 3: Write minimal implementation**

```go
// $LAB/writer/worker.go
package main

import (
	"context"
	"log"
	"math/rand"
	"time"

	"github.com/redis/go-redis/v9"
)

// OpMix is the weighted op distribution (weights need not sum to 100).
type OpMix struct{ Create, Update, Delete, Rename int }

func (m OpMix) total() int { return m.Create + m.Update + m.Delete + m.Rename }

// pick maps an arbitrary counter n into an op deterministically by weight.
func (m OpMix) pick(n uint64) string {
	t := m.total()
	if t <= 0 {
		return "update"
	}
	r := int(n % uint64(t))
	if r < m.Create {
		return "create"
	}
	r -= m.Create
	if r < m.Update {
		return "update"
	}
	r -= m.Update
	if r < m.Delete {
		return "delete"
	}
	return "rename"
}

type Worker struct {
	ID            int
	RDB           *redis.Client // central Redis (KV + app.events stream)
	StreamKey     string
	StreamMaxLen  int64
	PipelineDepth int
	PayloadBytes  int
	KeySpaceSize  int64
	Mix           OpMix
	Lim           *Limiter
	Counters      *Counters
	State         *RunState
	rng           *rand.Rand
}

// buildEvent picks an op and a key (any key in [0,KeySpaceSize) across a random
// pattern — multiple workers may collide on the same key, which is allowed).
func (w *Worker) buildEvent(seq uint64) Event {
	p := Patterns[w.rng.Intn(len(Patterns))]
	id := w.rng.Int63n(w.KeySpaceSize)
	switch w.Mix.pick(seq) {
	case "create":
		return NewCreateEvent(p.ActiveKey(id), w.PayloadBytes)
	case "update":
		return NewUpdateEvent(p.ActiveKey(id), w.PayloadBytes)
	case "delete":
		return NewDeleteEvent(p.ActiveKey(id))
	default: // rename: company uses standby->active; others active(id)->active(id+offset)
		if p.HasStandby() {
			return NewRenameEvent(p.StandbyKey(id), p.ActiveKey(id), w.PayloadBytes)
		}
		other := (id + 1) % w.KeySpaceSize
		return NewRenameEvent(p.ActiveKey(id), p.ActiveKey(other), w.PayloadBytes)
	}
}

// applyCentral applies the op to the central KV (the authoritative intent of
// record) within the same pipeline as the XADD (dual write; not atomic — that
// looseness is part of the no-LWW story).
func applyCentral(pipe redis.Pipeliner, ctx context.Context, e Event) {
	switch e.Op {
	case "create", "update":
		pipe.Set(ctx, e.KvKey, e.Body, 0)
	case "delete":
		pipe.Del(ctx, e.KvKey)
	case "rename":
		pipe.Del(ctx, e.OldKey)
		pipe.Set(ctx, e.NewKey, e.Body, 0)
	}
}

func (w *Worker) Run(ctx context.Context) {
	if w.rng == nil {
		w.rng = rand.New(rand.NewSource(int64(w.ID)*7919 + time.Now().UnixNano()))
	}
	var seq uint64
	for {
		depth := w.PipelineDepth
		if rate := int(w.Lim.Current()); rate > 0 && rate/10 < depth {
			if d := rate / 10; d >= 1 {
				depth = d
			}
		}
		waitCtx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
		err := w.Lim.WaitN(waitCtx, depth)
		cancel()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		if w.State.Epoch() == "" {
			select {
			case <-ctx.Done():
				return
			case <-time.After(100 * time.Millisecond):
			}
			continue
		}

		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		batch := make([]Event, 0, depth)
		for i := 0; i < depth; i++ {
			e := w.buildEvent(seq)
			seq++
			applyCentral(pipe, ctx, e)
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: e.StreamValues(),
			})
			batch = append(batch, e)
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(len(batch)))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
			continue
		}
		w.Counters.Sent.Add(int64(len(batch)))
		for _, e := range batch {
			w.Counters.bump(e.Op)
			key := e.KvKey
			if e.Op == "rename" {
				key = e.NewKey
			}
			w.State.Record(e.Op, key)
		}
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd $LAB/writer && go test ./... -run TestPickOp -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add -A labs/no-lww-simple-cdc/writer
git commit -m "no-lww-simple-cdc: writer worker — weighted op mix + dual write

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.5: HTTP surface (/healthz /metrics /rate /reset /state)

**Files:**
- Replace: `$LAB/writer/http.go`
- Test: `$LAB/writer/http_test.go` (replace parent's)

- [ ] **Step 1: Write the failing test**

```go
// $LAB/writer/http_test.go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer() *Server {
	return &Server{Lim: NewLimiter(), Counters: &Counters{}, MaxRate: 20000, State: NewRunState(), HealthCheck: func() bool { return true }}
}

func TestResetThenState(t *testing.T) {
	s := newTestServer()
	mux := http.NewServeMux()
	s.Register(mux)

	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest("POST", "/reset", strings.NewReader(`{"epoch":"e1"}`)))
	if rr.Code != 200 {
		t.Fatalf("reset code = %d", rr.Code)
	}
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest("GET", "/state", nil))
	var st StateSnapshot
	if err := json.Unmarshal(rr.Body.Bytes(), &st); err != nil {
		t.Fatalf("state json: %v", err)
	}
	if st.Epoch != "e1" {
		t.Fatalf("epoch = %q", st.Epoch)
	}
}

func TestMetricsHasPerOpSeries(t *testing.T) {
	s := newTestServer()
	s.Counters.Created.Store(5)
	mux := http.NewServeMux()
	s.Register(mux)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(rr.Body.String(), `cdc_writer_ops_total{op="create"} 5`) {
		t.Fatalf("metrics missing per-op series:\n%s", rr.Body.String())
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd $LAB/writer && go test ./... -run 'TestResetThenState|TestMetricsHasPerOp' -v`
Expected: FAIL — `Server` has no field `State` / undefined methods.

- [ ] **Step 3: Write minimal implementation**

```go
// $LAB/writer/http.go
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
	State       *RunState
	HealthCheck func() bool
}

func (s *Server) Register(mux *http.ServeMux) {
	mux.HandleFunc("/healthz", s.healthz)
	mux.HandleFunc("/metrics", s.metrics)
	mux.HandleFunc("/rate", s.rate)
	mux.HandleFunc("/reset", s.reset)
	mux.HandleFunc("/state", s.state)
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
	fmt.Fprintf(w, "# TYPE cdc_writer_sent_total counter\ncdc_writer_sent_total %d\n", s.Counters.Sent.Load())
	fmt.Fprintf(w, "# TYPE cdc_writer_errors_total counter\ncdc_writer_errors_total %d\n", s.Counters.Errors.Load())
	fmt.Fprintf(w, "# TYPE cdc_writer_ops_total counter\n")
	fmt.Fprintf(w, "cdc_writer_ops_total{op=\"create\"} %d\n", s.Counters.Created.Load())
	fmt.Fprintf(w, "cdc_writer_ops_total{op=\"update\"} %d\n", s.Counters.Updated.Load())
	fmt.Fprintf(w, "cdc_writer_ops_total{op=\"delete\"} %d\n", s.Counters.Deleted.Load())
	fmt.Fprintf(w, "cdc_writer_ops_total{op=\"rename\"} %d\n", s.Counters.Renamed.Load())
	fmt.Fprintf(w, "# TYPE cdc_writer_rate_target gauge\ncdc_writer_rate_target %d\n", s.Lim.Current())
	fmt.Fprintf(w, "# TYPE cdc_writer_inflight gauge\ncdc_writer_inflight %d\n", s.Counters.Inflight.Load())
}

func (s *Server) rate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var rq struct{ Rate int }
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
	var rq struct{ Epoch string }
	if err := json.NewDecoder(r.Body).Decode(&rq); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if rq.Epoch == "" {
		http.Error(w, "epoch required", http.StatusBadRequest)
		return
	}
	s.Counters.Reset()
	s.State.SetEpoch(rq.Epoch)
	fmt.Fprintf(w, "reset; epoch=%s\n", rq.Epoch)
}

func (s *Server) state(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(s.State.Snapshot())
}
```

Add `Reset()` to counters (used by `/reset`):

```go
// append to $LAB/writer/counters.go
func (c *Counters) Reset() {
	c.Sent.Store(0)
	c.Errors.Store(0)
	c.Created.Store(0)
	c.Updated.Store(0)
	c.Deleted.Store(0)
	c.Renamed.Store(0)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd $LAB/writer && go test ./... -run 'TestResetThenState|TestMetricsHasPerOp' -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add -A labs/no-lww-simple-cdc/writer
git commit -m "no-lww-simple-cdc: writer HTTP surface (per-op metrics, epoch reset/state)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.6: main wiring

**Files:**
- Replace: `$LAB/writer/main.go`

- [ ] **Step 1: Write the implementation (no new test; covered by `go build` + `go vet`)**

```go
// $LAB/writer/main.go
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
	keySpaceSize := envInt("KEY_SPACE_SIZE", 1000)
	payloadBytes := envInt("PAYLOAD_BYTES", 200)
	maxRate := envInt("MAX_RATE", 20_000)
	healthAddr := envStr("HEALTH_ADDR", ":8081")
	mix := OpMix{
		Create: envInt("OP_CREATE", 40),
		Update: envInt("OP_UPDATE", 40),
		Delete: envInt("OP_DELETE", 10),
		Rename: envInt("OP_RENAME", 10),
	}

	rdb := redis.NewClient(&redis.Options{Addr: addr, PoolSize: workers * 2})
	defer rdb.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lim := NewLimiter()
	lim.Set(initialRate)
	counters := &Counters{}
	state := NewRunState()

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		w := &Worker{
			ID: i, RDB: rdb, StreamKey: streamKey, StreamMaxLen: int64(streamMaxLen),
			PipelineDepth: pipelineDepth, PayloadBytes: payloadBytes, KeySpaceSize: int64(keySpaceSize),
			Mix: mix, Lim: lim, Counters: counters, State: state,
		}
		wg.Add(1)
		go func() { defer wg.Done(); w.Run(ctx) }()
	}

	srv := &Server{Lim: lim, Counters: counters, MaxRate: maxRate, State: state,
		HealthCheck: func() bool {
			c, cf := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cf()
			return rdb.Ping(c).Err() == nil
		}}
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
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		log.Printf("WARN: %s=%q not an int, using %d", k, v, def)
		return def
	}
	return n
}
```

- [ ] **Step 2: Build, vet, and run the full writer test suite**

Run: `cd $LAB/writer && go build ./... && go vet ./... && go test ./...`
Expected: build OK, vet clean, all tests PASS.

- [ ] **Step 3: Commit**

```bash
git add -A labs/no-lww-simple-cdc/writer
git commit -m "no-lww-simple-cdc: writer main wiring (op-mix env, central dual-write)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Connect configs & rename Lua

### Task 2.1: Source config (central stream → NATS, op subject + dedup)

**Files:**
- Create: `$LAB/chart/files/connect/cdc-forward.yaml`

- [ ] **Step 1: Write the file**

```yaml
# cdc-forward.yaml — reads central app.events stream; publishes each CDC event to
# NATS JetStream on <subjectPrefix>.<op> with Nats-Msg-Id=event_id for dedup.
# XADD fields (event_id/op/kv_key/old_key/new_key/ts) arrive as metadata; the body
# arrives as content (body_key=body). We republish a self-contained JSON ENVELOPE
# in the PAYLOAD (op/keys/body inside it) so the sink never depends on NATS
# header->metadata mapping — the same proven shape the parent used.
http:
  address: 0.0.0.0:4195
  enabled: true

input:
  label: redis_source
  redis_streams:
    url: {{ include "rrcs.redis.central.url" . }}
    kind: simple
    streams: [app.events]
    consumer_group: cdc_propagator
    client_id: ${HOSTNAME:rpconnect-cdc-forward}
    body_key: body
    create_streams: true
    start_from_oldest: false
    commit_period: 200ms
    timeout: 500ms
    limit: 50
    auto_replay_nacks: true

pipeline:
  threads: 2
  processors:
    - mapping: |
        let body = content().string()
        let eid  = meta("event_id").or($body.hash("sha256").encode("hex"))
        root = {
          "event_id": $eid,
          "op":       meta("op").or("update"),
          "kv_key":   meta("kv_key").or(""),
          "old_key":  meta("old_key").or(""),
          "new_key":  meta("new_key").or(""),
          "ts":       meta("ts").or("0"),
          "body":     $body
        }
        meta op       = meta("op").or("update")     # used for the subject interpolation
        meta event_id = $eid                          # used for the Nats-Msg-Id header

output:
  label: jetstream_sink
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth: { user_credentials_file: {{ .Values.nats.auth.creds.publisher | quote }} }
    subject: {{ include "rrcs.nats.stream.publishSubject" . | quote }}
    headers:
      Nats-Msg-Id: ${! meta("event_id") }
      Content-Type: application/json
    max_in_flight: 256

logger: { level: INFO, format: json, add_timestamp: true }
metrics:
  prometheus: { use_histogram_timing: true }
```

- [ ] **Step 2: Lint YAML offline**

Run: `cd $LAB && python3 -c "import sys,re; s=open('chart/files/connect/cdc-forward.yaml').read(); print('OK lines:', len(s.splitlines()))"`
Expected: prints a line count (this file is a Helm template, so full YAML parse happens via `helm template` in Phase 3 — here we only confirm it exists and is non-empty).

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/files/connect/cdc-forward.yaml
git commit -m "no-lww-simple-cdc: connect source config (op subject + Nats-Msg-Id dedup)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.2: Rename Lua (DEL old + SET new)

**Files:**
- Create: `$LAB/chart/files/connect/cdc_rename.lua`

- [ ] **Step 1: Write the file**

```lua
-- cdc_rename.lua — replay-idempotent rename: DEL old, SET new(snapshot).
-- KEYS[1]=old_key  KEYS[2]=new_key  ARGV[1]=body(json snapshot)
-- Always returns 1. Unlike Redis RENAME this never errors when old_key is gone
-- (second delivery), so JetStream redelivery is safe. Single EVAL = atomic per
-- Redis; KEYS[1]/KEYS[2] must share a hash tag (same slot) on Redis Cluster.
redis.call('DEL', KEYS[1])
redis.call('SET', KEYS[2], ARGV[1])
return 1
```

- [ ] **Step 2: Sanity-check it is valid Lua (optional, if `lua` present; else skip)**

Run: `command -v lua5.1 >/dev/null && lua5.1 -e "loadfile('$LAB/chart/files/connect/cdc_rename.lua')" && echo OK || echo "skip (no lua interpreter; redis validates at EVAL time)"`
Expected: `OK` or `skip ...`.

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/files/connect/cdc_rename.lua
git commit -m "no-lww-simple-cdc: rename Lua (DEL old + SET new, replay-safe)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.3: Sink config (NATS → region KV, switch on op, no fence)

**Files:**
- Create: `$LAB/chart/files/connect/cdc-reverse.yaml`

- [ ] **Step 1: Write the file**

```yaml
# cdc-reverse.yaml — single durable pull consumer; switch on op:
#   create/update -> SET kv_key body ; delete -> DEL kv_key ;
#   rename -> EVAL cdc_rename.lua (DEL old + SET new) ; unknown -> throw -> nack.
# No version fence: reordered/late same-key arrivals overwrite (no-LWW).
# reject_errored drop: success acks JetStream; processor failure nacks -> redelivery
# (absorbed by SET/DEL/Lua idempotency).
http:
  address: 0.0.0.0:4195
  enabled: true

input:
  label: jetstream_source
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth: { user_credentials_file: {{ .Values.nats.auth.creds.subscriber | quote }} }
    subject: {{ include "rrcs.nats.stream.subjects" . | quote }}
    stream: {{ .Values.nats.stream.name | quote }}
    durable: {{ .Values.nats.stream.consumer.durable | quote }}
    deliver: all
    ack_wait: 30s
    max_ack_pending: 1024

pipeline:
  threads: 4
  processors:
    # Stash the envelope fields into metadata FIRST: the `redis` processor below
    # REPLACES message content with the Redis reply, so any field needed by a
    # later processor (the metric label) or by args_mapping must live in metadata.
    - mapping: |
        meta op      = this.op
        meta kv_key  = this.kv_key
        meta old_key = this.old_key
        meta new_key = this.new_key
        meta body    = this.body
    - switch:
        - check: meta("op") == "create" || meta("op") == "update"
          processors:
            - redis:
                url: {{ include "rrcs.redis.region.url" . }}
                kind: simple
                command: set
                args_mapping: 'root = [ meta("kv_key"), meta("body") ]'
            - metric: { type: counter, name: cdc_apply, labels: { op: "${! meta(\"op\") }" } }
        - check: meta("op") == "delete"
          processors:
            - redis:
                url: {{ include "rrcs.redis.region.url" . }}
                kind: simple
                command: del
                args_mapping: 'root = [ meta("kv_key") ]'
            - metric: { type: counter, name: cdc_apply, labels: { op: "delete" } }
        - check: meta("op") == "rename"
          processors:
            - redis:
                url: {{ include "rrcs.redis.region.url" . }}
                kind: simple
                command: eval
                args_mapping: |
                  let script = {{ .Files.Get "files/connect/cdc_rename.lua" | toJson }}
                  root = [ $script, 2, meta("old_key"), meta("new_key"), meta("body") ]
            - metric: { type: counter, name: cdc_apply, labels: { op: "rename" } }
        - processors:
            - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'

output:
  reject_errored:
    drop: {}

logger: { level: INFO, format: json, add_timestamp: true }
metrics:
  prometheus: { use_histogram_timing: true }
```

- [ ] **Step 2: Confirm file exists and is non-empty**

Run: `wc -l $LAB/chart/files/connect/cdc-reverse.yaml`
Expected: ~50 lines.

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/files/connect/cdc-reverse.yaml
git commit -m "no-lww-simple-cdc: connect sink config (op switch, no fence, reject_errored)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.4: publishSubject helper — op suffix

**Files:**
- Modify: `$LAB/chart/templates/_helpers.tpl` (the `rrcs.nats.stream.publishSubject` define)

- [ ] **Step 1: Edit the define to use `op` instead of `pattern`**

Replace the body of `rrcs.nats.stream.publishSubject`:

```tpl
{{/*
rrcs.nats.stream.publishSubject — subject connect-source publishes each CDC event
to: <subjectPrefix>.<op>. The ".${! meta(\"op\") }" suffix is a Redpanda Connect
interpolation evaluated at publish time, not by Helm.
*/}}
{{- define "rrcs.nats.stream.publishSubject" -}}
{{- $p := required "nats.stream.subjectPrefix is required" .Values.nats.stream.subjectPrefix -}}
{{- printf "%s.${! meta(\"op\") }" $p -}}
{{- end -}}
```

(The only change from the parent is `meta(\"pattern\")` → `meta(\"op\")`.)

- [ ] **Step 2: Verify the helper renders (deferred to Phase 3 helm template; here grep confirms the edit)**

Run: `grep -n 'meta(\\"op\\")' $LAB/chart/templates/_helpers.tpl`
Expected: one match inside `publishSubject`.

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/templates/_helpers.tpl
git commit -m "no-lww-simple-cdc: publishSubject helper uses op suffix

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Chart wiring

### Task 3.1: values.yaml — profile, NATS names, replicas, op-mix

**Files:**
- Modify: `$LAB/chart/values.yaml`

- [ ] **Step 1: Set the profile**

Change `profile: lww` → `profile: cdc`.

- [ ] **Step 2: Re-scope the NATS stream block**

Replace the `nats.stream` block:

```yaml
  stream:
    name: KV_CDC
    subjectPrefix: "kv.cdc"
    consumer:
      durable: "cdc_sink"
    maxAge: "1h"
    maxBytes: "256MB"
    maxMsgSize: "1MB"
    dupeWindow: "5m"
```

(Changes from parent: `name APP_EVENTS→KV_CDC`, `subjectPrefix app.events→kv.cdc`, `consumer.durable region-writer→cdc_sink`. `subjectPrefix` is the single configurable knob for the whole subject namespace.)

- [ ] **Step 3: Single source + sink**

Replace the `connect` block's replica counts:

```yaml
connect:
  image: hpdevelop/connect:4.92.0-claudefix
  source:
    replicas: 1
  sink:
    replicas: 1
```

- [ ] **Step 4: Writer op-mix + keyspace env**

Replace the `writer.env` block:

```yaml
writer:
  image: redis-rrcs/writer:dev
  pullPolicy: ""
  env:
    STREAM_MAXLEN: "100000"
    WORKERS: "8"
    PIPELINE_DEPTH: "50"
    KEY_SPACE_SIZE: "1000"
    PAYLOAD_BYTES: "200"
    MAX_RATE: "20000"
    OP_CREATE: "40"
    OP_UPDATE: "40"
    OP_DELETE: "10"
    OP_RENAME: "10"
```

- [ ] **Step 5: Verify YAML parses**

Run: `cd $LAB && python3 -c "import yaml; yaml.safe_load(open('chart/values.yaml')); print('values.yaml OK')"`
Expected: `values.yaml OK`.

- [ ] **Step 6: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/values.yaml
git commit -m "no-lww-simple-cdc: values — profile=cdc, KV_CDC stream, single src/sink, op-mix

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.2: connect-sink.yaml — drop the headless Service

**Files:**
- Modify: `$LAB/chart/templates/connect-sink.yaml`

- [ ] **Step 1: Delete the headless Service block**

Remove the entire trailing block starting at the `---` before the headless-Service comment (`# Headless Service: clusterIP None ...`) through the end of file. The single sink has no per-pod metric summing, so only the regular ClusterIP Service remains.

- [ ] **Step 2: Verify only one Service remains**

Run: `grep -c 'kind: Service' $LAB/chart/templates/connect-sink.yaml`
Expected: `1`.

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/templates/connect-sink.yaml
git commit -m "no-lww-simple-cdc: drop sink headless Service (single sink)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.3: writer.yaml — op-mix env

**Files:**
- Modify: `$LAB/chart/templates/writer.yaml`

- [ ] **Step 1: Add op-mix env vars to the writer container**

In the writer container `env:` list, after the `MAX_RATE` entry, add:

```yaml
            - { name: OP_CREATE, value: "{{ .Values.writer.env.OP_CREATE }}" }
            - { name: OP_UPDATE, value: "{{ .Values.writer.env.OP_UPDATE }}" }
            - { name: OP_DELETE, value: "{{ .Values.writer.env.OP_DELETE }}" }
            - { name: OP_RENAME, value: "{{ .Values.writer.env.OP_RENAME }}" }
```

(`REDIS_ADDR` already points at central; the writer dual-writes the central KV through that same client. No other change.)

- [ ] **Step 2: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/templates/writer.yaml
git commit -m "no-lww-simple-cdc: writer template — op-mix env

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.4: dashboard.yaml — add CENTRAL_ADDR

**Files:**
- Modify: `$LAB/chart/templates/dashboard.yaml`

- [ ] **Step 1: Add the central Redis env**

In the dashboard container `env:` list, before `REGION_ADDR`, add:

```yaml
            - { name: CENTRAL_ADDR, value: {{ include "rrcs.redis.central.hostPort" . | quote }} }
```

(Keep the existing `REGION_ADDR`, `WRITER_URL`, `CONNECT_SINK_URL`, `LISTEN_ADDR`.)

- [ ] **Step 2: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/templates/dashboard.yaml
git commit -m "no-lww-simple-cdc: dashboard template — central Redis addr

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.5: verifier-job.yaml — CDC args

**Files:**
- Modify: `$LAB/chart/templates/verifier-job.yaml`

- [ ] **Step 1: Replace the container `args` list**

Replace the verifier container's `args:` with:

```yaml
          args:
            - --epoch={{ .Values.verifier.epoch }}
            - --redis-central={{ include "rrcs.redis.central.hostPort" . }}
            - --redis-region={{ include "rrcs.redis.region.hostPort" . }}
            - --nats={{ include "rrcs.nats.monitorUrl" . }}
            - --nats-stream={{ .Values.nats.stream.name }}
            - --nats-consumer={{ .Values.nats.stream.consumer.durable }}
            - --source-group=cdc_propagator
            - --quiesce-timeout=15s
```

(Drops `--rate/--duration/--warmup/--drain/--writer/--connect-sink-dns/--connect-sink-port`; the new verifier runs deterministic scripted checks, not a load run.)

- [ ] **Step 2: Verify the `verifier.run` gate and name-length guard are still intact**

Run: `grep -n 'Values.verifier.run\|exceeds 57-char' $LAB/chart/templates/verifier-job.yaml`
Expected: both lines present (untouched).

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/templates/verifier-job.yaml
git commit -m "no-lww-simple-cdc: verifier Job — CDC check args

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.6: NOTES.txt

**Files:**
- Modify: `$LAB/chart/templates/NOTES.txt`

- [ ] **Step 1: Replace the file contents**

```
no-lww-simple-cdc (fence-free CDC) installed in namespace {{ .Release.Namespace }}.

Profile           : {{ .Values.profile }}   (op switch at connect-sink; NO version fence)
NATS stream       : {{ .Values.nats.stream.name }}  subjects {{ .Values.nats.stream.subjectPrefix }}.>
Dedup window      : {{ .Values.nats.stream.dupeWindow }}  (Nats-Msg-Id = event_id)

Run the validation (dedup + per-op-under-quiescence + idempotent replay):
  RRCS_NS={{ .Release.Namespace }} RRCS_RELEASE={{ .Release.Name }} scripts/verify-cdc.sh

Insert messages by hand (prints copy-paste commands; does NOT run them):
  scripts/insert-msgs.sh

Watch central vs region live:
  scripts/dashboard-forward.sh               # binds 0.0.0.0; open http://<host>:8080

Tear down:
  helm uninstall {{ .Release.Name }} -n {{ .Release.Namespace }}
```

- [ ] **Step 2: Commit**

```bash
git add labs/no-lww-simple-cdc/chart/templates/NOTES.txt
git commit -m "no-lww-simple-cdc: NOTES for CDC lab

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.7: Regenerate NATS auth fixtures

The publisher/subscriber JWTs bake in the stream name, subject prefix, and durable name. Changing them (Task 3.1) requires regenerating the committed fixtures under `chart/files/nats-auth/`.

**Files:**
- Modify: `$LAB/chart/files/nats-auth/*` (regenerated)

- [ ] **Step 1: Confirm `nsc` is available**

Run: `command -v nsc && nsc --version`
Expected: a path + version. If missing, install nsc (`go install github.com/nats-io/nsc/v2@latest` or per the parent `chart/files/nats-auth/README.md`) before continuing — this is the one host tool the auth fixtures need.

- [ ] **Step 2: Regenerate from the new values**

Run: `cd $LAB && scripts/gen-nats-auth.sh --force`
Expected: writes `operator.jwt`, `APP.jwt`, `publisher.creds`, `subscriber.creds`, `admin.creds`, `nats-server.conf`. The publisher grant must now read `kv.cdc.>` and the subscriber grants `$JS.ACK.KV_CDC.cdc_sink.>` etc.

- [ ] **Step 3: Verify the grants picked up the new prefix/stream/durable**

Run: `cd $LAB && nsc describe user --account APP --name publisher 2>/dev/null | grep -i 'kv.cdc' && nsc describe user --account APP --name subscriber 2>/dev/null | grep -i 'KV_CDC.cdc_sink'`
Expected: both greps match (publisher pub on `kv.cdc.>`, subscriber on `KV_CDC.cdc_sink`).

- [ ] **Step 4: Commit the regenerated fixtures**

```bash
git add -A labs/no-lww-simple-cdc/chart/files/nats-auth
git commit -m "no-lww-simple-cdc: regenerate NATS auth for KV_CDC/kv.cdc/cdc_sink

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3.8: Render the chart end-to-end

**Files:** none (verification only)

- [ ] **Step 1: helm template must render with profile=cdc**

Run: `cd $LAB && helm template t ./chart --set profile=cdc -f chart/values-dev.yaml > /tmp/cdc-render.yaml && echo RENDER_OK`
Expected: `RENDER_OK` (no template errors).

- [ ] **Step 2: Assert the wired subject namespace + single replicas**

Run:
```bash
grep -E 'subject: "kv\.cdc\.>"|kv\.cdc\.\$\{! meta' /tmp/cdc-render.yaml
grep -c 'replicas: 1' /tmp/cdc-render.yaml
grep -E 'durable: "cdc_sink"' /tmp/cdc-render.yaml
```
Expected: source publish subject `kv.cdc.${! meta("op") }`, sink subjects `kv.cdc.>` and `durable: "cdc_sink"` present; `replicas: 1` count ≥ 2 (source + sink; redis/nats/writer/dashboard are also 1).

- [ ] **Step 3: Assert the connect configs are the cdc ones (profile-driven)**

Run: `grep -E 'cdc_propagator|command: set|command: del|command: eval' /tmp/cdc-render.yaml | head`
Expected: the source consumer group `cdc_propagator` and the sink `set`/`del`/`eval` commands are present (confirms `connect-configmaps.yaml` picked `cdc-forward.yaml`/`cdc-reverse.yaml` via `profile=cdc`).

- [ ] **Step 4: Commit (nothing to commit; this is a gate). If green, proceed.**

---

## Phase 4 — Verifier: three order-insensitive checks

The verifier drives **central Redis directly** (XADD CDC events to `app.events`) and observes region Redis + NATS, with the writer idle. It runs three checks and emits `RESULT_JSON`. Keeps the parent's `nats.go` (`ScrapeJSZ`) and the new `httpclient.go` (Phase 0); adds `redis.go`, `quiescence.go`, `checks.go`, `report.go`, `main.go`.

**Module:** `$LAB/verifier`.

> **Phase execution note:** Phase 0 already removed the parent's `main.go`/`redis.go`/`quiescence.go`/`report.go` and added `httpclient.go`, leaving only `nats.go` + `httpclient.go`. Each task below adds files in dependency order, so the package builds incrementally and every `go test` runs. `go build ./...` (the binary) only links once `main.go` lands in Task 4.5.

### Task 4.1: Redis helpers for the verifier

**Files:**
- Replace: `$LAB/verifier/redis.go`
- Test: `$LAB/verifier/redis_test.go`

- [ ] **Step 1: Write the failing test (pure helper, no live Redis)**

```go
// $LAB/verifier/redis_test.go
package main

import "testing"

func TestEventValuesOrder(t *testing.T) {
	vals := eventValues(map[string]string{"op": "create", "kv_key": "k", "event_id": "e", "body": "{}"})
	// must be an even-length key/value slice and include op/event_id
	if len(vals)%2 != 0 {
		t.Fatalf("odd-length values: %d", len(vals))
	}
	found := map[string]bool{}
	for i := 0; i < len(vals); i += 2 {
		found[vals[i].(string)] = true
	}
	for _, k := range []string{"event_id", "op", "kv_key", "old_key", "new_key", "ts", "body"} {
		if !found[k] {
			t.Fatalf("missing field %q in %v", k, vals)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd $LAB/verifier && go test ./... -run TestEventValuesOrder -v`
Expected: FAIL — `undefined: eventValues` (the package — `nats.go` + `httpclient.go` from Phase 0 — builds, so this is a clean undefined-symbol error, not a broader build break).

- [ ] **Step 3: Write minimal implementation**

```go
// $LAB/verifier/redis.go
package main

import (
	"context"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisClient struct{ rdb *redis.Client }

func NewRedisClient(addr string) *RedisClient {
	return &RedisClient{rdb: redis.NewClient(&redis.Options{Addr: addr})}
}
func (c *RedisClient) Close() error { return c.rdb.Close() }

// eventValues builds the ordered XADD field slice for a CDC event from a map.
// Always emits the full field set so the source pipeline metadata is consistent.
func eventValues(f map[string]string) []any {
	get := func(k string) string { return f[k] }
	return []any{
		"event_id", get("event_id"),
		"op", get("op"),
		"kv_key", get("kv_key"),
		"old_key", get("old_key"),
		"new_key", get("new_key"),
		"ts", get("ts"),
		"body", get("body"),
	}
}

// XAddEvent appends one CDC event to the central app.events stream.
func (c *RedisClient) XAddEvent(ctx context.Context, stream string, f map[string]string) error {
	if f["ts"] == "" {
		f["ts"] = strconv.FormatInt(time.Now().UnixMilli(), 10)
	}
	return c.rdb.XAdd(ctx, &redis.XAddArgs{Stream: stream, Values: eventValues(f)}).Err()
}

// GetString returns (value, exists).
func (c *RedisClient) GetString(ctx context.Context, key string) (string, bool, error) {
	v, err := c.rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, true, nil
}

// GroupLag returns unread entries for a consumer group on a stream (0 if the
// stream or group does not exist yet).
func (c *RedisClient) GroupLag(ctx context.Context, stream, group string) (int64, error) {
	groups, err := c.rdb.XInfoGroups(ctx, stream).Result()
	if err != nil {
		return 0, nil // stream absent → nothing pending
	}
	for _, g := range groups {
		if g.Name == group {
			return g.Lag, nil
		}
	}
	return 0, nil
}
```

- [ ] **Step 4: Run test to verify it passes, then commit**

Run: `cd $LAB/verifier && go test ./... -run TestEventValuesOrder -v`
Expected: PASS.

```bash
git add labs/no-lww-simple-cdc/verifier/redis.go labs/no-lww-simple-cdc/verifier/redis_test.go
git commit -m "no-lww-simple-cdc: verifier redis helpers (XADD event, GET, group lag)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 4.2: Quiescence

**Files:**
- Replace: `$LAB/verifier/quiescence.go`

- [ ] **Step 1: Write the implementation**

```go
// $LAB/verifier/quiescence.go
package main

import (
	"context"
	"log"
	"time"
)

// WaitQuiescent blocks until the source consumer group has drained app.events
// AND the sink JetStream consumer has zero pending — or the deadline fires.
// Returns true if quiesced, false on timeout (caller must NOT assert on timeout).
func WaitQuiescent(ctx context.Context, central *RedisClient, sourceGroup, natsURL, stream string, deadline time.Duration) bool {
	end := time.Now().Add(deadline)
	for {
		if ctx.Err() != nil || time.Now().After(end) {
			log.Printf("WARN: pipeline did not quiesce within %s", deadline)
			return false
		}
		srcOK := false
		if lag, err := central.GroupLag(ctx, "app.events", sourceGroup); err == nil && lag == 0 {
			srcOK = true
		}
		sinkOK := false
		if snap, err := ScrapeJSZ(ctx, natsURL, stream); err == nil && snap.MaxPending == 0 {
			sinkOK = true
		}
		if srcOK && sinkOK {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(250 * time.Millisecond):
		}
	}
}
```

- [ ] **Step 2: Commit**

```bash
git add labs/no-lww-simple-cdc/verifier/quiescence.go
git commit -m "no-lww-simple-cdc: verifier quiescence (source lag + sink pending)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 4.3: The three checks

**Files:**
- Create: `$LAB/verifier/checks.go`
- Test: `$LAB/verifier/checks_test.go`

- [ ] **Step 1: Write the failing test (pure helpers: key construction is deterministic)**

```go
// $LAB/verifier/checks_test.go
package main

import (
	"strings"
	"testing"
)

func TestVerifyKeysShareHashTag(t *testing.T) {
	a, b := renameKeys("e7")
	tagA := a[strings.Index(a, "{"):strings.Index(a, "}")+1]
	tagB := b[strings.Index(b, "{"):strings.Index(b, "}")+1]
	if tagA != tagB {
		t.Fatalf("rename keys must share a hash tag: %q vs %q", tagA, tagB)
	}
	if a == b {
		t.Fatal("rename keys must differ")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd $LAB/verifier && go test ./... -run TestVerifyKeysShareHashTag -v`
Expected: FAIL — `undefined: renameKeys`.

- [ ] **Step 3: Write minimal implementation**

```go
// $LAB/verifier/checks.go
package main

import (
	"context"
	"fmt"
	"time"
)

// renameKeys returns two keys sharing one hash tag (same Redis slot) for the
// rename/replay checks: lb:general:active:{verify-<epoch>}:a / :b
func renameKeys(epoch string) (string, string) {
	base := fmt.Sprintf("lb:general:active:{verify-%s}", epoch)
	return base + ":a", base + ":b"
}

type Checks struct {
	Central     *RedisClient
	Region      *RedisClient
	NatsURL     string
	Stream      string
	SourceGroup string
	Quiesce     time.Duration
}

func (c *Checks) quiesce(ctx context.Context) bool {
	return WaitQuiescent(ctx, c.Central, c.SourceGroup, c.NatsURL, c.Stream, c.Quiesce)
}

// Dedup: XADD the same event_id 5x; after the source drains, JetStream Messages
// must have grown by exactly 1 (dedup within the duplicate window).
func (c *Checks) Dedup(ctx context.Context, epoch string) (delta int64, ok bool, err error) {
	before, err := ScrapeJSZ(ctx, c.NatsURL, c.Stream)
	if err != nil {
		return 0, false, err
	}
	eid := "verify-dup-" + epoch
	key := fmt.Sprintf("lb:general:active:{verify-%s-dup}", epoch)
	for i := 0; i < 5; i++ {
		if err := c.Central.XAddEvent(ctx, "app.events", map[string]string{
			"event_id": eid, "op": "update", "kv_key": key, "body": `{"dup":true}`,
		}); err != nil {
			return 0, false, err
		}
	}
	if !c.quiesce(ctx) {
		return 0, false, fmt.Errorf("dedup: pipeline did not quiesce")
	}
	after, err := ScrapeJSZ(ctx, c.NatsURL, c.Stream)
	if err != nil {
		return 0, false, err
	}
	delta = after.Messages - before.Messages
	return delta, delta == 1, nil
}

// emit one event and wait for quiescence.
func (c *Checks) emit(ctx context.Context, f map[string]string) error {
	if err := c.Central.XAddEvent(ctx, "app.events", f); err != nil {
		return err
	}
	if !c.quiesce(ctx) {
		return fmt.Errorf("op %s: pipeline did not quiesce", f["op"])
	}
	return nil
}

func (c *Checks) regionEquals(ctx context.Context, key, want string) (bool, error) {
	got, ok, err := c.Region.GetString(ctx, key)
	if err != nil {
		return false, err
	}
	return ok && got == want, nil
}

func (c *Checks) regionAbsent(ctx context.Context, key string) (bool, error) {
	_, ok, err := c.Region.GetString(ctx, key)
	if err != nil {
		return false, err
	}
	return !ok, nil
}

// PerOp: create→update→rename→delete, one op at a time, asserting region after
// each quiesced step. Order-insensitive: there is no concurrency in flight.
func (c *Checks) PerOp(ctx context.Context, epoch string) (createOK, updateOK, renameOK, deleteOK bool, err error) {
	ka, kb := renameKeys(epoch)
	v1, v2 := `{"v":1}`, `{"v":2}`

	if err = c.emit(ctx, map[string]string{"event_id": "vc-" + epoch, "op": "create", "kv_key": ka, "body": v1}); err != nil {
		return
	}
	if createOK, err = c.regionEquals(ctx, ka, v1); err != nil {
		return
	}

	if err = c.emit(ctx, map[string]string{"event_id": "vu-" + epoch, "op": "update", "kv_key": ka, "body": v2}); err != nil {
		return
	}
	if updateOK, err = c.regionEquals(ctx, ka, v2); err != nil {
		return
	}

	if err = c.emit(ctx, map[string]string{"event_id": "vr-" + epoch, "op": "rename", "old_key": ka, "new_key": kb, "body": v2}); err != nil {
		return
	}
	oldGone, e := c.regionAbsent(ctx, ka)
	if e != nil {
		err = e
		return
	}
	newThere, e := c.regionEquals(ctx, kb, v2)
	if e != nil {
		err = e
		return
	}
	renameOK = oldGone && newThere

	if err = c.emit(ctx, map[string]string{"event_id": "vd-" + epoch, "op": "delete", "kv_key": kb}); err != nil {
		return
	}
	deleteOK, err = c.regionAbsent(ctx, kb)
	return
}

// Replay: apply the same rename twice (distinct event_ids so dedup does not
// swallow the second). DEL old + SET new is idempotent → terminal state stable.
func (c *Checks) Replay(ctx context.Context, epoch string) (ok bool, err error) {
	base := fmt.Sprintf("lb:general:active:{verify-%s-rep}", epoch)
	kc, kd := base+":c", base+":d"
	body := `{"v":9}`
	if err = c.emit(ctx, map[string]string{"event_id": "vrc-" + epoch, "op": "create", "kv_key": kc, "body": body}); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{"event_id": "vrr1-" + epoch, "op": "rename", "old_key": kc, "new_key": kd, "body": body}); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{"event_id": "vrr2-" + epoch, "op": "rename", "old_key": kc, "new_key": kd, "body": body}); err != nil {
		return
	}
	newThere, e := c.regionEquals(ctx, kd, body)
	if e != nil {
		err = e
		return
	}
	oldGone, e := c.regionAbsent(ctx, kc)
	if e != nil {
		err = e
		return
	}
	ok = newThere && oldGone
	return
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd $LAB/verifier && go test ./... -run TestVerifyKeysShareHashTag -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/no-lww-simple-cdc/verifier/checks.go labs/no-lww-simple-cdc/verifier/checks_test.go
git commit -m "no-lww-simple-cdc: verifier 3 checks (dedup, per-op-quiesced, replay)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 4.4: Result + verdict

**Files:**
- Replace: `$LAB/verifier/report.go`
- Test: `$LAB/verifier/report_test.go`

- [ ] **Step 1: Write the failing test**

```go
// $LAB/verifier/report_test.go
package main

import "testing"

func TestVerdictPassOnlyWhenAllGreen(t *testing.T) {
	all := CDCResult{DedupOK: true, OpsOK: true, ReplayOK: true}
	if v := ComputeVerdict(all); !v.Pass {
		t.Fatalf("all-green should pass: %+v", v)
	}
	bad := CDCResult{DedupOK: true, OpsOK: false, ReplayOK: true}
	if v := ComputeVerdict(bad); v.Pass {
		t.Fatal("ops failure must fail the verdict")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd $LAB/verifier && go test ./... -run TestVerdictPass -v`
Expected: FAIL — `undefined: CDCResult`.

- [ ] **Step 3: Write minimal implementation**

```go
// $LAB/verifier/report.go
package main

import "fmt"

type CDCResult struct {
	Epoch      string `json:"epoch"`
	DedupDelta int64  `json:"dedup_delta"`
	DedupOK    bool   `json:"dedup_ok"`
	CreateOK   bool   `json:"create_ok"`
	UpdateOK   bool   `json:"update_ok"`
	RenameOK   bool   `json:"rename_ok"`
	DeleteOK   bool   `json:"delete_ok"`
	OpsOK      bool   `json:"ops_ok"`
	ReplayOK   bool   `json:"replay_ok"`
}

type Verdict struct {
	Pass   bool   `json:"pass"`
	Reason string `json:"reason,omitempty"`
}

type Report struct {
	CDC     CDCResult `json:"cdc"`
	Verdict Verdict   `json:"verdict"`
}

func ComputeVerdict(r CDCResult) Verdict {
	switch {
	case !r.DedupOK:
		return Verdict{false, fmt.Sprintf("dedup failed: stream grew by %d (want 1)", r.DedupDelta)}
	case !r.OpsOK:
		return Verdict{false, fmt.Sprintf("per-op failed: create=%v update=%v rename=%v delete=%v", r.CreateOK, r.UpdateOK, r.RenameOK, r.DeleteOK)}
	case !r.ReplayOK:
		return Verdict{false, "replay not idempotent: rename re-delivery changed terminal state"}
	default:
		return Verdict{true, ""}
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd $LAB/verifier && go test ./... -run TestVerdictPass -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/no-lww-simple-cdc/verifier/report.go labs/no-lww-simple-cdc/verifier/report_test.go
git commit -m "no-lww-simple-cdc: verifier result + verdict

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 4.5: main orchestration

**Files:**
- Replace: `$LAB/verifier/main.go`

- [ ] **Step 1: Write the implementation**

```go
// $LAB/verifier/main.go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"time"
)

func main() {
	epoch := flag.String("epoch", "", "unique per-run epoch token (required)")
	central := flag.String("redis-central", "redis-central:6379", "central Redis host:port")
	region := flag.String("redis-region", "redis-region:6379", "region Redis host:port")
	natsURL := flag.String("nats", "http://nats:8222", "NATS monitoring URL")
	stream := flag.String("nats-stream", "KV_CDC", "JetStream stream name")
	_ = flag.String("nats-consumer", "cdc_sink", "sink durable name (informational)")
	sourceGroup := flag.String("source-group", "cdc_propagator", "source consumer group")
	quiesce := flag.Duration("quiesce-timeout", 15*time.Second, "per-op quiescence deadline")
	flag.Parse()

	if *epoch == "" {
		log.Fatal("--epoch is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	centralC := NewRedisClient(*central)
	defer centralC.Close()
	regionC := NewRedisClient(*region)
	defer regionC.Close()

	checks := &Checks{Central: centralC, Region: regionC, NatsURL: *natsURL, Stream: *stream, SourceGroup: *sourceGroup, Quiesce: *quiesce}

	res := CDCResult{Epoch: *epoch}

	delta, dok, err := checks.Dedup(ctx, *epoch)
	if err != nil {
		log.Printf("dedup error: %v", err)
	}
	res.DedupDelta, res.DedupOK = delta, dok

	cOK, uOK, rOK, dOK, err := checks.PerOp(ctx, *epoch)
	if err != nil {
		log.Printf("per-op error: %v", err)
	}
	res.CreateOK, res.UpdateOK, res.RenameOK, res.DeleteOK = cOK, uOK, rOK, dOK
	res.OpsOK = cOK && uOK && rOK && dOK

	rok, err := checks.Replay(ctx, *epoch)
	if err != nil {
		log.Printf("replay error: %v", err)
	}
	res.ReplayOK = rok

	rep := Report{CDC: res, Verdict: ComputeVerdict(res)}
	b, _ := json.Marshal(rep)
	fmt.Printf("RESULT_JSON:%s\n", b)
	log.Printf("verdict.pass=%v reason=%q dedup_delta=%d ops_ok=%v replay_ok=%v",
		rep.Verdict.Pass, rep.Verdict.Reason, res.DedupDelta, res.OpsOK, res.ReplayOK)
}
```

- [ ] **Step 2: Build, vet, and run the verifier test suite**

Run: `cd $LAB/verifier && go build ./... && go vet ./... && go test ./...`
Expected: build OK, vet clean, all tests PASS (redis/checks/report tests).

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/verifier/main.go
git commit -m "no-lww-simple-cdc: verifier main — run 3 checks, emit RESULT_JSON

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — Dashboard: central-vs-region divergence

The dashboard polls **both** central and region Redis over the `lb:*` keyspace, computes divergence (the visible no-LWW stale-overwrite cost), scrapes sink `cdc_apply` op counters and the writer `/state`, and streams it to the browser. It also subscribes to region keyspace events (`set`/`del`) for a live key-change feed.

**Module:** `$LAB/dashboard`.

### Task 5.1: Divergence computation (pure helper)

**Files:**
- Create: `$LAB/dashboard/divergence.go`
- Test: `$LAB/dashboard/divergence_test.go`

- [ ] **Step 1: Write the failing test**

```go
// $LAB/dashboard/divergence_test.go
package main

import "testing"

func TestDivergence(t *testing.T) {
	central := map[string]string{"a": "1", "b": "2", "c": "3"}
	region := map[string]string{"a": "1", "b": "9" /* differs */, "d": "4" /* region-only */}
	d := computeDivergence(central, region)
	if d.CentralCount != 3 || d.RegionCount != 3 {
		t.Fatalf("counts: %+v", d)
	}
	if d.OnlyCentral != 1 { // c
		t.Fatalf("OnlyCentral=%d want 1", d.OnlyCentral)
	}
	if d.OnlyRegion != 1 { // d
		t.Fatalf("OnlyRegion=%d want 1", d.OnlyRegion)
	}
	if d.Differing != 1 { // b
		t.Fatalf("Differing=%d want 1", d.Differing)
	}
	if d.Divergent != 3 {
		t.Fatalf("Divergent=%d want 3", d.Divergent)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd $LAB/dashboard && go test ./... -run TestDivergence -v`
Expected: FAIL — `undefined: computeDivergence`.

- [ ] **Step 3: Write minimal implementation**

```go
// $LAB/dashboard/divergence.go
package main

// Divergence summarizes central-vs-region disagreement: the visible no-LWW
// stale-overwrite / delete-resurrection cost.
type Divergence struct {
	CentralCount int      `json:"central_count"`
	RegionCount  int      `json:"region_count"`
	OnlyCentral  int      `json:"only_central"` // intent present, mirror missing
	OnlyRegion   int      `json:"only_region"`  // resurrected / orphan in mirror
	Differing    int      `json:"differing"`    // both present, bodies differ
	Divergent    int      `json:"divergent"`    // sum of the three
	Samples      []string `json:"samples"`      // up to 20 divergent keys
}

func computeDivergence(central, region map[string]string) Divergence {
	d := Divergence{CentralCount: len(central), RegionCount: len(region)}
	for k, cv := range central {
		rv, ok := region[k]
		switch {
		case !ok:
			d.OnlyCentral++
			d.addSample(k)
		case rv != cv:
			d.Differing++
			d.addSample(k)
		}
	}
	for k := range region {
		if _, ok := central[k]; !ok {
			d.OnlyRegion++
			d.addSample(k)
		}
	}
	d.Divergent = d.OnlyCentral + d.OnlyRegion + d.Differing
	return d
}

func (d *Divergence) addSample(k string) {
	if len(d.Samples) < 20 {
		d.Samples = append(d.Samples, k)
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd $LAB/dashboard && go test ./... -run TestDivergence -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/no-lww-simple-cdc/dashboard/divergence.go labs/no-lww-simple-cdc/dashboard/divergence_test.go
git commit -m "no-lww-simple-cdc: dashboard divergence computation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 5.2: Dashboard main (poll central+region, scrape sink, websocket)

**Files:**
- Replace: `$LAB/dashboard/main.go`

- [ ] **Step 1: Write the implementation**

```go
// $LAB/dashboard/main.go
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"
)

//go:embed static/index.html
var indexHTML []byte

type wsClient struct {
	conn   *websocket.Conn
	writeM sync.Mutex
}

func (c *wsClient) write(b []byte) error {
	c.writeM.Lock()
	defer c.writeM.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	return c.conn.WriteMessage(websocket.TextMessage, b)
}

type hub struct {
	mu      sync.Mutex
	clients map[*wsClient]struct{}
}

func newHub() *hub { return &hub{clients: map[*wsClient]struct{}{}} }
func (h *hub) add(c *wsClient) { h.mu.Lock(); h.clients[c] = struct{}{}; h.mu.Unlock() }
func (h *hub) remove(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[c]; ok {
		delete(h.clients, c)
		_ = c.conn.Close()
	}
}
func (h *hub) broadcast(b []byte) {
	h.mu.Lock()
	cs := make([]*wsClient, 0, len(h.clients))
	for c := range h.clients {
		cs = append(cs, c)
	}
	h.mu.Unlock()
	for _, c := range cs {
		if err := c.write(b); err != nil {
			h.remove(c)
		}
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	centralAddr := getenv("CENTRAL_ADDR", "redis-central:6379")
	regionAddr := getenv("REGION_ADDR", "redis-region:6379")
	writerURL := getenv("WRITER_URL", "http://writer:8081")
	sinkURL := getenv("CONNECT_SINK_URL", "http://connect-sink:4195")
	listen := getenv("LISTEN_ADDR", ":8080")
	scanMatch := getenv("SCAN_MATCH", "lb:*")

	central := redis.NewClient(&redis.Options{Addr: centralAddr})
	region := redis.NewClient(&redis.Options{Addr: regionAddr})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	for i := 0; i < 30; i++ {
		if region.Ping(ctx).Err() == nil && central.Ping(ctx).Err() == nil {
			break
		}
		time.Sleep(time.Second)
	}
	_ = region.ConfigSet(ctx, "notify-keyspace-events", "KEA").Err()

	h := newHub()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); subscribeChanges(ctx, region, h) }()
	go func() { defer wg.Done(); pollLoop(ctx, central, region, writerURL, sinkURL, scanMatch, h) }()

	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200); _, _ = w.Write([]byte("ok")) })
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		c := &wsClient{conn: conn}
		h.add(c)
		go func() {
			defer h.remove(c)
			for {
				if _, _, err := conn.ReadMessage(); err != nil {
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
		sc, cf := context.WithTimeout(context.Background(), 3*time.Second)
		defer cf()
		_ = srv.Shutdown(sc)
		cancel()
	}()

	log.Printf("dashboard listening on %s (scan=%s)", listen, scanMatch)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
	wg.Wait()
	_ = region.Close()
	_ = central.Close()
}

// subscribeChanges streams region key changes (set/del) to the browser.
func subscribeChanges(ctx context.Context, c *redis.Client, h *hub) {
	sub := c.PSubscribe(ctx, "__keyevent@0__:set", "__keyevent@0__:del")
	defer func() { _ = sub.Close() }()
	ch := sub.Channel()
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			key := msg.Payload
			if !strings.HasPrefix(key, "lb:") {
				continue
			}
			op := "set"
			if strings.HasSuffix(msg.Channel, ":del") {
				op = "del"
			}
			val := ""
			if op == "set" {
				val, _ = c.Get(ctx, key).Result()
			}
			b, _ := json.Marshal(map[string]any{
				"type": "event", "op": op, "key": key, "value": val, "ts_ms": time.Now().UnixMilli(),
			})
			h.broadcast(b)
		}
	}
}

// scanAll loads every key matching pattern and its string value into a map.
func scanAll(ctx context.Context, c *redis.Client, match string) map[string]string {
	out := map[string]string{}
	var cursor uint64
	for {
		keys, cur, err := c.Scan(ctx, cursor, match, 500).Result()
		if err != nil {
			return out
		}
		for _, k := range keys {
			if v, err := c.Get(ctx, k).Result(); err == nil {
				out[k] = v
			}
		}
		cursor = cur
		if cursor == 0 {
			break
		}
	}
	return out
}

func pollLoop(ctx context.Context, central, region *redis.Client, writerURL, sinkURL, match string, h *hub) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			cmap := scanAll(ctx, central, match)
			rmap := scanAll(ctx, region, match)
			div := computeDivergence(cmap, rmap)
			ops := scrapeApply(ctx, sinkURL)
			epoch, writerOps := scrapeState(ctx, writerURL)
			b, _ := json.Marshal(map[string]any{
				"type": "stats", "divergence": div, "sink_apply": ops,
				"writer_ops": writerOps, "epoch": epoch,
			})
			h.broadcast(b)
		}
	}
}

// scrapeApply parses connect-sink /metrics for cdc_apply{op="..."} counters.
func scrapeApply(ctx context.Context, sinkURL string) map[string]int64 {
	out := map[string]int64{"create": 0, "update": 0, "delete": 0, "rename": 0}
	body := httpGet(ctx, sinkURL+"/metrics")
	for _, ln := range strings.Split(body, "\n") {
		if !strings.HasPrefix(ln, "cdc_apply{") && !strings.HasPrefix(ln, "cdc_apply_total{") {
			continue
		}
		v := int64(trailingFloat(ln))
		for op := range out {
			if strings.Contains(ln, `op="`+op+`"`) {
				out[op] = v
			}
		}
	}
	return out
}

func scrapeState(ctx context.Context, writerURL string) (string, map[string]int64) {
	body := httpGet(ctx, writerURL+"/state")
	var st struct {
		Epoch string           `json:"epoch"`
		Ops   map[string]int64 `json:"ops"`
	}
	_ = json.Unmarshal([]byte(body), &st)
	return st.Epoch, st.Ops
}

func httpGet(ctx context.Context, url string) string {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return string(b)
}

func trailingFloat(line string) float64 {
	f := strings.Fields(line)
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[len(f)-1], 64)
	return v
}
```

- [ ] **Step 2: Build + vet + test**

Run: `cd $LAB/dashboard && go build ./... && go vet ./... && go test ./...`
Expected: build OK, vet clean, tests PASS.

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/dashboard/main.go
git commit -m "no-lww-simple-cdc: dashboard main — central/region poll + divergence + ws

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 5.3: Dashboard HTML

**Files:**
- Replace: `$LAB/dashboard/static/index.html`

- [ ] **Step 1: Write the file**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>no-lww-simple-cdc — central vs region (live)</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 14px; background: #0e1117; color: #e6e6e6; }
  h1 { font-size: 16px; margin: 0 0 12px; color: #fff; }
  h2 { font-size: 13px; color: #b8c2cc; margin: 16px 0 6px; font-weight: 500; }
  table { border-collapse: collapse; width: 100%; font-size: 12px; }
  th, td { border-bottom: 1px solid #2a2f3a; padding: 4px 8px; text-align: left; }
  th { background: #161b22; color: #b8c2cc; font-weight: 500; }
  .stats { display: flex; gap: 12px; flex-wrap: wrap; }
  .card { background: #161b22; padding: 8px 12px; border-radius: 6px; min-width: 130px; }
  .card .name { font-size: 11px; color: #b8c2cc; text-transform: uppercase; letter-spacing: 0.04em; }
  .card .val { font-size: 20px; margin-top: 4px; }
  .ok { color: #7ee787; } .warn { color: #d29922; } .bad { color: #f85149; }
  #status { font-size: 11px; color: #8b95a3; margin-bottom: 8px; }
  #log-wrap { max-height: 50vh; overflow-y: auto; border: 1px solid #2a2f3a; border-radius: 6px; }
  code { background: #161b22; padding: 1px 4px; border-radius: 3px; }
</style>
</head>
<body>
<h1>no-lww-simple-cdc — central (intent) vs region (no-LWW mirror)</h1>
<div id="status">connecting…</div>

<h2>Key counts &amp; divergence</h2>
<div class="stats">
  <div class="card"><div class="name">central keys</div><div class="val" id="c-central">—</div></div>
  <div class="card"><div class="name">region keys</div><div class="val" id="c-region">—</div></div>
  <div class="card"><div class="name">divergent</div><div class="val warn" id="c-div">—</div></div>
  <div class="card"><div class="name">only central</div><div class="val" id="c-oc">—</div></div>
  <div class="card"><div class="name">only region</div><div class="val" id="c-or">—</div></div>
  <div class="card"><div class="name">differing</div><div class="val" id="c-diff">—</div></div>
</div>

<h2>Sink applies by op</h2>
<div class="stats">
  <div class="card"><div class="name">create</div><div class="val ok" id="op-create">—</div></div>
  <div class="card"><div class="name">update</div><div class="val ok" id="op-update">—</div></div>
  <div class="card"><div class="name">delete</div><div class="val ok" id="op-delete">—</div></div>
  <div class="card"><div class="name">rename</div><div class="val ok" id="op-rename">—</div></div>
  <div class="card"><div class="name">epoch</div><div class="val" id="c-epoch">—</div></div>
</div>

<h2>Live region key changes</h2>
<div id="log-wrap">
  <table>
    <thead><tr><th>time</th><th>op</th><th>key</th><th>value (snippet)</th></tr></thead>
    <tbody id="rows"></tbody>
  </table>
</div>

<script>
const rows = document.getElementById("rows");
const status = document.getElementById("status");
const set = (id, v) => document.getElementById(id).textContent = v;

function onEvent(e) {
  const ts = new Date(e.ts_ms).toISOString().split("T")[1].replace("Z","");
  const tr = document.createElement("tr");
  const snippet = (e.value || "").slice(0, 48);
  tr.innerHTML = `<td>${ts}</td><td>${e.op}</td><td><code>${e.key}</code></td><td>${snippet}</td>`;
  rows.prepend(tr);
  while (rows.childElementCount > 200) rows.removeChild(rows.lastChild);
}
function onStats(s) {
  const d = s.divergence || {};
  set("c-central", d.central_count);
  set("c-region", d.region_count);
  set("c-div", d.divergent);
  set("c-oc", d.only_central);
  set("c-or", d.only_region);
  set("c-diff", d.differing);
  const a = s.sink_apply || {};
  set("op-create", a.create); set("op-update", a.update);
  set("op-delete", a.delete); set("op-rename", a.rename);
  set("c-epoch", s.epoch || "—");
}

let ws;
function connect() {
  ws = new WebSocket((location.protocol === "https:" ? "wss" : "ws") + "://" + location.host + "/ws");
  ws.onopen = () => status.textContent = "live · " + new Date().toISOString();
  ws.onclose = () => { status.textContent = "disconnected, retrying…"; setTimeout(connect, 1500); };
  ws.onmessage = (m) => {
    try {
      const e = JSON.parse(m.data);
      if (e.type === "event") onEvent(e);
      else if (e.type === "stats") onStats(e);
    } catch {}
  };
}
connect();
</script>
</body>
</html>
```

- [ ] **Step 2: Rebuild (embeds the new HTML)**

Run: `cd $LAB/dashboard && go build ./... && echo BUILD_OK`
Expected: `BUILD_OK`.

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/dashboard/static/index.html
git commit -m "no-lww-simple-cdc: dashboard HTML — central/region divergence view

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Scripts

### Task 6.1: insert-msgs.sh (command former, prints only)

**Files:**
- Create: `$LAB/scripts/insert-msgs.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# insert-msgs.sh — FORMS redis-cli XADD commands for each CDC op and the dedup
# test, and PRINTS them for you to copy-paste and run by hand. It does NOT execute
# anything (per lab-requirements: "scripts must just form commands").
#
# Override the target with REDIS_CLI (e.g. a kubectl exec wrapper) and IDs.
set -euo pipefail

REDIS_CLI="${REDIS_CLI:-redis-cli -h redis-central -p 6379}"
STREAM="${STREAM:-app.events}"
EMP_ID="${EMP_ID:-55688}"
GRP_ID="${GRP_ID:-89889}"
ITEM_ID="${ITEM_ID:-9123}"

uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "eid-$RANDOM-$RANDOM"; }
ts() { date +%s%3N; }

cat <<EOF
# ---- copy & run these by hand ----

# create a new item (general pattern)
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op create kv_key "lb:general:active:{items:${ITEM_ID}}" ts "$(ts)" body '{"id":"item-${ITEM_ID}","name":"widget"}'

# update an existing employee (company pattern)
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op update kv_key "lb:company:active:{employees:${EMP_ID}}" ts "$(ts)" body '{"id":"emp-${EMP_ID}","title":"staff"}'

# delete an employee
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op delete kv_key "lb:company:active:{employees:${EMP_ID}}" ts "$(ts)" body ''

# standby->active rename (add-not-enabled-then-enable)
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op rename old_key "lb:company:standby:{employees:${EMP_ID}}" new_key "lb:company:active:{employees:${EMP_ID}}" ts "$(ts)" body '{"id":"emp-${EMP_ID}","enabled":true}'

# dedup test: SAME event_id five times -> JetStream stores ONE
#   (check with: nats stream info ${NATS_STREAM:-KV_CDC} | grep Messages)
EOF

DUP_EID="$(uuid)"
for i in 1 2 3 4 5; do
  echo "${REDIS_CLI} XADD ${STREAM} '*' event_id \"${DUP_EID}\" op update kv_key \"lb:general:active:{items:${ITEM_ID}}\" ts \"\$(date +%s%3N)\" body '{\"n\":${i}}'"
done
```

- [ ] **Step 2: Make executable and confirm it only prints (no XADD runs)**

Run: `chmod +x $LAB/scripts/insert-msgs.sh && $LAB/scripts/insert-msgs.sh | grep -c 'XADD'`
Expected: `9` (4 ops + 5 dedup lines), and no Redis connection attempted.

- [ ] **Step 3: shellcheck**

Run: `command -v shellcheck >/dev/null && shellcheck $LAB/scripts/insert-msgs.sh || echo "skip shellcheck"`
Expected: no errors, or `skip shellcheck`.

- [ ] **Step 4: Commit**

```bash
git add labs/no-lww-simple-cdc/scripts/insert-msgs.sh
git commit -m "no-lww-simple-cdc: insert-msgs.sh — forms XADD commands, prints only

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 6.2: verify-cdc.sh

**Files:**
- Create: `$LAB/scripts/verify-cdc.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# verify-cdc.sh — boot the chart (profile=cdc), run the verifier Job, and assert
# its RESULT_JSON verdict.pass. Exit 0 only when dedup + per-op + replay all pass.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-k8s}"
RELEASE="${RRCS_RELEASE:-cdc}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
EPOCH="run-$(date +%s)"

echo "[boot] helm upgrade --install ${RELEASE} (profile=cdc) ns=${NS}"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  --set profile=cdc -f "${VALUES_FILE}" --wait --timeout 5m
RESOURCE_PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

JOB="verifier-${EPOCH}"
echo "[verify] launching verifier Job ${JOB}"
helm template "${RELEASE}" ./chart -n "${NS}" -s templates/verifier-job.yaml \
  -f "${VALUES_FILE}" --set profile=cdc \
  --set verifier.run=true --set "verifier.jobName=${JOB}" --set "verifier.epoch=${EPOCH}" \
  | kubectl apply -n "${NS}" -f -

JOB_FULL="${RESOURCE_PREFIX}${JOB}"
deadline=$(( $(date +%s) + 240 ))
while (( $(date +%s) < deadline )); do
  st=$(kubectl -n "${NS}" get job/"${JOB_FULL}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
  fa=$(kubectl -n "${NS}" get job/"${JOB_FULL}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
  [[ "$st" == "True" || "$fa" == "True" ]] && break
  sleep 3
done

RESULT="$(kubectl -n "${NS}" logs job/"${JOB_FULL}" | sed -n 's/^RESULT_JSON://p' | tail -n1)"
if [[ -z "${RESULT}" ]]; then
  echo "[verify-cdc] FAIL — no RESULT_JSON from verifier Job"; exit 1
fi
echo "${RESULT}" | jq '{dedup_delta:.cdc.dedup_delta, ops_ok:.cdc.ops_ok, replay_ok:.cdc.replay_ok, verdict:.verdict}'
PASS=$(echo "${RESULT}" | jq -r '.verdict.pass')
if [[ "${PASS}" == "true" ]]; then
  echo "[verify-cdc] PASS — dedup + per-op + replay all green"; exit 0
fi
echo "[verify-cdc] FAIL — $(echo "${RESULT}" | jq -r '.verdict.reason')"; exit 1
```

- [ ] **Step 2: Make executable + shellcheck**

Run: `chmod +x $LAB/scripts/verify-cdc.sh && (command -v shellcheck >/dev/null && shellcheck $LAB/scripts/verify-cdc.sh || echo "skip shellcheck")`
Expected: no errors / `skip shellcheck`.

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/scripts/verify-cdc.sh
git commit -m "no-lww-simple-cdc: verify-cdc.sh — boot + run verifier Job + assert verdict

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 6.3: render.sh default profile + dashboard-forward defaults

**Files:**
- Modify: `$LAB/scripts/render.sh`, `$LAB/scripts/dashboard-forward.sh`

- [ ] **Step 1: render.sh — default profile lww→cdc**

In `render.sh`, change the default profile value from `lww` to `cdc` (the line that sets `PROFILE` default / the `--profile=lww` fallback).

- [ ] **Step 2: dashboard-forward.sh — default namespace/release**

In `dashboard-forward.sh`, change defaults `RRCS_NS:-lww-k8s` → `RRCS_NS:-cdc-k8s` and `RRCS_RELEASE:-lww` → `RRCS_RELEASE:-cdc`.

- [ ] **Step 3: shellcheck both**

Run: `command -v shellcheck >/dev/null && shellcheck $LAB/scripts/render.sh $LAB/scripts/dashboard-forward.sh || echo "skip shellcheck"`
Expected: no errors / skip.

- [ ] **Step 4: Commit**

```bash
git add labs/no-lww-simple-cdc/scripts/render.sh labs/no-lww-simple-cdc/scripts/dashboard-forward.sh
git commit -m "no-lww-simple-cdc: scripts default to cdc profile/namespace

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 6.4: gen-report.sh (HTML report)

**Files:**
- Replace: `$LAB/scripts/gen-report.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# gen-report.sh — run verify-cdc.sh, capture its RESULT_JSON, scrape live key/op
# counts, and render a self-contained HTML report to reports/cdc-report.html.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-k8s}"
RELEASE="${RRCS_RELEASE:-cdc}"
OUT="${OUT:-reports/cdc-report.html}"
VERIFY_CMD="${VERIFY_CMD:-${SCRIPT_DIR}/verify-cdc.sh}"
mkdir -p "$(dirname "${OUT}")"

echo "[report] running verify-cdc.sh…" >&2
out="$(RRCS_NS="${NS}" RRCS_RELEASE="${RELEASE}" "${VERIFY_CMD}" 2>&1 || true)"
json="$(printf '%s\n' "${out}" | sed -n 's/^RESULT_JSON://p' | tail -n1 || true)"
if [[ -z "${json}" ]]; then
  # verify-cdc prints RESULT via jq, not raw; fall back to re-reading the job log line
  json="$(printf '%s\n' "${out}" | grep -o '{.*"verdict".*}' | tail -n1 || true)"
fi
[[ -z "${json}" ]] && json='{"cdc":{},"verdict":{"pass":false,"reason":"no RESULT_JSON captured"}}'

read -r dd oo rr pass reason <<<"$(printf '%s' "${json}" | jq -r '[.cdc.dedup_delta, .cdc.ops_ok, .cdc.replay_ok, .verdict.pass, (.verdict.reason//"")] | @tsv')"
banner=$([[ "${pass}" == "true" ]] && echo PASS || echo FAIL)
cls=$([[ "${pass}" == "true" ]] && echo ok || echo bad)

cat > "${OUT}" <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>no-lww-simple-cdc report</title>
<style>body{font-family:system-ui,sans-serif;margin:24px;background:#0e1117;color:#e6e6e6}
h1{font-size:18px}.b{display:inline-block;padding:4px 12px;border-radius:6px;font-weight:700}
.ok{background:#1a3d1a;color:#7ee787}.bad{background:#3d1a1a;color:#f85149}
table{border-collapse:collapse;margin-top:14px}td,th{border:1px solid #2a2f3a;padding:6px 12px;text-align:left}
th{background:#161b22}</style></head><body>
<h1>no-lww-simple-cdc — validation report</h1>
<p>Verdict: <span class="b ${cls}">${banner}</span> ${reason}</p>
<table>
<tr><th>check</th><th>result</th></tr>
<tr><td>dedup (same event_id ×5 → stream +1)</td><td>delta=${dd} (want 1)</td></tr>
<tr><td>per-op end-to-end (create/update/rename/delete under quiescence)</td><td>ops_ok=${oo}</td></tr>
<tr><td>idempotent replay (rename re-delivery)</td><td>replay_ok=${rr}</td></tr>
</table>
<p style="color:#8b95a3;font-size:12px;margin-top:18px">Generated by scripts/gen-report.sh.
This lab accepts stale overwrite / delete-resurrection; those are observed live in the
dashboard (central-vs-region divergence), not asserted here.</p>
</body></html>
EOF
echo "[report] wrote ${OUT}"
[[ "${pass}" == "true" ]] || exit 1
```

- [ ] **Step 2: shellcheck**

Run: `command -v shellcheck >/dev/null && shellcheck $LAB/scripts/gen-report.sh || echo "skip shellcheck"`
Expected: no errors / skip.

- [ ] **Step 3: Commit**

```bash
git add labs/no-lww-simple-cdc/scripts/gen-report.sh
git commit -m "no-lww-simple-cdc: gen-report.sh — HTML report of the 3 checks

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> `build-images.sh` and `scripts/lib/run-defaults.sh` are forked unchanged — image names (`redis-rrcs/{writer,verifier,dashboard}`) match `values.yaml` and need no edit. `gen-nats-auth.sh` is forked unchanged (it parses `subjectPrefix`/`name`/`consumer.durable` from values; Task 3.7 already re-ran it).

---

## Phase 7 — Docs

### Task 7.1: RESEARCH.md

**Files:**
- Create: `$LAB/RESEARCH.md`

- [ ] **Step 1: Write the file**

````markdown
# no-lww-simple-cdc — RESEARCH

## Property demonstrated

The no-LWW simplified CDC pipeline propagates `create` / `update` / `delete` /
`rename` end-to-end —
`writer → redis-central(Streams) → connect-source → NATS JetStream →
connect-sink → redis-region(KV)` — with at-least-once delivery, JetStream
`Nats-Msg-Id` dedup, and idempotent replay, while showing central- and region-KV
key changes live in a dashboard and an HTML run report.

There is **no version fence**: same-key reordered or late arrivals overwrite
newer values (stale overwrite), and a late `create`/`update` can resurrect a
deleted key. These are accepted and observed (central-vs-region divergence),
never failures.

## Why this is the right question

This is a fork of `../redis-connect-lww-multi-k8s`, which proves an LWW
compare-and-set fence survives inter-pod concurrency. This lab takes the opposite
design point: with the fence removed, the only correctness levers are op-level
idempotency (`SET`/`DEL`/`DEL+SET`) and JetStream `Nats-Msg-Id` dedup. The single
observable concern is four-op CDC propagation under at-least-once — not
throughput, not correctness-under-reorder (there is no such claim; that is the
point).

## Essentials (what is load-bearing)

- **Writer dual-writes**: each op is applied to the central KV (authoritative
  intent) and emitted as a CDC envelope to `app.events`. Region KV is the mirror.
- **Single source + sink** (one pod each). No queue deliver-group, no per-pod
  metric summing.
- **Subject namespace is one knob**: `nats.stream.subjectPrefix` (default
  `kv.cdc`) drives the stream subjects, source publish subject (`<prefix>.<op>`),
  sink consumer filter, and the publisher/subscriber JWT grants.
- **Sink switch on `op`**: create/update → `SET`; delete → `DEL`; rename →
  `EVAL cdc_rename.lua` (`DEL old + SET new`, replay-safe); unknown → throw →
  nack. `reject_errored: drop` acks on success, nacks on failure (redelivery
  absorbed by idempotency).

## Wire contract

XADD `app.events` fields (all but `body` become Connect metadata; `body_key=body`):
`event_id` (UUID, dedup key), `op`, `kv_key` | `old_key`+`new_key`, `ts`, `body`.
Source republishes to `kv.cdc.<op>` with header `Nats-Msg-Id: <event_id>`.

## Validation strategy (order-insensitive PASS bar)

`scripts/verify-cdc.sh` runs the Go verifier Job, which proves three
order-independent properties (the design is order-insensitive, so it asserts no
ordered state sequence):

1. **Dedup** — same `event_id` ×5 → JetStream stream `Messages` grows by exactly 1.
2. **Per-op under quiescence** — create→update→rename→delete, one at a time, each
   asserted only after the pipeline quiesces (source group lag 0 + sink pending
   0). No concurrency in flight → each op's effect is deterministic.
3. **Idempotent replay** — a rename re-delivered leaves the region terminal state
   unchanged.

The research-lab skill's `validate_lab.sh` (docker-compose) does not apply — this
is a Kubernetes lab; `verify-cdc.sh` exit 0 is the validation.

## Design decisions / rejected alternatives

- **Central KV first-class (dual write)** over stream-only: lab-requirements
  mandates "a server periodically updates KV in central Redis"; the central KV is
  the intent of record the dashboard compares region against.
- **Explicit XADD envelope** over keyspace notifications: durable, replayable,
  carries `op`/`event_id`.
- **`durable` consumer** (single sink) over the parent's queue deliver-group:
  no multi-pod sharing needed.
- **Lua `DEL+SET` rename** over native `RENAME`: replay-idempotent.

## Deliberately excluded

- Any correctness-under-reorder guarantee (stale overwrite / delete-resurrection
  accepted and observed).
- LWW fence, CAS, version counters (the parent's concern).
- Cross-slot rename (patterns are hash-tagged → single slot).
- PEL-reclaim supervisor, DLQ tooling, autoscaling, chaos.

## Validated result

> Pending first validated kind run (Phase 8 fills this in verbatim from the
> verifier `RESULT_JSON` — no numbers are asserted here before that run).

## Further reading

- `no-lww-simple-cdc/research-design.md` — upstream wire/pipeline design.
- `no-lww-simple-cdc/lab-requirements.md` — functional requirements.
- `../redis-connect-lww-multi-k8s/` — the parent (LWW) lab.
````

- [ ] **Step 2: Commit**

```bash
git add labs/no-lww-simple-cdc/RESEARCH.md
git commit -m "no-lww-simple-cdc: RESEARCH.md

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 7.2: README.md

**Files:**
- Create: `$LAB/README.md`

- [ ] **Step 1: Write the file**

````markdown
# no-lww-simple-cdc

## What this demonstrates

A fence-free CDC relay: a writer dual-writes each `create`/`update`/`delete`/
`rename` to **central** Redis KV and emits a CDC envelope to a Redis Stream;
**one** Redpanda Connect source publishes to NATS JetStream (with `Nats-Msg-Id`
dedup); **one** Connect sink switches on `op` and applies `SET`/`DEL`/rename-Lua
to **region** Redis KV — with **no last-write-wins fence**. Stale overwrites and
delete-resurrection are accepted and shown live as central-vs-region divergence.

Kubernetes/Helm fork of `../redis-connect-lww-multi-k8s` with the LWW fence
removed and the topology reduced to single-source/single-sink.

## Run it (kind)

```bash
kind create cluster --name cdc
scripts/build-images.sh --kind --kind-name=cdc        # build writer/verifier/dashboard, load into kind
# NATS auth fixtures are committed; regenerate only on a fresh checkout if missing:
#   scripts/gen-nats-auth.sh --force
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh
```

`verify-cdc.sh` boots the chart (`profile=cdc`), runs the verifier Job, and exits
0 only when all three checks pass (dedup, per-op-under-quiescence, idempotent
replay).

## Drive it by hand

`scripts/insert-msgs.sh` **prints** ready-to-run `redis-cli XADD` commands (one
per op + a 5× dedup test) — copy and run them yourself; the script never executes
them:

```bash
scripts/insert-msgs.sh
```

## Watch central vs region live

```bash
scripts/dashboard-forward.sh        # binds 0.0.0.0; open http://<host>:8080
```

The dashboard shows central key count, region key count, and divergence
(only-central / only-region / differing), per-op sink applies, and a live region
key-change feed.

## HTML report

```bash
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/gen-report.sh   # writes reports/cdc-report.html
```

## Validation note

This is a Kubernetes lab, so the research-lab skill's `validate_lab.sh`
(docker-compose) does not apply. `scripts/verify-cdc.sh` is the validation: exit
0 requires dedup + per-op + replay all green.

## Expected output

`verify-cdc.sh` prints a `RESULT_JSON` line; its `.cdc` object carries
`dedup_delta`, `ops_ok`, `replay_ok`, and `.verdict`. Actual numbers come from
your run — see `RESEARCH.md` → Validated result once the lab has been run on kind.

## Teardown

```bash
helm uninstall cdc -n cdc-k8s
kind delete cluster --name cdc
```

## Further reading

- `RESEARCH.md` — the property, wire contract, and order-insensitive PASS bar.
- `../redis-connect-lww-multi-k8s/` — the parent (LWW) lab.
````

- [ ] **Step 2: Commit**

```bash
git add labs/no-lww-simple-cdc/README.md
git commit -m "no-lww-simple-cdc: README.md

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 8 — Validate on kind

This phase requires Docker, `kind`, `kubectl`, `helm`, `jq`, and `nsc` on the host. It is the definitive end-to-end gate.

### Task 8.1: Build images and create the cluster

- [ ] **Step 1: Ensure NATS auth fixtures exist (Task 3.7 created them)**

Run: `ls $LAB/chart/files/nats-auth/publisher.creds $LAB/chart/files/nats-auth/subscriber.creds`
Expected: both exist. If missing: `cd $LAB && scripts/gen-nats-auth.sh --force`.

- [ ] **Step 2: Create kind cluster + build/load images**

```bash
kind create cluster --name cdc
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/no-lww-simple-cdc
scripts/build-images.sh --kind --kind-name=cdc
```
Expected: three images built and `kind load`ed (`redis-rrcs/writer:dev`, `…/verifier:dev`, `…/dashboard:dev`).

### Task 8.2: Run the validation

- [ ] **Step 1: verify-cdc.sh must exit 0**

Run: `cd $LAB && RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh; echo "EXIT=$?"`
Expected: prints the `RESULT_JSON` summary with `verdict.pass=true` and `EXIT=0`.

- [ ] **Step 2: If it fails, diagnose (do NOT mask)**

Common roots and checks:
```bash
kubectl -n cdc-k8s get pods                      # all Running/Complete?
kubectl -n cdc-k8s logs deploy/lab-connect-sink  # sink op-switch / redis errors?
kubectl -n cdc-k8s logs deploy/lab-connect-source
kubectl -n cdc-k8s logs job/lab-verifier-<epoch> # which check failed + reason
# sink 0/1 with a NATS auth error => JWT grants stale: re-run scripts/gen-nats-auth.sh --force,
#   commit, helm upgrade. (subjectPrefix/stream/durable must match the JWT.)
```
After fixing the root cause, re-run Step 1. After 3 failed attempts on the same root cause, invoke `superpowers:systematic-debugging`.

### Task 8.3: Smoke the dashboard + report, then record the validated result

- [ ] **Step 1: Drive a little load and check divergence renders**

```bash
kubectl -n cdc-k8s exec deploy/lab-writer -- sh -c 'wget -qO- --post-data="{\"epoch\":\"smoke\"}" --header=Content-Type:application/json http://localhost:8081/reset'
kubectl -n cdc-k8s exec deploy/lab-writer -- sh -c 'wget -qO- --post-data="{\"rate\":500}" --header=Content-Type:application/json http://localhost:8081/rate'
sleep 10
kubectl -n cdc-k8s exec deploy/lab-writer -- sh -c 'wget -qO- --post-data="{\"rate\":0}" --header=Content-Type:application/json http://localhost:8081/rate'
# Optional live view:
scripts/dashboard-forward.sh &   # open http://<host>:8080, confirm central/region counts + op applies move
```
Expected: dashboard shows non-zero central/region key counts and per-op sink applies.

- [ ] **Step 2: Generate the HTML report**

Run: `cd $LAB && RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/gen-report.sh && ls -l reports/cdc-report.html`
Expected: report written; verdict PASS.

- [ ] **Step 3: Fill RESEARCH.md "Validated result" from the real RESULT_JSON**

Replace the "Pending first validated kind run" block in `$LAB/RESEARCH.md` with the verbatim `RESULT_JSON` `.cdc` object and verdict from the passing run, plus one line naming the cluster (`kind cdc`, namespace `cdc-k8s`). Commit:

```bash
git add labs/no-lww-simple-cdc/RESEARCH.md
git commit -m "no-lww-simple-cdc: record validated kind run result

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Teardown**

```bash
helm uninstall cdc -n cdc-k8s
kind delete cluster --name cdc
```

- [ ] **Step 5: Confirm no debug artifacts left**

Run: `cd /media/hp/secondary/projects/gam-redis-pubsub && git status labs/no-lww-simple-cdc`
Expected: clean (the only tracked change is the committed RESEARCH.md result; `reports/` is gitignored by the forked `.gitignore` — confirm, and add `reports/` to `$LAB/.gitignore` if not present).

---

## Self-Review (completed by plan author)

**Spec coverage** — every spec section maps to a task:
- Topology (single src/sink, dual-write) → Tasks 1.4, 1.6, 2.1, 2.3, 3.1, 3.2.
- Writer 4-op + 3 patterns + multi-writer → Tasks 1.1–1.6.
- Source/sink configs + dedup + rename Lua → Tasks 2.1–2.3.
- Configurable subject prefix → Tasks 2.4, 3.1, 3.7, 3.8 (render assertion).
- NATS JetStream stream/consumer → Tasks 3.1, 3.7.
- redis-central (KV+stream) & redis-region (KV) → forked templates + Task 3.1; central KV written by writer (1.4).
- Verifier 3-check order-insensitive PASS bar → Tasks 4.1–4.5.
- Dashboard central-vs-region divergence → Tasks 5.1–5.3.
- HTML report → Task 6.4.
- Scripts (build, manual-insert command-former, verify, report) → Phase 6.
- Helm portability / NOTES → Tasks 3.1–3.6.
- RESEARCH.md / README.md → Phase 7.
- Validation on kind → Phase 8.

**Placeholder scan** — no "TBD/TODO/handle errors" left; RESEARCH.md "Validated result: pending" is an intentional doc-process step filled by Task 8.3, not a code placeholder.

**Type consistency** — verified across tasks: writer `Event.StreamValues()` field order matches the source config metadata reads (`op`/`kv_key`/`old_key`/`new_key`/`ts`/`body`); verifier `eventValues` uses the same field set; sink metric `cdc_apply{op}` matches dashboard `scrapeApply` parsing and report copy; writer `/metrics` `cdc_writer_ops_total{op}` matches the http test; `RESULT_JSON` `.cdc`/`.verdict` shape matches `verify-cdc.sh` and `gen-report.sh` jq paths; `nats.stream.consumer.durable` (`cdc_sink`) matches the sink config `durable`, the verifier `--nats-consumer`, and `gen-nats-auth.sh` `DURABLE_NAME`.

**Incremental-build correctness:** the writer (Task 1.0) and verifier (Task 0.2) each clear the parent files they replace and keep only the stable leaf files (`limiter.go`; `nats.go`+`httpclient.go`), so every intermediate `go test` compiles and runs. The binary link (`go build ./...`) is gated on the wiring task (1.6 / 4.5). Verified the shared `httpClient` (parent: `scrapers.go`, deleted) is re-homed in `verifier/httpclient.go` so the kept `nats.go` keeps compiling.



