# redis-connect-failover-ab-k8s Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a new Kubernetes lab that strips the inherited LWW machinery and compares two ways of achieving "at most one active Redpanda Connect consumer" — **Method A** (Deployment + fail-closed leader-election controller) vs **Method C** (`StatefulSet replicas: 1`) — measuring **failover time** (zero-active gap duration) and **robustness** (at-most-1-active held) under graceful-delete and force-delete faults.

**Architecture:** Fork `labs/redis-connect-leader-election-k8s/` → `labs/redis-connect-failover-ab-k8s/`. Remove LWW from the writer. Add a `.Values.method: A|C` toggle to the Helm chart: `A` renders the existing Deployment + elector sidecars; `C` renders a `StatefulSet replicas: 1` running connect in run-mode with a static pipeline (no elector, no lease). Make the observer's active signal counter-based so its overlap/gap/single-active math works identically for both methods. A new `scripts/verify-failover.sh` harness deploys each method, injects the two faults, and prints an A-vs-C comparison table.

**Tech Stack:** Go (writer, observer, elector, dashboard — each its own module), Helm chart, Redpanda Connect (`hpdevelop/connect:4.92.0-claudefix`), Redis 7, kind, bash + jq harness.

**Spec:** `docs/superpowers/specs/2026-06-09-redis-connect-failover-ab-k8s-design.md`

---

## File Structure

New lab root: `labs/redis-connect-failover-ab-k8s/` (copied from the parent, then modified).

**Writer (remove LWW):**
- `writer/run.go` — NEW, replaces `version.go`. Holds boot id + run epoch (the start gate). No per-key version map.
- `writer/run_test.go` — NEW, replaces `version_test.go`.
- `writer/worker.go` — MODIFY: plain producer loop (`Loop`), no `ownedKeyID`/version derivation, no `key`/`version` XADD fields.
- `writer/main.go` — MODIFY: drop keyspace guard + `KEY_SPACE_SIZE`; `NewRun()`.
- `writer/http.go` — MODIFY: `Server.Run` instead of `Server.Versions`; `/state` returns `{boot_id, epoch}`.
- `writer/http_test.go` — MODIFY: assert epoch + boot_id only (no keys).
- `writer/version.go`, `writer/version_test.go`, `writer/worker_test.go` — DELETE.
- `writer/payload.go`, `writer/payload_test.go`, `writer/limiter*.go`, `writer/counters.go` — UNCHANGED.

**Observer (counter-based active signal):**
- `observer/timeline.go` — MODIFY: `SingleActive(series, requireStreamCount bool)`.
- `observer/main.go` — MODIFY: read `REQUIRE_STREAM_COUNT` env, pass to `SingleActive`.
- `observer/timeline_test.go` — MODIFY: pass `true` to existing calls; add a counter-only test.

**Chart (method toggle):**
- `chart/templates/connect-deployment.yaml` — RENAMED from `connect-elector.yaml`; Deployment gated `if eq .Values.method "A"`; headless Service moved out.
- `chart/templates/connect-service.yaml` — NEW: the always-rendered headless `connect` Service.
- `chart/templates/connect-statefulset.yaml` — NEW: gated `if eq .Values.method "C"`.
- `chart/templates/connect-config.yaml` — MODIFY: per-method ConfigMaps.
- `chart/templates/rbac.yaml` — MODIFY: gate to method A.
- `chart/templates/observer.yaml` — MODIFY: add `REQUIRE_STREAM_COUNT` env.
- `chart/templates/writer.yaml` — MODIFY: drop `KEY_SPACE_SIZE` env.
- `chart/files/connect/pipeline-c.yaml` — NEW: full run-mode config for Method C.
- `chart/values.yaml` — MODIFY: add `method`, `connect.terminationGracePeriodSeconds`; drop `KEY_SPACE_SIZE`.
- `chart/Chart.yaml` — MODIFY: rename + description.
- `chart/templates/NOTES.txt` — MODIFY.

**Scripts / docs:**
- `scripts/verify-failover.sh` — NEW: the A-vs-C comparison harness. Replaces `verify-election.sh` (deleted).
- `scripts/lib/run-defaults.sh` — MODIFY: failover-oriented defaults.
- `README.md`, `RESEARCH.md` — REWRITE for the A-vs-C comparison.

---

## Task 1: Scaffold the new lab from the parent

**Files:**
- Create: `labs/redis-connect-failover-ab-k8s/` (copy of parent)
- Modify: `labs/redis-connect-failover-ab-k8s/chart/Chart.yaml`

- [ ] **Step 1: Copy the parent lab**

Run from repo root:
```bash
cp -r labs/redis-connect-leader-election-k8s labs/redis-connect-failover-ab-k8s
```

- [ ] **Step 2: Confirm the copy compiles and tests pass (baseline before changes)**

```bash
cd labs/redis-connect-failover-ab-k8s/writer   && go test ./... && cd -
cd labs/redis-connect-failover-ab-k8s/observer && go test ./... && cd -
```
Expected: both `ok` (this is the parent's still-green baseline).

- [ ] **Step 3: Rename the chart**

Replace `labs/redis-connect-failover-ab-k8s/chart/Chart.yaml` with:
```yaml
apiVersion: v2
name: redis-connect-failover-ab-k8s
description: Active-standby failover comparison — Method A (leader election) vs Method C (StatefulSet replicas:1), LWW removed
type: application
version: 0.1.0
appVersion: "1.0.0"
```

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-failover-ab-k8s
git commit -m "failover-ab-k8s: scaffold lab as fork of leader-election-k8s"
```

---

## Task 2: Writer — remove LWW

All paths under `labs/redis-connect-failover-ab-k8s/writer/`.

**Files:**
- Create: `run.go`, `run_test.go`
- Modify: `worker.go`, `main.go`, `http.go`, `http_test.go`
- Delete: `version.go`, `version_test.go`, `worker_test.go`

- [ ] **Step 1: Replace `version.go` with `run.go`**

Delete `version.go` and create `run.go`:
```bash
git rm labs/redis-connect-failover-ab-k8s/writer/version.go
```
Create `run.go`:
```go
package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync/atomic"
)

// State is the JSON shape returned by GET /state.
type State struct {
	BootID string `json:"boot_id"`
	Epoch  string `json:"epoch"`
}

// Run holds the per-process boot id and the current run epoch. The epoch doubles as
// the writer's start gate: workers emit nothing until /reset sets a non-empty epoch.
// (The parent lab's per-key LWW version map / epoch-scoped key naming is removed —
// this lab is a plain stream producer; order/uniqueness are not the concern here.)
type Run struct {
	bootID string
	epoch  atomic.Pointer[string]
}

func NewRun() *Run {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return &Run{bootID: hex.EncodeToString(b)}
}

func (r *Run) BootID() string { return r.bootID }

// SetEpoch opens (or re-opens) the start gate to the named run.
func (r *Run) SetEpoch(name string) { r.epoch.Store(&name) }

// Epoch returns the active epoch ("" before the first /reset).
func (r *Run) Epoch() string {
	if p := r.epoch.Load(); p != nil {
		return *p
	}
	return ""
}

func (r *Run) State() State {
	return State{BootID: r.bootID, Epoch: r.Epoch()}
}
```

- [ ] **Step 2: Replace `version_test.go` with `run_test.go`**

```bash
git rm labs/redis-connect-failover-ab-k8s/writer/version_test.go
```
Create `run_test.go`:
```go
package main

import "testing"

func TestRunBootIDStableNonEmpty(t *testing.T) {
	r := NewRun()
	if r.BootID() == "" {
		t.Fatal("BootID empty")
	}
	if r.BootID() != r.BootID() {
		t.Fatal("BootID changed between calls")
	}
}

func TestRunEpochStartsEmpty(t *testing.T) {
	r := NewRun()
	if r.Epoch() != "" {
		t.Fatalf("epoch=%q, want empty before reset (start gate closed)", r.Epoch())
	}
}

func TestRunSetEpochOpensGateAndStateReportsIt(t *testing.T) {
	r := NewRun()
	r.SetEpoch("run-1")
	if r.Epoch() != "run-1" {
		t.Fatalf("epoch=%q, want run-1", r.Epoch())
	}
	st := r.State()
	if st.Epoch != "run-1" {
		t.Fatalf("state epoch=%q", st.Epoch)
	}
	if st.BootID == "" {
		t.Fatal("state boot_id empty")
	}
}
```

- [ ] **Step 3: Delete `worker_test.go` (only tested the removed `ownedKeyID`)**

```bash
git rm labs/redis-connect-failover-ab-k8s/writer/worker_test.go
```

- [ ] **Step 4: Rewrite `worker.go` as a plain producer**

Replace the entire file with:
```go
package main

import (
	"context"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID            int
	Workers       int
	RDB           *redis.Client
	StreamKey     string
	StreamMaxLen  int64
	PipelineDepth int
	PayloadBytes  int
	Lim           *Limiter
	Counters      *Counters
	Run           *Run
}

// Loop emits payloads to the stream at the limiter's current rate. It is gated on the
// run epoch: nothing is sent until /reset opens the gate (Run.Epoch() != "").
func (w *Worker) Loop(ctx context.Context) {
	var emitted int64
	for {
		rate := int(w.Lim.Current())
		depth := w.PipelineDepth
		if rate > 0 {
			perTenth := rate / 10
			if perTenth < 1 {
				perTenth = 1
			}
			if perTenth < depth {
				depth = perTenth
			}
		}

		waitCtx, waitCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		err := w.Lim.WaitN(waitCtx, depth)
		waitCancel()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}

		if w.Run.Epoch() == "" {
			// No run started yet (no /reset received). Sleep before retrying so we
			// don't hot-spin discarding granted tokens if a rate was set pre-reset.
			select {
			case <-ctx.Done():
				return
			case <-time.After(100 * time.Millisecond):
			}
			continue
		}

		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		for i := 0; i < depth; i++ {
			emitted++
			p := NewPayload(emitted, w.PayloadBytes)
			body, _ := p.JSON()
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: map[string]any{
					"value":     string(body),
					"event_id":  p.EventID,
					"pattern":   "stress",
					"t_send_ms": p.TsNs / 1_000_000,
				},
			})
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
		}
	}
}
```

- [ ] **Step 5: Update `main.go` — drop keyspace, use `NewRun`, call `Loop`**

In `main.go`:

Remove these lines from the env block (line ~24):
```go
	keySpaceSize := envInt("KEY_SPACE_SIZE", 100_000)
```

Remove the keyspace guard block (lines ~39-47):
```go
	// Single-owner-per-key invariant: worker i owns keys where keyID % workers == i.
	// If the keyspace is smaller than the worker count, some workers would own zero
	// keys and the ownership math has no safe assignment — refuse to run rather than
	// let two workers share a key (which would silently break per-key version
	// monotonicity, the reorder-proof precondition).
	if keySpaceSize < workers {
		log.Fatalf("KEY_SPACE_SIZE (%d) must be >= WORKERS (%d): single-owner-per-key requires at least one key per worker", keySpaceSize, workers)
	}
	versions := NewVersions(workers)
```
Replace that whole block with:
```go
	run := NewRun()
```

Replace the worker construction loop:
```go
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		w := &Worker{
			ID: i, Workers: workers, RDB: rdb,
			StreamKey:     streamKey,
			StreamMaxLen:  int64(streamMaxLen),
			PipelineDepth: pipelineDepth,
			PayloadBytes:  payloadBytes,
			Lim:           lim,
			Counters:      counters,
			Run:           run,
		}
		wg.Add(1)
		go func() { defer wg.Done(); w.Loop(ctx) }()
	}
```

Replace the `srv := &Server{...}` block's `Versions: versions,` with `Run: run,`:
```go
	srv := &Server{
		Lim: lim, Counters: counters, MaxRate: maxRate,
		Run: run,
		HealthCheck: func() bool {
			c, cf := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cf()
			return rdb.Ping(c).Err() == nil
		},
	}
```

- [ ] **Step 6: Update `http.go` — `Run` field, minimal `/state`**

In `http.go`, change the `Server` struct field:
```go
type Server struct {
	Lim         *Limiter
	Counters    *Counters
	MaxRate     int
	HealthCheck func() bool
	Run         *Run
}
```
In `reset`, replace `s.Versions.SetEpoch(rq.Epoch)` with:
```go
	s.Run.SetEpoch(rq.Epoch)
```
In `state`, replace `_ = json.NewEncoder(w).Encode(s.Versions.State())` with:
```go
	_ = json.NewEncoder(w).Encode(s.Run.State())
```

- [ ] **Step 7: Update `http_test.go`**

Replace the whole file with:
```go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer() *Server {
	return &Server{
		Lim: NewLimiter(), Counters: &Counters{}, MaxRate: 100000,
		Run:         NewRun(),
		HealthCheck: func() bool { return true },
	}
}

func TestResetSetsEpochAndStateReportsIt(t *testing.T) {
	s := newTestServer()
	mux := http.NewServeMux()
	s.Register(mux)

	body := strings.NewReader(`{"epoch":"run-123"}`)
	req := httptest.NewRequest(http.MethodPost, "/reset", body)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("reset code=%d body=%s", rr.Code, rr.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/state", nil)
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("state code=%d", rr.Code)
	}
	var st State
	if err := json.Unmarshal(rr.Body.Bytes(), &st); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, rr.Body.String())
	}
	if st.Epoch != "run-123" {
		t.Errorf("epoch=%q", st.Epoch)
	}
	if st.BootID == "" {
		t.Error("boot_id empty")
	}
}

func TestResetRequiresEpoch(t *testing.T) {
	s := newTestServer()
	mux := http.NewServeMux()
	s.Register(mux)
	req := httptest.NewRequest(http.MethodPost, "/reset", strings.NewReader(`{}`))
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("want 400 for missing epoch, got %d", rr.Code)
	}
}
```

- [ ] **Step 8: Build and test the writer**

```bash
cd labs/redis-connect-failover-ab-k8s/writer && go vet ./... && go test ./... && cd -
```
Expected: PASS. (`go vet` catches any lingering `Versions`/`ownedKeyID`/`KeySpaceSize` reference.)

- [ ] **Step 9: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-failover-ab-k8s/writer
git commit -m "failover-ab-k8s: writer — remove LWW, keep /reset start gate"
```

---

## Task 3: Observer — counter-based active signal

All paths under `labs/redis-connect-failover-ab-k8s/observer/`.

**Files:**
- Modify: `timeline.go`, `timeline_test.go`, `main.go`

- [ ] **Step 1: Add the counter-only test (Method C) to `timeline_test.go`**

Update the existing `SingleActive(series)` calls to `SingleActive(series, true)`. There are three: in `TestSingleActive_FrozenKeyPlusNewPodRising`, `TestSingleActive_AllOnePodRising`, and the negative `TestSingleActive_FalseWhenTwoRise`. Then add this new test at the end of the file:
```go
// Method C path: requireStreamCount=false ignores ActiveStreams (run-mode connect does
// not serve the streams API), so single-active is decided purely by "exactly one pod
// rose per pair" — true even though ActiveStreams is 0 throughout.
func TestSingleActive_CounterOnlyIgnoresStreamCount(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"connect-0": 10}, 0),
		s(map[string]int64{"connect-0": 20}, 0),
		s(map[string]int64{"connect-0": 30}, 0),
	}
	if !SingleActive(series, false) {
		t.Fatal("one pod rising should be single-active when stream count is ignored")
	}
	if SingleActive(series, true) {
		t.Fatal("with requireStreamCount=true, ActiveStreams=0 must fail single-active")
	}
}
```

- [ ] **Step 2: Run the test to verify it fails to compile**

```bash
cd labs/redis-connect-failover-ab-k8s/observer && go test ./... ; cd -
```
Expected: FAIL — compile error, `SingleActive` takes 1 arg but 2 given (signature not updated yet).

- [ ] **Step 3: Update `SingleActive` in `timeline.go`**

Replace the `SingleActive` function with:
```go
// SingleActive is true iff every consecutive pair has exactly one pod rising. When
// requireStreamCount is true (Method A: streams-mode connect), it additionally requires
// every sample to report exactly one active stream. Method C (run-mode connect, no
// streams API) passes requireStreamCount=false and relies on the counter signal alone.
func SingleActive(series []Sample, requireStreamCount bool) bool {
	if len(series) < 2 {
		return false
	}
	if requireStreamCount {
		for _, s := range series {
			if s.ActiveStreams != 1 {
				return false
			}
		}
	}
	for i := 1; i < len(series); i++ {
		if roseCount(series[i-1], series[i]) != 1 {
			return false
		}
	}
	return true
}
```

- [ ] **Step 4: Update the `/verdict` handler in `main.go`**

In `main()`, add to the env block (near the other `env(...)` calls, after `intervalMs`):
```go
		requireStreamCount = env("REQUIRE_STREAM_COUNT", "true") == "true"
```
(Add it inside the `var ( ... )` group; it is a `bool`, so place it after the `intervalMs, _ = strconv.Atoi(...)` line as its own line.)

Then change the `/verdict` handler's `"single_active"` line from:
```go
			"single_active": SingleActive(series),
```
to:
```go
			"single_active": SingleActive(series, requireStreamCount),
```

- [ ] **Step 5: Run observer tests**

```bash
cd labs/redis-connect-failover-ab-k8s/observer && go vet ./... && go test ./... && cd -
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-failover-ab-k8s/observer
git commit -m "failover-ab-k8s: observer — counter-based single-active (REQUIRE_STREAM_COUNT flag)"
```

---

## Task 4: Method C pipeline config

**Files:**
- Create: `labs/redis-connect-failover-ab-k8s/chart/files/connect/pipeline-c.yaml`

- [ ] **Step 1: Create the full run-mode config**

`chart/files/connect/pipeline-c.yaml` — a complete single-config (observability + input + pipeline + output). `${POD_NAME}` is expanded by Redpanda Connect at config load (run mode supports env interpolation; the streams REST API does not — that trap only applies to Method A). Helm `tpl` only touches `{{ }}`, leaving `${POD_NAME}` intact.
```yaml
http:
  address: 0.0.0.0:4195
  enabled: true
logger:
  level: INFO
  format: json
  add_timestamp: true
metrics:
  prometheus: {}
input:
  label: redis_source
  redis_streams:
    url: {{ include "rrcs.redis.central.url" . }}
    kind: simple
    streams: [app.events]
    consumer_group: electors
    client_id: ${POD_NAME}
    body_key: value
    create_streams: true
    start_from_oldest: false
    commit_period: 200ms
    timeout: 500ms
    limit: 50
    auto_replay_nacks: true
pipeline:
  threads: 1
  processors:
    - redis:
        url: {{ include "rrcs.redis.central.url" . }}
        command: incr
        args_mapping: 'root = [ "consumed:${POD_NAME}" ]'
output:
  label: drop_sink
  drop: {}
```

- [ ] **Step 2: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-failover-ab-k8s/chart/files/connect/pipeline-c.yaml
git commit -m "failover-ab-k8s: Method C run-mode pipeline config"
```

---

## Task 5: Chart — method toggle (A=Deployment+elector, C=StatefulSet)

All paths under `labs/redis-connect-failover-ab-k8s/chart/`.

**Files:**
- Modify: `values.yaml`, `templates/connect-config.yaml`, `templates/rbac.yaml`, `templates/observer.yaml`, `templates/writer.yaml`
- Rename: `templates/connect-elector.yaml` → `templates/connect-deployment.yaml`
- Create: `templates/connect-service.yaml`, `templates/connect-statefulset.yaml`

- [ ] **Step 1: Add `method` + `terminationGracePeriodSeconds`, drop `KEY_SPACE_SIZE` in `values.yaml`**

At the very top of `values.yaml`, after the `resourcePrefix` line, add:
```yaml
# Which active-standby method to deploy: "A" (Deployment + leader-election controller)
# or "C" (StatefulSet replicas:1). The verify-failover.sh harness toggles this per run.
method: A
```
In the `connect:` block, add `terminationGracePeriodSeconds` (used by Method C so in-flight batches / XACK flush on graceful delete):
```yaml
connect:
  image: hpdevelop/connect:4.92.0-claudefix
  replicas: 3
  streamID: source_leg
  # Method C only: grace period for the StatefulSet pod to drain on graceful delete.
  terminationGracePeriodSeconds: 30
  # Lease timings — same algorithm as research's 15/10/2, shortened for fast demo failover.
  lease:
    name: connect-elector
    duration: 6s
    renewDeadline: 4s
    retryPeriod: 1s
```
In `writer.env`, delete the `KEY_SPACE_SIZE` line and its comment:
```yaml
    # Keyspace is irrelevant to gating (no LWW here); keep modest.
    KEY_SPACE_SIZE: "1000"
```
(so `writer.env` keeps only `STREAM_MAXLEN`, `WORKERS`, `PIPELINE_DEPTH`, `PAYLOAD_BYTES`, `MAX_RATE`).

- [ ] **Step 2: Rename `connect-elector.yaml` → `connect-deployment.yaml`, gate to method A, remove the inline Service**

```bash
git mv labs/redis-connect-failover-ab-k8s/chart/templates/connect-elector.yaml \
       labs/redis-connect-failover-ab-k8s/chart/templates/connect-deployment.yaml
```
Then edit `connect-deployment.yaml`: add `{{- if eq .Values.method "A" }}` as the first line, delete the trailing headless-Service block (everything from the `---` after `volumes:` onward — lines starting at `# Headless service:` through the end), and add `{{- end }}` as the new last line. The resulting file:
```yaml
{{- if eq .Values.method "A" }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect") }}
  labels: { app: connect }
spec:
  replicas: {{ .Values.connect.replicas }}
  selector:
    matchLabels: { app: connect }
  template:
    metadata:
      labels: { app: connect }
    spec:
      serviceAccountName: {{ include "rrcs.name" (dict "root" $ "base" "connect-elector") }}
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      initContainers:
        - name: wait-redis-central
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - HP="{{ include "rrcs.redis.central.hostPort" . }}"; HOST="${HP%%:*}"; PORT="${HP##*:}"; until redis-cli -h "$HOST" -p "$PORT" ping | grep -q PONG; do echo waiting redis-central; sleep 1; done
      containers:
        - name: connect
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.connect.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          # streams mode, empty boot (no pipeline until the elector POSTs one).
          args: ["streams", "-o", "/etc/connect/observability.yaml"]
          ports:
            - containerPort: 4195
          readinessProbe:
            # /ready returns 200 even with zero streams (research §3.5 trap 2) — that is
            # exactly what we want for a standby: healthy yet not consuming.
            httpGet: { path: /ready, port: 4195 }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /ping, port: 4195 }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          volumeMounts:
            - name: observability
              mountPath: /etc/connect/observability.yaml
              subPath: observability.yaml
          resources:
            {{- toYaml .Values.resources.connect | nindent 12 }}
        - name: elector
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.elector.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.elector.pullPolicy) }}
          env:
            - { name: POD_NAME, valueFrom: { fieldRef: { fieldPath: metadata.name } } }
            - { name: LEASE_NAMESPACE, valueFrom: { fieldRef: { fieldPath: metadata.namespace } } }
            - { name: LEASE_NAME, value: {{ include "rrcs.name" (dict "root" $ "base" .Values.connect.lease.name) | quote }} }
            - { name: CONNECT_ADDR, value: "http://localhost:4195" }
            - { name: STREAM_ID, value: {{ .Values.connect.streamID | quote }} }
            - { name: PIPELINE_PATH, value: "/etc/elector/pipeline.yaml" }
            - { name: HEALTH_ADDR, value: ":8090" }
            - { name: LEASE_DURATION, value: {{ .Values.connect.lease.duration | quote }} }
            - { name: RENEW_DEADLINE, value: {{ .Values.connect.lease.renewDeadline | quote }} }
            - { name: RETRY_PERIOD, value: {{ .Values.connect.lease.retryPeriod | quote }} }
          ports:
            - containerPort: 8090
          readinessProbe:
            httpGet: { path: /healthz, port: 8090 }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          volumeMounts:
            - name: pipeline
              mountPath: /etc/elector
              readOnly: true
          resources:
            {{- toYaml .Values.resources.elector | nindent 12 }}
      volumes:
        - name: observability
          configMap:
            name: {{ include "rrcs.name" (dict "root" $ "base" "connect-observability") }}
        - name: pipeline
          configMap:
            name: {{ include "rrcs.name" (dict "root" $ "base" "connect-pipeline") }}
{{- end }}
```

- [ ] **Step 3: Create the always-rendered headless Service `connect-service.yaml`**

```yaml
# Headless service: DNS returns ALL connect pod IPs so the observer can scrape each
# pod's /streams (Method A) without the K8s API. Rendered for BOTH methods — the
# selector app=connect matches the Deployment (A) and StatefulSet (C) pods alike.
apiVersion: v1
kind: Service
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-headless") }}
  labels: { app: connect }
spec:
  clusterIP: None
  selector: { app: connect }
  ports:
    - name: http
      port: 4195
      targetPort: 4195
```

- [ ] **Step 4: Create `connect-statefulset.yaml` (Method C)**

```yaml
{{- if eq .Values.method "C" }}
# Method C: StatefulSet replicas:1. K8s stable identity gives at-most-one consumer
# structurally — no elector, no lease, no RBAC. Connect runs the pipeline directly in
# run mode (env interpolation works here, unlike the streams REST API).
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect") }}
  labels: { app: connect }
spec:
  replicas: 1
  serviceName: {{ include "rrcs.name" (dict "root" $ "base" "connect-headless") }}
  selector:
    matchLabels: { app: connect }
  template:
    metadata:
      labels: { app: connect }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      terminationGracePeriodSeconds: {{ .Values.connect.terminationGracePeriodSeconds }}
      initContainers:
        - name: wait-redis-central
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - HP="{{ include "rrcs.redis.central.hostPort" . }}"; HOST="${HP%%:*}"; PORT="${HP##*:}"; until redis-cli -h "$HOST" -p "$PORT" ping | grep -q PONG; do echo waiting redis-central; sleep 1; done
      containers:
        - name: connect
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.connect.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          # run mode: one static pipeline that always consumes. ${POD_NAME} is expanded
          # by connect at config load.
          args: ["run", "/etc/connect/pipeline.yaml"]
          env:
            - { name: POD_NAME, valueFrom: { fieldRef: { fieldPath: metadata.name } } }
          ports:
            - containerPort: 4195
          readinessProbe:
            httpGet: { path: /ready, port: 4195 }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /ping, port: 4195 }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          volumeMounts:
            - name: pipeline
              mountPath: /etc/connect/pipeline.yaml
              subPath: pipeline.yaml
          resources:
            {{- toYaml .Values.resources.connect | nindent 12 }}
      volumes:
        - name: pipeline
          configMap:
            name: {{ include "rrcs.name" (dict "root" $ "base" "connect-pipeline-c") }}
{{- end }}
```

- [ ] **Step 5: Per-method ConfigMaps in `connect-config.yaml`**

Replace the whole file with:
```yaml
{{- if eq .Values.method "A" }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-observability") }}
  labels: { app: connect }
data:
  observability.yaml: |-
{{ tpl (.Files.Get "files/connect/observability.yaml") . | indent 4 }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-pipeline") }}
  labels: { app: connect }
data:
  pipeline.yaml: |-
{{ tpl (.Files.Get "files/connect/pipeline.yaml") . | indent 4 }}
{{- else if eq .Values.method "C" }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-pipeline-c") }}
  labels: { app: connect }
data:
  pipeline.yaml: |-
{{ tpl (.Files.Get "files/connect/pipeline-c.yaml") . | indent 4 }}
{{- end }}
```

- [ ] **Step 6: Gate `rbac.yaml` to method A**

Add `{{- if eq .Values.method "A" }}` as the first line of `rbac.yaml` and `{{- end }}` as the last line (the ServiceAccount + Role + RoleBinding are only needed by the elector).

- [ ] **Step 7: Add `REQUIRE_STREAM_COUNT` env to `observer.yaml`**

In the observer container `env:` list, after the `SAMPLE_INTERVAL_MS` line, add:
```yaml
            - { name: REQUIRE_STREAM_COUNT, value: "{{ if eq .Values.method "A" }}true{{ else }}false{{ end }}" }
```

- [ ] **Step 8: Drop `KEY_SPACE_SIZE` from `writer.yaml`**

In `writer.yaml`, delete the env line:
```yaml
            - { name: KEY_SPACE_SIZE, value: "{{ .Values.writer.env.KEY_SPACE_SIZE }}" }
```

- [ ] **Step 9: Render both methods to verify the chart templates are valid**

```bash
cd labs/redis-connect-failover-ab-k8s
helm template t ./chart --set method=A > /tmp/render-A.yaml
helm template t ./chart --set method=C > /tmp/render-C.yaml
cd -
echo "--- A: expect Deployment + elector SA/Role, no StatefulSet ---"
grep -E "kind: (Deployment|StatefulSet|Role|ServiceAccount)" /tmp/render-A.yaml
grep -c "name: elector" /tmp/render-A.yaml
echo "--- C: expect StatefulSet, NO elector, NO Role/SA ---"
grep -E "kind: (Deployment|StatefulSet|Role|ServiceAccount)" /tmp/render-C.yaml
grep -c "connect-pipeline-c" /tmp/render-C.yaml
echo "--- C: REQUIRE_STREAM_COUNT should be false ---"
grep -A1 "REQUIRE_STREAM_COUNT" /tmp/render-C.yaml
```
Expected: A renders a `Deployment`, a `ServiceAccount`, a `Role`, and contains an `elector` container; no `StatefulSet`. C renders a `StatefulSet`, the `connect-pipeline-c` ConfigMap, `REQUIRE_STREAM_COUNT` value `false`, and NO `Role`/`ServiceAccount`/elector. Both render exactly one headless `connect-headless` Service. Both commands exit without a Helm template error.

- [ ] **Step 10: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-failover-ab-k8s/chart
git commit -m "failover-ab-k8s: chart method toggle (A=Deployment+elector, C=StatefulSet)"
```

---

## Task 6: Harness — verify-failover.sh + defaults

All paths under `labs/redis-connect-failover-ab-k8s/`.

**Files:**
- Modify: `scripts/lib/run-defaults.sh`, `chart/templates/NOTES.txt`
- Create: `scripts/verify-failover.sh`
- Delete: `scripts/verify-election.sh`

- [ ] **Step 1: Failover-oriented run defaults**

Replace `scripts/lib/run-defaults.sh` with:
```bash
# Run-window defaults for the A-vs-C failover comparison (env-overridable).
: "${RATE:=2000}"            # writer msg/s during the run
: "${SETTLE_S:=20}"          # wait for the active consumer + consumption to ramp / reconverge
: "${OBS_WINDOW_S:=6}"       # clean steady-state observation window
: "${FAULT_WAIT_S:=20}"      # observe window after each fault (>= worst-case failover + buffer)
: "${SAMPLE_MS:=100}"        # observer sample interval (keep in sync with values observer.sampleIntervalMs)
: "${METHODS:=A C}"          # which methods to compare
```

- [ ] **Step 2: Create `scripts/verify-failover.sh`**

```bash
#!/usr/bin/env bash
# A-vs-C failover comparison harness. For each method (A=Deployment+leader-election,
# C=StatefulSet replicas:1) it boots the chart, runs a clean steady-state check, then
# injects two faults on the ACTIVE consumer — graceful delete and force delete —
# measuring for each:
#   failover_time_s = gap_pairs * SAMPLE_MS/1000   (zero-active gap = liveness recovery)
#   overlap_pairs                                    (>=2 active at once; robustness breach)
#   at_most_1_held  = (overlap_pairs == 0)
# Prints a comparison table. Exits 0 iff every method reached steady single-active AND
# every scenario held at-most-1 (overlap_pairs == 0).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/run-defaults.sh"

NS="${LEL_NS:-lel-k8s}"
RELEASE="${LEL_RELEASE:-lel}"
VALUES_FILE="${LEL_VALUES:-chart/values-dev.yaml}"

K() { kubectl -n "${NS}" "$@"; }
now_ms() { date +%s%3N; }

ROWS=()        # "method|fault|failover_s|overlap|at_most_1"
FAIL=0

# active_pod METHOD -> name of the pod currently consuming.
active_pod() {
  local method="$1"
  if [[ "$method" == "A" ]]; then
    K get lease "${PREFIX}connect-elector" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true
  else
    echo "${PREFIX}connect-0"
  fi
}

# reset_counters wipes the observer's consumed:* signal so a previous method's frozen
# counters never pollute the next method's overlap/gap math.
reset_counters() {
  K exec "deploy/${PREFIX}redis-central" -- \
    sh -c "redis-cli --scan --pattern 'consumed:*' | xargs -r redis-cli del" >/dev/null 2>&1 || true
}

# measure_fault METHOD FAULT_KIND -> echoes "failover_s overlap"
measure_fault() {
  local method="$1" kind="$2" pod start verdict gap overlap
  pod="$(active_pod "$method")"
  if [[ -z "$pod" ]]; then echo "[${method}/${kind}] no active pod" >&2; echo "0 0"; return; fi
  echo "[${method}/${kind}] injecting on ${pod}" >&2
  start="$(now_ms)"
  if [[ "$kind" == "graceful-delete" ]]; then
    K delete pod "$pod" >/dev/null 2>&1 || true
  else
    K delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
  fi
  sleep "${FAULT_WAIT_S}"
  verdict="$(OBS "verdict?since_unix_ms=${start}")"
  echo "[${method}/${kind}] ${verdict}" >&2
  gap="$(echo "$verdict" | jq -r '.gap_pairs')"
  overlap="$(echo "$verdict" | jq -r '.overlap_pairs')"
  local fs
  fs="$(awk -v g="${gap:-0}" -v ms="${SAMPLE_MS}" 'BEGIN{printf "%.1f", g*ms/1000}')"
  echo "${fs} ${overlap:-0}"
}

run_method() {
  local method="$1"
  echo "================ METHOD ${method} ================"
  echo "[boot] helm upgrade --install ${RELEASE} (method=${method})"
  helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
    -f "${VALUES_FILE}" --set "method=${method}" --wait --timeout 5m
  PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

  # OBS() depends on PREFIX, so (re)define it here.
  OBS() { K exec "deploy/${PREFIX}observer" -- wget -qO- "http://localhost:8070/$1"; }

  reset_counters
  echo "[writer] reset + start rate=${RATE}"
  K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data='{"epoch":"run"}' http://localhost:8081/reset >/dev/null
  K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data="{\"rate\":${RATE}}" http://localhost:8081/rate >/dev/null

  echo "[steady] settle ${SETTLE_S}s, observe ${OBS_WINDOW_S}s"
  sleep "${SETTLE_S}"
  local s_start sv sa
  s_start="$(now_ms)"
  sleep "${OBS_WINDOW_S}"
  sv="$(OBS "verdict?since_unix_ms=${s_start}")"
  echo "[steady] ${sv}"
  sa="$(echo "$sv" | jq -r '.single_active')"
  if [[ "$sa" != "true" ]]; then
    echo "[steady] FAIL — method ${method} did not reach single-active"
    FAIL=1
  fi

  # Scenario 1: graceful delete.
  read -r fs1 ov1 < <(measure_fault "$method" "graceful-delete")
  ROWS+=("${method}|graceful-delete|${fs1}|${ov1}")
  [[ "${ov1:-0}" -gt 0 ]] && FAIL=1

  echo "[reconverge] ${SETTLE_S}s"
  sleep "${SETTLE_S}"

  # Scenario 2: force delete.
  read -r fs2 ov2 < <(measure_fault "$method" "force-delete")
  ROWS+=("${method}|force-delete|${fs2}|${ov2}")
  [[ "${ov2:-0}" -gt 0 ]] && FAIL=1
}

for m in ${METHODS}; do run_method "$m"; done

echo ""
echo "==================== COMPARISON ===================="
printf "%-7s %-16s %-18s %-15s %s\n" "method" "fault" "failover_time_s" "overlap_pairs" "at_most_1_held"
for row in "${ROWS[@]}"; do
  IFS='|' read -r m f fs ov <<<"$row"
  amh="yes"; [[ "${ov:-0}" -gt 0 ]] && amh="no"
  printf "%-7s %-16s %-18s %-15s %s\n" "$m" "$f" "$fs" "$ov" "$amh"
done
echo "===================================================="

if [[ "$FAIL" -eq 0 ]]; then
  echo "[verify-failover] PASS — both methods steady single-active AND at-most-1 held under graceful+force delete"
  exit 0
fi
echo "[verify-failover] FAIL — see rows above (steady single-active failed, or overlap_pairs>0)"
exit 1
```
Make it executable:
```bash
chmod +x labs/redis-connect-failover-ab-k8s/scripts/verify-failover.sh
```

- [ ] **Step 3: Delete the old election harness**

```bash
git rm labs/redis-connect-failover-ab-k8s/scripts/verify-election.sh
```

- [ ] **Step 4: Update NOTES.txt**

Replace `chart/templates/NOTES.txt` with:
```
redis-connect-failover-ab-k8s installed (method={{ .Values.method }}).

Method A: N connect pods (streams mode) + elector sidecars; the Lease holder consumes.
Method C: a single StatefulSet pod (run mode) consumes; identity is the only gate.

Compare both methods' failover time + robustness:

  scripts/verify-failover.sh

Watch live:  scripts/dashboard-forward.sh  -> http://<host>:8080
```

- [ ] **Step 5: Lint the harness**

```bash
bash -n labs/redis-connect-failover-ab-k8s/scripts/verify-failover.sh && echo "syntax ok"
```
Expected: `syntax ok`. (If `shellcheck` is installed, also run it and address warnings.)

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-failover-ab-k8s/scripts labs/redis-connect-failover-ab-k8s/chart/templates/NOTES.txt
git commit -m "failover-ab-k8s: verify-failover.sh comparison harness + defaults"
```

---

## Task 7: Docs — README + RESEARCH

All paths under `labs/redis-connect-failover-ab-k8s/`.

**Files:**
- Modify (rewrite): `README.md`, `RESEARCH.md`

- [ ] **Step 1: Rewrite `README.md`**

```markdown
# redis-connect-failover-ab-k8s

## What this demonstrates

A head-to-head comparison of two ways to keep **at most one** Redpanda Connect pod
consuming a Redis stream, under failover:

- **Method A** — Deployment of N pods (streams mode) + a fail-closed client-go
  **leader-election** controller (one elector sidecar per pod). The Lease holder
  consumes. Optimizes **liveness**: fast failover, but *best-effort* (no fencing).
- **Method C** — `StatefulSet replicas: 1` running connect in run mode. K8s
  at-most-one pod identity is the only gate. Optimizes **safety**: overlap is
  structurally ~0, but failover is slower and can stall.

For each method the harness injects **graceful delete** and **force delete** on the
active consumer and records **failover time** (zero-active gap duration) and
**robustness** (whether at-most-1 held, i.e. `overlap_pairs == 0`).

LWW (the parent lab's per-key version machinery) is **removed** — the writer is a plain
stream producer; this lab is about the gating mechanism, not data correctness.
Mechanism definitions: `../../active-stanby-mechanism/research.md` (Method A §3, Method C §5).

## Run it (kind)

```bash
kind create cluster --name lel
scripts/build-images.sh --kind --kind-name=lel    # writer/elector/observer/dashboard
scripts/verify-failover.sh                         # compares A and C; prints the table
```

Tune via env (defaults in `scripts/lib/run-defaults.sh`):
`RATE=2000 SETTLE_S=20 FAULT_WAIT_S=20 METHODS="A C" scripts/verify-failover.sh`
(`LEL_NS`, `LEL_RELEASE`, `LEL_VALUES` override namespace/release/values.)

Watch live in a browser:

```bash
scripts/dashboard-forward.sh        # binds --address 0.0.0.0; prints LAN URLs
```

## Expected output

```
==================== COMPARISON ====================
method  fault            failover_time_s    overlap_pairs   at_most_1_held
A       graceful-delete  ~X.X               0               yes
A       force-delete     ~6 (≈ lease)       0               yes
C       graceful-delete  ~Y.Y               0               yes
C       force-delete     ~Z.Z               0               yes
====================================================
[verify-failover] PASS — both methods steady single-active AND at-most-1 held ...
```

`verify-failover.sh` exits 0 iff both methods reach steady single-active AND every
scenario holds at-most-1 (`overlap_pairs == 0`).

## Validation note

This is a Kubernetes lab, so the research-lab skill's `validate_lab.sh` (docker-compose)
does **not** apply. `scripts/verify-failover.sh` is the validation.

## Teardown

```bash
helm uninstall lel -n lel-k8s
kind delete cluster --name lel
```

## Further reading

- `RESEARCH.md` — the two mechanisms, what the fault matrix does and does not expose.
- `../../active-stanby-mechanism/research.md` — Method A (§3), Method C (§5).
- `../redis-connect-leader-election-k8s/` — the Method-A-only lab this forks.
```

- [ ] **Step 2: Rewrite `RESEARCH.md`**

```markdown
# Redis → Connect Failover: Method A vs Method C (Kubernetes) — RESEARCH

## Property compared

Two ways to keep **at most one** Redpanda Connect pod consuming a Redis stream, measured
under failover for **failover time** (zero-active gap) and **robustness** (at-most-1 held):

- **Method A** — Deployment + fail-closed client-go leader-election controller
  (research §3). Lease 6s/4s/1s. The Lease holder POSTs the consuming pipeline to its
  local streams API; on failover the standby takes over. **Best-effort active-gating, not
  fencing** — under clock skew / GC pause / SIGSTOP two pods can briefly consume at once.
- **Method C** — `StatefulSet replicas: 1` (research §5). Connect runs the pipeline
  directly (run mode). K8s guarantees at-most-one pod identity, so overlap is
  **structural ~0**; the cost is slower failover (terminate + reschedule + connect
  startup) and a potential **stall** on node failure (a pod stuck `Unknown` is not
  rescheduled until deleted).

LWW is removed; the writer is a plain producer. The lower correctness defenses (JetStream
dedup, sink CAS) remain out of scope — this lab isolates the gating mechanism.

## Fault matrix (what it does and does NOT expose)

The harness injects two faults on the active consumer, applied identically to A and C:

- **graceful-delete** — `kubectl delete pod` (respects `terminationGracePeriodSeconds`).
  Clean failover. A: the elector's `OnStoppedLeading` DELETEs its stream and
  `ReleaseOnCancel` frees the Lease, so a standby takes over quickly. C: the pod drains,
  then the StatefulSet creates a fresh `connect-0`.
- **force-delete** — `kubectl delete pod --force --grace-period=0` (the honest worst
  case; research §5 warns Method C against this). A: the dead pod's stream dies with it
  and the Lease lingers ~one lease-duration → a gap. C: `connect-0` is recreated → a gap
  of roughly pod scheduling + connect startup.

> **Honest scope note.** Both faults make the old consumer *stop* (deleted or
> Lease-cancelled), so neither manufactures a dual-active window. **Method A's
> best-effort overlap is therefore expected to read 0 here**, the same as Method C's
> structural 0. The fault that *would* expose A's overlap is **SIGSTOP on the elector**
> (the frozen controller keeps its stream while a standby wins the Lease) — deliberately
> **out of scope** for this comparison. `overlap_pairs` is measured on every run so the
> at-most-1 claim is backed by data, not asserted.

So the measured head-to-head signal is **failover time**, with `at_most_1_held = yes`
expected for both methods under this matrix.

## How failover time is measured

The observer samples every 100ms. A pod is "active" in a consecutive sample-pair iff its
`consumed:<pod>` counter rose. From that single signal:
- `gap_pairs` — pairs where the grand total did not increase (no pod consumed).
- `overlap_pairs` — pairs where ≥2 pods rose (dual-active).
- `single_active` — every pair had exactly one pod rising (Method A additionally requires
  the streams API to report exactly one active stream; Method C, run mode with no streams
  API, relies on the counter alone — `REQUIRE_STREAM_COUNT=false`).

**failover_time_s = gap_pairs × 0.1s**, stamped over the post-fault window.

## Interpreting the result

- **Liveness:** Method A recovers within ~the lease duration on force-delete and faster
  on graceful delete; Method C pays connect's cold-start each time. Expect A ≤ C.
- **Safety:** both hold at-most-1 under this matrix (`overlap_pairs = 0`). The difference
  is *why*: C's zero is structural (K8s identity), A's zero is best-effort and would break
  under SIGSTOP-class faults — so correctness must never rest on Method A's Lease.

## Design decisions

- **Single chart, `method` toggle** — both methods see the identical writer load, Redis,
  and observer math; the only honest way to compare. `method=A` renders the
  Deployment + elector + Lease RBAC; `method=C` renders the StatefulSet (no elector, no
  RBAC).
- **Counter-based active signal** — makes the observer's overlap/gap/single-active math
  identical for both methods; the streams-API stream-count check is Method-A-only.
- **Lease 6s/4s/1s** — shortened from research's 15/10/2 for fast demo failover.
- **Method C run mode** — `connect run` expands `${POD_NAME}` at config load (the streams
  REST API does not — that trap is Method A's, §3.5).

## Deliberately excluded

- SIGSTOP and node-NotReady faults (would expose A's overlap / C's stall) — named above.
- JetStream dedup, sink CAS, region Redis — the parent fork's concern.
- Method B; strict-ordering knobs (`max_in_flight`, partition-by-key).

## Further reading

- `../../active-stanby-mechanism/research.md` — Method A (§3), Method C (§5), the
  best-effort-not-fencing thesis (§0–§2).
- `../redis-connect-leader-election-k8s/` — the Method-A-only lab this forks.
```

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-failover-ab-k8s/README.md labs/redis-connect-failover-ab-k8s/RESEARCH.md
git commit -m "failover-ab-k8s: README + RESEARCH for A-vs-C comparison"
```

---

## Task 8: End-to-end validation on kind

This task produces the populated comparison table — the lab's acceptance gate. No code
changes; if a step fails, fix the relevant earlier task and re-run.

**Files:** none (validation only).

- [ ] **Step 1: Ensure a kind cluster exists and build/load images**

```bash
cd labs/redis-connect-failover-ab-k8s
kind get clusters | grep -qx lel || kind create cluster --name lel
scripts/build-images.sh --kind --kind-name=lel
```
Expected: writer/elector/observer/dashboard images built and `kind load`ed without error.

- [ ] **Step 2: Run the comparison harness**

```bash
scripts/verify-failover.sh
```
Expected: the run boots method A, prints a steady `single_active=true`, measures both
faults; then boots method C and does the same; finally prints the COMPARISON table with
`at_most_1_held = yes` on all four rows and non-empty `failover_time_s` values, ending
with `[verify-failover] PASS`. Exit code 0.

- [ ] **Step 3: Sanity-check the headline finding**

Confirm in the printed table that Method C's `failover_time_s` is ≥ Method A's for the
same fault (C pays connect cold-start). If C is dramatically larger than `FAULT_WAIT_S`,
the window was too short — re-run with `FAULT_WAIT_S=30`. Record the observed numbers in
the commit message of the next step.

- [ ] **Step 4: Capture the validated result in RESEARCH.md**

Append a `## Validated result (kind)` section to `RESEARCH.md` with the actual table from
Step 2 (the four rows and the PASS line), then commit:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-failover-ab-k8s/RESEARCH.md
git commit -m "failover-ab-k8s: record validated A-vs-C failover result (kind)"
```

- [ ] **Step 5: (Optional) Teardown**

```bash
helm uninstall lel -n lel-k8s || true
# keep the kind cluster for re-runs, or: kind delete cluster --name lel
```

---

## Self-Review

**Spec coverage:**
- Remove LWW → Task 2 (writer) + Task 5 step 1/8 (chart env). ✓
- Method A path → preserved in Task 5 (gated Deployment + elector + RBAC). ✓
- Method C path → Task 4 (pipeline) + Task 5 (StatefulSet, ConfigMap, no RBAC). ✓
- Counter-based observer / REQUIRE_STREAM_COUNT → Task 3 + Task 5 step 7. ✓
- Failover time = gap_pairs × interval → Task 6 (`measure_fault`). ✓
- Robustness = overlap_pairs==0 / at_most_1_held → Task 6 table + exit code. ✓
- Fault matrix graceful + force delete → Task 6 (`measure_fault` two kinds). ✓
- Comparison table deliverable → Task 6 + Task 8. ✓
- Honest scope note (A overlap not exposed; SIGSTOP out of scope) → Task 7 RESEARCH. ✓
- Single-chart toggle (approach 1) → Task 5. ✓
- Validation note (no docker-compose validate_lab) → Task 7 README. ✓

**Placeholder scan:** Table cells `~X.X/~Y.Y/~Z.Z` are intentional *expected-output*
illustrations in docs, replaced by real numbers in Task 8 step 4 — not plan placeholders.
No TODO/TBD/"handle edge cases" in any executable step. ✓

**Type consistency:** `Run` type + `NewRun()`/`SetEpoch()`/`Epoch()`/`State()`/`BootID()`
used consistently across run.go, run_test.go, worker.go (`w.Run`), main.go (`run`),
http.go (`s.Run`), http_test.go. Worker loop method renamed `Loop` everywhere (worker.go
defines it, main.go calls `w.Loop`). `SingleActive(series, bool)` updated in timeline.go,
all timeline_test.go callers, and main.go `/verdict`. ConfigMap name `connect-pipeline-c`
matches between connect-config.yaml (creates) and connect-statefulset.yaml (mounts).
Headless service `connect-headless` rendered once (connect-service.yaml) and referenced by
the StatefulSet `serviceName` and the observer `CONNECT_HEADLESS` env. ✓
```
