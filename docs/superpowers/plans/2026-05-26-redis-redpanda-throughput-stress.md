# redis-redpanda-throughput-stress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork `labs/redis-redpanda-connect-stress/` into a new throughput-focused lab at `labs/redis-redpanda-throughput-stress/` that exercises 5k–50k msg/s with two writer modes (pipelined batch vs single-XADD), 60k+ hashtag-wrapped keys across three patterns (employee/role/org), and reports per-message sync latency from `t_send_ms` (writer) to `applied_ms` (Connect-sink).

**Architecture:** Copy parent lab, then surgically modify: strip non-ALO Connect YAMLs and chaos artifacts; rename project / containers / ports to 18xxx range; rebuild writer with key-generator + pattern-picker + mode toggle wired into `POST /rate`; redefine collector's latency metric from receiver wall-clock to `applied_ms − t_send_ms` from stream fields; rework harness matrix to `tiers × modes`. Verdict ships with p99 ceiling = `null` (calibration mode) — only rate floor and `missing==0` are gated until first calibration run fills the table.

**Tech Stack:** Go 1.25 (writer) / Go 1.24 (collector); `go-redis/v9`; HDR Histogram; Redpanda Connect 4.92.0; NATS JetStream 2.10; Redis 7.4; Bash; Docker Compose.

**Spec:** `docs/superpowers/specs/2026-05-26-redis-redpanda-throughput-stress-design.md`.

---

## Conventions

- All paths below the lab are written relative to `labs/redis-redpanda-throughput-stress/`.
- Every task ends with a commit. Commit messages follow the parent lab's style: `redis-redpanda-throughput-stress: <terse imperative>`.
- "Run from lab dir" means `cd labs/redis-redpanda-throughput-stress` first.
- Go tests run with `cd <package> && go test ./...` from inside the writer or collector directory.
- Compose project name is `redis-redpanda-throughput-stress`; container prefix is `rrts-`; bridge network is `rrts-net`.
- Host ports use the 18xxx range exclusively.

---

## Phase A — Fork & strip

### Task 1: Copy parent lab as baseline; rename project / containers / network

**Files:**
- Create: `labs/redis-redpanda-throughput-stress/` (full copy of parent)
- Modify: `labs/redis-redpanda-throughput-stress/docker-compose.yml`

- [ ] **Step 1: Copy the parent lab tree**

```bash
cp -r labs/redis-redpanda-connect-stress labs/redis-redpanda-throughput-stress
rm -rf labs/redis-redpanda-throughput-stress/reports/*
rm -f  labs/redis-redpanda-throughput-stress/writer/writer  # any stray built binary
```

- [ ] **Step 2: Rename Compose project, container prefix, and network in `docker-compose.yml`**

Replace at the top of `labs/redis-redpanda-throughput-stress/docker-compose.yml`:

- `name: redis-redpanda-connect-stress` → `name: redis-redpanda-throughput-stress`
- Every `container_name: rrcs-<x>` → `container_name: rrts-<x>` (10 occurrences: `rrts-redis-central`, `rrts-redis-region`, `rrts-nats`, `rrts-nats-init`, `rrts-connect-source`, `rrts-connect-sink`, `rrts-writer`, `rrts-collector`)
- The two `networks: [rrcs]` references → `networks: [rrts]`
- The bottom `networks:\n  rrcs:\n    name: rrcs-net` → `networks:\n  rrts:\n    name: rrts-net`

- [ ] **Step 3: Verify compose still parses**

Run from lab dir: `docker compose config -q`
Expected: exit 0, no output.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/
git commit -m "redis-redpanda-throughput-stress: fork from connect-stress; rename project/containers/network

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Rebase host ports to 18xxx

**Files:**
- Modify: `labs/redis-redpanda-throughput-stress/docker-compose.yml`
- Modify: `labs/redis-redpanda-throughput-stress/.env.example`

- [ ] **Step 1: Update `docker-compose.yml` default ports**

Inside `docker-compose.yml`, change every `:-17xxx` to `:-18xxx`:

| Variable                | Old default | New default |
|-------------------------|-------------|-------------|
| `REDIS_CENTRAL_PORT`    | `17379`     | `18379`     |
| `REDIS_REGION_PORT`     | `17380`     | `18380`     |
| `NATS_CLIENT_PORT`      | `17222`     | `18222`     |
| `NATS_MON_PORT`         | `17322`     | `18322`     |
| `CONNECT_SRC_PORT`      | `17195`     | `18195`     |
| `CONNECT_SINK_PORT`     | `17196`     | `18196`     |
| `WRITER_PORT`           | `17081`     | `18081`     |

- [ ] **Step 2: Update `.env.example`**

Replace each `=17xxx` line with the matching `=18xxx` value from the table above.

- [ ] **Step 3: Verify**

Run from lab dir: `docker compose config | grep -E '^\s+- "1[78][0-9]+'`
Expected: every published port begins with `183` (redis), `182` (nats client), `1822` (writer was 18081 — also shown), `1819` (connect), `1808` (writer); zero `17xxx` lines.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/docker-compose.yml labs/redis-redpanda-throughput-stress/.env.example
git commit -m "redis-redpanda-throughput-stress: rebase host ports 17xxx -> 18xxx

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Strip non-ALO Connect YAMLs; rename ALO to default

**Files:**
- Delete: `connect/amo-forward.yaml`, `connect/amo-reverse.yaml`, `connect/eoe-forward.yaml`, `connect/eoe-reverse.yaml`
- Rename: `connect/alo-forward.yaml` → `connect/forward.yaml`
- Rename: `connect/alo-reverse.yaml` → `connect/reverse.yaml`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Delete non-ALO YAMLs and rename ALO**

```bash
cd labs/redis-redpanda-throughput-stress
git rm connect/amo-forward.yaml connect/amo-reverse.yaml connect/eoe-forward.yaml connect/eoe-reverse.yaml
git mv connect/alo-forward.yaml connect/forward.yaml
git mv connect/alo-reverse.yaml connect/reverse.yaml
```

- [ ] **Step 2: Drop `${PROFILE_QOS}` interpolation in `docker-compose.yml`**

In `connect-source` service, change:

```yaml
    volumes:
      - ./connect/${PROFILE_QOS:-alo}-forward.yaml:/connect.yaml:ro
```

to:

```yaml
    volumes:
      - ./connect/forward.yaml:/connect.yaml:ro
```

In `connect-sink` service, change:

```yaml
    volumes:
      - ./connect/${PROFILE_QOS:-alo}-reverse.yaml:/connect.yaml:ro
```

to:

```yaml
    volumes:
      - ./connect/reverse.yaml:/connect.yaml:ro
```

- [ ] **Step 3: Verify compose parses and the new mount paths resolve**

Run from lab dir:

```bash
docker compose config -q
docker compose config | grep -E '/connect/(forward|reverse)\.yaml'
```

Expected: two `/connect/forward.yaml` and two `/connect/reverse.yaml` lines (source path + container target each).

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/
git commit -m "redis-redpanda-throughput-stress: strip non-ALO YAMLs; rename alo-* to default

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Strip chaos artifacts

**Files:**
- Delete: `scripts/chaos/kill-connect-sink.sh` (and the `scripts/chaos/` directory if empty)
- Modify: `scripts/stress-run.sh` (chaos branch removal happens fully in Task 16; here only delete the script file)

- [ ] **Step 1: Delete chaos kill script**

```bash
cd labs/redis-redpanda-throughput-stress
git rm scripts/chaos/kill-connect-sink.sh
rmdir scripts/chaos 2>/dev/null || true
```

- [ ] **Step 2: Verify**

```bash
test ! -d scripts/chaos && echo "ok: chaos dir gone"
```

Expected: `ok: chaos dir gone`.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/
git commit -m "redis-redpanda-throughput-stress: drop chaos kill script

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase B — Writer rebuild (TDD)

### Task 5: Writer — KeyGen package (3 hashtag-wrapped patterns)

**Files:**
- Create: `writer/key_gen.go`
- Create: `writer/key_gen_test.go`

- [ ] **Step 1: Write the failing test**

Create `writer/key_gen_test.go`:

```go
package main

import (
	"strings"
	"testing"
)

func TestKeyGen_EmployeeShape(t *testing.T) {
	g := NewKeyGen(KeyGenConfig{Cardinality: 20000, Seed: 42})
	got := g.Employee(7)
	want := "lb:company:active:{employee:7}"
	if got != want {
		t.Fatalf("Employee(7) = %q, want %q", got, want)
	}
}

func TestKeyGen_OrgShape(t *testing.T) {
	g := NewKeyGen(KeyGenConfig{Cardinality: 20000, Seed: 42})
	got := g.Org(123)
	want := "lb:functions:active:{org:123}"
	if got != want {
		t.Fatalf("Org(123) = %q, want %q", got, want)
	}
}

func TestKeyGen_RoleShape(t *testing.T) {
	g := NewKeyGen(KeyGenConfig{Cardinality: 20000, Seed: 42})
	got := g.Role(0)
	if !strings.HasPrefix(got, "lb:functions:active:{role:") || !strings.HasSuffix(got, "}") {
		t.Fatalf("Role(0) = %q, want prefix lb:functions:active:{role: and suffix }", got)
	}
	hex := strings.TrimSuffix(strings.TrimPrefix(got, "lb:functions:active:{role:"), "}")
	if len(hex) != 40 {
		t.Fatalf("Role(0) hex length = %d, want 40 (SHA-1)", len(hex))
	}
}

func TestKeyGen_RoleDeterministicPerSeed(t *testing.T) {
	a := NewKeyGen(KeyGenConfig{Cardinality: 100, Seed: 42}).Role(5)
	b := NewKeyGen(KeyGenConfig{Cardinality: 100, Seed: 42}).Role(5)
	if a != b {
		t.Fatalf("Role(5) not deterministic for same seed: %q vs %q", a, b)
	}
}

func TestKeyGen_RoleDifferentSeeds(t *testing.T) {
	a := NewKeyGen(KeyGenConfig{Cardinality: 100, Seed: 1}).Role(5)
	b := NewKeyGen(KeyGenConfig{Cardinality: 100, Seed: 2}).Role(5)
	if a == b {
		t.Fatalf("Role(5) coincidentally equal across seeds: %q", a)
	}
}

func TestKeyGen_AllRolesUnique(t *testing.T) {
	const n = 20000
	g := NewKeyGen(KeyGenConfig{Cardinality: n, Seed: 42})
	seen := make(map[string]struct{}, n)
	for i := 0; i < n; i++ {
		k := g.Role(i)
		if _, dup := seen[k]; dup {
			t.Fatalf("Role(%d) duplicate: %q", i, k)
		}
		seen[k] = struct{}{}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go test -run TestKeyGen ./...
```

Expected: FAIL with `undefined: NewKeyGen` or similar.

- [ ] **Step 3: Write minimal implementation**

Create `writer/key_gen.go`:

```go
package main

import (
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/rand"
)

type KeyGenConfig struct {
	Cardinality int
	Seed        int64
}

type KeyGen struct {
	cardinality int
	rolePool    []string
}

func NewKeyGen(cfg KeyGenConfig) *KeyGen {
	g := &KeyGen{cardinality: cfg.Cardinality}
	g.rolePool = make([]string, cfg.Cardinality)
	r := rand.New(rand.NewSource(cfg.Seed))
	var buf [8]byte
	h := sha1.New()
	for i := 0; i < cfg.Cardinality; i++ {
		binary.LittleEndian.PutUint64(buf[:], r.Uint64())
		h.Reset()
		h.Write(buf[:])
		g.rolePool[i] = hex.EncodeToString(h.Sum(nil))
	}
	return g
}

func (g *KeyGen) Employee(id int) string {
	return fmt.Sprintf("lb:company:active:{employee:%d}", id)
}

func (g *KeyGen) Org(id int) string {
	return fmt.Sprintf("lb:functions:active:{org:%d}", id)
}

func (g *KeyGen) Role(idx int) string {
	return fmt.Sprintf("lb:functions:active:{role:%s}", g.rolePool[idx%g.cardinality])
}

func (g *KeyGen) Cardinality() int { return g.cardinality }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go test -run TestKeyGen ./...
```

Expected: PASS (`ok writer`).

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/writer/key_gen.go labs/redis-redpanda-throughput-stress/writer/key_gen_test.go
git commit -m "redis-redpanda-throughput-stress: writer key_gen with 3 hashtag patterns

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Writer — Weighted pattern picker

**Files:**
- Create: `writer/picker.go`
- Create: `writer/picker_test.go`

- [ ] **Step 1: Write the failing test**

Create `writer/picker_test.go`:

```go
package main

import (
	"math/rand"
	"testing"
)

func TestPicker_ParseWeights(t *testing.T) {
	got, err := ParsePatternWeights("40,30,30")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []int{40, 30, 30}
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("ParsePatternWeights = %v, want %v", got, want)
	}
}

func TestPicker_ParseWeightsRejectsBadInput(t *testing.T) {
	if _, err := ParsePatternWeights("1,2"); err == nil {
		t.Fatal("expected error for 2-element weights")
	}
	if _, err := ParsePatternWeights("0,0,0"); err == nil {
		t.Fatal("expected error for all-zero weights")
	}
	if _, err := ParsePatternWeights("a,b,c"); err == nil {
		t.Fatal("expected error for non-numeric weights")
	}
}

func TestPicker_Distribution(t *testing.T) {
	p, err := NewPicker([]int{50, 25, 25})
	if err != nil {
		t.Fatalf("NewPicker: %v", err)
	}
	r := rand.New(rand.NewSource(1))
	counts := [3]int{}
	const n = 100_000
	for i := 0; i < n; i++ {
		counts[p.Pick(r)]++
	}
	// Allow 2% tolerance per bucket.
	check := func(name string, got, target int) {
		diff := got - target
		if diff < -2000 || diff > 2000 {
			t.Errorf("%s bucket = %d, want ~%d (±2000)", name, got, target)
		}
	}
	check("employee", counts[0], n/2)
	check("role", counts[1], n/4)
	check("org", counts[2], n/4)
}

func TestPicker_DefaultsEvenSplit(t *testing.T) {
	p, err := NewPicker([]int{33, 33, 34})
	if err != nil {
		t.Fatalf("NewPicker: %v", err)
	}
	r := rand.New(rand.NewSource(7))
	counts := [3]int{}
	const n = 99_000
	for i := 0; i < n; i++ {
		counts[p.Pick(r)]++
	}
	for i, c := range counts {
		if c < 31000 || c > 35000 {
			t.Errorf("bucket %d = %d, want ~33000", i, c)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go test -run TestPicker ./...
```

Expected: FAIL with `undefined: ParsePatternWeights` (and friends).

- [ ] **Step 3: Write minimal implementation**

Create `writer/picker.go`:

```go
package main

import (
	"fmt"
	"math/rand"
	"strconv"
	"strings"
)

const (
	PatternEmployee = 0
	PatternRole     = 1
	PatternOrg      = 2
)

type Picker struct {
	total int
	cum   [3]int
}

func ParsePatternWeights(s string) ([]int, error) {
	parts := strings.Split(s, ",")
	if len(parts) != 3 {
		return nil, fmt.Errorf("PATTERN_WEIGHTS must have 3 comma-separated values, got %d", len(parts))
	}
	w := make([]int, 3)
	sum := 0
	for i, p := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil {
			return nil, fmt.Errorf("PATTERN_WEIGHTS[%d] not a number: %q", i, p)
		}
		if n < 0 {
			return nil, fmt.Errorf("PATTERN_WEIGHTS[%d] negative: %d", i, n)
		}
		w[i] = n
		sum += n
	}
	if sum == 0 {
		return nil, fmt.Errorf("PATTERN_WEIGHTS all zero")
	}
	return w, nil
}

func NewPicker(weights []int) (*Picker, error) {
	if len(weights) != 3 {
		return nil, fmt.Errorf("NewPicker: need 3 weights, got %d", len(weights))
	}
	p := &Picker{}
	for i := 0; i < 3; i++ {
		p.total += weights[i]
		p.cum[i] = p.total
	}
	if p.total == 0 {
		return nil, fmt.Errorf("NewPicker: total weight is 0")
	}
	return p, nil
}

func (p *Picker) Pick(r *rand.Rand) int {
	n := r.Intn(p.total)
	switch {
	case n < p.cum[0]:
		return PatternEmployee
	case n < p.cum[1]:
		return PatternRole
	default:
		return PatternOrg
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go test -run TestPicker ./...
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/writer/picker.go labs/redis-redpanda-throughput-stress/writer/picker_test.go
git commit -m "redis-redpanda-throughput-stress: writer pattern-weighted picker

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Writer — Atomic write-mode store

**Files:**
- Create: `writer/mode.go`
- Create: `writer/mode_test.go`

- [ ] **Step 1: Write the failing test**

Create `writer/mode_test.go`:

```go
package main

import (
	"sync"
	"testing"
)

func TestModeStore_DefaultBatch(t *testing.T) {
	m := NewModeStore("batch")
	if m.Get() != ModeBatch {
		t.Fatalf("default Get() = %v, want ModeBatch", m.Get())
	}
}

func TestModeStore_SetGet(t *testing.T) {
	m := NewModeStore("batch")
	if err := m.SetByName("single"); err != nil {
		t.Fatalf("SetByName(single): %v", err)
	}
	if m.Get() != ModeSingle {
		t.Fatalf("after SetByName(single), Get() = %v, want ModeSingle", m.Get())
	}
}

func TestModeStore_RejectInvalid(t *testing.T) {
	m := NewModeStore("batch")
	if err := m.SetByName("yolo"); err == nil {
		t.Fatal("SetByName(yolo) should error")
	}
}

func TestModeStore_ConcurrentReadWriteRaceClean(t *testing.T) {
	m := NewModeStore("batch")
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				if i%2 == 0 {
					_ = m.Get()
				} else {
					name := "batch"
					if j%2 == 0 {
						name = "single"
					}
					_ = m.SetByName(name)
				}
			}
		}(i)
	}
	wg.Wait()
}

func TestModeStore_NameRoundTrip(t *testing.T) {
	m := NewModeStore("single")
	if m.Name() != "single" {
		t.Fatalf("Name() = %q, want single", m.Name())
	}
	_ = m.SetByName("batch")
	if m.Name() != "batch" {
		t.Fatalf("after SetByName(batch), Name() = %q, want batch", m.Name())
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go test -run TestModeStore ./...
```

Expected: FAIL (`undefined: NewModeStore`).

- [ ] **Step 3: Write minimal implementation**

Create `writer/mode.go`:

```go
package main

import (
	"fmt"
	"sync/atomic"
)

type Mode int32

const (
	ModeBatch Mode = iota
	ModeSingle
)

type ModeStore struct {
	v atomic.Int32
}

func NewModeStore(initial string) *ModeStore {
	m := &ModeStore{}
	if initial == "single" {
		m.v.Store(int32(ModeSingle))
	} else {
		m.v.Store(int32(ModeBatch))
	}
	return m
}

func (m *ModeStore) Get() Mode { return Mode(m.v.Load()) }

func (m *ModeStore) Name() string {
	if m.Get() == ModeSingle {
		return "single"
	}
	return "batch"
}

func (m *ModeStore) SetByName(name string) error {
	switch name {
	case "batch":
		m.v.Store(int32(ModeBatch))
	case "single":
		m.v.Store(int32(ModeSingle))
	default:
		return fmt.Errorf("invalid mode %q: want batch|single", name)
	}
	return nil
}
```

- [ ] **Step 4: Run test under -race to verify atomicity**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go test -race -run TestModeStore ./...
```

Expected: PASS, no DATA RACE warnings.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/writer/mode.go labs/redis-redpanda-throughput-stress/writer/mode_test.go
git commit -m "redis-redpanda-throughput-stress: writer atomic mode store

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Writer — Per-pattern counters

**Files:**
- Modify: `writer/counters.go`

- [ ] **Step 1: Replace the file**

Overwrite `writer/counters.go`:

```go
package main

import "sync/atomic"

type Counters struct {
	Sent          atomic.Int64
	Errors        atomic.Int64
	Inflight      atomic.Int64
	SentByPattern [3]atomic.Int64 // indexed by PatternEmployee/PatternRole/PatternOrg
}

func (c *Counters) Reset() {
	c.Sent.Store(0)
	c.Errors.Store(0)
	c.Inflight.Store(0)
	for i := range c.SentByPattern {
		c.SentByPattern[i].Store(0)
	}
}
```

- [ ] **Step 2: Verify writer still compiles (worker.go still references old API; that's fixed in Task 10)**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go build ./... 2>&1 | head -20
```

Expected: build succeeds (the additions are additive; nothing else references `SentByPattern` yet).

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/writer/counters.go
git commit -m "redis-redpanda-throughput-stress: writer per-pattern counters

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Writer — Extend POST /rate to accept mode (TDD via httptest)

**Files:**
- Modify: `writer/http.go`
- Create: `writer/http_test.go`

- [ ] **Step 1: Write the failing test**

Create `writer/http_test.go`:

```go
package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestServer() (*Server, *ModeStore) {
	mode := NewModeStore("batch")
	return &Server{
		Lim:         NewLimiter(),
		Counters:    &Counters{},
		Mode:        mode,
		MaxRate:     60000,
		HealthCheck: func() bool { return true },
	}, mode
}

func doRate(t *testing.T, s *Server, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/rate", bytes.NewBufferString(body))
	rr := httptest.NewRecorder()
	mux := http.NewServeMux()
	s.Register(mux)
	mux.ServeHTTP(rr, req)
	var out map[string]any
	_ = json.Unmarshal(rr.Body.Bytes(), &out)
	return rr.Code, out
}

func TestRate_SetsBoth(t *testing.T) {
	s, mode := newTestServer()
	code, out := doRate(t, s, `{"rate": 10000, "mode": "single"}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d, body=%v", code, out)
	}
	if mode.Get() != ModeSingle {
		t.Fatalf("mode = %v, want ModeSingle", mode.Get())
	}
	if s.Lim.Current() != 10000 {
		t.Fatalf("rate = %d, want 10000", s.Lim.Current())
	}
	if out["mode"] != "single" || int(out["rate"].(float64)) != 10000 {
		t.Fatalf("echo body = %v", out)
	}
}

func TestRate_OmittedFieldsKeepCurrent(t *testing.T) {
	s, mode := newTestServer()
	s.Lim.Set(5000)
	_ = mode.SetByName("batch")

	// Only rate, no mode.
	code, _ := doRate(t, s, `{"rate": 7000}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if mode.Get() != ModeBatch {
		t.Fatal("mode mutated when omitted")
	}
	if s.Lim.Current() != 7000 {
		t.Fatalf("rate = %d, want 7000", s.Lim.Current())
	}

	// Only mode, no rate.
	code, _ = doRate(t, s, `{"mode": "single"}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if mode.Get() != ModeSingle {
		t.Fatal("mode unchanged when set")
	}
	if s.Lim.Current() != 7000 {
		t.Fatalf("rate mutated to %d when omitted", s.Lim.Current())
	}
}

func TestRate_RejectsInvalidMode(t *testing.T) {
	s, _ := newTestServer()
	code, _ := doRate(t, s, `{"mode": "yolo"}`)
	if code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", code)
	}
}

func TestRate_RejectsOutOfRangeRate(t *testing.T) {
	s, _ := newTestServer()
	code, _ := doRate(t, s, `{"rate": 999999}`)
	if code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", code)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go test -run TestRate ./...
```

Expected: FAIL — `Server` has no `Mode` field, `rateReq` has no `mode`.

- [ ] **Step 3: Rewrite `writer/http.go`**

Overwrite `writer/http.go`:

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
	Mode        *ModeStore
	MaxRate     int
	HealthCheck func() bool
}

type rateReq struct {
	Rate *int    `json:"rate,omitempty"`
	Mode *string `json:"mode,omitempty"`
}

type rateResp struct {
	Rate int    `json:"rate"`
	Mode string `json:"mode"`
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
	fmt.Fprintf(w, "# TYPE stress_writer_mode gauge\n")
	fmt.Fprintf(w, "stress_writer_mode{name=%q} 1\n", s.Mode.Name())
	for i, name := range [3]string{"employee", "role", "org"} {
		fmt.Fprintf(w, "# TYPE stress_writer_sent_by_pattern_total counter\n")
		fmt.Fprintf(w, "stress_writer_sent_by_pattern_total{pattern=%q} %d\n", name, s.Counters.SentByPattern[i].Load())
	}
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
	if rq.Rate != nil {
		if *rq.Rate < 0 || *rq.Rate > s.MaxRate {
			http.Error(w, fmt.Sprintf("rate %d out of range [0,%d]", *rq.Rate, s.MaxRate), http.StatusBadRequest)
			return
		}
		s.Lim.Set(*rq.Rate)
	}
	if rq.Mode != nil {
		if err := s.Mode.SetByName(*rq.Mode); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(rateResp{
		Rate: int(s.Lim.Current()),
		Mode: s.Mode.Name(),
	})
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

- [ ] **Step 4: Run test to verify it passes**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go test -run TestRate ./...
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/writer/http.go labs/redis-redpanda-throughput-stress/writer/http_test.go
git commit -m "redis-redpanda-throughput-stress: writer /rate accepts mode field

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Writer — Worker.Run rewrite (KeyGen + Picker + Mode + per-pattern counters)

**Files:**
- Modify: `writer/worker.go`

- [ ] **Step 1: Replace the file**

Overwrite `writer/worker.go`:

```go
package main

import (
	"context"
	"log"
	"math/rand"
	"time"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID           int
	RDB          *redis.Client
	StreamKey    string
	StreamMaxLen int64
	BatchMax     int
	PayloadBytes int
	Cardinality  int
	Lim          *Limiter
	Counters     *Counters
	Mode         *ModeStore
	KeyGen       *KeyGen
	Picker       *Picker
	rng          *rand.Rand
}

func (w *Worker) Run(ctx context.Context) {
	w.rng = rand.New(rand.NewSource(int64(w.ID)*1_000_003 + time.Now().UnixNano()))
	var seq int64
	base := int64(w.ID) << 40 // distinct high-bits per worker so seqs never collide
	for {
		rate := int(w.Lim.Current())
		mode := w.Mode.Get()
		depth := 1
		if mode == ModeBatch {
			depth = w.BatchMax
			if rate > 0 {
				perTenth := rate / 10
				if perTenth < 1 {
					perTenth = 1
				}
				if perTenth < depth {
					depth = perTenth
				}
			}
		}

		// Per-iteration timeout so workers re-fetch limiter and mode every pass.
		waitCtx, waitCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		err := w.Lim.WaitN(waitCtx, depth)
		waitCancel()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		patternsThisBatch := make([]int, 0, depth)
		for i := 0; i < depth; i++ {
			seq++
			pat := w.Picker.Pick(w.rng)
			id := w.rng.Intn(w.Cardinality)
			var key, patternName string
			switch pat {
			case PatternEmployee:
				key = w.KeyGen.Employee(id)
				patternName = "employee"
			case PatternRole:
				key = w.KeyGen.Role(id)
				patternName = "role"
			case PatternOrg:
				key = w.KeyGen.Org(id)
				patternName = "org"
			}
			p := NewPayload(base|seq, w.PayloadBytes)
			body, _ := p.JSON()
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: map[string]any{
					"value":     string(body),
					"event_id":  p.EventID,
					"key":       key,
					"pattern":   patternName,
					"t_send_ms": p.TsNs / 1_000_000,
				},
			})
			patternsThisBatch = append(patternsThisBatch, pat)
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(depth))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		} else {
			w.Counters.Sent.Add(int64(depth))
			for _, pat := range patternsThisBatch {
				w.Counters.SentByPattern[pat].Add(1)
			}
		}
	}
}
```

- [ ] **Step 2: Verify compilation (main.go isn't updated yet — expect a build failure citing main.go only)**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go build ./... 2>&1 | head -20
```

Expected: failures are in `main.go` (references to `PipelineDepth`, `KeySpaceSize`, missing `Mode`/`KeyGen`/`Picker`). Worker file itself compiles. If errors come from any file other than `main.go`, fix before continuing.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/writer/worker.go
git commit -m "redis-redpanda-throughput-stress: writer worker uses KeyGen/Picker/Mode

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Writer — main.go env-var wiring

**Files:**
- Modify: `writer/main.go`

- [ ] **Step 1: Replace the file**

Overwrite `writer/main.go`:

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
	streamMaxLen := envInt("STREAM_MAXLEN", 2_000_000)
	workers := envInt("WORKERS", 16)
	batchMax := envInt("BATCH_MAX", 500)
	initialRate := envInt("INITIAL_RATE", 0)
	cardinality := envInt("PATTERN_CARDINALITY", 20_000)
	payloadBytes := envInt("PAYLOAD_BYTES", 1024)
	maxRate := envInt("MAX_RATE", 60_000)
	healthAddr := envStr("HEALTH_ADDR", ":8081")
	initialMode := envStr("INITIAL_MODE", "batch")
	weightsStr := envStr("PATTERN_WEIGHTS", "33,33,34")
	keySeed := int64(envInt("KEY_SEED", 42))

	weights, err := ParsePatternWeights(weightsStr)
	if err != nil {
		log.Fatalf("PATTERN_WEIGHTS: %v", err)
	}
	picker, err := NewPicker(weights)
	if err != nil {
		log.Fatalf("NewPicker: %v", err)
	}
	keyGen := NewKeyGen(KeyGenConfig{Cardinality: cardinality, Seed: keySeed})

	rdb := redis.NewClient(&redis.Options{Addr: addr, PoolSize: workers * 2})
	defer rdb.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lim := NewLimiter()
	lim.Set(initialRate)
	mode := NewModeStore(initialMode)
	counters := &Counters{}

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		w := &Worker{
			ID: i, RDB: rdb,
			StreamKey:    streamKey,
			StreamMaxLen: int64(streamMaxLen),
			BatchMax:     batchMax,
			PayloadBytes: payloadBytes,
			Cardinality:  cardinality,
			Lim:          lim,
			Counters:     counters,
			Mode:         mode,
			KeyGen:       keyGen,
			Picker:       picker,
		}
		wg.Add(1)
		go func() { defer wg.Done(); w.Run(ctx) }()
	}

	srv := &Server{
		Lim: lim, Counters: counters, Mode: mode, MaxRate: maxRate,
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
		log.Printf("writer listening on %s (initial mode=%s)", healthAddr, mode.Name())
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
		log.Printf("WARN: %s=%q is not a valid int, using default %d", k, v, def)
		return def
	}
	return n
}
```

- [ ] **Step 2: Verify writer builds and all unit tests pass**

```bash
cd labs/redis-redpanda-throughput-stress/writer
go build ./...
go test -race ./...
```

Expected: build OK; `ok writer` from tests (key_gen, picker, mode, http, limiter, payload — six green).

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/writer/main.go
git commit -m "redis-redpanda-throughput-stress: writer main wires new env vars

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase C — Connect + compose

### Task 12: Connect YAMLs — bump max_in_flight & MAXLEN

**Files:**
- Modify: `connect/forward.yaml`
- Modify: `connect/reverse.yaml`

- [ ] **Step 1: Bump `connect/forward.yaml` output throughput**

In the `output:` block, find:

```yaml
    max_in_flight: 256
```

Replace with:

```yaml
    max_in_flight: 1024
```

- [ ] **Step 2: Bump `connect/reverse.yaml` outputs**

In both fan-out outputs (cache + redis_streams), change `max_in_flight: 64` → `max_in_flight: 256`.

In the `redis_streams` output, change `max_length: 100000` → `max_length: 2000000`.

- [ ] **Step 3: Sanity check (no Connect daemon needed — just YAML parse)**

```bash
cd labs/redis-redpanda-throughput-stress
python3 -c 'import yaml; yaml.safe_load(open("connect/forward.yaml")); yaml.safe_load(open("connect/reverse.yaml")); print("ok")'
```

Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/connect/
git commit -m "redis-redpanda-throughput-stress: raise Connect max_in_flight and region MAXLEN

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: docker-compose.yml — raise caps, new env vars, JetStream sizing

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Raise per-service resource caps**

Apply these edits (each `deploy.resources.limits` block):

| Service          | Old cpus | Old memory | New cpus | New memory |
|------------------|----------|------------|----------|------------|
| `redis-central`  | `"2.0"`  | `"512m"`   | `"4.0"`  | `"1g"`     |
| `redis-region`   | `"2.0"`  | `"512m"`   | `"4.0"`  | `"1g"`     |
| `nats`           | `"2.0"`  | `"1g"`     | `"4.0"`  | `"2g"`     |
| `connect-source` | `"2.0"`  | `"1g"`     | `"6.0"`  | `"2g"`     |
| `connect-sink`   | `"2.0"`  | `"1g"`     | `"6.0"`  | `"2g"`     |
| `writer`         | `"2.0"`  | `"256m"`   | `"4.0"`  | `"1g"`     |
| `collector`      | `"0.5"`  | `"128m"`   | `"1.0"`  | `"256m"`   |

- [ ] **Step 2: Update writer env block**

In the `writer:` service, replace the entire `environment:` block with:

```yaml
    environment:
      REDIS_ADDR: redis-central:6379
      STREAM_KEY: app.events
      STREAM_MAXLEN: "${STREAM_MAXLEN:-2000000}"
      WORKERS: "${WORKERS:-16}"
      BATCH_MAX: "${BATCH_MAX:-500}"
      INITIAL_RATE: "0"
      INITIAL_MODE: "${INITIAL_MODE:-batch}"
      PATTERN_WEIGHTS: "${PATTERN_WEIGHTS:-33,33,34}"
      PATTERN_CARDINALITY: "${PATTERN_CARDINALITY:-20000}"
      PAYLOAD_BYTES: "${PAYLOAD_BYTES:-1024}"
      MAX_RATE: "${MAX_RATE:-60000}"
      HEALTH_ADDR: ":8081"
```

- [ ] **Step 3: Raise JetStream `--max-bytes` and `--max-msg-size` in `nats-init`**

In the `nats-init` service's `command:` block, change the `stream add` invocation:

- `--max-bytes 256MB` → `--max-bytes 2GB`
- `--max-msg-size=1MB` → `--max-msg-size=4KB`

(Lines must remain inside the same `if` branch.)

- [ ] **Step 4: Verify compose still parses and the env block reflects the new vars**

```bash
cd labs/redis-redpanda-throughput-stress
docker compose config -q
docker compose config | grep -E 'STREAM_MAXLEN|BATCH_MAX|PATTERN_WEIGHTS|INITIAL_MODE|PAYLOAD_BYTES'
```

Expected: five lines, default values from the table above.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/docker-compose.yml
git commit -m "redis-redpanda-throughput-stress: raise caps, new writer env, JetStream 2GB

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase D — Collector + verdict

### Task 14: Collector — Replace `extractTsNs` with stream-field-based sync latency

**Files:**
- Modify: `collector/latency.go`
- Modify: `collector/latency_test.go`

- [ ] **Step 1: Update the test file first (TDD)**

Overwrite `collector/latency_test.go`:

```go
package main

import (
	"testing"

	"github.com/redis/go-redis/v9"
)

func TestExtractSyncLatencyMs_OK(t *testing.T) {
	fields := map[string]any{
		"t_send_ms":  "1700000000000",
		"applied_ms": "1700000000123",
	}
	got, err := extractSyncLatencyMs(fields)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 123 {
		t.Fatalf("got %d, want 123", got)
	}
}

func TestExtractSyncLatencyMs_MissingFields(t *testing.T) {
	if _, err := extractSyncLatencyMs(map[string]any{"t_send_ms": "1"}); err == nil {
		t.Error("expected error when applied_ms missing")
	}
	if _, err := extractSyncLatencyMs(map[string]any{"applied_ms": "1"}); err == nil {
		t.Error("expected error when t_send_ms missing")
	}
}

func TestExtractSyncLatencyMs_NegativeClamped(t *testing.T) {
	// Clock skew or out-of-order edge case: applied_ms < t_send_ms.
	// Should not panic; tracker handles the clamp internally.
	fields := map[string]any{
		"t_send_ms":  "1700000000200",
		"applied_ms": "1700000000100",
	}
	got, err := extractSyncLatencyMs(fields)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != -100 {
		t.Fatalf("got %d, want -100 (raw delta; clamp happens in tracker)", got)
	}
}

func TestLatencyTracker_RecordsMs(t *testing.T) {
	lt := NewLatencyTracker()
	lt.RecordMs(10)
	lt.RecordMs(50)
	lt.RecordMs(200)
	s := lt.Summary()
	if s.Samples != 3 {
		t.Fatalf("Samples = %d, want 3", s.Samples)
	}
	if s.P99Ms < 100 || s.P99Ms > 250 {
		t.Errorf("P99 = %v, want roughly 200", s.P99Ms)
	}
}

func TestLatencyTracker_ClampsNegative(t *testing.T) {
	lt := NewLatencyTracker()
	lt.RecordMs(-50) // should be clamped to 1ms (or smallest valid), not panic
	lt.RecordMs(10)
	if lt.Summary().Samples != 2 {
		t.Fatalf("Samples = %d, want 2", lt.Summary().Samples)
	}
}

// Compile-time sanity: latency.go references redis.XMessage internally.
var _ redis.XMessage
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd labs/redis-redpanda-throughput-stress/collector
go test -run TestExtractSyncLatencyMs ./...
go test -run TestLatencyTracker ./...
```

Expected: build error / undefined `extractSyncLatencyMs`, `RecordMs`.

- [ ] **Step 3: Rewrite `collector/latency.go`**

Overwrite `collector/latency.go`:

```go
package main

import (
	"fmt"
	"strconv"

	"github.com/HdrHistogram/hdrhistogram-go"
)

// extractSyncLatencyMs reads t_send_ms and applied_ms from Redis stream entry
// fields (both stamped as milliseconds since epoch — t_send_ms by the writer
// at central XADD time, applied_ms by Connect-sink immediately before regional
// SET). Returns the signed delta in ms (caller clamps).
func extractSyncLatencyMs(fields map[string]any) (int64, error) {
	tSend, err := readMsField(fields, "t_send_ms")
	if err != nil {
		return 0, err
	}
	applied, err := readMsField(fields, "applied_ms")
	if err != nil {
		return 0, err
	}
	return applied - tSend, nil
}

func readMsField(fields map[string]any, name string) (int64, error) {
	v, ok := fields[name]
	if !ok {
		return 0, fmt.Errorf("field %q missing", name)
	}
	s, ok := v.(string)
	if !ok {
		return 0, fmt.Errorf("field %q has type %T, want string", name, v)
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("field %q not int: %w", name, err)
	}
	return n, nil
}

type LatencyTracker struct {
	h *hdrhistogram.Histogram
}

func NewLatencyTracker() *LatencyTracker {
	// Range 1 ms .. 300 000 ms (5 min). Sync-latency is in ms already; no us conversion.
	return &LatencyTracker{h: hdrhistogram.New(1, 300_000, 3)}
}

// RecordMs clamps negatives to 1 (clock-skew artifact) and ceils to the histogram max.
func (l *LatencyTracker) RecordMs(d int64) {
	if d < 1 {
		d = 1
	}
	if d > 300_000 {
		d = 300_000
	}
	_ = l.h.RecordValue(d)
}

type LatencySummary struct {
	P50Ms   float64 `json:"p50"`
	P95Ms   float64 `json:"p95"`
	P99Ms   float64 `json:"p99"`
	P999Ms  float64 `json:"p999"`
	MaxMs   float64 `json:"max"`
	Samples int64   `json:"count"`
}

func (l *LatencyTracker) Summary() LatencySummary {
	f := func(q float64) float64 { return float64(l.h.ValueAtQuantile(q)) }
	return LatencySummary{
		P50Ms:   f(50),
		P95Ms:   f(95),
		P99Ms:   f(99),
		P999Ms:  f(99.9),
		MaxMs:   float64(l.h.Max()),
		Samples: l.h.TotalCount(),
	}
}
```

- [ ] **Step 4: Run latency tests**

```bash
cd labs/redis-redpanda-throughput-stress/collector
go test -run 'TestExtractSyncLatencyMs|TestLatencyTracker' ./...
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/collector/latency.go labs/redis-redpanda-throughput-stress/collector/latency_test.go
git commit -m "redis-redpanda-throughput-stress: collector sync_latency from stream fields

Replaces receiver-wall-clock latency with applied_ms - t_send_ms read
from region-events entry fields. Adds p999 to summary, renames samples
JSON tag to count.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: Collector — Receiver tally per-pattern; consume new latency API

**Files:**
- Modify: `collector/receiver.go`
- Modify: `collector/receiver_test.go`

- [ ] **Step 1: Rewrite `collector/receiver_test.go`**

Overwrite `collector/receiver_test.go`:

```go
package main

import (
	"strconv"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestReceiver_ProcessCountsAndPatternsAndLatency(t *testing.T) {
	r := &Receiver{
		stream:  "region-events",
		latency: NewLatencyTracker(),
	}
	now := time.Now().UnixMilli()
	mk := func(id string, pat string, latMs int64) redis.XMessage {
		return redis.XMessage{
			ID: id,
			Values: map[string]any{
				"value":      `{"event_id":"x","ts_ns":1,"seq":1,"pad":""}`,
				"key":        "lb:company:active:{employee:1}",
				"event_id":   "x",
				"pattern":    pat,
				"t_send_ms":  strconv.FormatInt(now-latMs, 10),
				"applied_ms": strconv.FormatInt(now, 10),
			},
		}
	}
	streams := []redis.XStream{{
		Stream: "region-events",
		Messages: []redis.XMessage{
			mk("1-0", "employee", 10),
			mk("2-0", "role", 50),
			mk("3-0", "org", 100),
			mk("4-0", "employee", 200),
		},
	}}
	r.processStreams(streams)

	if r.Count() != 4 {
		t.Fatalf("Count = %d, want 4", r.Count())
	}
	if r.CountByPattern("employee") != 2 {
		t.Errorf("employee = %d, want 2", r.CountByPattern("employee"))
	}
	if r.CountByPattern("role") != 1 {
		t.Errorf("role = %d, want 1", r.CountByPattern("role"))
	}
	if r.CountByPattern("org") != 1 {
		t.Errorf("org = %d, want 1", r.CountByPattern("org"))
	}
	sum := r.Latency()
	if sum.Samples != 4 {
		t.Fatalf("latency Samples = %d, want 4", sum.Samples)
	}
	if sum.MaxMs < 150 {
		t.Errorf("MaxMs = %v, want >= 150", sum.MaxMs)
	}
}

func TestReceiver_UnknownPatternStillCounted(t *testing.T) {
	r := &Receiver{stream: "region-events", latency: NewLatencyTracker()}
	now := time.Now().UnixMilli()
	streams := []redis.XStream{{
		Stream: "region-events",
		Messages: []redis.XMessage{{
			ID: "1-0",
			Values: map[string]any{
				"pattern":    "garbage",
				"t_send_ms":  strconv.FormatInt(now-1, 10),
				"applied_ms": strconv.FormatInt(now, 10),
			},
		}},
	}}
	r.processStreams(streams)
	if r.Count() != 1 {
		t.Fatalf("Count = %d, want 1", r.Count())
	}
	if got := r.CountByPattern("garbage"); got != 0 {
		t.Errorf("unknown pattern bucket = %d, want 0", got)
	}
}
```

- [ ] **Step 2: Rewrite `collector/receiver.go`**

Overwrite `collector/receiver.go`:

```go
package main

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
)

type Receiver struct {
	rdb      *redis.Client
	stream   string
	latency  *LatencyTracker
	received atomic.Int64
	errCount atomic.Int64
	// Per-pattern counters: index aligns with PatternEmployee/PatternRole/PatternOrg.
	byPattern [3]atomic.Int64
	lastID    string
}

func NewReceiver(addr, stream string) *Receiver {
	return &Receiver{
		rdb:     redis.NewClient(&redis.Options{Addr: addr}),
		stream:  stream,
		latency: NewLatencyTracker(),
	}
}

func (r *Receiver) Count() int64            { return r.received.Load() }
func (r *Receiver) Errors() int64           { return r.errCount.Load() }
func (r *Receiver) Latency() LatencySummary { return r.latency.Summary() }
func (r *Receiver) Close() error            { return r.rdb.Close() }

func (r *Receiver) CountByPattern(name string) int64 {
	switch name {
	case "employee":
		return r.byPattern[0].Load()
	case "role":
		return r.byPattern[1].Load()
	case "org":
		return r.byPattern[2].Load()
	}
	return 0
}

func (r *Receiver) processStreams(streams []redis.XStream) {
	for _, st := range streams {
		for _, msg := range st.Messages {
			r.received.Add(1)
			if d, err := extractSyncLatencyMs(msg.Values); err == nil {
				r.latency.RecordMs(d)
			}
			if v, ok := msg.Values["pattern"].(string); ok {
				switch v {
				case "employee":
					r.byPattern[0].Add(1)
				case "role":
					r.byPattern[1].Add(1)
				case "org":
					r.byPattern[2].Add(1)
				}
			}
			r.lastID = msg.ID
		}
	}
}

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
		r.processStreams(res)
	}
}
```

- [ ] **Step 3: Run receiver tests**

```bash
cd labs/redis-redpanda-throughput-stress/collector
go test -run TestReceiver ./...
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/collector/receiver.go labs/redis-redpanda-throughput-stress/collector/receiver_test.go
git commit -m "redis-redpanda-throughput-stress: collector receiver tallies per-pattern

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 16: Collector — Verdict (nullable p99 ceiling)

**Files:**
- Modify: `collector/verdict.go`
- Modify: `collector/verdict_test.go`

- [ ] **Step 1: Rewrite `collector/verdict_test.go`**

Overwrite `collector/verdict_test.go`:

```go
package main

import "testing"

func ptr(f float64) *float64 { return &f }

func TestVerdict_PassAllGates(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 9800,
		Missing: 0, LatencyP99Ms: 120,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: ptr(200.0)},
	})
	if !v.Pass {
		t.Fatalf("expected PASS, got %+v", v)
	}
	if v.Detail.P99LatencyOk == nil || !*v.Detail.P99LatencyOk {
		t.Errorf("expected P99LatencyOk=true, got %+v", v.Detail.P99LatencyOk)
	}
}

func TestVerdict_FailRateFloor(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 8000,
		Missing: 0, LatencyP99Ms: 50,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: ptr(200.0)},
	})
	if v.Pass {
		t.Fatalf("expected FAIL on rate, got PASS")
	}
	if v.Detail.RateFloorOk {
		t.Error("RateFloorOk should be false")
	}
}

func TestVerdict_FailMissing(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 9800,
		Missing: 5, LatencyP99Ms: 50,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: ptr(200.0)},
	})
	if v.Pass {
		t.Fatal("expected FAIL on missing")
	}
	if v.Detail.MissingOk {
		t.Error("MissingOk should be false")
	}
}

func TestVerdict_NullCeilingSkipsP99Gate(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 9800,
		Missing: 0, LatencyP99Ms: 9999,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: nil},
	})
	if !v.Pass {
		t.Fatalf("expected PASS when p99 ceiling is nil even with huge latency, got %+v", v)
	}
	if v.Detail.P99LatencyOk != nil {
		t.Errorf("P99LatencyOk = %v, want nil (skipped)", *v.Detail.P99LatencyOk)
	}
}

func TestVerdict_NullCeilingButOtherFailures(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 5000,
		Missing: 10, LatencyP99Ms: 50,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: nil},
	})
	if v.Pass {
		t.Fatal("expected FAIL")
	}
	if v.Detail.P99LatencyOk != nil {
		t.Error("P99LatencyOk should still be nil when ceiling is nil")
	}
}
```

- [ ] **Step 2: Rewrite `collector/verdict.go`**

Overwrite `collector/verdict.go`:

```go
package main

type SLO struct {
	RateMinPct      float64  `json:"rate_min_pct"`
	LatencyP99MsMax *float64 `json:"latency_p99_ms_max"` // nil = calibration mode (gate skipped)
}

type VerdictInput struct {
	RateTarget      int
	RateAchievedAvg float64
	Missing         int64
	LatencyP99Ms    float64
	SLO             SLO
}

type VerdictDetail struct {
	RateFloorOk  bool  `json:"rate_floor_ok"`
	MissingOk    bool  `json:"missing_ok"`
	P99LatencyOk *bool `json:"p99_latency_ok"` // nil when SLO.LatencyP99MsMax is nil
}

type Verdict struct {
	Pass   bool          `json:"pass"`
	Detail VerdictDetail `json:"detail"`
}

func ComputeVerdict(in VerdictInput) Verdict {
	d := VerdictDetail{}
	d.RateFloorOk = in.RateTarget == 0 ||
		in.RateAchievedAvg/float64(in.RateTarget) >= in.SLO.RateMinPct
	d.MissingOk = in.Missing == 0

	pass := d.RateFloorOk && d.MissingOk
	if in.SLO.LatencyP99MsMax != nil {
		ok := in.LatencyP99Ms <= *in.SLO.LatencyP99MsMax
		d.P99LatencyOk = &ok
		pass = pass && ok
	}
	return Verdict{Pass: pass, Detail: d}
}
```

- [ ] **Step 3: Run verdict tests**

```bash
cd labs/redis-redpanda-throughput-stress/collector
go test -run TestVerdict ./...
```

Expected: PASS (5 tests).

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/collector/verdict.go labs/redis-redpanda-throughput-stress/collector/verdict_test.go
git commit -m "redis-redpanda-throughput-stress: collector verdict supports nullable p99 ceiling

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: Collector — Quiescence drop profile parameter (ALO only)

**Files:**
- Modify: `collector/quiescence.go`
- Modify: `collector/quiescence_test.go`

- [ ] **Step 1: Rewrite `collector/quiescence.go`**

Overwrite `collector/quiescence.go`:

```go
package main

import (
	"context"
	"log"
	"time"
)

// xlenReader is the minimal subset used by waitForPipelineQuiescence.
// (Name kept for diff continuity with parent; GroupLag is the load-bearing call.)
type xlenReader interface {
	XLen(ctx context.Context, key string) (int64, error)
	GroupLag(ctx context.Context, stream, group string) (int64, error)
}

// waitForPipelineQuiescence polls every 250ms until both conditions hold for
// one poll or the deadline elapses.
//
//	Source-side: GroupLag("app.events", "propagator") == 0
//	Sink-side:   ScrapeJSZ(natsURL, natsStream).MaxPending == 0
//
// Returns true if the deadline fired.
//
// XLEN is intentionally NOT used: Redis streams don't shrink on ack, so XLEN
// never drops back to zero during a run. Parent lab regressed on this exact
// mistake (commit bdf31a9); we inherit the fixed signal.
func waitForPipelineQuiescence(
	ctx context.Context,
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
			log.Printf("WARN: pipeline did not quiesce within %s", deadline)
			return true
		}
		sourceOK := false
		if lag, err := central.GroupLag(ctx, "app.events", "propagator"); err == nil && lag == 0 {
			sourceOK = true
		}
		sinkOK := false
		if snap, err := ScrapeJSZ(ctx, natsURL, natsStream); err == nil && snap.MaxPending == 0 {
			sinkOK = true
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

- [ ] **Step 2: Surgical edits to `collector/quiescence_test.go`**

`collector/final_xlen_test.go` reuses `newFakeStreamClient`, `itoa`, and the `fakeStreamClient` type defined in `quiescence_test.go` (Go test files in the same package share symbols). DO NOT wholesale-replace `quiescence_test.go` — surgically edit it.

Make exactly these three changes:

**(a) Strip the profile parameter from every `waitForPipelineQuiescence` call.** Find every line of the form:

```go
timedOut := waitForPipelineQuiescence(ctx, "alo", central, srv.URL, "APP_EVENTS", 2*time.Second)
```

Replace with:

```go
timedOut := waitForPipelineQuiescence(ctx, central, srv.URL, "APP_EVENTS", 2*time.Second)
```

(Apply to all 5 call sites — same pattern for both `"alo"` and `"amo"` literals.)

**(b) Delete the two AMO-branch test functions entirely.** Remove these two functions verbatim:

- `TestWaitQuiescenceAmoSkipsPendingCheck` (~10 lines, ends at the test's closing `}`)
- `TestWaitQuiescenceAmoStillRequiresSourceDrain` (~10 lines, ends at the test's closing `}`)

The new quiescence code is ALO-only; sink check is always required, so AMO-skip behavior no longer exists.

**(c) (Optional cosmetic) Rename the remaining three ALO tests to drop the `Alo` infix.** This is cosmetic — leave as-is if you prefer to keep the diff minimal. Acceptable as:

- `TestWaitQuiescenceAloReturnsFalseWhenBothQueuesDrain` → keep or rename to `TestWaitQuiescenceReturnsFalseWhenBothQueuesDrain`
- Same for the other two.

Leave `newFakeStreamClient`, `fakeStreamClient`, `setXLen`, `setLag`, `setError`, `jszServer`, `itoa` exactly as they are — they're shared with `final_xlen_test.go`.

- [ ] **Step 3: Run quiescence tests**

```bash
cd labs/redis-redpanda-throughput-stress/collector
go test -run TestQuiescence ./...
```

Expected: 3 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/collector/quiescence.go labs/redis-redpanda-throughput-stress/collector/quiescence_test.go
git commit -m "redis-redpanda-throughput-stress: collector quiescence is always ALO

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 18: Collector — Report schema (drop Profile/Chaos, add SyncLatency + ReceivedByPattern + VerdictDetail)

**Files:**
- Modify: `collector/report.go`
- Modify: `collector/report_test.go`

- [ ] **Step 1: Rewrite `collector/report_test.go`**

Overwrite `collector/report_test.go`:

```go
package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestReport_JSONShape(t *testing.T) {
	r := Report{
		Tier: 50000, Mode: "batch",
		StartedAt:       time.Date(2026, 5, 26, 10, 0, 0, 0, time.UTC),
		DurationS:       30,
		RateTarget:      50000,
		RateAchievedAvg: 49850.2,
		Sent:            1495506,
		Received:        1492841,
		ReceivedByPattern: map[string]int64{
			"employee": 497612, "role": 497615, "org": 497614,
		},
		Trimmed:           0,
		Missing:           2665,
		SyncLatency:       LatencySummary{P50Ms: 142.3, P95Ms: 612.1, P99Ms: 1180.4, P999Ms: 1843.2, MaxMs: 2010.7, Samples: 1492841},
		ReceivedErrors:    0,
		QuiescenceTimeout: false,
		Verdict: Verdict{
			Pass: true,
			Detail: VerdictDetail{RateFloorOk: true, MissingOk: true, P99LatencyOk: nil},
		},
	}
	buf, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	s := string(buf)
	for _, want := range []string{
		`"tier": 50000`,
		`"mode": "batch"`,
		`"sync_latency_ms"`,
		`"p999": 1843.2`,
		`"count": 1492841`,
		`"received_by_pattern"`,
		`"p99_latency_ok": null`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in JSON:\n%s", want, s)
		}
	}
	for _, forbidden := range []string{
		`"profile"`,
		`"chaos"`,
		`"latency_ms"`,
		`"checks"`,
	} {
		if strings.Contains(s, forbidden) {
			t.Errorf("forbidden %q present in JSON:\n%s", forbidden, s)
		}
	}
}
```

- [ ] **Step 2: Rewrite `collector/report.go`**

Overwrite `collector/report.go`:

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

type Report struct {
	Tier              int              `json:"tier"`
	Mode              string           `json:"mode"`
	StartedAt         time.Time        `json:"started_at"`
	DurationS         int              `json:"duration_s"`
	RateTarget        int              `json:"rate_target"`
	RateAchievedAvg   float64          `json:"rate_achieved"`
	RateAchievedMin   float64          `json:"rate_achieved_min"`
	Sent              int64            `json:"sent"`
	Errors            int64            `json:"errors"`
	Received          int64            `json:"received"`
	ReceivedByPattern map[string]int64 `json:"received_by_pattern"`
	Missing           int64            `json:"missing"`
	MissingPct        float64          `json:"missing_pct"`
	Trimmed           int64            `json:"trimmed"`
	ReceivedErrors    int64            `json:"received_errors"`
	SyncLatency       LatencySummary   `json:"sync_latency_ms"`
	Redis             RedisStats       `json:"redis"`
	NATS              NATSStats        `json:"nats"`
	Connect           ConnectStats     `json:"connect"`
	SLO               SLO              `json:"slo"`
	Verdict           Verdict          `json:"verdict"`
	QuiescenceTimeout bool             `json:"quiescence_timeout"`
}
```

- [ ] **Step 3: Run report tests**

```bash
cd labs/redis-redpanda-throughput-stress/collector
go test -run TestReport ./...
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/collector/report.go labs/redis-redpanda-throughput-stress/collector/report_test.go
git commit -m "redis-redpanda-throughput-stress: collector report schema (sync_latency_ms, received_by_pattern, nullable p99)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 19: Collector — main.go strip profile/chaos; mode is batch/single; wire new schema

**Files:**
- Modify: `collector/main.go`

- [ ] **Step 1: Replace the file**

Overwrite `collector/main.go`:

```go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type RunConfig struct {
	Tier         int
	Mode         string // "batch" | "single"
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
	SLO          SLO
}

func main() {
	var (
		tier        = flag.Int("tier", 0, "target msg/s (required)")
		mode        = flag.String("mode", "batch", "batch|single")
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
		sloRatePct  = flag.Float64("slo-rate-pct", 0.90, "")
		sloP99Ms    = flag.Float64("slo-p99-ms", -1, "<=0 means no p99 gate (calibration mode)")
	)
	flag.Parse()
	if *tier <= 0 {
		log.Fatal("--tier required (>0)")
	}
	if *mode != "batch" && *mode != "single" {
		log.Fatalf("--mode must be batch|single, got %q", *mode)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		<-c
		cancel()
	}()

	slo := SLO{RateMinPct: *sloRatePct}
	if *sloP99Ms > 0 {
		v := *sloP99Ms
		slo.LatencyP99MsMax = &v
	}

	cfg := RunConfig{
		Tier: *tier, Mode: *mode,
		Duration: *duration, Warmup: *warmup, Drain: *drain,
		WriterURL:    *writerURL,
		RedisCentral: *central, RedisRegion: *region,
		NATSURL: *natsURL, NATSStream: *natsStream,
		ConnectSrc: *connectSrc, ConnectSink: *connectSink,
		SLO: slo,
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
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	enc := json.NewEncoder(tmp)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

func Run(ctx context.Context, cfg RunConfig) (Report, error) {
	central := NewStreamClient(cfg.RedisCentral)
	defer central.Close()
	region := NewStreamClient(cfg.RedisRegion)
	defer region.Close()

	if err := central.Trim(ctx, "app.events"); err != nil {
		return Report{}, fmt.Errorf("trim app.events: %w", err)
	}
	if err := region.Trim(ctx, "region-events"); err != nil {
		return Report{}, fmt.Errorf("trim region-events: %w", err)
	}
	if err := PostReset(ctx, cfg.WriterURL); err != nil {
		return Report{}, err
	}

	defer func() {
		c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = PostRate(c, cfg.WriterURL, 0, "")
	}()

	receiver := NewReceiver(cfg.RedisRegion, "region-events")
	defer receiver.Close()
	receiverCtx, cancelRecv := context.WithCancel(ctx)
	defer cancelRecv()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		receiver.Run(receiverCtx)
	}()

	// Arm the writer's mode before warmup (rate=tier/2, mode=cfg.Mode).
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier/2, cfg.Mode); err != nil {
		return Report{}, err
	}
	sleep(ctx, cfg.Warmup)

	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier, ""); err != nil {
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

	if err := PostRate(ctx, cfg.WriterURL, 0, ""); err != nil {
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

	quiescenceTimedOut := waitForPipelineQuiescence(
		ctx, central, cfg.NATSURL, cfg.NATSStream, 10*time.Second)
	if ctx.Err() != nil {
		return Report{}, ctx.Err()
	}

	sleep(ctx, 1500*time.Millisecond) // tail-flush; see spec §5 step 10
	if ctx.Err() != nil {
		return Report{}, ctx.Err()
	}

	snaps = append(snaps, sampler.Tick(ctx))
	cancelRecv()
	wg.Wait()

	finalRegionXLen := readFinalRegionXLen(ctx, region, snaps)
	return buildReport(cfg, startedAt, snaps, receiver, finalRegionXLen, quiescenceTimedOut), nil
}

func buildReport(
	cfg RunConfig,
	startedAt time.Time,
	snaps []Snapshot,
	receiver *Receiver,
	finalRegionXLen int64,
	quiescenceTimedOut bool,
) Report {
	r := Report{
		Tier: cfg.Tier, Mode: cfg.Mode,
		StartedAt: startedAt, DurationS: int(cfg.Duration.Seconds()),
		RateTarget:  cfg.Tier,
		SyncLatency: receiver.Latency(),
		SLO:         cfg.SLO,
	}
	r.Received = receiver.Count()
	r.ReceivedErrors = receiver.Errors()
	r.QuiescenceTimeout = quiescenceTimedOut
	r.Redis.RegionXLenFinal = finalRegionXLen
	r.Trimmed = r.Received - r.Redis.RegionXLenFinal
	if r.Trimmed < 0 {
		r.Trimmed = 0
	}
	r.ReceivedByPattern = map[string]int64{
		"employee": receiver.CountByPattern("employee"),
		"role":     receiver.CountByPattern("role"),
		"org":      receiver.CountByPattern("org"),
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
	r.Missing = r.Sent - r.Received
	if r.Missing < 0 {
		r.Missing = 0
	}
	if r.Sent > 0 {
		r.MissingPct = float64(r.Missing) / float64(r.Sent) * 100.0
	}

	var minRate float64 = 1e18
	var sumRate, samples float64
	var lastSent int64
	var lastAt time.Time
	var maxXLen, maxPending int64
	for i, snap := range snaps {
		sent := int64(snap.WriterMetrics["stress_writer_sent_total"])
		rateTarget := int(snap.WriterMetrics["stress_writer_rate_target"])
		if i > 0 && rateTarget == cfg.Tier {
			deltaSec := snap.At.Sub(lastAt).Seconds()
			if deltaSec > 0 {
				deltaCount := float64(sent - lastSent)
				if deltaCount < 0 {
					deltaCount = 0
				}
				rate := deltaCount / deltaSec
				sumRate += rate
				samples++
				if rate < minRate {
					minRate = rate
				}
			}
		}
		lastSent = sent
		lastAt = snap.At
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

	r.Verdict = ComputeVerdict(VerdictInput{
		RateTarget:      cfg.Tier,
		RateAchievedAvg: r.RateAchievedAvg,
		Missing:         r.Missing,
		LatencyP99Ms:    r.SyncLatency.P99Ms,
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

- [ ] **Step 2: Update `collector/scrapers.go` to expose `PostRate(ctx, url, rate int, mode string)`**

Find `PostRate` in `collector/scrapers.go`. Replace its signature and body with:

```go
func PostRate(ctx context.Context, baseURL string, rate int, mode string) error {
	body := map[string]any{"rate": rate}
	if mode != "" {
		body["mode"] = mode
	}
	buf, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/rate", bytes.NewReader(buf))
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /rate: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("POST /rate: status %d", resp.StatusCode)
	}
	return nil
}
```

(If imports change, ensure `bytes`, `encoding/json`, `net/http`, `context`, `fmt` are present.)

- [ ] **Step 3: Delete the obsolete `collector/final_xlen_test.go` only if it exercised chaos/profile branches; otherwise keep it**

Run: `grep -E 'profile|chaos' labs/redis-redpanda-throughput-stress/collector/final_xlen_test.go || echo "clean"`

- If output is `clean`, leave the file as-is.
- Otherwise, delete the references with targeted edits (or rewrite the file as a single ReadFinalRegionXLen test that doesn't depend on `Profile`).

- [ ] **Step 4: Build and run all collector tests**

```bash
cd labs/redis-redpanda-throughput-stress/collector
go build ./...
go test -race ./...
```

Expected: build OK; every test PASS.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/collector/main.go labs/redis-redpanda-throughput-stress/collector/scrapers.go labs/redis-redpanda-throughput-stress/collector/final_xlen_test.go 2>/dev/null || true
git commit -m "redis-redpanda-throughput-stress: collector main is mode-aware, profile-free

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase E — Harness, env, docs

### Task 20: scripts/lib/tier-defs.sh — new tiers, modes, null p99 ceiling

**Files:**
- Modify: `scripts/lib/tier-defs.sh`

- [ ] **Step 1: Replace the file**

Overwrite `labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh`:

```bash
#!/usr/bin/env bash
# Tier knobs for the throughput-stress lab. Sourced by stress-run.sh.

# Default tiers (override via --tiers=5000,50000)
DEFAULT_TIERS=(5000 10000 20000 30000 40000 50000)

# Default modes (override via --modes=batch,single)
DEFAULT_MODES=(batch single)

# Achieved-rate floor as fraction of target.
declare -A TIER_RATE_MIN_PCT=(
  [5000]=0.95
  [10000]=0.95
  [20000]=0.90
  [30000]=0.90
  [40000]=0.90
  [50000]=0.90
)

# Per-tier p99 sync-latency ceiling (ms).
# Empty string = no ceiling (calibration mode); collector treats <=0 as "skip p99 gate".
# After the first full-matrix run, edit these to commit real ceilings.
declare -A TIER_P99_MS=(
  [5000]=""
  [10000]=""
  [20000]=""
  [30000]=""
  [40000]=""
  [50000]=""
)

# Run windows (env-overridable)
DURATION_S="${DURATION_S:-30}"
WARMUP_S="${WARMUP_S:-5}"
DRAIN_S="${DRAIN_S:-10}"
```

- [ ] **Step 2: Smoke parse**

```bash
bash -n labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh && echo "ok"
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/scripts/lib/tier-defs.sh
git commit -m "redis-redpanda-throughput-stress: tier-defs (5k-50k x batch/single; null p99)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 21: scripts/stress-run.sh — drop profile/chaos; mode axis; per-run flow

**Files:**
- Modify: `scripts/stress-run.sh`

- [ ] **Step 1: Replace the file**

Overwrite `labs/redis-redpanda-throughput-stress/scripts/stress-run.sh`:

```bash
#!/usr/bin/env bash
# Top-level throughput-stress harness. See README for usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/tier-defs.sh"

TIERS=("${DEFAULT_TIERS[@]}")
MODES=("${DEFAULT_MODES[@]}")

for arg in "$@"; do
  case "$arg" in
    --tiers=*) IFS=',' read -r -a TIERS <<< "${arg#*=}";;
    --modes=*) IFS=',' read -r -a MODES <<< "${arg#*=}";;
    -h|--help)
      cat <<EOF
Usage: $0 [--tiers=5000,10000,...] [--modes=batch,single]

Env overrides:
  DURATION_S=30  WARMUP_S=5  DRAIN_S=10
EOF
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

NO_ARGS_RUN=$(( $# == 0 ? 1 : 0 ))
cleanup() {
  if (( NO_ARGS_RUN )); then
    echo "[teardown] docker compose down -v"
    docker compose down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Validate tiers
for t in "${TIERS[@]}"; do
  if [[ -z "${TIER_RATE_MIN_PCT[$t]:-}" ]]; then
    echo "error: unknown tier '${t}'. Known: ${!TIER_RATE_MIN_PCT[*]}" >&2
    exit 2
  fi
done

# Validate modes
for m in "${MODES[@]}"; do
  case "$m" in
    batch|single) ;;
    *) echo "error: unknown mode '${m}'. Known: batch single" >&2; exit 2;;
  esac
done

echo "[boot] starting compose services"
docker compose up -d --wait

run_one() {
  local tier="$1" mode="$2"
  local rate_min_pct="${TIER_RATE_MIN_PCT[$tier]}"
  local p99_ms="${TIER_P99_MS[$tier]:-}"
  local p99_arg=()
  if [[ -n "${p99_ms}" ]]; then
    p99_arg=(--slo-p99-ms="${p99_ms}")
  fi

  echo "[run] tier=${tier} mode=${mode}"
  docker compose --profile tools run --rm \
    --user "$(id -u):$(id -g)" \
    collector \
      --tier="${tier}" --mode="${mode}" \
      --duration="${DURATION_S}s" --warmup="${WARMUP_S}s" --drain="${DRAIN_S}s" \
      --out="/reports/${tier}-${mode}.json" \
      --slo-rate-pct="${rate_min_pct}" \
      "${p99_arg[@]}" || true

  # Between-run hygiene: purge JetStream so accumulated bytes never approach the cap.
  docker run --rm --network rrts-net natsio/nats-box:0.14.5 \
    nats --server nats://nats:4222 stream purge APP_EVENTS -f >/dev/null 2>&1 \
    || echo "[purge] WARN: nats stream purge APP_EVENTS failed (continuing)" >&2
}

mkdir -p reports

for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    run_one "${tier}" "${mode}"
  done
done

echo
printf "%-9s %-8s %-15s %-9s %-9s %-9s %s\n" "tier" "mode" "rate_achieved" "missing" "trimmed" "p99 ms" "verdict"
printf -- "-----------------------------------------------------------------------\n"
all_pass=true
for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    f="reports/${tier}-${mode}.json"
    if [[ ! -f "$f" ]]; then
      printf "%-9s %-8s %-15s %-9s %-9s %-9s %s\n" "$tier" "$mode" "-" "-" "-" "-" "MISSING"
      all_pass=false
      continue
    fi
    python3 - "$f" "$tier" "$mode" <<'PY'
import json,sys
path, tier, mode = sys.argv[1], sys.argv[2], sys.argv[3]
r = json.load(open(path))
ach = r.get("rate_achieved", 0)
miss = r.get("missing", 0)
trim = r.get("trimmed", 0)
p99 = r.get("sync_latency_ms", {}).get("p99", 0)
verdict = "PASS" if r.get("verdict", {}).get("pass") else "FAIL"
print(f"{tier:<9} {mode:<8} {ach:6.1f}/{tier:<8} {miss:<9} {trim:<9} {p99:<9.1f} {verdict}")
PY
    pass=$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1]))["verdict"]["pass"] else 0)' "$f" 2>/dev/null || echo 0)
    [[ "$pass" == "1" ]] || all_pass=false
  done
done
printf -- "-----------------------------------------------------------------------\n"

if $all_pass; then exit 0; fi
exit 1
```

- [ ] **Step 2: Make executable and smoke parse**

```bash
chmod +x labs/redis-redpanda-throughput-stress/scripts/stress-run.sh
bash -n labs/redis-redpanda-throughput-stress/scripts/stress-run.sh && echo "ok"
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/scripts/stress-run.sh
git commit -m "redis-redpanda-throughput-stress: harness drops profile/chaos; adds mode axis

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 22: .env.example — rewrite for new vars

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Replace the file**

Overwrite `labs/redis-redpanda-throughput-stress/.env.example`:

```bash
# Stress run knobs (consumed by scripts/stress-run.sh)
DURATION_S=30
WARMUP_S=5
DRAIN_S=10

# Writer tuning
WORKERS=16
BATCH_MAX=500
PATTERN_WEIGHTS=33,33,34
PATTERN_CARDINALITY=20000
PAYLOAD_BYTES=1024
STREAM_MAXLEN=2000000
MAX_RATE=60000
INITIAL_MODE=batch

# Host port overrides (defaults shown)
REDIS_CENTRAL_PORT=18379
REDIS_REGION_PORT=18380
NATS_CLIENT_PORT=18222
NATS_MON_PORT=18322
CONNECT_SRC_PORT=18195
CONNECT_SINK_PORT=18196
WRITER_PORT=18081

# These are fixed in docker-compose.yml (listed for visibility):
#   REDIS_ADDR=redis-central:6379   (intra-network; do not change)
#   STREAM_KEY=app.events           (must match what Connect YAMLs read)
#   INITIAL_RATE=0                  (writer starts paused; harness drives /rate)
#   HEALTH_ADDR=:8081               (intra-container; host port is WRITER_PORT)
```

- [ ] **Step 2: Verify compose still parses with the example env**

```bash
cd labs/redis-redpanda-throughput-stress
cp .env.example .env
docker compose config -q
rm .env
```

Expected: exit 0, no output.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/.env.example
git commit -m "redis-redpanda-throughput-stress: .env.example for new writer/runtime knobs

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 23: README.md — full rewrite

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Overwrite `labs/redis-redpanda-throughput-stress/README.md`**

```markdown
# redis-redpanda-throughput-stress

Throughput-focused stress harness for the Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis pipeline. Forked from [`../redis-redpanda-connect-stress/`](../redis-redpanda-connect-stress/) (which itself forks `../redis-redpanda-qos-resilience/`); all three labs coexist on different host port ranges.

## What this demonstrates

Two writer modes (pipelined batch vs single-XADD) across six tiers (5k, 10k, 20k, 30k, 40k, 50k msg/s) on three hashtag-wrapped key patterns:

- `lb:company:active:{employee:<int>}`
- `lb:functions:active:{role:<sha1-hex>}`
- `lb:functions:active:{org:<int>}`

with 60 000 unique keys (20 000 per pattern) and a per-message sync-latency report (`applied_ms − t_send_ms`) covering writer → central Redis → Connect → JetStream → Connect → regional Redis.

ALO only. No chaos drill. No QoS profile comparison.

## Run it

```bash
cd labs/redis-redpanda-throughput-stress
cp .env.example .env             # optional
bash scripts/stress-run.sh       # default matrix: 6 tiers × 2 modes = 12 runs
```

Total wall-clock: ~10–15 min for the full default matrix. Each run writes `reports/{tier}-{mode}.json` and a summary table prints at the end.

### Subset runs

```bash
# Single tier + single mode (no auto-teardown)
bash scripts/stress-run.sh --tiers=50000 --modes=batch

# Multiple tiers, both modes
bash scripts/stress-run.sh --tiers=10000,20000

# All tiers, single mode only
bash scripts/stress-run.sh --modes=single
```

No-arg runs auto-teardown (`docker compose down -v`). Any explicit arg suppresses teardown.

### Knobs

| Env var       | Default | Effect                                        |
|---------------|---------|-----------------------------------------------|
| `DURATION_S`  | `30`    | sustain window per tier                       |
| `WARMUP_S`    | `5`     | half-rate warmup window                       |
| `DRAIN_S`     | `10`    | post-sustain drain window                     |
| `WORKERS`     | `16`    | writer goroutines                             |
| `BATCH_MAX`   | `500`   | ceiling on adaptive batch depth (batch mode)  |
| `PATTERN_WEIGHTS`     | `33,33,34` | per-write pattern weighted picker       |
| `PATTERN_CARDINALITY` | `20000`    | unique IDs per pattern                  |
| `PAYLOAD_BYTES` | `1024`| JSON pad bytes per event                      |
| `STREAM_MAXLEN` | `2000000` | central + region stream MAXLEN ~ cap      |
| `MAX_RATE`    | `60000` | hard ceiling on `POST /rate`                   |
| `INITIAL_MODE`| `batch` | starting write mode                            |

## Ports (host)

| Service           | Host port | Notes                                     |
|-------------------|-----------|-------------------------------------------|
| writer            | 18081     | `/healthz`, `/metrics`, `/rate`, `/reset` |
| redis-central     | 18379     | `redis-cli -p 18379`                      |
| redis-region      | 18380     | `redis-cli -p 18380`                      |
| nats (client)     | 18222     |                                           |
| nats (monitoring) | 18322     | `/jsz`, `/healthz`, `/varz`               |
| connect-source    | 18195     | `/ready`, `/metrics`                      |
| connect-sink      | 18196     | `/ready`, `/metrics`                      |

Coexists with `redis-multiregion-via-connect/` (15xxx), `redis-redpanda-qos-resilience/` (16xxx), and `redis-redpanda-connect-stress/` (17xxx).

## Resource caps

Per-container caps total ~29 CPU and ~9.25 GiB. On a 32-core / 122 GiB host that's <90% CPU and <8% RAM. See `docker-compose.yml` for per-service breakdown.

## Calibration mode (default)

Out of the box `scripts/lib/tier-defs.sh` ships with **`TIER_P99_MS=""` for every tier**. The verdict gates rate floor and `missing==0`; p99 sync-latency is reported but not gated.

To commit per-tier p99 ceilings:

1. Run the full matrix at least once on the target host.
2. Inspect `reports/*.json` for `sync_latency_ms.p99` across both modes.
3. Pick ceilings (suggested: `round_up_to_100ms(max(p99_batch, p99_single) * 1.25)`).
4. Edit `TIER_P99_MS` in `scripts/lib/tier-defs.sh`.

After calibration, the harness gates all three: rate, missing, p99.

## Live `/rate` endpoint

The writer's `POST /rate` accepts a JSON body `{ "rate": <int>, "mode": "batch"|"single" }`. Either field is optional — missing fields keep their current value.

```bash
curl -s -X POST -d '{"rate":35000,"mode":"single"}' \
  -H 'content-type: application/json' http://localhost:18081/rate
# -> {"rate":35000,"mode":"single"}
```

## Useful checks (between runs)

```bash
# Stream lengths
redis-cli -p 18379 XLEN app.events
redis-cli -p 18380 XLEN region-events

# JetStream
docker exec rrts-nats nats stream info APP_EVENTS

# Writer state
curl -s http://localhost:18081/metrics
curl -s -X POST -d '{"rate":0}' -H 'content-type: application/json' http://localhost:18081/rate

# Report fields
jq '.sync_latency_ms, .missing, .received_by_pattern, .verdict' reports/50000-batch.json
```

## Tear down

```bash
docker compose down -v
```

## Further reading

- [`RESEARCH.md`](RESEARCH.md) — design rationale.
- Parent: [`../redis-redpanda-connect-stress/`](../redis-redpanda-connect-stress/) — QoS-aware stress with 3 profiles and chaos drills.
- Design spec: `docs/superpowers/specs/2026-05-26-redis-redpanda-throughput-stress-design.md`.
- Implementation plan: `docs/superpowers/plans/2026-05-26-redis-redpanda-throughput-stress.md`.
```

- [ ] **Step 2: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/README.md
git commit -m "redis-redpanda-throughput-stress: README rewrite for new lab

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 24: RESEARCH.md — full rewrite

**Files:**
- Modify: `RESEARCH.md`

- [ ] **Step 1: Overwrite `labs/redis-redpanda-throughput-stress/RESEARCH.md`**

```markdown
# RESEARCH — redis-redpanda-throughput-stress

## What this lab proves vs parent

The parent (`../redis-redpanda-connect-stress/`) is a 3-axis matrix: tiers × modes × profiles, with chaos drills and per-tier p99 ceilings. It asks: "do the QoS guarantees hold under load?"

This lab strips that to one axis. It asks: **"where does this pipeline top out, and how much of the ceiling comes from writer-side batching?"**

- One profile (ALO), no chaos.
- Two writer modes (batch vs single-XADD), exposed as a hot-swap on `POST /rate`.
- Six tiers from 5k to 50k msg/s.
- Three hashtag-wrapped key patterns (`employee`, `role`, `org`), 60 000 unique keys, weighted picker.
- Calibration-mode verdict: rate floor + `missing == 0` are gated; p99 sync-latency is reported but un-gated until calibrated.

## Sync-latency = `applied_ms − t_send_ms`

Parent's "latency" was computed at the receiver: `receiver_now − ts_ns`, including XREAD polling and regional XADD round-trip. Useful, but not strictly "central Redis vs regional Redis".

This lab reads two timestamps from each `region-events` stream entry:

- `t_send_ms` — writer-stamped, immediately before central XADD.
- `applied_ms` — Connect-sink-stamped (via `meta applied_ms = (timestamp_unix_nano() / 1000000).string()` in `connect/reverse.yaml`), immediately before regional fan-out.

Sync latency = `applied_ms − t_send_ms`. Covers writer → central XADD ack → Connect-source pull → JetStream publish/ack → Connect-sink consume. Does **not** include the final SET round-trip to regional — sub-millisecond on a single host, dominated by Connect/JetStream cost.

## Why hot-swap mode (not container restart)

Twelve mode-switches per matrix run × ~5 s container recreate = 60 s wasted + a reconnect storm against central Redis. The writer's `POST /rate` now accepts `{ "mode": "batch"|"single" }` alongside `rate`; mode swap is atomic (single `atomic.Int32`) and observed by every worker at the top of each loop iteration. Zero connection churn.

## Why hashtags on three patterns

Real workloads pin related keys to the same Cluster slot via `{...}` hashtags. Even though this lab runs single-Redis nodes (not a cluster), keeping the hashtag shape:

- Surfaces realistic key-allocation patterns for the Connect/JetStream pipeline (longer keys, JSON-envelope size).
- Lets a future Cluster topology slot-pin without rewriting the writer.
- Forces the receiver to handle per-pattern accounting, which is the more interesting per-message report than parent's anonymous `stress:<int>` keys.

20 000 unique IDs per pattern × 3 patterns = 60 000 keys. At 50k/s × 30 s = 1.5 M writes, that's ~25 hits per key — enough churn to exercise downstream cache writes, not so much that the pipeline becomes a per-key hot loop.

## Why STREAM_MAXLEN = 2 000 000 (was 100 000 in parent)

50k/s × 30s = 1.5 M peak. Parent's 100 k cap trimmed aggressively at 10k; at 50k it would discard 93% of entries before the receiver could read them. 2 M caps the stream at ~33% headroom over peak. Receiver is still untainted by MAXLEN trimming (streaming `XREAD BLOCK` reads every entry as it arrives; trim only matters for end-of-run XLEN), but the larger cap lets operators eyeball stream contents post-run.

## Why calibration-mode verdict

There's no reference number for what p99 sync-latency *should* be at, say, 30k batch mode on a given host. Hard-coding a guess turns the verdict into noise. Ship with `TIER_P99_MS=""` for every tier; collector's `--slo-p99-ms <= 0` flag skips the p99 gate; run the full matrix once on real hardware; pick ceilings; commit them. Future runs gate on real numbers.

## Quiescence note (inherited from parent v2)

Source-side quiescence uses `GroupLag("app.events", "propagator") == 0`, NOT `XLEN("app.events") == 0`. Redis streams don't shrink on ack, so XLEN never returns to zero during a run. The parent lab fixed this in commit `bdf31a9` ("Redis streams don't shrink on ack, so XLEN is not the right metric here"). We inherit the fixed signal. Sink-side uses `ScrapeJSZ.MaxPending == 0`. Both required; tail-flush 1500ms after observation before cancelling the receiver (parent commit `1e9e7b2`).

## Pointers

- Design spec: [`../../docs/superpowers/specs/2026-05-26-redis-redpanda-throughput-stress-design.md`](../../docs/superpowers/specs/2026-05-26-redis-redpanda-throughput-stress-design.md)
- Implementation plan: [`../../docs/superpowers/plans/2026-05-26-redis-redpanda-throughput-stress.md`](../../docs/superpowers/plans/2026-05-26-redis-redpanda-throughput-stress.md)
- Parent lab: [`../redis-redpanda-connect-stress/RESEARCH.md`](../redis-redpanda-connect-stress/RESEARCH.md)
- Redpanda Connect docs: <https://docs.redpanda.com/redpanda-connect/about/>
- Redis Cluster hashtags: <https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/#hash-tags>
- NATS JetStream: <https://docs.nats.io/nats-concepts/jetstream>
- HDR Histogram: <https://github.com/HdrHistogram/hdrhistogram-go>
```

- [ ] **Step 2: Commit**

```bash
git add labs/redis-redpanda-throughput-stress/RESEARCH.md
git commit -m "redis-redpanda-throughput-stress: RESEARCH rewrite

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase F — Integration

### Task 25: End-to-end smoke (boot + 5k-batch single run + verify report + teardown)

**Files:**
- None modified (verification only).

- [ ] **Step 1: Build images and boot stack**

```bash
cd labs/redis-redpanda-throughput-stress
docker compose up -d --build --wait
docker compose ps
```

Expected: all 6 services (`redis-central`, `redis-region`, `nats`, `connect-source`, `connect-sink`, `writer`) `Up (healthy)`. `nats-init` `Exited (0)`.

- [ ] **Step 2: Run a single low-tier batch run**

```bash
bash scripts/stress-run.sh --tiers=5000 --modes=batch
```

Expected: completes in ~50 s (5 s warmup + 30 s sustain + 10 s drain + quiescence). Exit code 0 or 1 — we inspect the report next.

- [ ] **Step 3: Verify report fields**

```bash
jq '{tier, mode, rate_target, rate_achieved, sent, received, missing, trimmed,
     p50: .sync_latency_ms.p50, p99: .sync_latency_ms.p99, count: .sync_latency_ms.count,
     received_by_pattern, verdict}' reports/5000-batch.json
```

Expected (approximate, hardware-dependent):
- `tier: 5000`, `mode: "batch"`
- `rate_achieved` ≥ 4750 (95% floor)
- `sent ≈ 150000` (5000 × 30); `received ≈ 150000`; `missing: 0`; `trimmed: 0`
- `sync_latency_ms.count ≈ 150000`; `p99` reported as a real number (untyped because calibration-mode null ceiling means the verdict ignores it)
- `received_by_pattern` shows all 3 patterns ≥ 30 000 (33% × 150 000 with ±2% jitter)
- `verdict.pass: true`, `verdict.detail.p99_latency_ok: null`

- [ ] **Step 4: Verify mode hot-swap works mid-run**

```bash
# Re-arm rate=0
curl -s -X POST -d '{"rate":0}' -H 'content-type: application/json' http://localhost:18081/rate

# Set to single mode at 3k/s
curl -s -X POST -d '{"rate":3000,"mode":"single"}' -H 'content-type: application/json' http://localhost:18081/rate

# Wait 2 s and read metrics
sleep 2
curl -s http://localhost:18081/metrics | grep -E 'mode|rate_target'
```

Expected: `stress_writer_mode{name="single"} 1` and `stress_writer_rate_target 3000`. Switch back to `batch` and confirm the label flips.

- [ ] **Step 5: Teardown**

```bash
docker compose down -v
```

Expected: all containers removed, volume `nats-data` deleted.

- [ ] **Step 6: Commit the lab as functionally complete (no code changes — empty commit allowed)**

```bash
git -C $(git -C labs/redis-redpanda-throughput-stress rev-parse --show-toplevel) commit --allow-empty -m "redis-redpanda-throughput-stress: smoke-tested end-to-end at 5k batch

Boot, run, mode hot-swap, teardown all verified locally.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Acceptance — definition of done

- All 25 tasks committed in order.
- `cd labs/redis-redpanda-throughput-stress/writer && go test -race ./...` → all PASS.
- `cd labs/redis-redpanda-throughput-stress/collector && go test -race ./...` → all PASS.
- `docker compose config -q` in the lab dir → exit 0.
- `bash scripts/stress-run.sh --tiers=5000 --modes=batch` produces `reports/5000-batch.json` with `verdict.pass: true` and `verdict.detail.p99_latency_ok: null`.
- README and RESEARCH files reference the spec and parent labs correctly.
- Coexistence: starting this lab does not collide with any 15xxx/16xxx/17xxx port (verify with `ss -tlnp | grep -E ':(15|16|17|18)[0-9]{3}'`).
