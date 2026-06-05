# Redis → Connect LWW under Multiple Connect Instances — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork `labs/redis-connect-lww-k8s` into `labs/redis-connect-lww-multi-k8s` and prove that scaling `connect-source` + `connect-sink` to N>1 replicas preserves the LWW CAS fence (`mismatches=0`, `stale>0` from cross-instance reordering), while scaling the *writer* breaks it via a silent lost update invisible to the version-only check.

**Architecture:** Same topology as the parent lab, with `connect-source`/`connect-sink` at `replicas: 3`. A headless Service exposes every sink pod so the verifier can DNS-enumerate pods and **sum** the per-pod `lww_apply` counters (the correctness check is unchanged — it reads region Redis directly). A deterministic scripted "Proof C" demonstrates the multi-writer break; the forked `verify-lww.sh` runs Proof A (mechanism) + Proof C (negative) + Proof B′ (positive, multi-instance).

**Tech Stack:** Helm/Kubernetes (kind), Redpanda Connect (`hpdevelop/connect:4.92.0-claudefix`), NATS JetStream, Redis 7, Go (writer/verifier/dashboard), bash.

**Spec:** `docs/superpowers/specs/2026-06-05-redis-connect-lww-multi-k8s-design.md`

---

## File Structure

New lab directory `labs/redis-connect-lww-multi-k8s/` (forked copy of the parent). Files touched relative to that directory:

- `chart/values.yaml` — add `connect.source.replicas` / `connect.sink.replicas` (default 3).
- `chart/templates/connect-source.yaml` — `replicas:` from values.
- `chart/templates/connect-sink.yaml` — `replicas:` from values; **add headless Service** `connect-sink-headless`.
- `chart/files/connect/lww-reverse.yaml` — add `queue:` deliver-group so 3 sink pods share the durable.
- `chart/templates/verifier-job.yaml` — pass `--connect-sink-dns` instead of `--connect-sink`.
- `verifier/pods.go` *(new)* — DNS-enumerate sink pods, sum `lww_apply`, fail-loud restart guard.
- `verifier/pods_test.go` *(new)* — unit tests for the sum + regression guard.
- `verifier/main.go` — use the pod-aggregating baseline/delta instead of single-URL scrape.
- `scripts/proof-c.sh` *(new)* — deterministic multi-writer lost-update negative proof.
- `scripts/verify-lww.sh` — run Proof A + Proof C + Proof B′.
- `RESEARCH.md`, `README.md` — forked + rewritten for the multi-instance property.

---

## Task 0: Fork the lab directory

**Files:**
- Create: `labs/redis-connect-lww-multi-k8s/` (copy of `labs/redis-connect-lww-k8s/`)

- [ ] **Step 1: Copy the lab, excluding build artifacts**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
rsync -a --exclude='out' --exclude='reports' \
  --exclude='writer/writer' --exclude='verifier/verifier' --exclude='dashboard/dashboard' \
  labs/redis-connect-lww-k8s/ labs/redis-connect-lww-multi-k8s/
```
Expected: new directory exists with `chart/`, `writer/`, `verifier/`, `dashboard/`, `scripts/`, `RESEARCH.md`, `README.md`.

- [ ] **Step 2: Verify the forked chart still renders unchanged**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
helm template lww ./chart --set profile=lww -f chart/values-dev.yaml >/dev/null && echo RENDER_OK
```
Expected: `RENDER_OK` (no template errors).

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-multi-k8s
git commit -m "lww-multi-k8s: fork redis-connect-lww-k8s as starting point"
```

---

## Task 1: Values-driven replica knobs

**Files:**
- Modify: `labs/redis-connect-lww-multi-k8s/chart/values.yaml`
- Modify: `labs/redis-connect-lww-multi-k8s/chart/templates/connect-source.yaml:7`
- Modify: `labs/redis-connect-lww-multi-k8s/chart/templates/connect-sink.yaml:7`

- [ ] **Step 1: Add replica fields under the `connect:` key in values.yaml**

In `chart/values.yaml`, replace the `connect:` block (currently just `image:`) with:
```yaml
connect:
  image: hpdevelop/connect:4.92.0-claudefix
  # Multi-instance is the whole point of this lab: source + sink run N>1 so that
  # reordering is INTER-pod (parallel stream consumption at the source; concurrent
  # same-key CAS at the sink), not just intra-pod threads. The LWW fence must hold
  # regardless. >=2 each is required to exercise the property; 3 is the default.
  source:
    replicas: 3
  sink:
    replicas: 3
```

- [ ] **Step 2: Wire source replicas**

In `chart/templates/connect-source.yaml`, change line 7 from:
```yaml
  replicas: 1
```
to:
```yaml
  replicas: {{ .Values.connect.source.replicas }}
```

- [ ] **Step 3: Wire sink replicas**

In `chart/templates/connect-sink.yaml`, change line 7 from:
```yaml
  replicas: 1
```
to:
```yaml
  replicas: {{ .Values.connect.sink.replicas }}
```

- [ ] **Step 4: Verify rendered replica counts**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
helm template lww ./chart --set profile=lww \
  | awk '/kind: Deployment/{d=1} /name: lab-connect-(source|sink)$/{n=$2} d&&/replicas:/{print n, $2; d=0}'
```
Expected: both `lab-connect-source` and `lab-connect-sink` show `replicas: 3`.

- [ ] **Step 5: Commit**

```bash
git add labs/redis-connect-lww-multi-k8s/chart
git commit -m "lww-multi-k8s: values-driven replica knobs (source/sink default 3)"
```

---

## Task 2: Headless Service for per-pod sink scraping

**Files:**
- Modify: `labs/redis-connect-lww-multi-k8s/chart/templates/connect-sink.yaml` (append a second Service)

- [ ] **Step 1: Append the headless Service**

At the end of `chart/templates/connect-sink.yaml` (after the existing ClusterIP Service block), append:
```yaml
---
# Headless Service: clusterIP None makes DNS return an A record per READY sink pod
# (not a single VIP). The verifier resolves this name to enumerate every sink pod
# and SUM its per-pod lww_apply counters — a single-VIP scrape would round-robin to
# one pod and undercount. publishNotReadyAddresses stays false so a not-yet-ready
# pod (no traffic, zero counters) cannot dilute the baseline.
apiVersion: v1
kind: Service
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-sink-headless") }}
  labels: { app: connect-sink }
spec:
  clusterIP: None
  publishNotReadyAddresses: false
  selector: { app: connect-sink }
  ports:
    - name: http
      port: 4195
      targetPort: 4195
```

- [ ] **Step 2: Verify the headless Service renders**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
helm template lww ./chart --set profile=lww \
  | awk '/kind: Service/{s=1} s&&/name: lab-connect-sink-headless/{n=1} s&&/clusterIP: None/&&n{print "HEADLESS_OK"; n=0; s=0}'
```
Expected: `HEADLESS_OK`.

- [ ] **Step 3: Commit**

```bash
git add labs/redis-connect-lww-multi-k8s/chart/templates/connect-sink.yaml
git commit -m "lww-multi-k8s: headless Service for per-pod sink metric scraping"
```

---

## Task 3: JetStream shared-durable (deliver group) + empirical verification

**Files:**
- Modify: `labs/redis-connect-lww-multi-k8s/chart/files/connect/lww-reverse.yaml:11-19`

**Background:** With 3 sink pods binding the same durable push consumer `region-writer` and **no** deliver group, NATS rejects the 2nd/3rd subscription ("consumer already bound"). A `queue` (deliver group) turns it into a load-balanced push consumer so each message is delivered to exactly one of the 3 pods. This task adds the `queue` field and **empirically verifies** distribution against the real image.

- [ ] **Step 1: Add the deliver group to the sink input**

In `chart/files/connect/lww-reverse.yaml`, change the `nats_jetstream` input block (lines ~11-19) from:
```yaml
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth: { user_credentials_file: {{ .Values.nats.auth.creds.subscriber | quote }} }
    subject: {{ include "rrcs.nats.stream.subjects" . | quote }}
    stream: {{ .Values.nats.stream.name | quote }}
    durable: {{ .Values.nats.stream.consumer.durable | quote }}
    deliver: all
    ack_wait: 30s
```
to (add the `queue` line):
```yaml
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth: { user_credentials_file: {{ .Values.nats.auth.creds.subscriber | quote }} }
    subject: {{ include "rrcs.nats.stream.subjects" . | quote }}
    stream: {{ .Values.nats.stream.name | quote }}
    durable: {{ .Values.nats.stream.consumer.durable | quote }}
    # Deliver group: lets all N sink pods share ONE durable push consumer and
    # load-balance deliveries (each message → exactly one pod). Without this, the
    # 2nd/3rd pod binding the same durable is rejected by NATS. This is what makes
    # same-key messages land on DIFFERENT pods concurrently — the inter-pod reorder
    # vector the LWW fence must survive.
    queue: {{ printf "%s-q" .Values.nats.stream.consumer.durable | quote }}
    deliver: all
    ack_wait: 30s
```

- [ ] **Step 2: Verify the config renders with the queue field**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
helm template lww ./chart --set profile=lww -s templates/connect-configmaps.yaml \
  | grep -E 'queue:|durable:' | head
```
Expected: shows `durable: "region-writer"` and `queue: "region-writer-q"`.

- [ ] **Step 3: Empirical check — build a kind cluster and confirm distribution**

This is the research gate. Stand the lab up and confirm all 3 sink pods actually receive a share of one durable.

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
kind create cluster --name lwwm
scripts/build-images.sh --kind --kind-name=lwwm
helm upgrade --install lwwm ./chart -n lwwm-k8s --create-namespace \
  --set profile=lww -f chart/values-dev.yaml --wait --timeout 5m
# Drive a brief burst of traffic
kubectl -n lwwm-k8s exec deploy/lab-writer -- sh -c 'true' 2>/dev/null || true
W=$(kubectl -n lwwm-k8s get pod -l app=writer -o jsonpath='{.items[0].metadata.name}')
kubectl -n lwwm-k8s exec "$W" -- wget -qO- --post-data='{"epoch":"jsdist"}' --header=Content-Type:application/json http://localhost:8081/reset
kubectl -n lwwm-k8s exec "$W" -- wget -qO- --post-data='{"rate":5000}' --header=Content-Type:application/json http://localhost:8081/rate
sleep 8
# Each sink pod's applied counter should be > 0 (work was distributed, not all to one pod)
for p in $(kubectl -n lwwm-k8s get pod -l app=connect-sink -o jsonpath='{.items[*].metadata.name}'); do
  echo -n "$p applied="; kubectl -n lwwm-k8s exec "$p" -- wget -qO- http://localhost:4195/metrics | awk -F' ' '/^lww_apply.*result="applied"/{s+=$2} END{print s+0}'
done
```
Expected: **every** sink pod prints `applied=` with a value > 0, confirming the deliver group distributes one durable across all pods.

- [ ] **Step 4: If Step 3 fails (image does not honor `queue`), apply the documented fallback**

Only if one pod gets all traffic or pods crash-loop on subscribe:
- Inspect: `kubectl -n lwwm-k8s logs -l app=connect-sink --tail=40` and `kubectl -n lwwm-k8s exec "$W" -- nats ...` is unavailable; instead exec a nats-box. Capture the actual error.
- Fallback A (preferred if `queue` unsupported): switch the input to a **pull** consumer if the image's `nats_jetstream` exposes it (check `args: ["run","/connect.yaml"]` image docs via `kubectl -n lwwm-k8s exec "$p" -- /connect list inputs` or the image's `--help`). Document the exact field used.
- Fallback B (last resort): per-pod durable fan-out — set `durable: ${HOSTNAME}` so each pod has its own consumer and processes EVERY message. This still proves the fence's idempotency under concurrent duplicate CAS but is NOT realistic HA. **Must** be labelled as such in RESEARCH.md.
- Record the chosen mechanism and the observed evidence in RESEARCH.md (Task 7). Do not proceed with a silently-broken sink.

- [ ] **Step 5: Tear down the probe cluster (the real validation run rebuilds it in Task 8)**

Run:
```bash
helm uninstall lwwm -n lwwm-k8s || true
kind delete cluster --name lwwm
```

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-multi-k8s/chart/files/connect/lww-reverse.yaml
git commit -m "lww-multi-k8s: deliver group so N sink pods share one JetStream durable"
```

---

## Task 4: Verifier — aggregate lww_apply across all sink pods

**Files:**
- Create: `labs/redis-connect-lww-multi-k8s/verifier/pods.go`
- Create: `labs/redis-connect-lww-multi-k8s/verifier/pods_test.go`
- Modify: `labs/redis-connect-lww-multi-k8s/verifier/main.go`
- Modify: `labs/redis-connect-lww-multi-k8s/chart/templates/verifier-job.yaml:33`

- [ ] **Step 1: Write the failing test for per-pod sum + regression guard**

Create `verifier/pods_test.go`:
```go
package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// sinkStub serves a connect /metrics endpoint with the given lww counters.
func sinkStub(applied, stale, duplicate int64) *httptest.Server {
	body := fmt.Sprintf(
		"# HELP lww_apply\n# TYPE lww_apply counter\n"+
			"lww_apply{result=\"applied\"} %d\n"+
			"lww_apply{result=\"stale\"} %d\n"+
			"lww_apply{result=\"duplicate\"} %d\n",
		applied, stale, duplicate)
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/metrics") {
			w.WriteHeader(404)
			return
		}
		_, _ = w.Write([]byte(body))
	}))
}

// hostPort splits an httptest URL "http://127.0.0.1:PORT" into host, port.
func hostPort(t *testing.T, srv *httptest.Server) (string, string) {
	t.Helper()
	hp := strings.TrimPrefix(srv.URL, "http://")
	i := strings.LastIndexByte(hp, ':')
	return hp[:i], hp[i+1:]
}

func TestScrapeAllSumsAcrossPods(t *testing.T) {
	s1 := sinkStub(100, 5, 1)
	s2 := sinkStub(200, 7, 2)
	s3 := sinkStub(50, 0, 3)
	defer s1.Close()
	defer s2.Close()
	defer s3.Close()

	ips := []string{}
	port := ""
	for _, s := range []*httptest.Server{s1, s2, s3} {
		h, p := hostPort(t, s)
		ips = append(ips, h)
		port = p // all share 127.0.0.1; ports differ — see note below
		_ = p
	}
	// httptest servers use distinct ports, so model each as its own host:port pair.
	pairs := []string{}
	for _, s := range []*httptest.Server{s1, s2, s3} {
		h, p := hostPort(t, s)
		pairs = append(pairs, h+":"+p)
	}
	got, err := scrapeAllPairs(context.Background(), pairs)
	if err != nil {
		t.Fatalf("scrapeAllPairs: %v", err)
	}
	var a, st, d int64
	for _, c := range got {
		a += c.applied
		st += c.stale
		d += c.duplicate
	}
	if a != 350 || st != 12 || d != 6 {
		t.Fatalf("sum = (%d,%d,%d), want (350,12,6)", a, st, d)
	}
}

func TestDeltaRejectsCounterRegression(t *testing.T) {
	// Baseline higher than current simulates a pod restart (cumulative counter reset).
	base := map[string]lwwCounts{"10.0.0.1:4195": {applied: 100, stale: 5, duplicate: 1}}
	cur := map[string]lwwCounts{"10.0.0.1:4195": {applied: 40, stale: 5, duplicate: 1}}
	_, _, _, err := sumDelta([]string{"10.0.0.1:4195"}, base, cur)
	if err == nil {
		t.Fatal("expected regression error (pod restart), got nil")
	}
}

func TestDeltaSumsAcrossPods(t *testing.T) {
	pairs := []string{"a:4195", "b:4195"}
	base := map[string]lwwCounts{"a:4195": {10, 1, 0}, "b:4195": {20, 2, 0}}
	cur := map[string]lwwCounts{"a:4195": {60, 4, 0}, "b:4195": {120, 9, 0}}
	a, s, d, err := sumDelta(pairs, base, cur)
	if err != nil {
		t.Fatalf("sumDelta: %v", err)
	}
	if a != 150 || s != 10 || d != 0 {
		t.Fatalf("delta = (%d,%d,%d), want (150,10,0)", a, s, d)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s/verifier
go test ./... -run 'ScrapeAll|Delta' 2>&1 | head -20
```
Expected: FAIL — `undefined: scrapeAllPairs`, `undefined: lwwCounts`, `undefined: sumDelta`.

- [ ] **Step 3: Implement pods.go**

Create `verifier/pods.go`:
```go
package main

import (
	"context"
	"fmt"
	"net"
	"sort"
	"sync"
)

// lwwCounts is one sink pod's cumulative applied/stale/duplicate counters.
type lwwCounts struct{ applied, stale, duplicate int64 }

// SinkBaseline pins the set of sink pod "host:port" endpoints observed at sustain
// start plus their cumulative counters, so end-of-window scrapes can be summed as
// deltas against the SAME pods. A pod vanishing or a counter regressing (restart)
// is a hard precondition failure, not a silent under-count.
type SinkBaseline struct {
	pairs []string // host:port, pinned at baseline
	base  map[string]lwwCounts
}

// resolveSinkPairs resolves the headless service DNS name to one host:port per pod.
func resolveSinkPairs(ctx context.Context, dns, port string) ([]string, error) {
	var r net.Resolver
	ips, err := r.LookupHost(ctx, dns)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", dns, err)
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("resolve %s: no sink pod IPs (is connect-sink ready?)", dns)
	}
	sort.Strings(ips)
	pairs := make([]string, len(ips))
	for i, ip := range ips {
		pairs[i] = net.JoinHostPort(ip, port)
	}
	return pairs, nil
}

// scrapeAllPairs scrapes lww_apply from every host:port concurrently. Any failed
// scrape fails the whole call (the proof needs every pod's counter).
func scrapeAllPairs(ctx context.Context, pairs []string) (map[string]lwwCounts, error) {
	out := make(map[string]lwwCounts, len(pairs))
	var mu sync.Mutex
	var wg sync.WaitGroup
	errs := make([]error, len(pairs))
	for i, hp := range pairs {
		wg.Add(1)
		go func(i int, hp string) {
			defer wg.Done()
			a, s, d, err := ScrapeLWW(ctx, "http://"+hp)
			if err != nil {
				errs[i] = fmt.Errorf("scrape %s: %w", hp, err)
				return
			}
			mu.Lock()
			out[hp] = lwwCounts{a, s, d}
			mu.Unlock()
		}(i, hp)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			return nil, e
		}
	}
	return out, nil
}

// sumDelta returns summed applied/stale/duplicate deltas across pinned pods, failing
// loud if any pod's current counter is below baseline (a restart zeroed cumulative
// counters, which would corrupt the delta and could manufacture a false stale>0).
func sumDelta(pairs []string, base, cur map[string]lwwCounts) (applied, stale, duplicate int64, err error) {
	for _, hp := range pairs {
		c, ok := cur[hp]
		if !ok {
			return 0, 0, 0, fmt.Errorf("sink pod %s missing at end-of-window (rescaled/restarted mid-run): proof invalid", hp)
		}
		z := base[hp]
		if c.applied < z.applied || c.stale < z.stale || c.duplicate < z.duplicate {
			return 0, 0, 0, fmt.Errorf("sink pod %s counter regressed (applied %d->%d, stale %d->%d, dup %d->%d): pod restarted mid-run; proof invalid",
				hp, z.applied, c.applied, z.stale, c.stale, z.duplicate, c.duplicate)
		}
		applied += c.applied - z.applied
		stale += c.stale - z.stale
		duplicate += c.duplicate - z.duplicate
	}
	return applied, stale, duplicate, nil
}

// NewSinkBaseline resolves sink pods and records their baseline counters.
func NewSinkBaseline(ctx context.Context, dns, port string) (*SinkBaseline, error) {
	pairs, err := resolveSinkPairs(ctx, dns, port)
	if err != nil {
		return nil, err
	}
	base, err := scrapeAllPairs(ctx, pairs)
	if err != nil {
		return nil, err
	}
	return &SinkBaseline{pairs: pairs, base: base}, nil
}

// Delta re-scrapes the SAME baseline pods and returns summed deltas.
func (b *SinkBaseline) Delta(ctx context.Context) (applied, stale, duplicate int64, err error) {
	cur, err := scrapeAllPairs(ctx, b.pairs)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("sink delta scrape (a baseline pod went unreachable; rescale/restart breaks the proof): %w", err)
	}
	return sumDelta(b.pairs, b.base, cur)
}

// PodCount reports how many sink pods the baseline pinned (for logging/reporting).
func (b *SinkBaseline) PodCount() int { return len(b.pairs) }
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s/verifier
go test ./... -run 'ScrapeAll|Delta' -v 2>&1 | tail -20
```
Expected: PASS for `TestScrapeAllSumsAcrossPods`, `TestDeltaRejectsCounterRegression`, `TestDeltaSumsAcrossPods`.

- [ ] **Step 5: Wire main.go to use the pod-aggregating baseline**

In `verifier/main.go`:

(a) In the `flag` block (around lines 16-30), replace:
```go
		connectSink = flag.String("connect-sink", "http://connect-sink:4195", "")
```
with:
```go
		connectSinkDNS  = flag.String("connect-sink-dns", "connect-sink-headless", "headless Service DNS name resolving to every sink pod IP")
		connectSinkPort = flag.String("connect-sink-port", "4195", "sink pod metrics port")
```

(b) Replace the baseline scrape (around lines 84-87):
```go
	a0, s0, d0, err := ScrapeLWW(ctx, *connectSink)
	if err != nil {
		log.Fatalf("baseline scrape (connect-sink /metrics): %v", err)
	}
```
with:
```go
	sinkBase, err := NewSinkBaseline(ctx, *connectSinkDNS, *connectSinkPort)
	if err != nil {
		log.Fatalf("baseline scrape (sink pods via %s): %v", *connectSinkDNS, err)
	}
	log.Printf("aggregating lww_apply across %d sink pods", sinkBase.PodCount())
```

(c) Inside the `runStale` closure, replace the end-of-window scrape (around lines 117-125):
```go
		a, s, d, serr := ScrapeLWW(ctx, *connectSink)
		if serr != nil {
			log.Printf("WARN end-of-window scrape: %v", serr)
		}
		rateAvg := 0.0
		if n > 0 {
			rateAvg = sumRate / n
		}
		return a - a0, s - s0, d - d0, rateAvg
```
with:
```go
		a, s, d, serr := sinkBase.Delta(ctx)
		if serr != nil {
			log.Fatalf("end-of-window sink aggregation: %v", serr)
		}
		rateAvg := 0.0
		if n > 0 {
			rateAvg = sumRate / n
		}
		return a, s, d, rateAvg
```

Note: `sinkBase.Delta` already returns deltas against the pinned baseline, so the `- a0` subtraction is gone. A scrape failure is now fatal (a missing pod invalidates the proof) rather than a warning.

- [ ] **Step 6: Verify the verifier still builds and all tests pass**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s/verifier
go build ./... && go test ./... 2>&1 | tail -20
```
Expected: build succeeds; all tests (including the pre-existing `lww_test.go`) PASS.

- [ ] **Step 7: Update the verifier Job to pass the headless DNS name**

In `chart/templates/verifier-job.yaml`, replace line 33:
```yaml
            - --connect-sink=http://{{ include "rrcs.name" (dict "root" $ "base" "connect-sink") }}:4195
```
with:
```yaml
            - --connect-sink-dns={{ include "rrcs.name" (dict "root" $ "base" "connect-sink-headless") }}
            - --connect-sink-port=4195
```

- [ ] **Step 8: Verify the Job template renders the new flags**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
helm template lww ./chart -s templates/verifier-job.yaml --set profile=lww \
  --set verifier.run=true --set verifier.epoch=t \
  | grep -E 'connect-sink-dns|connect-sink-port'
```
Expected: shows `--connect-sink-dns=lab-connect-sink-headless` and `--connect-sink-port=4195`.

- [ ] **Step 9: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-multi-k8s/verifier labs/redis-connect-lww-multi-k8s/chart/templates/verifier-job.yaml
git commit -m "lww-multi-k8s: verifier sums lww_apply across all sink pods (fail-loud on restart)"
```

---

## Task 5: Proof C — deterministic multi-writer lost-update negative proof

**Files:**
- Create: `labs/redis-connect-lww-multi-k8s/scripts/proof-c.sh`

- [ ] **Step 1: Write the Proof C script**

Create `scripts/proof-c.sh` (and `chmod +x`):
```bash
#!/usr/bin/env bash
# Proof C — NEGATIVE. Scaling the *writer* (two uncoordinated owners of one key)
# breaks LWW via a silent same-version lost update that the version-only
# CompareVersions check CANNOT detect. Scripted directly against redis-region with
# lww_set.lua (same style as Proof A); no pipeline involved.
#
# Two writers A and B each "own" the SAME key and each stamp versions 1..K with
# their own value namespace, interleaved (A:v1, B:v1, A:v2, B:v2, ...). A reaches
# each version first → applied(1); B's equal-version write → duplicate(-1), dropped.
# Result: region ends at ver=K (== writer B's max → a version-only verifier querying
# B would report mismatches=0, a FALSE pass) but val=A:vK — B's version-K commit is
# silently lost.
set -euo pipefail
NS="${1:?usage: proof-c.sh <namespace> <redis-region-pod> [K]}"
POD="${2:?redis-region pod name}"
K="${3:-5}"
KEY="lwwproofC:1"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl -n "$NS" cp "${LAB_DIR}/chart/files/connect/lww_set.lua" "${POD}:/tmp/lww_set.lua"
OUT="$(kubectl -n "$NS" exec "$POD" -- sh -c '
  K='"$K"'; KEY="'"$KEY"'"
  redis-cli DEL "$KEY" >/dev/null
  a=""; b=""
  v=1
  while [ "$v" -le "$K" ]; do
    a=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , "A:v$v" "$v")
    b=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , "B:v$v" "$v")
    v=$((v+1))
  done
  echo "aK=$a bK=$b ver=$(redis-cli HGET "$KEY" ver) val=$(redis-cli HGET "$KEY" val)"
')"
echo "[proofC] ${OUT}"
AK="$(echo "$OUT"  | sed -n 's/.*aK=\([-0-9]*\).*/\1/p')"
BK="$(echo "$OUT"  | sed -n 's/.*bK=\([-0-9]*\).*/\1/p')"
VER="$(echo "$OUT" | sed -n 's/.*ver=\([0-9]*\).*/\1/p')"
VAL="$(echo "$OUT" | sed -n 's/.*val=\([A-Za-z0-9:]*\).*/\1/p')"

fail=0
# (a) version-only check is SATISFIED: region ver == K == each writer's max.
[ "$VER" = "$K" ]        || { echo "[proofC] FAIL: expected ver=$K (version-only check would pass), got '$VER'"; fail=1; }
# A's version-K write applied; B's equal-version write was dropped as duplicate.
[ "$AK" = "1" ]          || { echo "[proofC] FAIL: expected writer A v$K applied(1), got '$AK'"; fail=1; }
[ "$BK" = "-1" ]         || { echo "[proofC] FAIL: expected writer B v$K duplicate(-1), got '$BK'"; fail=1; }
# (b) value check REVEALS the loss: region holds A:vK; B's committed v$K vanished.
[ "$VAL" = "A:v$K" ]     || { echo "[proofC] FAIL: expected val=A:v$K (B's v$K lost), got '$VAL'"; fail=1; }
[ "$fail" = 0 ] || exit 1

echo "[proofC] PASS — multi-writer lost update CONFIRMED:"
echo "  region ver=$K equals writer B's max version → a version-only check (CompareVersions)"
echo "  reports mismatches=0 and would FALSELY pass; yet region val=A:v$K means writer B's"
echo "  version-$K commit was silently dropped as a duplicate. The single-writer-per-key"
echo "  precondition is load-bearing: multi-CONNECT is safe (connect never mints versions),"
echo "  multi-WRITER is not."
```

- [ ] **Step 2: Make it executable**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
chmod +x scripts/proof-c.sh
bash -n scripts/proof-c.sh && echo SYNTAX_OK
```
Expected: `SYNTAX_OK` (syntax check passes; full run happens in Task 6/8 against a live cluster).

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-multi-k8s/scripts/proof-c.sh
git commit -m "lww-multi-k8s: Proof C — deterministic multi-writer lost-update negative proof"
```

---

## Task 6: Fork verify-lww.sh to run Proof A + Proof C + Proof B′

**Files:**
- Modify: `labs/redis-connect-lww-multi-k8s/scripts/verify-lww.sh`

- [ ] **Step 1: Insert the Proof C invocation after Proof A**

In `scripts/verify-lww.sh`, immediately after the `echo "[proofA] PASS"` line (line ~50), insert:
```bash

echo "[proofC] negative: multi-writer (two owners of one key) breaks LWW invisibly"
bash "${SCRIPT_DIR}/proof-c.sh" "${NS}" "$(REGION_POD)" 5
echo "[proofC] PASS"
```

- [ ] **Step 2: Update the banner/comment to reflect the three proofs**

In `scripts/verify-lww.sh`, change the header comment (lines 2-4) from:
```bash
# LWW verification harness. Boots the chart (profile=lww), runs Proof A
# (deterministic 3->1->2 + duplicate, direct to redis-region) and Proof B
# (end-to-end verifier Job at a target rate). Exits 0 iff both pass.
```
to:
```bash
# LWW (multi-instance) verification harness. Boots the chart (profile=lww) with
# N>1 connect-source + connect-sink pods, then runs:
#   Proof A  — deterministic fence mechanism (3->1->2 + duplicate, direct to region)
#   Proof C  — NEGATIVE: multi-writer same-version lost update, invisible to the
#              version-only check (proves the single-writer-per-key precondition)
#   Proof B' — end-to-end positive: fence holds (mismatches=0, stale>0) under
#              INTER-pod reordering, with lww_apply summed across all sink pods.
# Exits 0 iff all three pass.
```

- [ ] **Step 3: Update the final success message**

In `scripts/verify-lww.sh`, change the final pass line (line ~79) from:
```bash
  echo "[verify-lww] PASS — both proofs green"; exit 0
```
to:
```bash
  echo "[verify-lww] PASS — all three proofs green (A mechanism, C negative, B' multi-instance)"; exit 0
```

- [ ] **Step 4: Syntax check**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
bash -n scripts/verify-lww.sh && echo SYNTAX_OK
```
Expected: `SYNTAX_OK`.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-multi-k8s/scripts/verify-lww.sh
git commit -m "lww-multi-k8s: verify-lww.sh runs Proof A + Proof C + Proof B'"
```

---

## Task 7: Rewrite RESEARCH.md and README.md for the multi-instance property

**Files:**
- Modify: `labs/redis-connect-lww-multi-k8s/RESEARCH.md`
- Modify: `labs/redis-connect-lww-multi-k8s/README.md`

- [ ] **Step 1: Rewrite RESEARCH.md**

Replace `RESEARCH.md` with content covering, in this order (use the spec as source):
1. **Property demonstrated** — verbatim the spec's one-sentence property.
2. **Essentials** — the two inter-pod reorder vectors (source consumer-group split; sink deliver-group concurrent CAS); why the fence is order- and pod-count-independent (Redis serializes per-key EVAL).
3. **Wire contract** — unchanged from parent EXCEPT: sink input adds `queue: region-writer-q`; verifier scrapes per-pod via headless Service DNS and sums `lww_apply`.
4. **How the proof is unambiguous** — Proof B′ keeps the parent's §3.4.1 guards; ADD that `lww_apply` is summed across pods with a per-pod restart guard (counter regression ⇒ hard fail).
5. **The negative result (Proof C)** — the version-only-blindness finding (`CompareVersions` checks version, not value); multi-writer drops a committed write as `duplicate` with no signal.
6. **Validated result** — fill in with the ACTUAL numbers captured in Task 8 (do not invent; run first, then write).
7. **Design decisions / rejected alternatives** — carry the parent's, plus: deliver-group vs per-pod-durable fan-out (whichever Task 3 selected, with the evidence); DNS enumeration vs K8s API (chose DNS — no RBAC).
8. **Deliberately excluded** — writer-HA fix, Redis Cluster, HPA, chaos (per spec).

- [ ] **Step 2: Rewrite README.md**

Replace `README.md` with: what it demonstrates (multi-instance), the `Run it (kind)` block (cluster name `lwwm`, release `lwwm`), expected output for all three proofs, the dashboard caveat (the dashboard scrapes the round-robin Service so it shows ONE pod's counters — the verifier is the authoritative aggregator), the inconclusive-run guidance (carry from parent), and teardown. Mirror the parent README's structure.

- [ ] **Step 3: Commit (docs first; validated numbers filled in Task 8)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-multi-k8s/RESEARCH.md labs/redis-connect-lww-multi-k8s/README.md
git commit -m "lww-multi-k8s: RESEARCH.md + README.md for the multi-instance property"
```

---

## Task 8: End-to-end validation on kind

**Files:** none (validation run); updates `RESEARCH.md` with observed numbers.

- [ ] **Step 1: Build, boot, and run the full verification**

Run:
```bash
cd labs/redis-connect-lww-multi-k8s
kind create cluster --name lwwm
scripts/build-images.sh --kind --kind-name=lwwm
RRCS_NS=lwwm-k8s RRCS_RELEASE=lwwm scripts/verify-lww.sh 2>&1 | tee /tmp/lwwm-verify.log
```
Expected final line: `[verify-lww] PASS — all three proofs green (A mechanism, C negative, B' multi-instance)` and exit code 0.

- [ ] **Step 2: Confirm the proof signals are genuine**

Run:
```bash
grep -E '\[proofA\] PASS|\[proofC\] PASS|"mismatches":0|"stale":[1-9]' /tmp/lwwm-verify.log
kubectl -n lwwm-k8s get pod -l app=connect-sink --no-headers | wc -l   # expect 3
```
Expected: Proof A PASS, Proof C PASS, Proof B′ JSON shows `"mismatches":0` and `"stale">0`; 3 sink pods. (If `stale==0` ⇒ inconclusive: re-run with `RATE=20000 DURATION_S=30` or lower `KEY_SPACE_SIZE` per the parent's tuning note.)

- [ ] **Step 3: Record the actual measured numbers in RESEARCH.md**

Copy the Proof B′ `RESULT_JSON` line and the sink pod count from `/tmp/lwwm-verify.log` into the RESEARCH.md "Validated result" section (the real `stale`, `mismatches`, `rate_achieved_avg`, `writes_per_key_avg`, and "aggregating lww_apply across N sink pods" log line). Do not invent numbers.

- [ ] **Step 4: Tear down**

Run:
```bash
helm uninstall lwwm -n lwwm-k8s || true
kind delete cluster --name lwwm
docker ps -a --filter name=lwwm --format '{{.Names}}'   # expect empty
```
Expected: no leftover lab containers.

- [ ] **Step 5: Commit the validated numbers**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-multi-k8s/RESEARCH.md
git commit -m "lww-multi-k8s: record validated multi-instance run (mismatches=0, stale>0, N sink pods)"
```

---

## Self-Review

**Spec coverage:**
- Property (multi-instance fence holds; multi-writer breaks) → Tasks 1-6, proven in 8. ✓
- Replica knobs default 3 → Task 1. ✓
- JetStream shared-durable resolution (research unknown) → Task 3 (with empirical gate + documented fallback). ✓
- Headless Service + per-pod metric aggregation with fail-loud guards → Tasks 2, 4. ✓
- `CompareVersions` value-blindness / Proof C → Task 5. ✓
- Forked verify-lww.sh (Proof C + Proof B′) → Task 6. ✓
- RESEARCH.md + README.md → Task 7 (numbers in 8). ✓
- Correctness check unchanged (region Redis is source of truth) → noted in Task 4 Step 5. ✓

**Placeholder scan:** No TBD/TODO. The only "fill in later" is the *measured numbers* in RESEARCH.md, which are necessarily produced by the Task 8 run and have explicit capture instructions (not a plan placeholder).

**Type consistency:** `lwwCounts{applied,stale,duplicate}`, `scrapeAllPairs`, `sumDelta`, `NewSinkBaseline`, `(*SinkBaseline).Delta`, `(*SinkBaseline).PodCount` are defined in Task 4 Step 3 and used consistently in Steps 1 and 5. Flags `--connect-sink-dns` / `--connect-sink-port` defined (Step 5a) and consumed by the Job template (Step 7). `queue: region-writer-q` (Task 3) matches the `printf "%s-q"` of `nats.stream.consumer.durable: "region-writer"`.

---

## Execution Handoff

This is a Kubernetes lab (kind + Helm + Go). It builds working, testable software at each task: chart renders are asserted per task, the verifier change is TDD'd with Go unit tests (Task 4), and the whole thing is validated end-to-end on kind (Task 8).
