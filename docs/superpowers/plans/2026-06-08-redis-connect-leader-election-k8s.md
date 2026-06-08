# redis-connect-leader-election-k8s Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Kubernetes lab proving that a self-written client-go leader-election controller makes exactly one of N=3 Redpanda Connect pods consume a Redis stream under steady state, and measure both best-effort failure windows (dual-active overlap via SIGSTOP, zero-active gap via force-kill) — demonstrating active-gating is **not** fencing.

**Architecture:** Fork `labs/redis-connect-lww-k8s`, strip it to the source leg only (drop NATS/JetStream/sink-CAS/region/LWW-verifier). Connect runs in **streams mode** (empty boot) with a per-pod `elector` sidecar (Go, `k8s.io/client-go/tools/leaderelection`) that POST/DELETEs the consuming pipeline against local `:4195` on leadership transitions, fail-closed. Each consumed message does `INCR consumed:<pod>` in Redis for per-pod attribution. An in-cluster `observer` (Go) samples per-pod counters + each pod's `/streams` count every 100ms and serves a timeline + verdict math over a headless service. `scripts/verify-election.sh` orchestrates faults (reads the Lease `holderIdentity` to target the leader) and asserts the three proofs.

**Tech Stack:** Go 1.25 (elector, observer, reused writer/dashboard), Helm, kind, Redpanda Connect streams mode + REST API, Redis 7, `k8s.io/client-go` leaderelection + `coordination.k8s.io/v1` Lease.

---

## File Structure

New lab at `labs/redis-connect-leader-election-k8s/`:

```
labs/redis-connect-leader-election-k8s/
  README.md                         # NEW (Task 17)
  RESEARCH.md                       # NEW (Task 16)
  .gitignore                        # copied from fork
  chart/
    Chart.yaml                      # renamed (Task 1)
    values.yaml                     # rewritten — no NATS (Task 7)
    values-dev.yaml                 # rewritten (Task 7)
    templates/
      _helpers.tpl                  # trimmed — drop NATS/region helpers (Task 2)
      redis-central.yaml            # reused as-is (Task 1)
      writer.yaml                   # reused, drop wait-connect-source init (Task 6)
      connect-elector.yaml          # NEW — Deployment(replicas:3) connect+elector, +headless svc (Task 8)
      rbac.yaml                     # NEW — SA + Role/RoleBinding for leases (Task 8)
      connect-config.yaml           # NEW — ConfigMaps: observability + pipeline (Task 8)
      observer.yaml                 # NEW — Deployment + headless svc (Task 12)
      dashboard.yaml                # reused, repointed env (Task 14)
      NOTES.txt                     # trimmed (Task 1)
    files/connect/
      observability.yaml            # NEW — connect -o config (metrics/logger) (Task 8)
      pipeline.yaml                 # NEW — the POSTed redis_streams->INCR stream (Task 8)
  elector/                          # NEW Go module (Tasks 3-5)
    go.mod  go.sum
    Dockerfile
    main.go                         # leaderelection wiring + lifecycle
    streams.go                      # POST/DELETE client + __POD__ substitution
    streams_test.go
  observer/                         # NEW Go module (Tasks 9-11)
    go.mod  go.sum
    Dockerfile
    main.go                         # sampler + HTTP (/timeline /verdict /healthz)
    timeline.go                     # pure verdict math
    timeline_test.go
  writer/                           # copied verbatim from fork (Task 6)
  dashboard/                        # copied, index.html + main.go repointed (Task 14)
  scripts/
    build-images.sh                 # adapted: writer/observer/dashboard/elector (Task 15)
    render.sh                       # reused, default profile dropped (Task 15)
    dashboard-forward.sh            # reused as-is (Task 15)
    verify-election.sh              # NEW — Proof A/B1/B2 orchestrator (Task 15)
    lib/run-defaults.sh             # rewritten (Task 15)
```

**Pre-req verification (Task 0)** confirms the connect image's `streams` subcommand and REST API content-type before any chart work.

Throughout, the chart keeps the fork's `rrcs.name`/`rrcs.image`/`rrcs.pullPolicy`/`rrcs.imagePullSecrets`/`rrcs.scheduling` helpers and the `resourcePrefix: "lab-"` convention. All resource names flow through `rrcs.name`.

---

## Task 0: Verify connect image streams mode + REST API

**Files:** none (investigation; record findings in a scratch note used by later tasks).

- [ ] **Step 1: Confirm the `streams` subcommand exists**

Run:
```bash
docker run --rm hpdevelop/connect:4.92.0-claudefix streams --help 2>&1 | head -30
```
Expected: help text for streams mode (mentions serving the streams API / `--no-api` etc). If the subcommand is absent, STOP and report — the whole lab depends on it.

- [ ] **Step 2: Confirm streams REST API accepts a config and lists streams**

Run (boots streams mode with no streams, then drives the API):
```bash
docker run --rm -d --name lectest -p 14195:4195 hpdevelop/connect:4.92.0-claudefix streams
sleep 3
# empty boot => zero streams
curl -s localhost:14195/streams
# create a trivial stream from YAML body
curl -s -XPOST localhost:14195/streams/probe \
  -H 'Content-Type: application/x-yaml' \
  --data-binary $'input:\n  generate:\n    interval: 1s\n    mapping: "root.x = 1"\noutput:\n  drop: {}\n'
echo; curl -s localhost:14195/streams         # probe now present
curl -s -XDELETE localhost:14195/streams/probe; echo
curl -s localhost:14195/streams               # empty again
docker rm -f lectest
```
Expected: first `/streams` is `{}` (or empty), POST returns 200, second `/streams` shows `probe`, DELETE returns 200, final `/streams` empty.

- [ ] **Step 3: Record the working content-type**

Note which `Content-Type` succeeded (`application/x-yaml` expected; fall back to converting YAML→JSON with `Content-Type: application/json` if YAML is rejected). The elector in Task 4 MUST use the content-type confirmed here. Write the result into a one-line comment at the top of `elector/streams.go` when you create it.

- [ ] **Step 4: Commit (no code yet — skip).** Proceed to Task 1.

---

## Task 1: Scaffold lab directory from fork (copy + prune)

**Files:**
- Create dir: `labs/redis-connect-leader-election-k8s/`
- Copy from: `labs/redis-connect-lww-k8s/`

- [ ] **Step 1: Copy the fork, then delete what we drop**

Run from repo root (the worktree):
```bash
cd labs
cp -r redis-connect-lww-k8s redis-connect-leader-election-k8s
cd redis-connect-leader-election-k8s
# drop NATS, sink, region, LWW verifier, LWW connect configs, old reports/out
rm -rf verifier reports out
rm -rf chart/files/nats-auth
rm -f  chart/templates/nats.yaml chart/templates/nats-config-cm.yaml \
       chart/templates/nats-init-job.yaml chart/templates/nats-auth-secrets.yaml \
       chart/templates/connect-sink.yaml chart/templates/connect-source.yaml \
       chart/templates/connect-configmaps.yaml chart/templates/redis-region.yaml \
       chart/templates/verifier-job.yaml
rm -f  chart/files/connect/lww-forward.yaml chart/files/connect/lww-reverse.yaml \
       chart/files/connect/lww_set.lua
rm -f  scripts/gen-nats-auth.sh scripts/gen-report.sh scripts/verify-lww.sh
rm -f  values-external.yaml.example
rm -rf docs   # fork's lab-local docs; this lab documents in RESEARCH.md/README.md
```

- [ ] **Step 2: Rename the chart**

Edit `chart/Chart.yaml` — set:
```yaml
apiVersion: v2
name: redis-connect-leader-election-k8s
description: Best-effort active-gating PoC — client-go leader election in front of Redpanda Connect streams mode
type: application
version: 0.1.0
appVersion: "1.0.0"
```

- [ ] **Step 3: Replace NOTES.txt with a minimal note**

Overwrite `chart/templates/NOTES.txt`:
```
redis-connect-leader-election-k8s installed.

N connect pods run streams mode (empty boot); each has an elector sidecar that
POSTs the consuming pipeline only while it holds the Lease. Verify with:

  scripts/verify-election.sh

Watch live:  scripts/dashboard-forward.sh  -> http://<host>:8080
```

- [ ] **Step 4: Verify the tree is what we expect**

Run:
```bash
find chart -type f | sort
ls scripts writer dashboard
```
Expected: no `nats*`, no `connect-sink/source`, no `verifier`, no `lww_*`. `writer/` and `dashboard/` present.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-connect-leader-election-k8s
git commit -m "leader-election-k8s: scaffold from lww fork, prune NATS/sink/region/verifier"
```

---

## Task 2: Trim chart helpers to the source leg

**Files:**
- Modify: `labs/redis-connect-leader-election-k8s/chart/templates/_helpers.tpl`

- [ ] **Step 1: Delete NATS and region helpers**

Remove these defines entirely from `_helpers.tpl` (they reference dropped values and would error on render): `rrcs.nats.url`, `rrcs.nats.monitorUrl`, `rrcs.redis.region.url`, `rrcs.redis.region.hostPort`, `rrcs.nats.stream.subjects`, `rrcs.nats.stream.publishSubject`, `rrcs.nats.credsSecret.publisher`, `rrcs.nats.credsSecret.subscriber`, `rrcs.nats.credsSecret.admin`.

Keep: `rrcs.image`, `rrcs.pullPolicy`, `rrcs.imagePullSecrets`, `rrcs.scheduling`, `rrcs.redis.central.url`, `rrcs.redis.central.hostPort`, `rrcs.name`.

- [ ] **Step 2: Verify nothing else references the removed helpers**

Run:
```bash
cd labs/redis-connect-leader-election-k8s
grep -rn "rrcs.nats\|rrcs.redis.region" chart/ || echo "clean"
```
Expected: `clean` (templates referencing them were deleted in Task 1; if any remain, they belong to a file we keep — fix in its task).

- [ ] **Step 3: Commit**

```bash
git add chart/templates/_helpers.tpl
git commit -m "leader-election-k8s: trim helpers to source leg (drop NATS/region)"
```

---

## Task 3: Elector — Go module + streams client with TDD

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/elector/go.mod`
- Create: `labs/redis-connect-leader-election-k8s/elector/streams.go`
- Create: `labs/redis-connect-leader-election-k8s/elector/streams_test.go`

- [ ] **Step 1: Init the module**

Run:
```bash
cd labs/redis-connect-leader-election-k8s/elector
cat > go.mod <<'EOF'
module elector

go 1.25.0
EOF
```

- [ ] **Step 2: Write the failing test for pod-name substitution**

Create `streams_test.go`:
```go
package main

import "testing"

func TestRenderPipeline(t *testing.T) {
	tmpl := "processors:\n  - redis:\n      args_mapping: 'root = [\"consumed:__POD__\"]'\n"
	got := renderPipeline(tmpl, "connect-xyz-0")
	want := "processors:\n  - redis:\n      args_mapping: 'root = [\"consumed:connect-xyz-0\"]'\n"
	if got != want {
		t.Fatalf("renderPipeline:\n got=%q\nwant=%q", got, want)
	}
}

func TestRenderPipelineReplacesAll(t *testing.T) {
	got := renderPipeline("__POD__ and __POD__", "p1")
	if got != "p1 and p1" {
		t.Fatalf("want all replaced, got %q", got)
	}
}
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `go test ./...`
Expected: FAIL — `undefined: renderPipeline`.

- [ ] **Step 4: Write the streams client + substitution**

Create `streams.go` (set the Content-Type to whatever Task 0 confirmed; `application/x-yaml` shown):
```go
// Streams REST client for Redpanda Connect streams mode.
// Content-Type confirmed working against hpdevelop/connect:4.92.0-claudefix in Task 0: application/x-yaml
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// renderPipeline substitutes the literal pod name for the __POD__ placeholder.
// We substitute in the controller (not via env interpolation) because the streams
// REST API does NOT expand environment variables in POSTed configs (research §3.5).
func renderPipeline(tmpl, podName string) string {
	return strings.ReplaceAll(tmpl, "__POD__", podName)
}

type streamsClient struct {
	base string // e.g. http://localhost:4195
	hc   *http.Client
}

func newStreamsClient(base string) *streamsClient {
	return &streamsClient{base: strings.TrimRight(base, "/"), hc: &http.Client{Timeout: 5 * time.Second}}
}

func (c *streamsClient) post(ctx context.Context, id, configYAML string) error {
	url := fmt.Sprintf("%s/streams/%s", c.base, id)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBufferString(configYAML))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-yaml")
	return c.do(req)
}

func (c *streamsClient) delete(ctx context.Context, id string) error {
	url := fmt.Sprintf("%s/streams/%s", c.base, id)
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, url, nil)
	if err != nil {
		return err
	}
	return c.do(req)
}

func (c *streamsClient) do(req *http.Request) error {
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	// DELETE of a non-existent stream returns 404 — treat as already-absent (idempotent).
	if req.Method == http.MethodDelete && resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s -> %d: %s", req.Method, req.URL.Path, resp.StatusCode, string(body))
	}
	return nil
}

// retry runs fn up to n times with a fixed delay, returning the last error.
func retry(ctx context.Context, n int, delay time.Duration, fn func() error) error {
	var err error
	for i := 0; i < n; i++ {
		if err = fn(); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return err
}
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `go test ./...`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add elector/go.mod elector/streams.go elector/streams_test.go
git commit -m "leader-election-k8s: elector streams client + pod-name substitution (TDD)"
```

---

## Task 4: Elector — leaderelection main with fail-closed lifecycle

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/elector/main.go`
- Modify: `labs/redis-connect-leader-election-k8s/elector/go.mod` (add client-go)

- [ ] **Step 1: Write main.go**

Create `main.go`:
```go
// elector: a fail-closed client-go leader-election controller (research Method A, §3.1-3.3).
//
// Default state = NO stream. POST the consuming pipeline only while leading; on any
// uncertainty DELETE or exit so the stream dies with the process. Order/uniqueness must
// NOT depend on this — it is best-effort active-gating, not fencing.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"sync/atomic"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envDur(k string, def time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
		log.Printf("WARN: %s=%q not a duration, using %s", k, os.Getenv(k), def)
	}
	return def
}

func main() {
	var (
		podName     = env("POD_NAME", "")
		namespace   = env("LEASE_NAMESPACE", "default")
		leaseName   = env("LEASE_NAME", "connect-elector")
		connectAddr = env("CONNECT_ADDR", "http://localhost:4195")
		streamID    = env("STREAM_ID", "source_leg")
		pipePath    = env("PIPELINE_PATH", "/etc/elector/pipeline.yaml")
		healthAddr  = env("HEALTH_ADDR", ":8090")
		leaseDur    = envDur("LEASE_DURATION", 6*time.Second)
		renewDl     = envDur("RENEW_DEADLINE", 4*time.Second)
		retryPd     = envDur("RETRY_PERIOD", 1*time.Second)
	)
	if podName == "" {
		log.Fatal("POD_NAME is required (downward API)")
	}

	raw, err := os.ReadFile(pipePath)
	if err != nil {
		log.Fatalf("read pipeline %s: %v", pipePath, err)
	}
	pipelineYAML := renderPipeline(string(raw), podName)

	sc := newStreamsClient(connectAddr)

	// fail-closed metrics
	var (
		leading       atomic.Int32
		postOK, postE atomic.Int64
		delOK, delE   atomic.Int64
	)

	// Health + metrics endpoint (research §8).
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		writeMetric(w, "elector_leading", float64(leading.Load()))
		writeMetric(w, "elector_post_total{result=\"ok\"}", float64(postOK.Load()))
		writeMetric(w, "elector_post_total{result=\"err\"}", float64(postE.Load()))
		writeMetric(w, "elector_delete_total{result=\"ok\"}", float64(delOK.Load()))
		writeMetric(w, "elector_delete_total{result=\"err\"}", float64(delE.Load()))
	})
	go func() {
		log.Printf("elector health/metrics on %s", healthAddr)
		if err := http.ListenAndServe(healthAddr, mux); err != nil {
			log.Printf("health server: %v", err)
		}
	}()

	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("in-cluster config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("k8s client: %v", err)
	}

	// FAIL-CLOSED BOOT (research §3.2 row 1): before anything, ensure no residual stream.
	bootCtx, bootCancel := context.WithTimeout(context.Background(), 10*time.Second)
	if err := retry(bootCtx, 30, retryPd, func() error { return sc.delete(bootCtx, streamID) }); err != nil {
		log.Printf("boot DELETE (best-effort): %v", err)
	}
	bootCancel()
	log.Printf("boot: ensured no local stream; entering election as %q", podName)

	lock := &resourcelock.LeaseLock{
		LeaseMeta: metav1.ObjectMeta{Name: leaseName, Namespace: namespace},
		Client:    client.CoordinationV1(),
		LockConfig: resourcelock.ResourceLockConfig{Identity: podName},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
		Lock:            lock,
		ReleaseOnCancel: true, // release lease on exit -> shorten dual-active window
		LeaseDuration:   leaseDur,
		RenewDeadline:   renewDl,
		RetryPeriod:     retryPd,
		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: func(c context.Context) {
				log.Printf("OnStartedLeading: POST stream %q", streamID)
				if err := retry(c, 10, retryPd, func() error { return sc.post(c, streamID, pipelineYAML) }); err != nil {
					postE.Add(1)
					log.Printf("POST kept failing (%v) -> releasing leadership, staying fail-closed", err)
					cancel() // give up leadership; another pod will try
					return
				}
				postOK.Add(1)
				leading.Store(1)
			},
			OnStoppedLeading: func() {
				leading.Store(0)
				log.Printf("OnStoppedLeading: DELETE stream %q", streamID)
				dc, dcl := context.WithTimeout(context.Background(), 8*time.Second)
				defer dcl()
				if err := retry(dc, 8, retryPd, func() error { return sc.delete(dc, streamID) }); err != nil {
					delE.Add(1)
					log.Printf("DELETE kept failing (%v) -> os.Exit(1) so kubelet restarts the pod and the stream dies with it", err)
					os.Exit(1)
				}
				delOK.Add(1)
			},
			OnNewLeader: func(id string) {
				if id != podName {
					log.Printf("new leader: %s", id)
				}
			},
		},
	})
	log.Printf("election loop exited; bye")
	_ = exec.Command // keep import if unused in some builds
	_ = strconv.Itoa
}

func writeMetric(w http.ResponseWriter, name string, v float64) {
	_, _ = w.Write([]byte(name + " " + strconv.FormatFloat(v, 'f', -1, 64) + "\n"))
}
```

> Note: remove the two `_ = ...` no-op lines and the `os/exec`/`strconv` imports if your linter flags them; `strconv` is used by `writeMetric` so keep it, drop `os/exec`.

- [ ] **Step 2: Resolve dependencies**

Run:
```bash
cd labs/redis-connect-leader-election-k8s/elector
go get k8s.io/client-go@v0.31.0 k8s.io/apimachinery@v0.31.0
go mod tidy
```
Expected: `go.mod`/`go.sum` populated with client-go + transitive deps.

- [ ] **Step 3: Build to verify it compiles**

Run: `go build ./... && go test ./...`
Expected: build succeeds; the 2 streams tests still PASS.

- [ ] **Step 4: Commit**

```bash
git add elector/main.go elector/go.mod elector/go.sum
git commit -m "leader-election-k8s: elector leaderelection main (fail-closed lifecycle)"
```

---

## Task 5: Elector — Dockerfile with non-PID-1 init (tini)

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/elector/Dockerfile`

- [ ] **Step 1: Write the Dockerfile**

The controller MUST NOT be PID 1 (Proof B1 SIGSTOPs it; SIG_DFL signals are not delivered to PID 1 in a namespace). Run it under `tini` so it is a normal child PID.

Create `Dockerfile`:
```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/elector .

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
RUN apk add --no-cache tini ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/elector /usr/local/bin/elector
# tini is PID 1; elector is a child PID so SIGSTOP/SIGCONT (Proof B1) act on it.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/elector"]
```

- [ ] **Step 2: Build the image to verify**

Run:
```bash
cd labs/redis-connect-leader-election-k8s/elector
docker build -t redis-rrcs/elector:dev .
```
Expected: image builds.

- [ ] **Step 3: Confirm elector is a child of tini (not PID 1)**

Run:
```bash
docker run --rm --entrypoint /bin/sh redis-rrcs/elector:dev -c '/sbin/tini -- sleep 1 & sleep 0.2; ps -o pid,comm'
```
Expected: `tini` appears as a low PID and child processes are separate PIDs (sanity check of the init shim; the real elector needs k8s so we don't run it here).

- [ ] **Step 4: Commit**

```bash
git add elector/Dockerfile
git commit -m "leader-election-k8s: elector Dockerfile (tini init so controller is not PID 1)"
```

---

## Task 6: Reuse writer; drop its connect-source wait

**Files:**
- Modify: `labs/redis-connect-leader-election-k8s/chart/templates/writer.yaml:N` (remove `wait-connect-source` init container)

(`writer/` Go sources were copied verbatim in Task 1 and are unchanged — the version field is harmless; YAGNI, don't rewrite working tested code.)

- [ ] **Step 1: Remove the connect-source readiness gate**

In `chart/templates/writer.yaml`, delete the `wait-connect-source` initContainer block (the one that `wget --spider http://...connect-source...:4195/ready`). The writer only needs `redis-central` up; connect pods consume independently. Keep the `wait-redis-central` initContainer.

- [ ] **Step 2: Verify writer template no longer references connect-source**

Run:
```bash
cd labs/redis-connect-leader-election-k8s
grep -n "connect-source" chart/templates/writer.yaml || echo "clean"
```
Expected: `clean`.

- [ ] **Step 3: Commit**

```bash
git add chart/templates/writer.yaml
git commit -m "leader-election-k8s: writer waits only on redis-central"
```

---

## Task 7: Chart values without NATS

**Files:**
- Modify: `labs/redis-connect-leader-election-k8s/chart/values.yaml` (rewrite)
- Modify: `labs/redis-connect-leader-election-k8s/chart/values-dev.yaml` (rewrite)

- [ ] **Step 1: Rewrite `chart/values.yaml`**

Replace the whole file with (drops `profile`, `nats`, `natsBox`, `redis.region`, `verifier`; adds `connect.replicas`, `elector`, `observer`):
```yaml
# Prefix prepended to every chart-rendered resource name (see rrcs.name helper).
resourcePrefix: "lab-"

images:
  registry: ""
  pullPolicy: IfNotPresent
  pullSecrets: []

redis:
  image: redis:7.4-alpine
  central:
    external:
      enabled: false
      url: ""
      authSecret: ""   # RESERVED — not consumed in v1

connect:
  image: hpdevelop/connect:4.92.0-claudefix
  replicas: 3
  streamID: source_leg
  # Lease timings — same algorithm as research's 15/10/2, shortened for fast demo failover.
  lease:
    name: connect-elector
    duration: 6s
    renewDeadline: 4s
    retryPeriod: 1s

elector:
  image: redis-rrcs/elector:dev
  pullPolicy: ""

observer:
  image: redis-rrcs/observer:dev
  pullPolicy: ""
  sampleIntervalMs: 100

writer:
  image: redis-rrcs/writer:dev
  pullPolicy: ""
  env:
    STREAM_MAXLEN: "100000"
    WORKERS: "8"
    PIPELINE_DEPTH: "50"
    # Keyspace is irrelevant to gating (no LWW here); keep modest.
    KEY_SPACE_SIZE: "1000"
    PAYLOAD_BYTES: "200"
    MAX_RATE: "20000"

dashboard:
  image: redis-rrcs/dashboard:dev
  pullPolicy: ""

scheduling:
  nodeSelector: {}
  tolerations: []
  affinity: {}

resources:
  redis:
    requests: { cpu: 250m, memory: 128Mi }
    limits:   { cpu: "2",  memory: 512Mi }
  connect:
    requests: { cpu: 250m, memory: 256Mi }
    limits:   { cpu: "2",  memory: 1Gi }
  elector:
    requests: { cpu: 50m,  memory: 32Mi }
    limits:   { cpu: 500m, memory: 128Mi }
  observer:
    requests: { cpu: 100m, memory: 64Mi }
    limits:   { cpu: 500m, memory: 128Mi }
  writer:
    requests: { cpu: 250m, memory: 64Mi }
    limits:   { cpu: "2",  memory: 256Mi }
  dashboard:
    requests: { cpu: 100m, memory: 64Mi }
    limits:   { cpu: 500m, memory: 128Mi }
```

- [ ] **Step 2: Rewrite `chart/values-dev.yaml`**

Inspect the fork's `chart/values-dev.yaml` first (`cat chart/values-dev.yaml`), then replace with a dev-only override that keeps the same intent (pullPolicy/resources tuning for kind) but removes any `nats`/`profile`/`verifier`/`region` keys. Minimum viable content:
```yaml
# Dev overrides for local kind runs.
images:
  pullPolicy: IfNotPresent
connect:
  replicas: 3
```

- [ ] **Step 3: Commit**

```bash
git add chart/values.yaml chart/values-dev.yaml
git commit -m "leader-election-k8s: chart values without NATS (add connect.replicas/elector/observer)"
```

---

## Task 8: Connect streams Deployment + elector sidecar + RBAC + configs

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/chart/templates/rbac.yaml`
- Create: `labs/redis-connect-leader-election-k8s/chart/templates/connect-config.yaml`
- Create: `labs/redis-connect-leader-election-k8s/chart/files/connect/observability.yaml`
- Create: `labs/redis-connect-leader-election-k8s/chart/files/connect/pipeline.yaml`
- Create: `labs/redis-connect-leader-election-k8s/chart/templates/connect-elector.yaml`

- [ ] **Step 1: RBAC (research §4) — SA + Role + RoleBinding for leases**

Create `chart/templates/rbac.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-elector") }}
  labels: { app: connect }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-elector") }}
  labels: { app: connect }
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-elector") }}
  labels: { app: connect }
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-elector") }}
subjects:
  - kind: ServiceAccount
    name: {{ include "rrcs.name" (dict "root" $ "base" "connect-elector") }}
```

- [ ] **Step 2: Observability config for streams mode (`-o`)**

Create `chart/files/connect/observability.yaml` (resources/metrics live here, NOT in the POSTed stream — research §3.5 trap 3):
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
```

- [ ] **Step 3: The POSTed pipeline (redis_streams -> INCR consumed:<pod>)**

Create `chart/files/connect/pipeline.yaml`. `__POD__` is substituted by the elector before POST (env interpolation is unavailable in streams configs — research §3.5 trap 1). The `redis` processor runs `INCR`; output drops (we only want the consumer-group consumption + counter side effect).
```yaml
input:
  label: redis_source
  redis_streams:
    url: {{ include "rrcs.redis.central.url" . }}
    kind: simple
    streams: [app.events]
    consumer_group: electors
    client_id: __POD__
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
        args_mapping: 'root = [ "consumed:__POD__" ]'
output:
  label: drop_sink
  drop: {}
```
> This file is rendered by Helm (`tpl`) into a ConfigMap, so `{{ include ... }}` resolves at install time; `__POD__` survives Helm and is replaced by the elector at POST time.

- [ ] **Step 4: ConfigMaps for observability + pipeline**

Create `chart/templates/connect-config.yaml`:
```yaml
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
```

- [ ] **Step 5: Connect Deployment (replicas:3) with elector sidecar + headless service**

Create `chart/templates/connect-elector.yaml`:
```yaml
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
---
# Headless service: DNS returns ALL connect pod IPs so the observer can scrape each
# pod's /streams without the K8s API.
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

- [ ] **Step 6: Render the chart to verify it templates**

Run:
```bash
cd labs/redis-connect-leader-election-k8s
helm template lel ./chart -n lel-k8s -f chart/values-dev.yaml > /tmp/lel.yaml && echo "rendered $(grep -c '^kind:' /tmp/lel.yaml) objects"
grep -A2 'kind: Role' /tmp/lel.yaml | head
grep '__POD__' /tmp/lel.yaml   # must still be present (substituted at runtime, not by Helm)
```
Expected: render succeeds; Role present; `__POD__` appears in the connect-pipeline ConfigMap (proves Helm left it for the elector).

- [ ] **Step 7: Commit**

```bash
git add chart/templates/rbac.yaml chart/templates/connect-config.yaml \
        chart/templates/connect-elector.yaml chart/files/connect/observability.yaml \
        chart/files/connect/pipeline.yaml
git commit -m "leader-election-k8s: connect streams Deployment + elector sidecar + RBAC + configs"
```

---

## Task 9: Observer — Go module + verdict math with TDD

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/observer/go.mod`
- Create: `labs/redis-connect-leader-election-k8s/observer/timeline.go`
- Create: `labs/redis-connect-leader-election-k8s/observer/timeline_test.go`

- [ ] **Step 1: Init module**

```bash
cd labs/redis-connect-leader-election-k8s/observer
cat > go.mod <<'EOF'
module observer

go 1.25.0
EOF
```

- [ ] **Step 2: Write failing tests for the verdict math**

Create `timeline_test.go`:
```go
package main

import "testing"

// helper: build a sample with a per-pod consumed map and active-stream total.
func s(consumed map[string]int64, active int) Sample {
	return Sample{Consumed: consumed, ActiveStreams: active}
}

func TestSingleActive_AllOnePodRising(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"a": 10, "b": 0, "c": 0}, 1),
		s(map[string]int64{"a": 20, "b": 0, "c": 0}, 1),
		s(map[string]int64{"a": 30, "b": 0, "c": 0}, 1),
	}
	if !SingleActive(series) {
		t.Fatal("expected single-active for one pod rising with active==1")
	}
}

func TestSingleActive_FalseWhenTwoRise(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"a": 10, "b": 5}, 2),
		s(map[string]int64{"a": 20, "b": 9}, 2),
	}
	if SingleActive(series) {
		t.Fatal("expected NOT single-active when two pods rise")
	}
}

func TestOverlapPairs_LongestRun(t *testing.T) {
	// pairs where >=2 pods increased: between idx1-2 and idx2-3 (two consecutive pairs).
	series := []Sample{
		s(map[string]int64{"a": 0, "b": 0}, 1),  // 0
		s(map[string]int64{"a": 10, "b": 0}, 1), // a rose only
		s(map[string]int64{"a": 20, "b": 5}, 2), // a,b rose  <- overlap pair #1
		s(map[string]int64{"a": 30, "b": 9}, 2), // a,b rose  <- overlap pair #2
		s(map[string]int64{"a": 40, "b": 9}, 1), // a rose only
	}
	got := OverlapPairs(series)
	if got != 2 {
		t.Fatalf("OverlapPairs = %d, want 2", got)
	}
}

func TestGapPairs_NoTotalIncrease(t *testing.T) {
	// pairs where total did not increase: idx1-2 and idx2-3.
	series := []Sample{
		s(map[string]int64{"a": 10}, 1), // 0
		s(map[string]int64{"a": 10}, 0), // flat <- gap pair #1
		s(map[string]int64{"a": 10}, 0), // flat <- gap pair #2
		s(map[string]int64{"a": 25}, 1), // rose
	}
	got := GapPairs(series)
	if got != 2 {
		t.Fatalf("GapPairs = %d, want 2", got)
	}
}
```

- [ ] **Step 3: Run tests, verify they fail**

Run: `go test ./...`
Expected: FAIL — `undefined: Sample/SingleActive/OverlapPairs/GapPairs`.

- [ ] **Step 4: Implement the math**

Create `timeline.go`:
```go
package main

import "time"

// Sample is one observation of the cluster at time T.
type Sample struct {
	T             time.Time        `json:"t"`
	Consumed      map[string]int64 `json:"consumed"`       // pod -> consumed counter
	ActiveStreams int              `json:"active_streams"` // sum of /streams counts across pods
}

// roseCount returns how many pods strictly increased their counter from a to b.
func roseCount(a, b Sample) int {
	n := 0
	for pod, bv := range b.Consumed {
		if bv > a.Consumed[pod] {
			n++
		}
	}
	return n
}

// total sums all per-pod counters in a sample.
func total(s Sample) int64 {
	var t int64
	for _, v := range s.Consumed {
		t += v
	}
	return t
}

// SingleActive is true iff every consecutive pair has exactly one pod rising AND
// every sample reports exactly one active stream. This is steady-state Proof A.
func SingleActive(series []Sample) bool {
	if len(series) < 2 {
		return false
	}
	for _, s := range series {
		if s.ActiveStreams != 1 {
			return false
		}
	}
	for i := 1; i < len(series); i++ {
		if roseCount(series[i-1], series[i]) != 1 {
			return false
		}
	}
	return true
}

// OverlapPairs counts consecutive sample-pairs where >=2 distinct pods' counters
// rose simultaneously — the measured dual-active window (Proof B1).
func OverlapPairs(series []Sample) int {
	n := 0
	for i := 1; i < len(series); i++ {
		if roseCount(series[i-1], series[i]) >= 2 {
			n++
		}
	}
	return n
}

// GapPairs counts consecutive sample-pairs where the grand total did not increase
// — the measured zero-active window (Proof B2). Caller ensures the writer is sending.
func GapPairs(series []Sample) int {
	n := 0
	for i := 1; i < len(series); i++ {
		if total(series[i]) <= total(series[i-1]) {
			n++
		}
	}
	return n
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `go test ./...`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add observer/go.mod observer/timeline.go observer/timeline_test.go
git commit -m "leader-election-k8s: observer verdict math (single-active/overlap/gap) TDD"
```

---

## Task 10: Observer — sampler + HTTP server

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/observer/main.go`
- Modify: `labs/redis-connect-leader-election-k8s/observer/go.mod` (add go-redis)

- [ ] **Step 1: Write main.go**

Create `main.go`:
```go
// observer: samples per-pod consumed:* counters (from redis-central) and each connect
// pod's /streams count (via the headless service) every interval, keeps a ring buffer,
// and serves /timeline + /verdict + /healthz. No K8s API/RBAC needed (uses DNS).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

type ring struct {
	mu      sync.RWMutex
	samples []Sample
	max     int
}

func (r *ring) add(s Sample) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.samples = append(r.samples, s)
	if len(r.samples) > r.max {
		r.samples = r.samples[len(r.samples)-r.max:]
	}
}

// since returns samples at/after t (copy).
func (r *ring) since(t time.Time) []Sample {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := []Sample{}
	for _, s := range r.samples {
		if !s.T.Before(t) {
			out = append(out, s)
		}
	}
	return out
}

func main() {
	var (
		redisAddr    = env("REDIS_ADDR", "lab-redis-central:6379")
		connectHost  = env("CONNECT_HEADLESS", "lab-connect-headless")
		connectPort  = env("CONNECT_PORT", "4195")
		listen       = env("LISTEN_ADDR", ":8070")
		intervalMs, _ = strconv.Atoi(env("SAMPLE_INTERVAL_MS", "100"))
	)
	if intervalMs <= 0 {
		intervalMs = 100
	}
	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	hc := &http.Client{Timeout: 1 * time.Second}
	rb := &ring{max: 36000} // ~1h at 100ms

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		tick := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				rb.add(sampleOnce(ctx, rdb, hc, connectHost, connectPort))
			}
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/timeline", func(w http.ResponseWriter, r *http.Request) {
		t := parseSince(r)
		writeJSON(w, rb.since(t))
	})
	mux.HandleFunc("/verdict", func(w http.ResponseWriter, r *http.Request) {
		series := rb.since(parseSince(r))
		writeJSON(w, map[string]any{
			"samples":       len(series),
			"single_active": SingleActive(series),
			"overlap_pairs": OverlapPairs(series),
			"gap_pairs":     GapPairs(series),
		})
	})
	fmt.Printf("observer sampling every %dms; serving %s\n", intervalMs, listen)
	_ = http.ListenAndServe(listen, mux)
}

// sampleOnce reads all consumed:* counters and sums active streams across pods.
func sampleOnce(ctx context.Context, rdb *redis.Client, hc *http.Client, host, port string) Sample {
	c, cancel := context.WithTimeout(ctx, 800*time.Millisecond)
	defer cancel()
	consumed := map[string]int64{}
	var cursor uint64
	for {
		keys, cur, err := rdb.Scan(c, cursor, "consumed:*", 200).Result()
		if err != nil {
			break
		}
		for _, k := range keys {
			v, _ := rdb.Get(c, k).Int64()
			consumed[k[len("consumed:"):]] = v
		}
		cursor = cur
		if cursor == 0 {
			break
		}
	}
	active := 0
	ips, _ := net.LookupHost(host)
	for _, ip := range ips {
		active += streamCount(hc, ip, port)
	}
	return Sample{T: time.Now(), Consumed: consumed, ActiveStreams: active}
}

// streamCount GETs /streams on one pod and returns the number of streams (0 or 1 here).
func streamCount(hc *http.Client, ip, port string) int {
	resp, err := hc.Get(fmt.Sprintf("http://%s:%s/streams", ip, port))
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var m map[string]any
	if json.Unmarshal(body, &m) != nil {
		return 0
	}
	return len(m)
}

func parseSince(r *http.Request) time.Time {
	if v := r.URL.Query().Get("since_unix_ms"); v != "" {
		if ms, err := strconv.ParseInt(v, 10, 64); err == nil {
			return time.UnixMilli(ms)
		}
	}
	return time.Time{} // zero -> everything
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
```

> Note: `net.LookupHost` on the headless service name returns all ready pod IPs. The observer therefore only counts streams on pods currently in `Endpoints` — fine, since a not-ready pod isn't consuming anyway.

- [ ] **Step 2: Resolve deps**

Run:
```bash
cd labs/redis-connect-leader-election-k8s/observer
go get github.com/redis/go-redis/v9@v9.19.0
go mod tidy
go build ./... && go test ./...
```
Expected: builds; the 5 timeline tests PASS.

- [ ] **Step 3: Commit**

```bash
git add observer/main.go observer/go.mod observer/go.sum
git commit -m "leader-election-k8s: observer sampler + /timeline /verdict server"
```

---

## Task 11: Observer Dockerfile

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/observer/Dockerfile`

- [ ] **Step 1: Write Dockerfile**

Create `Dockerfile` (mirror the writer's; no tini needed — observer is never SIGSTOPped):
```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/observer .

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 app
USER app
COPY --from=build /out/observer /usr/local/bin/observer
ENTRYPOINT ["/usr/local/bin/observer"]
```

- [ ] **Step 2: Build to verify**

Run: `cd labs/redis-connect-leader-election-k8s/observer && docker build -t redis-rrcs/observer:dev .`
Expected: image builds.

- [ ] **Step 3: Commit**

```bash
git add observer/Dockerfile
git commit -m "leader-election-k8s: observer Dockerfile"
```

---

## Task 12: Observer Deployment + service

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/chart/templates/observer.yaml`

- [ ] **Step 1: Write the template**

Create `chart/templates/observer.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "observer") }}
  labels: { app: observer }
spec:
  replicas: 1
  selector:
    matchLabels: { app: observer }
  template:
    metadata:
      labels: { app: observer }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      containers:
        - name: observer
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.observer.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.observer.pullPolicy) }}
          env:
            - { name: REDIS_ADDR,        value: {{ include "rrcs.redis.central.hostPort" . | quote }} }
            - { name: CONNECT_HEADLESS,  value: {{ include "rrcs.name" (dict "root" $ "base" "connect-headless") | quote }} }
            - { name: CONNECT_PORT,      value: "4195" }
            - { name: LISTEN_ADDR,       value: ":8070" }
            - { name: SAMPLE_INTERVAL_MS, value: "{{ .Values.observer.sampleIntervalMs }}" }
          ports:
            - containerPort: 8070
          readinessProbe:
            httpGet: { path: /healthz, port: 8070 }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          resources:
            {{- toYaml .Values.resources.observer | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "observer") }}
  labels: { app: observer }
spec:
  selector: { app: observer }
  ports:
    - name: http
      port: 8070
      targetPort: 8070
```

- [ ] **Step 2: Render to verify**

Run:
```bash
cd labs/redis-connect-leader-election-k8s
helm template lel ./chart -n lel-k8s -f chart/values-dev.yaml -s templates/observer.yaml | head -20
```
Expected: valid Deployment + Service YAML.

- [ ] **Step 3: Commit**

```bash
git add chart/templates/observer.yaml
git commit -m "leader-election-k8s: observer Deployment + service"
```

---

## Task 13: Full chart render gate

**Files:** none (verification).

- [ ] **Step 1: Render the whole chart and lint**

Run:
```bash
cd labs/redis-connect-leader-election-k8s
helm lint ./chart -f chart/values-dev.yaml
helm template lel ./chart -n lel-k8s -f chart/values-dev.yaml > /tmp/lel-full.yaml
echo "objects: $(grep -c '^kind:' /tmp/lel-full.yaml)"
# sanity: no leftover NATS/region/sink/verifier refs anywhere
grep -in "nats\|region\|connect-sink\|verifier\|lww" /tmp/lel-full.yaml || echo "clean of dropped components"
# connect Deployment has 2 containers and replicas 3
grep -A3 'kind: Deployment' /tmp/lel-full.yaml | grep -c 'replicas: 3'
```
Expected: lint passes; render lists redis-central, writer, connect (replicas 3, connect+elector containers), connect-headless svc, observer (+svc), dashboard, RBAC (SA/Role/RoleBinding), 2 connect ConfigMaps; "clean of dropped components".

- [ ] **Step 2: Commit (only if any fixes were needed).** Otherwise proceed.

---

## Task 14: Repoint the dashboard to per-pod consumption

**Files:**
- Modify: `labs/redis-connect-leader-election-k8s/dashboard/main.go`
- Modify: `labs/redis-connect-leader-election-k8s/dashboard/static/index.html`
- Modify: `labs/redis-connect-leader-election-k8s/chart/templates/dashboard.yaml`

- [ ] **Step 1: Inspect the current dashboard fully**

Run: `cat dashboard/main.go dashboard/static/index.html chart/templates/dashboard.yaml`
Note the functions `subscribeApplied` and `pollStats` and which env vars are read (`REGION_ADDR`, `WRITER_URL`, `CONNECT_SINK_URL`, `KEYSPACE_EVENT`).

- [ ] **Step 2: Repoint data sources**

In `dashboard/main.go`:
- Replace `regionAddr := getenv("REGION_ADDR", "redis-region:6379")` with `centralAddr := getenv("CENTRAL_ADDR", "lab-redis-central:6379")` and use it for the redis client.
- Replace the `event` default `"__keyevent@0__:hset"` with `"__keyevent@0__:incr"` (we now watch `INCR consumed:<pod>`).
- Replace `sinkURL`/`CONNECT_SINK_URL` usage and the `pollStats` sink scrape with a poll of the **observer** `/verdict?since_unix_ms=0` (env `OBSERVER_URL`, default `http://lab-observer:8070`) so the page can show live `overlap_pairs`/`gap_pairs`/`single_active`. Keep the writer poll (`WRITER_URL`).
- In `subscribeApplied`, the message channel for `__keyevent@0__:incr` delivers the key name (e.g. `consumed:connect-xyz-0`); broadcast `{pod: <suffix>, ts: ...}` to the hub instead of the LWW key/version/value shape.

- [ ] **Step 3: Repoint the HTML**

In `dashboard/static/index.html`, change the LWW key/version/value stream view to a per-pod consumption view: one row/bar per `consumed:<pod>`, and a status banner driven by the observer verdict (single_active / overlap / gap). Keep the websocket plumbing.

- [ ] **Step 4: Repoint the chart env**

In `chart/templates/dashboard.yaml`, replace the env block so it sets:
```yaml
          env:
            - { name: CENTRAL_ADDR, value: {{ include "rrcs.redis.central.hostPort" . | quote }} }
            - { name: WRITER_URL,   value: "http://{{ include "rrcs.name" (dict "root" $ "base" "writer") }}:8081" }
            - { name: OBSERVER_URL, value: "http://{{ include "rrcs.name" (dict "root" $ "base" "observer") }}:8070" }
            - { name: KEYSPACE_EVENT, value: "__keyevent@0__:incr" }
            - { name: LISTEN_ADDR,  value: ":8080" }
```
Remove any `REGION_ADDR`/`CONNECT_SINK_URL` lines.

- [ ] **Step 5: Build the dashboard image to verify it compiles**

Run: `cd labs/redis-connect-leader-election-k8s/dashboard && go build ./...`
Expected: builds.

- [ ] **Step 6: Render dashboard template**

Run: `cd labs/redis-connect-leader-election-k8s && helm template lel ./chart -n lel-k8s -f chart/values-dev.yaml -s templates/dashboard.yaml | grep -A12 'name: .*dashboard'`
Expected: env has CENTRAL_ADDR/WRITER_URL/OBSERVER_URL/KEYSPACE_EVENT; no REGION_ADDR.

- [ ] **Step 7: Commit**

```bash
git add dashboard chart/templates/dashboard.yaml
git commit -m "leader-election-k8s: repoint dashboard to per-pod consumption + observer verdict"
```

---

## Task 15: Scripts — build-images + verify-election orchestrator

**Files:**
- Modify: `labs/redis-connect-leader-election-k8s/scripts/build-images.sh`
- Modify: `labs/redis-connect-leader-election-k8s/scripts/render.sh`
- Rewrite: `labs/redis-connect-leader-election-k8s/scripts/lib/run-defaults.sh`
- Create: `labs/redis-connect-leader-election-k8s/scripts/verify-election.sh`

- [ ] **Step 1: Add elector + observer to build-images.sh**

In `scripts/build-images.sh`, after the writer/verifier/dashboard image vars, replace the verifier image with elector+observer. Set:
```bash
WRITER_IMG="${prefix}redis-rrcs/writer:${TAG}"
ELECTOR_IMG="${prefix}redis-rrcs/elector:${TAG}"
OBSERVER_IMG="${prefix}redis-rrcs/observer:${TAG}"
DASHBOARD_IMG="${prefix}redis-rrcs/dashboard:${TAG}"
```
And replace the `build_one verifier ...` / kind-load / push lines for `verifier` with `elector` and `observer` equivalents:
```bash
build_one writer    "${WRITER_IMG}"
build_one elector   "${ELECTOR_IMG}"
build_one observer  "${OBSERVER_IMG}"
build_one dashboard "${DASHBOARD_IMG}"
```
(plus the matching `kind load docker-image` and `docker push` lines for ELECTOR_IMG/OBSERVER_IMG, removing the VERIFIER_IMG lines).

- [ ] **Step 2: Drop the `--profile` default from render.sh**

In `scripts/render.sh`, remove the `PROFILE="lww"` default and the `--set profile=...` arg (this chart has no `profile`). Keep `--values` and `RRCS_NS` (rename default ns to `lel-k8s`).

- [ ] **Step 3: Rewrite run-defaults.sh**

Overwrite `scripts/lib/run-defaults.sh`:
```bash
# Run-window defaults for the leader-election lab (env-overridable).
: "${RATE:=2000}"          # writer msg/s during the proofs
: "${SETTLE_S:=15}"        # steady-state observation before/after faults
: "${LEASE_DURATION:=6}"   # must match chart connect.lease.duration (seconds)
: "${OVERLAP_WAIT_S:=12}"  # how long to keep the leader SIGSTOPped (>= lease + buffer)
: "${GAP_WAIT_S:=12}"      # how long to observe after force-kill
```

- [ ] **Step 4: Write verify-election.sh (Proof A/B1/B2)**

Create `scripts/verify-election.sh`:
```bash
#!/usr/bin/env bash
# Leader-election verification harness. Boots the chart, then:
#   Proof A : steady state -> exactly one connect pod consumes (single-active).
#   Proof B1: SIGSTOP the leader's elector -> measured dual-active OVERLAP window.
#   Proof B2: force-delete the leader pod  -> measured zero-active GAP window.
# Exits 0 iff Proof A passes AND (B1 overlap>0 OR B2 gap>0) — gating works AND is best-effort.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/run-defaults.sh"

NS="${LEL_NS:-lel-k8s}"
RELEASE="${LEL_RELEASE:-lel}"
VALUES_FILE="${LEL_VALUES:-chart/values-dev.yaml}"

echo "[boot] helm upgrade --install ${RELEASE}"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  -f "${VALUES_FILE}" --wait --timeout 5m
PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

K() { kubectl -n "${NS}" "$@"; }
OBS() { K exec "deploy/${PREFIX}observer" -- wget -qO- "http://localhost:8070/$1"; }
LEASE_NAME="${PREFIX}connect-elector"

leader_pod() { K get lease "${LEASE_NAME}" -o jsonpath='{.spec.holderIdentity}'; }
elector_pid() { # PID of the elector binary inside the elector container of $1
  K exec "$1" -c elector -- sh -c 'pgrep -f /usr/local/bin/elector | head -n1'
}

echo "[writer] start rate=${RATE}"
K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data='{"epoch":"run"}' http://localhost:8081/reset
K exec "deploy/${PREFIX}writer" -- wget -qO- --post-data="{\"rate\":${RATE}}" http://localhost:8081/rate

echo "[proofA] settle ${SETTLE_S}s then check single-active"
sleep "${SETTLE_S}"
A_VERDICT="$(OBS "verdict?since_unix_ms=0")"
echo "[proofA] ${A_VERDICT}"
SA="$(echo "$A_VERDICT" | jq -r '.single_active')"
LEADER="$(leader_pod)"
echo "[proofA] lease holder = ${LEADER}"
if [[ "$SA" != "true" || -z "$LEADER" ]]; then
  echo "[proofA] FAIL (single_active=$SA holder=$LEADER)"; exit 1
fi
echo "[proofA] PASS"

echo "[proofB1] SIGSTOP elector on leader ${LEADER} for ${OVERLAP_WAIT_S}s"
B1_START="$(date +%s%3N)"
PID="$(elector_pid "${LEADER}")"
K exec "${LEADER}" -c elector -- kill -STOP "${PID}"
sleep "${OVERLAP_WAIT_S}"
K exec "${LEADER}" -c elector -- kill -CONT "${PID}" || true
B1_VERDICT="$(OBS "verdict?since_unix_ms=${B1_START}")"
echo "[proofB1] ${B1_VERDICT}"
OVERLAP="$(echo "$B1_VERDICT" | jq -r '.overlap_pairs')"
sleep "${SETTLE_S}"   # allow reconvergence

echo "[proofB2] force-delete leader (lease holder now $(leader_pod))"
LEADER2="$(leader_pod)"
B2_START="$(date +%s%3N)"
K delete pod "${LEADER2}" --force --grace-period=0
sleep "${GAP_WAIT_S}"
B2_VERDICT="$(OBS "verdict?since_unix_ms=${B2_START}")"
echo "[proofB2] ${B2_VERDICT}"
GAP="$(echo "$B2_VERDICT" | jq -r '.gap_pairs')"

echo "----"
echo "[verdict] single_active=${SA} overlap_pairs=${OVERLAP} gap_pairs=${GAP}"
if [[ "$SA" == "true" && ( "${OVERLAP:-0}" -gt 0 || "${GAP:-0}" -gt 0 ) ]]; then
  echo "[verify-election] PASS — active-gating works AND is best-effort (measured window)"; exit 0
fi
echo "[verify-election] FAIL — gating or best-effort window not observed"; exit 1
```

- [ ] **Step 5: Make scripts executable**

Run: `chmod +x scripts/verify-election.sh scripts/build-images.sh scripts/render.sh scripts/dashboard-forward.sh`

- [ ] **Step 6: Shellcheck (best-effort)**

Run: `bash -n scripts/verify-election.sh && echo "syntax ok"`
Expected: `syntax ok`.

- [ ] **Step 7: Commit**

```bash
git add scripts
git commit -m "leader-election-k8s: scripts — build elector/observer + verify-election Proof A/B1/B2"
```

---

## Task 16: RESEARCH.md

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/RESEARCH.md`

- [ ] **Step 1: Write RESEARCH.md**

Follow the fork's RESEARCH.md shape. Required sections (fill with this lab's content):

- **Property demonstrated** — verbatim from the spec's one-sentence property.
- **Essentials (what is load-bearing)** — streams mode empty boot; elector POST/DELETE on leadership; fail-closed boot DELETE; `__POD__` substitution (env interpolation unavailable, research §3.5); Lease `holderIdentity`=POD_NAME; `consumed:<pod>` attribution; observer single-active/overlap/gap math.
- **Wire contract** — writer XADD fields (`value,event_id,key,pattern,t_send_ms,version`); streams REST `POST/DELETE /streams/{id}`, `GET /streams`; elector metrics `elector_leading`,`elector_post_total`,`elector_delete_total`; observer `/timeline`,`/verdict`.
- **How the proof is made unambiguous** — Proof A needs `single_active==true` over a multi-sample window AND lease has a holder; B1 overlap counts pairs with ≥2 pods rising (only possible if two pods truly consumed concurrently); B2 gap counts pairs with no total increase while the writer is provably sending.
- **Best-effort, NOT fencing** — quote the research §7 disclaimer; state that correctness boundary (consumer group + dedup + CAS) is deliberately excluded.
- **Validated result** — leave a clear placeholder line `TO BE FILLED BY Task 18` ONLY for the measured numbers; everything else complete. (This is the one allowed forward-reference; Task 18 fills it.)
- **Design decisions** — N=3; 6s/4s/1s lease; tini so elector isn't PID 1; source-leg only; observer via headless DNS (no RBAC).
- **Rejected alternatives** — sidecar+watcher script (research §3); env interpolation in stream config (§3.5).
- **Deliberately excluded** — lower defenses, native sidecar, strict ordering, Method C.
- **Further reading** — `active-stanby-mechanism/research.md`, the spec, the fork.

- [ ] **Step 2: Commit**

```bash
git add RESEARCH.md
git commit -m "leader-election-k8s: RESEARCH.md"
```

---

## Task 17: README.md

**Files:**
- Create: `labs/redis-connect-leader-election-k8s/README.md`

- [ ] **Step 1: Write README.md**

Mirror the fork's README structure:
- **What this demonstrates** (one paragraph: best-effort active-gating, source-leg only).
- **Run it (kind)**:
  ```bash
  kind create cluster --name lel
  scripts/build-images.sh --kind --kind-name=lel
  scripts/verify-election.sh
  ```
  Tunables: `RATE`, `SETTLE_S`, `OVERLAP_WAIT_S`, `GAP_WAIT_S`, `LEL_NS`, `LEL_RELEASE`.
- **Watch live**: `scripts/dashboard-forward.sh` → `http://<host>:8080`.
- **Expected output** — `verify-election.sh` exits 0 only when Proof A passes and B1 overlap>0 or B2 gap>0; show the example verdict line.
- **Validation note** — K8s lab; `validate_lab.sh` (compose-only) does not apply; `verify-election.sh` is the gate.
- **Teardown**:
  ```bash
  helm uninstall lel -n lel-k8s
  kind delete cluster --name lel
  ```
- **Further reading** — RESEARCH.md, `active-stanby-mechanism/research.md`, the fork.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "leader-election-k8s: README"
```

---

## Task 18: End-to-end validation on kind

**Files:**
- Modify: `labs/redis-connect-leader-election-k8s/RESEARCH.md` (fill validated numbers)

- [ ] **Step 1: Create cluster and build/load images**

Run:
```bash
cd labs/redis-connect-leader-election-k8s
kind create cluster --name lel
scripts/build-images.sh --kind --kind-name=lel
```
Expected: cluster up; writer/elector/observer/dashboard images loaded.

- [ ] **Step 2: Run the verification gate**

Run: `scripts/verify-election.sh`
Expected final lines:
```
[proofA] PASS
[proofB1] {... "overlap_pairs": >0 ...}
[proofB2] {... "gap_pairs": >0 ...}
[verify-election] PASS — active-gating works AND is best-effort (measured window)
```
Exit code 0.

- [ ] **Step 3: If a proof fails, diagnose (do not weaken the proof)**

Common roots and fixes:
- **`single_active=false` with `overlap_pairs>0` at steady state** → two pods POSTed; check elector logs (`K logs <pod> -c elector`) for double leadership — likely lease RBAC denied (watch for 403). Fix RBAC (Task 8), not the assertion.
- **`single_active=false`, no pod rising** → connect not consuming; check `K logs <pod> -c connect` and that the elector POST succeeded (`elector_post_total{result="ok"}`); verify Task 0 content-type.
- **B1 `overlap_pairs=0`** → SIGSTOP hit PID 1 (no effect) → confirm tini in elector image (Task 5) and that `pgrep` resolves the child PID; or `OVERLAP_WAIT_S` < lease — raise it.
- **B2 `gap_pairs=0`** → standby took over within one sample; lower `SAMPLE_INTERVAL_MS` or confirm `--force --grace-period=0` actually deleted (no graceful DELETE).
- After 3 failed attempts on one root cause, invoke `superpowers:systematic-debugging`.

- [ ] **Step 4: Record measured numbers in RESEARCH.md**

Replace the `TO BE FILLED BY Task 18` line in RESEARCH.md "Validated result" with the actual observed values: steady-state `single_active=true`, the B1 `overlap_pairs` (and approx overlap ms = pairs × sample interval), the B2 `gap_pairs` (× interval), and the lease timings used.

- [ ] **Step 5: Teardown to leave a clean tree**

Run:
```bash
helm uninstall lel -n lel-k8s || true
kind delete cluster --name lel
git status --short   # expect clean except the RESEARCH.md edit
```

- [ ] **Step 6: Commit**

```bash
git add RESEARCH.md
git commit -m "leader-election-k8s: record validated single-active + measured overlap/gap windows"
```

---

## Self-Review

**Spec coverage:**
- Property (single-active + best-effort) → Tasks 8 (gating), 15 (Proof A/B1/B2), 9–10 (verdict math). ✓
- elector fail-closed lifecycle (boot DELETE, POST-on-lead, DELETE/exit-on-stop) → Task 4. ✓
- §3.5 env-interpolation trap (`__POD__` substitution) → Tasks 3/8. ✓
- §3.5 trap 3 (resources/metrics in observability, not stream) → Task 8 observability.yaml. ✓
- §3.5 trap 2 (`/ready`=200 with zero streams) → Task 8 readiness comment; observer uses `/streams` not `/ready`. ✓
- PID-1 SIGSTOP caveat → Task 5 (tini), Task 15 (`pgrep` child PID). ✓
- RBAC for leases (§4) → Task 8 rbac.yaml. ✓
- N=3, dashboard kept, 6s/4s/1s lease → Tasks 7/8/12/14. ✓
- Source-leg only / drop NATS+sink+region+verifier → Tasks 1/2. ✓
- Both failure scenarios (overlap + gap) → Task 15 B1/B2. ✓
- Isolated worktree → already created (`worktree-leader-election-lab`). ✓
- Validation gate (not validate_lab.sh) → Tasks 15/18. ✓

**Placeholder scan:** Only one intentional forward-reference — RESEARCH.md "Validated result" numbers, explicitly filled in Task 18. All code steps contain complete code. No "TBD/handle errors/similar to".

**Type consistency:** `Sample{T,Consumed,ActiveStreams}`, `SingleActive/OverlapPairs/GapPairs`, `renderPipeline`, `streamsClient.post/delete`, `retry` — used identically across Tasks 3/4/9/10. Env var names (`POD_NAME`,`LEASE_NAME`,`STREAM_ID`,`CONNECT_ADDR`,`PIPELINE_PATH`,`REDIS_ADDR`,`CONNECT_HEADLESS`,`SAMPLE_INTERVAL_MS`) match between Go (Tasks 4/10) and chart env (Tasks 8/12). Resource names via `rrcs.name` (`connect`,`connect-headless`,`connect-elector`,`connect-observability`,`connect-pipeline`,`observer`,`writer`,`redis-central`) consistent across templates and `verify-election.sh`.
