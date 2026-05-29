# Redis → Redpanda Connect Stress Lab (Kubernetes Fork) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork the Docker Compose stress lab `labs/redis-redpanda-connect-stress/` into a Kubernetes-native lab `labs/redis-redpanda-connect-stress-k8s/`, deployed as a Helm chart and exercised by a host `kubectl` harness, producing the same tier × mode × QoS verdict matrix.

**Architecture:** The pipeline (Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis) is unchanged; only the deployment substrate changes. Seven long-lived workloads + a stream-init Job ship as a Helm chart; the collector runs as a per-run Job rendered via `helm template -s ... | kubectl apply`. A host harness (`stress-run.sh`) drives the matrix over `kubectl`, extracting each verdict from the collector's stdout via a `RESULT_JSON:` sentinel. Chaos = scale `connect-sink` to 0, sleep, back to 1, gated by readiness probes.

**Tech Stack:** Helm 3, kubectl, kind (local dev), Docker, Go 1.24 (collector/writer, copied from source), bash. The full design is in `docs/superpowers/specs/2026-05-29-redis-redpanda-connect-stress-k8s-design.md`.

**Testing strategy (per task type):**
- **Go (collector change):** strict TDD — failing test first, then implementation.
- **Helm templates:** `helm lint` + `helm template … | grep`/`yq` render assertions (the testable surface for templates).
- **Bash scripts:** `bash -n` syntax check + `shellcheck` + `--help`/dry-run where possible.
- **Integration:** a final kind end-to-end task installs the chart and runs one tiny matrix cell + one chaos cell.

**Prerequisites the executor must have installed:** `helm`, `kubectl`, `kind`, `docker`, `go`, `shellcheck`, `yq` (optional; grep fallbacks given). Verify with `helm version && kubectl version --client && kind version && docker version && go version && shellcheck --version`.

**Conventions used throughout:**
- New lab root: `labs/redis-redpanda-connect-stress-k8s/` (abbreviated below as `$LAB`).
- Namespace: `rrcs-k8s`.
- Run every command from the repo root `/media/hp/secondary/projects/gam-redis-pubsub` unless stated.
- Commit after each task with the message shown.

---

### Task 1: Scaffold lab directory and copy verbatim source assets

Creates the new lab tree and copies the files that are reused unchanged (Go services, connect configs, tier-defs). The connect YAMLs are copied into `chart/files/connect/` so Helm `.Files` can read them (design fix #2).

**Files:**
- Create dir: `labs/redis-redpanda-connect-stress-k8s/`
- Copy: source `writer/` → `$LAB/writer/`
- Copy: source `collector/` → `$LAB/collector/`
- Copy: source `connect/*.yaml` → `$LAB/chart/files/connect/`
- Copy: source `scripts/lib/tier-defs.sh` → `$LAB/scripts/lib/tier-defs.sh`
- Create: `$LAB/.gitignore`

- [ ] **Step 1: Create the directory tree**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
LAB=labs/redis-redpanda-connect-stress-k8s
mkdir -p "$LAB/chart/templates" "$LAB/chart/files/connect" "$LAB/scripts/chaos" "$LAB/scripts/lib" "$LAB/reports"
```

- [ ] **Step 2: Copy the Go services and connect configs (verbatim), drop stale build artifacts**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
LAB=labs/redis-redpanda-connect-stress-k8s
SRC=labs/redis-redpanda-connect-stress
cp -r "$SRC/writer" "$LAB/writer"
cp -r "$SRC/collector" "$LAB/collector"
cp "$SRC"/connect/*.yaml "$LAB/chart/files/connect/"
cp "$SRC/scripts/lib/tier-defs.sh" "$LAB/scripts/lib/tier-defs.sh"
# Remove committed binaries (the source dir has prebuilt ./writer and ./collector executables)
rm -f "$LAB/writer/writer" "$LAB/collector/collector"
```

- [ ] **Step 3: Create `$LAB/.gitignore`**

```gitignore
# Built Go binaries
writer/writer
collector/collector
# Rendered manifests
out/
# Local run output
reports/*.json
```

- [ ] **Step 4: Verify the copied Go modules still build and test**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
( cd writer && go build ./... && go test ./... )
( cd collector && go build ./... && go test ./... )
```
Expected: both `go build` succeed and `go test` prints `ok` for each module (writer has `limiter_test.go`/`payload_test.go`; collector has several `_test.go`).

- [ ] **Step 5: Verify connect files and tier-defs landed**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
ls chart/files/connect/ && test -f scripts/lib/tier-defs.sh && echo OK
```
Expected: lists `alo-forward.yaml alo-reverse.yaml amo-forward.yaml amo-reverse.yaml eoe-forward.yaml eoe-reverse.yaml` and prints `OK`.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/
git commit -m "rrcs-k8s: scaffold lab dir, copy writer/collector/connect/tier-defs"
```

---

### Task 2: Add `--out=-` stdout mode to the collector (TDD)

The collector currently writes indented multi-line JSON to a file and exits 1 on verdict-fail. For K8s, add a `--out=-` mode that emits exactly one compact `RESULT_JSON:<json>` line on stdout and **exits 0 whenever it produced a report** (verdict travels in the JSON, not the exit code — design §6). The file path behavior is unchanged.

**Files:**
- Modify: `$LAB/collector/main.go` (the `writeJSON`/`main` output path, lines 36-101 and 103-126)
- Create: `$LAB/collector/result_out_test.go`

- [ ] **Step 1: Write the failing test**

Create `labs/redis-redpanda-connect-stress-k8s/collector/result_out_test.go`:

```go
package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mkReport(pass bool) Report {
	return Report{
		Tier: 10, Mode: "throughput", Profile: "alo",
		Verdict: Verdict{Pass: pass, Checks: map[string]bool{"rate_ok": pass}},
	}
}

func TestWriteReportStdoutEmitsSingleSentinelLine(t *testing.T) {
	var buf bytes.Buffer
	exitFail, err := writeReport("-", &buf, mkReport(false))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if exitFail {
		t.Fatalf("stdout mode must never set exitFail (verdict travels in JSON)")
	}
	out := buf.String()
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("want exactly 1 line, got %d: %q", len(lines), out)
	}
	const prefix = "RESULT_JSON:"
	if !strings.HasPrefix(lines[0], prefix) {
		t.Fatalf("line must start with %q, got %q", prefix, lines[0])
	}
	var r Report
	if err := json.Unmarshal([]byte(strings.TrimPrefix(lines[0], prefix)), &r); err != nil {
		t.Fatalf("payload after sentinel must be valid JSON: %v", err)
	}
	if r.Verdict.Pass != false || r.Tier != 10 {
		t.Fatalf("round-trip mismatch: got pass=%v tier=%d", r.Verdict.Pass, r.Tier)
	}
}

func TestWriteReportStdoutPassAlsoExitsZero(t *testing.T) {
	var buf bytes.Buffer
	exitFail, err := writeReport("-", &buf, mkReport(true))
	if err != nil || exitFail {
		t.Fatalf("pass verdict in stdout mode: err=%v exitFail=%v", err, exitFail)
	}
}

func TestWriteReportFileModeKeepsExitOnFail(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "run.json")
	exitFail, err := writeReport(path, &bytes.Buffer{}, mkReport(false))
	if err != nil {
		t.Fatalf("file write failed: %v", err)
	}
	if !exitFail {
		t.Fatalf("file mode must report exitFail=true on verdict fail (legacy behavior)")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("report file not written: %v", err)
	}
	if !bytes.Contains(b, []byte("\n")) {
		t.Fatalf("file mode should still write indented (multi-line) JSON")
	}
}
```

- [ ] **Step 2: Run the test to verify it fails (function not defined)**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s/collector
go test ./... -run TestWriteReport -v
```
Expected: FAIL — compile error `undefined: writeReport`.

- [ ] **Step 3: Implement `writeReport` and wire it into `main`**

In `labs/redis-redpanda-connect-stress-k8s/collector/main.go`, add the `io` and `fmt` imports if missing (`fmt` is already imported; add `io`), then add this function near `writeJSON` (after line 126):

```go
const resultSentinel = "RESULT_JSON:"

// writeReport emits the report. When path == "-" it prints exactly one compact
// "RESULT_JSON:{...}" line to stdout and returns exitFail=false unconditionally:
// in stdout mode the verdict travels in the JSON, never the process exit code
// (so a legitimately-failing verdict does not trip a K8s Job into failure/retry).
// For a real path it writes indented JSON atomically (legacy) and returns
// exitFail = !r.Verdict.Pass so the caller exits 1 on a failing verdict.
func writeReport(path string, stdout io.Writer, r Report) (exitFail bool, err error) {
	if path == "-" {
		b, err := json.Marshal(r)
		if err != nil {
			return false, err
		}
		if _, err := fmt.Fprintf(stdout, "%s%s\n", resultSentinel, b); err != nil {
			return false, err
		}
		return false, nil
	}
	if err := writeJSON(path, r); err != nil {
		return false, err
	}
	return !r.Verdict.Pass, nil
}
```

Then replace the output block in `main` (currently lines 94-100):

```go
	if err := writeJSON(*out, r); err != nil {
		log.Fatalf("write %s: %v", *out, err)
	}
	log.Printf("report written to %s; verdict.pass=%v", *out, r.Verdict.Pass)
	if !r.Verdict.Pass {
		os.Exit(1)
	}
```

with:

```go
	exitFail, err := writeReport(*out, os.Stdout, r)
	if err != nil {
		log.Fatalf("emit report (%s): %v", *out, err)
	}
	log.Printf("report emitted (out=%s); verdict.pass=%v", *out, r.Verdict.Pass)
	if exitFail {
		os.Exit(1)
	}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s/collector
go test ./... -v
```
Expected: PASS — the three `TestWriteReport*` tests pass and all pre-existing collector tests still pass.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/collector/
git commit -m "rrcs-k8s: collector --out=- stdout mode (RESULT_JSON sentinel, exit 0 on report)"
```

---

### Task 3: Make Dockerfile base images registry-configurable

Add `ARG BASE_REGISTRY` before each `FROM` in both Dockerfiles so the base images can be redirected to a corporate/airgapped mirror (design §8). Default `""` reproduces today's behavior.

**Files:**
- Modify: `$LAB/writer/Dockerfile`
- Modify: `$LAB/collector/Dockerfile`

- [ ] **Step 1: Edit `$LAB/writer/Dockerfile`**

Replace the two `FROM` lines so the file reads:

```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/writer .

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
RUN apk add --no-cache wget ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/writer /usr/local/bin/writer
ENTRYPOINT ["/usr/local/bin/writer"]
```

Note: `ARG BASE_REGISTRY` must be repeated after the first `FROM` because an `ARG` declared before `FROM` goes out of scope inside each build stage.

- [ ] **Step 2: Edit `$LAB/collector/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/collector .

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
RUN apk add --no-cache wget ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/collector /usr/local/bin/collector
ENTRYPOINT ["/usr/local/bin/collector"]
```

- [ ] **Step 3: Verify both images build with the default (empty) base registry**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
docker build -t rrcs-k8s-test/writer:probe ./writer
docker build -t rrcs-k8s-test/collector:probe ./collector
```
Expected: both builds succeed (the `ARG BASE_REGISTRY=""` default yields `FROM golang:1.25-alpine` / `FROM alpine:3.20`, identical to before).

- [ ] **Step 4: Verify the build-arg is actually consumed (no "unconsumed build arg" warning)**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
docker build --build-arg BASE_REGISTRY= -t rrcs-k8s-test/writer:probe ./writer 2>&1 | grep -i "unconsumed" || echo "no unconsumed-arg warning (good)"
docker image rm rrcs-k8s-test/writer:probe rrcs-k8s-test/collector:probe >/dev/null 2>&1 || true
```
Expected: prints `no unconsumed-arg warning (good)`.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/writer/Dockerfile labs/redis-redpanda-connect-stress-k8s/collector/Dockerfile
git commit -m "rrcs-k8s: ARG BASE_REGISTRY in writer/collector Dockerfiles"
```

---

### Task 4: Helm chart skeleton — Chart.yaml, values, helpers, NOTES

Create the chart metadata, the full value surface, the dev overlay, the helper templates, and install notes. No workload templates yet — those come in Tasks 5-10.

**Files:**
- Create: `$LAB/chart/Chart.yaml`
- Create: `$LAB/chart/values.yaml`
- Create: `$LAB/chart/values-dev.yaml`
- Create: `$LAB/chart/templates/_helpers.tpl`
- Create: `$LAB/chart/templates/NOTES.txt`

- [ ] **Step 1: Create `$LAB/chart/Chart.yaml`**

```yaml
apiVersion: v2
name: redis-redpanda-connect-stress
description: Kubernetes fork of the Redis -> Redpanda Connect -> NATS JetStream stress lab
type: application
version: 0.1.0
appVersion: "1.0.0"
```

- [ ] **Step 2: Create `$LAB/chart/values.yaml`**

```yaml
# Active QoS profile: alo | amo | eoe. Selects which connect config pair is mounted.
profile: alo

# The chart does NOT template a Namespace (design fix #3). Install with:
#   helm install rrcs ./chart -n rrcs-k8s --create-namespace

images:
  registry: ""              # prepended to every image ref. "" => use ref as-is.
  pullPolicy: IfNotPresent  # global default; public images need this on kind.
  pullSecrets: []           # list of { name: <secret-name> }

redis:
  image: redis:7.4-alpine

nats:
  image: nats:2.10-alpine
  clientPort: 4222
  monitorPort: 8222
  stream:
    name: APP_EVENTS
    subjects: "app.events.>"
    maxAge: "1h"
    maxBytes: "256MB"
    maxMsgSize: "1MB"
    dupeWindow: "5m"
  persistence:
    mode: emptyDir          # emptyDir | pvc
    size: 4Gi               # used only when mode=pvc
    storageClassName: ""    # used only when mode=pvc; "" => omit (cluster default)

natsBox:
  image: natsio/nats-box:0.14.5

connect:
  image: hpdevelop/connect:4.92.0-claudefix

writer:
  image: redis-rrcs/writer:dev
  pullPolicy: ""            # "" => inherit images.pullPolicy
  env:
    STREAM_MAXLEN: "100000"
    WORKERS: "8"
    PIPELINE_DEPTH: "50"
    KEY_SPACE_SIZE: "100000"
    PAYLOAD_BYTES: "200"
    MAX_RATE: "20000"

collector:
  image: redis-rrcs/collector:dev
  pullPolicy: ""            # "" => inherit images.pullPolicy
  # The harness sets the fields below per-run via `helm template -s ... --set`.
  run: false               # gate: only the harness renders the collector Job
  jobName: ""              # unique per-run name; defaults to a derived name if empty
  tier: 0
  mode: throughput
  durationS: 30
  warmupS: 5
  drainS: 10
  sloRatePct: "0.95"
  sloP99Ms: "1000"
  sloAllowMissing: false
  chaosAtS: 0
  chaosDurationS: 8

scheduling:
  nodeSelector: {}
  tolerations: []
  affinity: {}

resources:
  redis:
    requests: { cpu: 250m, memory: 128Mi }
    limits:   { cpu: "2",  memory: 512Mi }
  nats:
    requests: { cpu: 250m, memory: 256Mi }
    limits:   { cpu: "2",  memory: 1Gi }
  connect:
    requests: { cpu: 500m, memory: 256Mi }
    limits:   { cpu: "2",  memory: 1Gi }
  writer:
    requests: { cpu: 250m, memory: 64Mi }
    limits:   { cpu: "2",  memory: 256Mi }
  collector:
    requests: { cpu: 100m, memory: 64Mi }
    limits:   { cpu: 500m, memory: 128Mi }
```

- [ ] **Step 3: Create `$LAB/chart/values-dev.yaml`**

```yaml
# kind / local overlay. Images for writer+collector are built locally and
# side-loaded via `kind load docker-image`, so pin THOSE to Never (fail fast if
# not loaded, never attempt a registry pull). Public images stay at the global
# IfNotPresent so a fresh kind node can pull them.
writer:
  pullPolicy: Never
collector:
  pullPolicy: Never
nats:
  persistence:
    mode: emptyDir
```

- [ ] **Step 4: Create `$LAB/chart/templates/_helpers.tpl`**

```yaml
{{/*
rrcs.image — join the global registry prefix with a per-image ref.
Usage: {{ include "rrcs.image" (dict "root" $ "ref" .Values.writer.image) }}
*/}}
{{- define "rrcs.image" -}}
{{- printf "%s%s" .root.Values.images.registry .ref -}}
{{- end -}}

{{/*
rrcs.pullPolicy — per-image override or global default.
Usage: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.writer.pullPolicy) }}
*/}}
{{- define "rrcs.pullPolicy" -}}
{{- if .override }}{{ .override }}{{- else }}{{ .root.Values.images.pullPolicy }}{{- end -}}
{{- end -}}

{{/*
rrcs.imagePullSecrets — render imagePullSecrets if any are configured.
Usage (at pod-spec indent): {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "rrcs.imagePullSecrets" -}}
{{- with .Values.images.pullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ .name }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
rrcs.scheduling — global nodeSelector / tolerations / affinity for every pod.
Usage (at pod-spec indent): {{- include "rrcs.scheduling" . | nindent 6 }}
*/}}
{{- define "rrcs.scheduling" -}}
{{- with .Values.scheduling.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.scheduling.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.scheduling.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
```

- [ ] **Step 5: Create `$LAB/chart/templates/NOTES.txt`**

```txt
redis-redpanda-connect-stress (Kubernetes fork) installed in namespace {{ .Release.Namespace }}.

Active QoS profile: {{ .Values.profile }}
NATS persistence : {{ .Values.nats.persistence.mode }}

Run the stress matrix from the host:
  bash scripts/stress-run.sh --tiers=10 --modes=throughput --profile={{ .Values.profile }}

Tear down:
  helm uninstall {{ .Release.Name }} -n {{ .Release.Namespace }}
```

- [ ] **Step 6: Lint the chart**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm lint chart/
```
Expected: `1 chart(s) linted, 0 chart(s) failed` (an INFO about no icon is fine).

- [ ] **Step 7: Verify values render without error**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s >/dev/null && echo "render OK"
```
Expected: prints `render OK` (no templates yet → empty render, no error).

- [ ] **Step 8: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/
git commit -m "rrcs-k8s: Helm chart skeleton (Chart.yaml, values, helpers, NOTES)"
```

---

### Task 5: Connect config ConfigMaps template

Render two ConfigMaps holding the active profile's forward/reverse Connect YAMLs, read from `chart/files/connect/` (design fix #2). connect-source/sink mount these in Task 8.

**Files:**
- Create: `$LAB/chart/templates/connect-configmaps.yaml`

- [ ] **Step 1: Create `$LAB/chart/templates/connect-configmaps.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: connect-source-config
  labels: { app: connect-source }
data:
  connect.yaml: |-
{{ .Files.Get (printf "files/connect/%s-forward.yaml" .Values.profile) | indent 4 }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: connect-sink-config
  labels: { app: connect-sink }
data:
  connect.yaml: |-
{{ .Files.Get (printf "files/connect/%s-reverse.yaml" .Values.profile) | indent 4 }}
```

- [ ] **Step 2: Assert the active profile's forward config is embedded**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s --set profile=alo \
  | grep -q "redis://redis-central:6379" && echo "source config embedded OK"
```
Expected: prints `source config embedded OK` (the alo-forward.yaml content includes the central Redis URL).

- [ ] **Step 3: Assert profile switching changes the rendered content**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s --set profile=eoe -s templates/connect-configmaps.yaml \
  | grep -c "connect.yaml" 
```
Expected: prints `2` (one key in each of the two ConfigMaps). The command rendering without error confirms `eoe-forward.yaml`/`eoe-reverse.yaml` exist and embed.

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-configmaps.yaml
git commit -m "rrcs-k8s: connect config ConfigMaps from chart/files (profile-selected)"
```

---

### Task 6: Redis Deployments + Services (central, region)

Two near-identical Deployments + ClusterIP Services. Names must be exactly `redis-central` / `redis-region` (the connect YAMLs and writer env address them by DNS).

**Files:**
- Create: `$LAB/chart/templates/redis-central.yaml`
- Create: `$LAB/chart/templates/redis-region.yaml`

- [ ] **Step 1: Create `$LAB/chart/templates/redis-central.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-central
  labels: { app: redis-central }
spec:
  replicas: 1
  selector:
    matchLabels: { app: redis-central }
  template:
    metadata:
      labels: { app: redis-central }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      containers:
        - name: redis
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          args:
            - redis-server
            - --notify-keyspace-events
            - ""
            - --appendonly
            - "no"
            - --save
            - ""
          ports:
            - containerPort: 6379
          readinessProbe:
            exec: { command: ["redis-cli", "ping"] }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          livenessProbe:
            exec: { command: ["redis-cli", "ping"] }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          resources:
            {{- toYaml .Values.resources.redis | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: redis-central
  labels: { app: redis-central }
spec:
  selector: { app: redis-central }
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
```

- [ ] **Step 2: Create `$LAB/chart/templates/redis-region.yaml`**

Identical to Step 1 but with every `redis-central` replaced by `redis-region`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-region
  labels: { app: redis-region }
spec:
  replicas: 1
  selector:
    matchLabels: { app: redis-region }
  template:
    metadata:
      labels: { app: redis-region }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      containers:
        - name: redis
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          args:
            - redis-server
            - --notify-keyspace-events
            - ""
            - --appendonly
            - "no"
            - --save
            - ""
          ports:
            - containerPort: 6379
          readinessProbe:
            exec: { command: ["redis-cli", "ping"] }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          livenessProbe:
            exec: { command: ["redis-cli", "ping"] }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          resources:
            {{- toYaml .Values.resources.redis | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: redis-region
  labels: { app: redis-region }
spec:
  selector: { app: redis-region }
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
```

- [ ] **Step 3: Assert both Deployments and Services render**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s | grep -E "name: redis-(central|region)" | sort -u
```
Expected: shows `name: redis-central` and `name: redis-region` (each appears for both the Deployment and Service).

- [ ] **Step 4: Validate the rendered YAML is well-formed**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -s templates/redis-central.yaml | kubectl apply --dry-run=client -f - 2>&1 | tail -3
```
Expected: `deployment.apps/redis-central created (dry run)` and `service/redis-central created (dry run)` (client-side validation only; no cluster needed).

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/redis-central.yaml labs/redis-redpanda-connect-stress-k8s/chart/templates/redis-region.yaml
git commit -m "rrcs-k8s: redis-central and redis-region Deployments + Services"
```

---

### Task 7: NATS Deployment + Service + stream-init Job

NATS JetStream broker with switchable persistence (emptyDir|pvc, fix #11), plus the stream-init **plain Job** (not a hook, fix #1) that idempotently creates `APP_EVENTS`. Every `nats` CLI call carries the full `--server nats://nats:4222` URL (fix #4).

**Files:**
- Create: `$LAB/chart/templates/nats.yaml`
- Create: `$LAB/chart/templates/nats-init-job.yaml`

- [ ] **Step 1: Create `$LAB/chart/templates/nats.yaml`**

```yaml
{{- if eq .Values.nats.persistence.mode "pvc" }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nats-data
  labels: { app: nats }
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: {{ .Values.nats.persistence.size }}
  {{- if .Values.nats.persistence.storageClassName }}
  storageClassName: {{ .Values.nats.persistence.storageClassName }}
  {{- end }}
---
{{- end }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nats
  labels: { app: nats }
spec:
  replicas: 1
  selector:
    matchLabels: { app: nats }
  template:
    metadata:
      labels: { app: nats }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      containers:
        - name: nats
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.nats.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          args: ["-js", "-sd", "/data", "-m", "{{ .Values.nats.monitorPort }}"]
          ports:
            - { name: client, containerPort: {{ .Values.nats.clientPort }} }
            - { name: monitor, containerPort: {{ .Values.nats.monitorPort }} }
          readinessProbe:
            httpGet: { path: /healthz, port: {{ .Values.nats.monitorPort }} }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          livenessProbe:
            httpGet: { path: /healthz, port: {{ .Values.nats.monitorPort }} }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            {{- toYaml .Values.resources.nats | nindent 12 }}
      volumes:
        - name: data
        {{- if eq .Values.nats.persistence.mode "pvc" }}
          persistentVolumeClaim:
            claimName: nats-data
        {{- else }}
          emptyDir: {}
        {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: nats
  labels: { app: nats }
spec:
  selector: { app: nats }
  ports:
    - { name: client, port: {{ .Values.nats.clientPort }}, targetPort: {{ .Values.nats.clientPort }} }
    - { name: monitor, port: {{ .Values.nats.monitorPort }}, targetPort: {{ .Values.nats.monitorPort }} }
```

- [ ] **Step 2: Create `$LAB/chart/templates/nats-init-job.yaml`**

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: nats-init
  labels: { app: nats-init }
spec:
  backoffLimit: 6
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: { app: nats-init }
    spec:
      restartPolicy: OnFailure
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      initContainers:
        - name: wait-nats
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.natsBox.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - |
              until nats --server nats://nats:{{ .Values.nats.clientPort }} rtt >/dev/null 2>&1; do
                echo "waiting for nats..."; sleep 1;
              done
      containers:
        - name: create-stream
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.natsBox.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              SERVER="nats://nats:{{ .Values.nats.clientPort }}"
              if nats --server "$SERVER" stream info {{ .Values.nats.stream.name }} >/dev/null 2>&1; then
                echo "{{ .Values.nats.stream.name }} already exists"
              else
                nats --server "$SERVER" stream add {{ .Values.nats.stream.name }} \
                  --subjects '{{ .Values.nats.stream.subjects }}' \
                  --storage file \
                  --replicas 1 \
                  --retention limits \
                  --discard old \
                  --max-age {{ .Values.nats.stream.maxAge }} \
                  --max-bytes {{ .Values.nats.stream.maxBytes }} \
                  --max-msgs=-1 \
                  --max-msg-size={{ .Values.nats.stream.maxMsgSize }} \
                  --dupe-window {{ .Values.nats.stream.dupeWindow }} \
                  --defaults
              fi
              nats --server "$SERVER" stream info {{ .Values.nats.stream.name }}
          resources:
            {{- toYaml .Values.resources.collector | nindent 12 }}
```

- [ ] **Step 3: Assert default (emptyDir) renders no PVC and includes the full NATS URL**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s | grep -q "kind: PersistentVolumeClaim" && echo "PVC present (WRONG for default)" || echo "no PVC at default (OK)"
helm template rrcs chart/ -n rrcs-k8s | grep -q "emptyDir: {}" && echo "emptyDir OK"
helm template rrcs chart/ -n rrcs-k8s | grep -q "nats --server nats://nats:4222 stream info" && echo "full --server URL OK"
```
Expected: `no PVC at default (OK)`, `emptyDir OK`, `full --server URL OK`.

- [ ] **Step 4: Assert pvc mode renders a PVC and omits storageClassName when blank**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s --set nats.persistence.mode=pvc -s templates/nats.yaml | grep -A8 "kind: PersistentVolumeClaim"
helm template rrcs chart/ -n rrcs-k8s --set nats.persistence.mode=pvc -s templates/nats.yaml | grep -q "storageClassName" && echo "storageClassName present (WRONG when blank)" || echo "storageClassName omitted when blank (OK)"
helm template rrcs chart/ -n rrcs-k8s --set nats.persistence.mode=pvc --set nats.persistence.storageClassName=standard -s templates/nats.yaml | grep -q "storageClassName: standard" && echo "storageClassName emitted when set (OK)"
```
Expected: PVC block shown; `storageClassName omitted when blank (OK)`; `storageClassName emitted when set (OK)`.

- [ ] **Step 5: Validate rendered YAML client-side**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -s templates/nats.yaml | kubectl apply --dry-run=client -f - 2>&1 | tail -2
helm template rrcs chart/ -n rrcs-k8s -s templates/nats-init-job.yaml | kubectl apply --dry-run=client -f - 2>&1 | tail -1
```
Expected: `deployment.apps/nats created (dry run)`, `service/nats created (dry run)`, `job.batch/nats-init created (dry run)`.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats.yaml labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-init-job.yaml
git commit -m "rrcs-k8s: NATS Deployment/Service (emptyDir|pvc) + plain stream-init Job"
```

---

### Task 8: Connect source + sink Deployments + Services

Both legs of the pipeline. Each has initContainers gating on its Redis + `APP_EVENTS` existence (full `--server` URL, fix #4), a `/ready` readiness probe (fix #6, makes chaos recovery a real gate), and mounts its profile ConfigMap at `/connect.yaml`.

**Files:**
- Create: `$LAB/chart/templates/connect-source.yaml`
- Create: `$LAB/chart/templates/connect-sink.yaml`

- [ ] **Step 1: Create `$LAB/chart/templates/connect-source.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connect-source
  labels: { app: connect-source }
spec:
  replicas: 1
  selector:
    matchLabels: { app: connect-source }
  template:
    metadata:
      labels: { app: connect-source }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      initContainers:
        - name: wait-redis-central
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until redis-cli -h redis-central ping | grep -q PONG; do echo waiting redis-central; sleep 1; done
        - name: wait-stream
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.natsBox.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until nats --server nats://nats:{{ .Values.nats.clientPort }} stream info {{ .Values.nats.stream.name }} >/dev/null 2>&1; do echo waiting stream; sleep 1; done
      containers:
        - name: connect
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.connect.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["run", "/connect.yaml"]
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
            - name: config
              mountPath: /connect.yaml
              subPath: connect.yaml
          resources:
            {{- toYaml .Values.resources.connect | nindent 12 }}
      volumes:
        - name: config
          configMap:
            name: connect-source-config
---
apiVersion: v1
kind: Service
metadata:
  name: connect-source
  labels: { app: connect-source }
spec:
  selector: { app: connect-source }
  ports:
    - name: http
      port: 4195
      targetPort: 4195
```

Note: Redpanda Connect serves `/ready` (ready to process) and `/ping` (liveness) on its HTTP port 4195; the compose healthcheck used `/ready`.

- [ ] **Step 2: Create `$LAB/chart/templates/connect-sink.yaml`**

Same shape as Step 1 but `connect-sink`, gating on `redis-region`, mounting `connect-sink-config`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: connect-sink
  labels: { app: connect-sink }
spec:
  replicas: 1
  selector:
    matchLabels: { app: connect-sink }
  template:
    metadata:
      labels: { app: connect-sink }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      initContainers:
        - name: wait-redis-region
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until redis-cli -h redis-region ping | grep -q PONG; do echo waiting redis-region; sleep 1; done
        - name: wait-stream
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.natsBox.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until nats --server nats://nats:{{ .Values.nats.clientPort }} stream info {{ .Values.nats.stream.name }} >/dev/null 2>&1; do echo waiting stream; sleep 1; done
      containers:
        - name: connect
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.connect.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["run", "/connect.yaml"]
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
            - name: config
              mountPath: /connect.yaml
              subPath: connect.yaml
          resources:
            {{- toYaml .Values.resources.connect | nindent 12 }}
      volumes:
        - name: config
          configMap:
            name: connect-sink-config
---
apiVersion: v1
kind: Service
metadata:
  name: connect-sink
  labels: { app: connect-sink }
spec:
  selector: { app: connect-sink }
  ports:
    - name: http
      port: 4195
      targetPort: 4195
```

- [ ] **Step 3: Assert probes, initContainers, and config mount render**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -s templates/connect-source.yaml | grep -q "path: /ready" && echo "readiness probe OK"
helm template rrcs chart/ -n rrcs-k8s -s templates/connect-sink.yaml | grep -q "redis-cli -h redis-region ping" && echo "sink redis gate OK"
helm template rrcs chart/ -n rrcs-k8s -s templates/connect-source.yaml | grep -q "subPath: connect.yaml" && echo "config subPath mount OK"
```
Expected: `readiness probe OK`, `sink redis gate OK`, `config subPath mount OK`.

- [ ] **Step 4: Client-side validate both**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
for t in connect-source connect-sink; do
  helm template rrcs chart/ -n rrcs-k8s -s templates/$t.yaml | kubectl apply --dry-run=client -f - 2>&1 | tail -2
done
```
Expected: `deployment.apps/connect-source created (dry run)` + its Service, and the same for `connect-sink`.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-source.yaml labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-sink.yaml
git commit -m "rrcs-k8s: connect-source and connect-sink Deployments with init gates + /ready probes"
```

---

### Task 9: Writer Deployment + Service

The load generator. Env mirrors compose verbatim (`REDIS_ADDR=redis-central:6379`, `STREAM_KEY=app.events`, `INITIAL_RATE=0`, tunables from values). initContainers gate on redis-central + connect-source `/ready`; readiness probe on `/healthz` (fix #6).

**Files:**
- Create: `$LAB/chart/templates/writer.yaml`

- [ ] **Step 1: Create `$LAB/chart/templates/writer.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: writer
  labels: { app: writer }
spec:
  replicas: 1
  selector:
    matchLabels: { app: writer }
  template:
    metadata:
      labels: { app: writer }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      initContainers:
        - name: wait-redis-central
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until redis-cli -h redis-central ping | grep -q PONG; do echo waiting redis-central; sleep 1; done
        - name: wait-connect-source
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until wget -q --spider http://connect-source:4195/ready; do echo waiting connect-source; sleep 1; done
      containers:
        - name: writer
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.writer.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.writer.pullPolicy) }}
          env:
            - { name: REDIS_ADDR,    value: "redis-central:6379" }
            - { name: STREAM_KEY,    value: "app.events" }
            - { name: INITIAL_RATE,  value: "0" }
            - { name: HEALTH_ADDR,   value: ":8081" }
            - { name: STREAM_MAXLEN, value: "{{ .Values.writer.env.STREAM_MAXLEN }}" }
            - { name: WORKERS,        value: "{{ .Values.writer.env.WORKERS }}" }
            - { name: PIPELINE_DEPTH, value: "{{ .Values.writer.env.PIPELINE_DEPTH }}" }
            - { name: KEY_SPACE_SIZE, value: "{{ .Values.writer.env.KEY_SPACE_SIZE }}" }
            - { name: PAYLOAD_BYTES,  value: "{{ .Values.writer.env.PAYLOAD_BYTES }}" }
            - { name: MAX_RATE,       value: "{{ .Values.writer.env.MAX_RATE }}" }
          ports:
            - containerPort: 8081
          readinessProbe:
            httpGet: { path: /healthz, port: 8081 }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          livenessProbe:
            httpGet: { path: /healthz, port: 8081 }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          resources:
            {{- toYaml .Values.resources.writer | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: writer
  labels: { app: writer }
spec:
  selector: { app: writer }
  ports:
    - name: http
      port: 8081
      targetPort: 8081
```

- [ ] **Step 2: Assert env, gates, and probe render correctly**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -s templates/writer.yaml | grep -q 'value: "redis-central:6379"' && echo "REDIS_ADDR OK"
helm template rrcs chart/ -n rrcs-k8s -s templates/writer.yaml | grep -q "http://connect-source:4195/ready" && echo "connect-source gate OK"
helm template rrcs chart/ -n rrcs-k8s -s templates/writer.yaml | grep -q "path: /healthz" && echo "writer probe OK"
```
Expected: `REDIS_ADDR OK`, `connect-source gate OK`, `writer probe OK`.

- [ ] **Step 3: Assert dev overlay pins writer pullPolicy to Never (public images unaffected)**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -f chart/values-dev.yaml -s templates/writer.yaml | grep -q "imagePullPolicy: Never" && echo "writer Never OK"
helm template rrcs chart/ -n rrcs-k8s -f chart/values-dev.yaml -s templates/redis-central.yaml | grep -q "imagePullPolicy: IfNotPresent" && echo "redis still IfNotPresent OK"
```
Expected: `writer Never OK` and `redis still IfNotPresent OK` (the per-image override works; public images keep the global policy).

- [ ] **Step 4: Client-side validate**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -s templates/writer.yaml | kubectl apply --dry-run=client -f - 2>&1 | tail -2
```
Expected: `deployment.apps/writer created (dry run)` and `service/writer created (dry run)`.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/writer.yaml
git commit -m "rrcs-k8s: writer Deployment + Service with init gates and /healthz probe"
```

---

### Task 10: Collector Job template (per-run, gated)

The collector is NOT created at install time. It is a Job rendered per matrix cell by the harness via `helm template -s ... --set collector.run=true`. It uses `--out=-` (Task 2) and reaches services by in-cluster DNS.

**Files:**
- Create: `$LAB/chart/templates/collector-job.yaml`

- [ ] **Step 1: Create `$LAB/chart/templates/collector-job.yaml`**

```yaml
{{- if .Values.collector.run }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Values.collector.jobName | default (printf "collector-%v-%s-%s" .Values.collector.tier .Values.collector.mode .Values.profile) }}
  labels: { app: collector }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: { app: collector }
    spec:
      restartPolicy: Never
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      containers:
        - name: collector
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.collector.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.collector.pullPolicy) }}
          args:
            - --tier={{ .Values.collector.tier }}
            - --mode={{ .Values.collector.mode }}
            - --profile={{ .Values.profile }}
            - --duration={{ .Values.collector.durationS }}s
            - --warmup={{ .Values.collector.warmupS }}s
            - --drain={{ .Values.collector.drainS }}s
            - --out=-
            - --slo-rate-pct={{ .Values.collector.sloRatePct }}
            - --slo-p99-ms={{ .Values.collector.sloP99Ms }}
            - --slo-allow-missing={{ .Values.collector.sloAllowMissing }}
            {{- if eq .Values.collector.mode "chaos" }}
            - --chaos-at-s={{ .Values.collector.chaosAtS }}
            - --chaos-duration={{ .Values.collector.chaosDurationS }}
            {{- end }}
          resources:
            {{- toYaml .Values.resources.collector | nindent 12 }}
{{- end }}
```

- [ ] **Step 2: Assert install does NOT render the collector (run=false default)**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s | grep -q "app: collector" && echo "collector rendered at install (WRONG)" || echo "collector NOT at install (OK)"
```
Expected: `collector NOT at install (OK)`.

- [ ] **Step 3: Assert per-run render produces a uniquely-named Job with `--out=-`**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -s templates/collector-job.yaml \
  --set collector.run=true --set collector.jobName=collector-10-throughput-alo-123 \
  --set collector.tier=10 --set collector.mode=throughput | tee /tmp/cj.yaml | grep -E "name: collector-10-throughput-alo-123|--out=-|--tier=10"
grep -q -- "--chaos-at-s" /tmp/cj.yaml && echo "chaos args present (WRONG for throughput)" || echo "no chaos args for throughput (OK)"
```
Expected: shows the unique name, `--out=-`, `--tier=10`, then `no chaos args for throughput (OK)`.

- [ ] **Step 4: Assert chaos mode adds chaos args**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -s templates/collector-job.yaml \
  --set collector.run=true --set collector.mode=chaos --set collector.chaosAtS=15 --set collector.chaosDurationS=8 \
  | grep -E -- "--chaos-at-s=15|--chaos-duration=8"
```
Expected: both `--chaos-at-s=15` and `--chaos-duration=8` appear.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/collector-job.yaml
git commit -m "rrcs-k8s: per-run collector Job template (gated, --out=-, chaos args)"
```

---

### Task 11: `render.sh` — plain-YAML generation wrapper

A thin `helm template` wrapper so users can produce portable plain YAML for any cluster (design §9).

**Files:**
- Create: `$LAB/scripts/render.sh`

- [ ] **Step 1: Create `$LAB/scripts/render.sh`**

```bash
#!/usr/bin/env bash
# Renders the chart to plain YAML at out/manifests.yaml.
# Usage: scripts/render.sh [--profile=alo] [--values=path] [extra helm args...]
# Env: RRCS_NS (default rrcs-k8s)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

NS="${RRCS_NS:-rrcs-k8s}"
PROFILE=""
VALUES=""
EXTRA=()
for arg in "$@"; do
  case "$arg" in
    --profile=*) PROFILE="${arg#*=}";;
    --values=*)  VALUES="${arg#*=}";;
    *)           EXTRA+=("$arg");;
  esac
done

mkdir -p out
args=(template rrcs ./chart --namespace "${NS}")
[[ -n "${PROFILE}" ]] && args+=(--set "profile=${PROFILE}")
[[ -n "${VALUES}" ]]  && args+=(-f "${VALUES}")

helm "${args[@]}" "${EXTRA[@]}" > out/manifests.yaml

echo "wrote out/manifests.yaml"
echo "NOTE: the chart does not create the namespace. Apply with:"
echo "  kubectl create namespace ${NS} --dry-run=client -o yaml | kubectl apply -f -"
echo "  kubectl apply -n ${NS} -f out/manifests.yaml"
```

- [ ] **Step 2: Make executable + syntax check + shellcheck**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
chmod +x scripts/render.sh
bash -n scripts/render.sh && echo "syntax OK"
shellcheck scripts/render.sh && echo "shellcheck clean"
```
Expected: `syntax OK` and `shellcheck clean` (no warnings).

- [ ] **Step 3: Run it and validate the output applies client-side**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
scripts/render.sh --profile=alo
test -s out/manifests.yaml && echo "manifests non-empty"
kubectl apply --dry-run=client -f out/manifests.yaml 2>&1 | grep -E "deployment|service|job|configmap" | wc -l
```
Expected: `manifests non-empty`, and the count of validated resources is `13` (5 Deployments + 6 Services + 1 nats-init Job + 2 ConfigMaps = 14; the collector Job is gated off, so expect 14 — accept ≥13).

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/scripts/render.sh
git commit -m "rrcs-k8s: render.sh plain-YAML wrapper"
```

---

### Task 12: `build-images.sh` — build with configurable registry, optional push

Builds the writer + collector images with a configurable base/target registry; push is opt-in; `--kind` side-loads into a kind cluster (design §8).

**Files:**
- Create: `$LAB/scripts/build-images.sh`

- [ ] **Step 1: Create `$LAB/scripts/build-images.sh`**

```bash
#!/usr/bin/env bash
# Builds the writer and collector images. Push and kind-load are opt-in.
# Usage:
#   scripts/build-images.sh                                   # build-only, tag :dev
#   scripts/build-images.sh --base-registry=corp.io/mirror/   # redirect Dockerfile FROM
#   scripts/build-images.sh --registry=corp.io/team --push    # retag + push to remote
#   scripts/build-images.sh --kind --kind-name=rrcs           # load into kind cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

BASE_REGISTRY=""
REGISTRY=""
TAG="dev"
PUSH=0
KIND=0
KIND_NAME="kind"
for arg in "$@"; do
  case "$arg" in
    --base-registry=*) BASE_REGISTRY="${arg#*=}";;
    --registry=*)      REGISTRY="${arg#*=}";;
    --tag=*)           TAG="${arg#*=}";;
    --push)            PUSH=1;;
    --kind)            KIND=1;;
    --kind-name=*)     KIND_NAME="${arg#*=}";;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

# Image refs. REGISTRY (if set) prefixes the local name; must match values
# images.registry so the chart pulls what we built.
prefix=""
[[ -n "${REGISTRY}" ]] && prefix="${REGISTRY%/}/"
WRITER_IMG="${prefix}redis-rrcs/writer:${TAG}"
COLLECTOR_IMG="${prefix}redis-rrcs/collector:${TAG}"

build_one() {
  local ctx="$1" img="$2"
  echo "[build] ${img} (BASE_REGISTRY='${BASE_REGISTRY}')"
  docker build --build-arg "BASE_REGISTRY=${BASE_REGISTRY}" -t "${img}" "${ctx}"
}

build_one writer "${WRITER_IMG}"
build_one collector "${COLLECTOR_IMG}"

if (( KIND )); then
  echo "[kind] loading images into cluster '${KIND_NAME}'"
  kind load docker-image "${WRITER_IMG}" --name "${KIND_NAME}"
  kind load docker-image "${COLLECTOR_IMG}" --name "${KIND_NAME}"
fi

if (( PUSH )); then
  if [[ -z "${REGISTRY}" ]]; then
    echo "[push] --push requires --registry=<ref>" >&2
    exit 2
  fi
  echo "[push] pushing to ${REGISTRY}"
  docker push "${WRITER_IMG}"
  docker push "${COLLECTOR_IMG}"
else
  echo "[push] skipped (no --push). Built locally:"
  echo "  ${WRITER_IMG}"
  echo "  ${COLLECTOR_IMG}"
fi
```

- [ ] **Step 2: Make executable + syntax check + shellcheck**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
chmod +x scripts/build-images.sh
bash -n scripts/build-images.sh && echo "syntax OK"
shellcheck scripts/build-images.sh && echo "shellcheck clean"
```
Expected: `syntax OK` and `shellcheck clean`.

- [ ] **Step 3: Build-only default produces both images locally, no push**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
scripts/build-images.sh
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "redis-rrcs/(writer|collector):dev"
```
Expected: lists `redis-rrcs/writer:dev` and `redis-rrcs/collector:dev`; the script prints `[push] skipped (no --push)`.

- [ ] **Step 4: `--push` without `--registry` errors clearly**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
scripts/build-images.sh --push 2>&1 | tail -1
```
Expected: `[push] --push requires --registry=<ref>` and a non-zero exit.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/scripts/build-images.sh
git commit -m "rrcs-k8s: build-images.sh (configurable registry, optional push, kind load)"
```

---

### Task 13: Chaos script + host harness `stress-run.sh`

The chaos scaler (scale connect-sink 0→sleep→1, gated by readiness) and the kubectl-driven matrix harness (design §7).

**Files:**
- Create: `$LAB/scripts/chaos/scale-connect-sink.sh`
- Create: `$LAB/scripts/stress-run.sh`

- [ ] **Step 1: Create `$LAB/scripts/chaos/scale-connect-sink.sh`**

```bash
#!/usr/bin/env bash
# Scales connect-sink to 0 for DOWN_S seconds, then back to 1, waiting for the
# readiness probe (via rollout status) to confirm real recovery.
# Usage: scale-connect-sink.sh [DOWN_S]
# Env: RRCS_NS (default rrcs-k8s), READY_TIMEOUT_S (default 60)
set -euo pipefail

NS="${RRCS_NS:-rrcs-k8s}"
DOWN_S="${1:-8}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-60}"
DEPLOY=connect-sink

echo "[chaos] scaling ${DEPLOY} to 0 for ${DOWN_S}s"
kubectl -n "${NS}" scale deploy/"${DEPLOY}" --replicas=0
# Wait for the pod to terminate gracefully (parity with docker stop).
kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=30s

sleep "${DOWN_S}"

echo "[chaos] scaling ${DEPLOY} back to 1"
kubectl -n "${NS}" scale deploy/"${DEPLOY}" --replicas=1
# rollout status returns ready only once the /ready probe passes (real gate).
if kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout="${READY_TIMEOUT_S}s"; then
  echo "[chaos] ${DEPLOY} recovered (ready)"
  exit 0
fi
echo "[chaos] WARN: ${DEPLOY} not ready within ${READY_TIMEOUT_S}s" >&2
exit 1
```

- [ ] **Step 2: Create `$LAB/scripts/stress-run.sh`**

```bash
#!/usr/bin/env bash
# Kubernetes-native stress harness. Drives the tier x mode matrix against the
# chart installed in namespace $NS, extracting each verdict from the collector
# Job's stdout (RESULT_JSON sentinel). See README.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/tier-defs.sh"

NS="${RRCS_NS:-rrcs-k8s}"
RELEASE="${RRCS_RELEASE:-rrcs}"
PROFILE="${PROFILE_QOS:-alo}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
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
  RRCS_NS=rrcs-k8s  RRCS_RELEASE=rrcs  RRCS_VALUES=chart/values-dev.yaml
  DURATION_S=30  WARMUP_S=5  DRAIN_S=10  CHAOS_DOWN_S=8
EOF
      exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

# Validate tiers/modes against known SLO keys (same as compose harness).
for t in "${TIERS[@]}"; do
  if [[ -z "${TIER_P99_MS[$t]:-}" ]]; then
    echo "error: unknown tier '${t}'. Known: ${!TIER_P99_MS[*]}" >&2; exit 2
  fi
done
valid_modes=" throughput latency chaos "
for m in "${MODES[@]}"; do
  if [[ "${valid_modes}" != *" ${m} "* ]]; then
    echo "error: unknown mode '${m}'. Known: throughput latency chaos" >&2; exit 2
  fi
done

NO_ARGS_RUN=$(( $# == 0 ? 1 : 0 ))
PIDS=()
PF_PID=""
cleanup() {
  for pid in "${PIDS[@]}"; do kill "${pid}" >/dev/null 2>&1 || true; done
  [[ -n "${PF_PID}" ]] && kill "${PF_PID}" >/dev/null 2>&1 || true
  if (( NO_ARGS_RUN )); then
    echo "[teardown] helm uninstall ${RELEASE} -n ${NS}"
    helm uninstall "${RELEASE}" -n "${NS}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# Boot the chart (idempotent). nats-init is a plain Job, so --wait does not deadlock.
echo "[boot] helm upgrade --install ${RELEASE} (profile=${PROFILE})"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  --set "profile=${PROFILE}" -f "${VALUES_FILE}" --wait --timeout 5m

# One port-forward for the chaos pre-flight (NATS monitoring), opened lazily.
needs_pf=0
for m in "${MODES[@]}"; do [[ "$m" == "chaos" ]] && needs_pf=1; done
if (( needs_pf )); then
  kubectl -n "${NS}" port-forward svc/nats 18222:8222 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
fi

mkdir -p reports

jetstream_bytes() {
  curl -fs "http://127.0.0.1:18222/jsz?streams=true&consumers=true&accounts=true" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin); b=0
for a in d.get("account_details",[]):
 for s in a.get("stream_detail",[]):
  if s.get("name")=="APP_EVENTS": b=s.get("state",{}).get("bytes",0)
print(b)'
}

run_one() {
  local tier="$1" mode="$2"
  local p99_ms="${TIER_P99_MS[$tier]}"
  local rate_min_pct="${TIER_RATE_MIN_PCT[$tier]}"
  local allow_missing chaos_pid="" chaos_sets=()
  allow_missing="$(allow_missing_for_profile "${PROFILE}")"

  if [[ "${mode}" == "chaos" ]]; then
    local bytes; bytes="$(jetstream_bytes)"
    if (( bytes > 200*1024*1024 )); then
      echo "[abort] APP_EVENTS already ${bytes} bytes (>200MB). helm uninstall and retry." >&2
      exit 3
    fi
    chaos_sets=(--set "collector.chaosAtS=$(chaos_at_s)" --set "collector.chaosDurationS=${CHAOS_DOWN_S}")
    ( sleep "${WARMUP_S}"; sleep "$(chaos_at_s)"; bash "${SCRIPT_DIR}/chaos/scale-connect-sink.sh" "${CHAOS_DOWN_S}" ) &
    chaos_pid=$!
    PIDS+=("${chaos_pid}")
  fi

  local job="collector-${tier}-${mode}-${PROFILE}-$(date +%s)"
  echo "[run] tier=${tier} mode=${mode} profile=${PROFILE} job=${job}"

  helm template "${RELEASE}" ./chart -n "${NS}" -s templates/collector-job.yaml \
    -f "${VALUES_FILE}" \
    --set "profile=${PROFILE}" \
    --set "collector.run=true" \
    --set "collector.jobName=${job}" \
    --set "collector.tier=${tier}" \
    --set "collector.mode=${mode}" \
    --set "collector.durationS=${DURATION_S}" \
    --set "collector.warmupS=${WARMUP_S}" \
    --set "collector.drainS=${DRAIN_S}" \
    --set "collector.sloRatePct=${rate_min_pct}" \
    --set "collector.sloP99Ms=${p99_ms}" \
    --set "collector.sloAllowMissing=${allow_missing}" \
    "${chaos_sets[@]}" \
    | kubectl apply -n "${NS}" -f -

  # Wait for terminal state: complete OR failed (a failing verdict is NOT a Job
  # failure — the collector exits 0 on report; only a genuine error fails it).
  local timeout_s=$(( DURATION_S + WARMUP_S + DRAIN_S + 120 ))
  if kubectl -n "${NS}" wait --for=condition=complete --timeout="${timeout_s}s" "job/${job}" 2>/dev/null; then
    if kubectl -n "${NS}" logs "job/${job}" | sed -n 's/^RESULT_JSON://p' | tail -n 1 > "reports/${tier}-${mode}-${PROFILE}.json" \
       && [[ -s "reports/${tier}-${mode}-${PROFILE}.json" ]]; then
      echo "[ok] report saved"
    else
      echo "[ERROR] no RESULT_JSON in collector logs for ${job}" >&2
      kubectl -n "${NS}" logs "job/${job}" | tail -20 >&2
      rm -f "reports/${tier}-${mode}-${PROFILE}.json"
    fi
  else
    echo "[ERROR] collector job ${job} did not complete (genuine failure)" >&2
    kubectl -n "${NS}" logs "job/${job}" --tail=20 >&2 || true
    rm -f "reports/${tier}-${mode}-${PROFILE}.json"
  fi

  kubectl -n "${NS}" delete "job/${job}" --wait=true >/dev/null 2>&1 || true

  if [[ -n "${chaos_pid}" ]]; then
    set +e; wait "${chaos_pid}"; local rc=$?; set -e
    (( rc != 0 )) && echo "[chaos] WARN: scaler exited ${rc}" >&2
  fi

  # Purge JetStream so the next run starts hermetic (full --server URL, fix #4).
  kubectl -n "${NS}" run "nats-purge-$(date +%s)" --rm -i --restart=Never \
    --image="$(helm show values ./chart | awk '/^natsBox:/{f=1} f&&/image:/{print $2; exit}')" -- \
    nats --server nats://nats:4222 stream purge APP_EVENTS -f >/dev/null 2>&1 \
    || echo "[purge] WARN: stream purge failed (continuing)" >&2
}

for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    run_one "${tier}" "${mode}"
  done
done

# Summary table (same reducer as the compose harness).
echo
printf "%-9s %-12s %-15s %-9s %-9s %-9s %s\n" "tier" "mode" "rate_achieved" "missing" "trimmed" "p99 ms" "verdict"
printf -- "-------------------------------------------------------------------------------\n"
all_pass=true
for tier in "${TIERS[@]}"; do
  for mode in "${MODES[@]}"; do
    f="reports/${tier}-${mode}-${PROFILE}.json"
    if [[ ! -f "$f" ]]; then
      printf "%-9s %-12s %-15s %-9s %-9s %-9s %s\n" "$tier" "$mode" "-" "-" "-" "-" "MISSING/ERROR"
      all_pass=false; continue
    fi
    python3 - "$f" "$tier" "$mode" <<'PY'
import json,sys
path, tier, mode = sys.argv[1], sys.argv[2], sys.argv[3]
r = json.load(open(path))
ach = r.get("rate_achieved_avg", 0); miss = r.get("missing", 0)
trim = r.get("trimmed", 0); p99 = r.get("latency_ms", {}).get("p99", 0)
verdict = "PASS" if r.get("verdict", {}).get("pass") else "FAIL"
print(f"{tier:<9} {mode:<12} {ach:6.1f}/{tier:<8} {miss:<9} {trim:<9} {p99:<9.1f} {verdict}")
PY
    pass=$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1]))["verdict"]["pass"] else 0)' "$f" 2>/dev/null || echo 0)
    [[ "$pass" == "1" ]] || all_pass=false
  done
done
printf -- "-------------------------------------------------------------------------------\n"
$all_pass && exit 0 || exit 1
```

- [ ] **Step 3: Make executable + syntax check + shellcheck both scripts**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
chmod +x scripts/chaos/scale-connect-sink.sh scripts/stress-run.sh
bash -n scripts/chaos/scale-connect-sink.sh && bash -n scripts/stress-run.sh && echo "syntax OK"
shellcheck scripts/chaos/scale-connect-sink.sh scripts/stress-run.sh && echo "shellcheck clean"
```
Expected: `syntax OK` and `shellcheck clean`. (If shellcheck flags the `source` of tier-defs, the inline `# shellcheck disable=SC1091` suppresses it.)

- [ ] **Step 4: `--help` works without a cluster**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
scripts/stress-run.sh --help
```
Expected: prints the usage block and exits 0.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/scripts/chaos/scale-connect-sink.sh labs/redis-redpanda-connect-stress-k8s/scripts/stress-run.sh
git commit -m "rrcs-k8s: chaos scale script + kubectl-driven stress-run harness"
```

---

### Task 14: README and RESEARCH docs

Author the lab README (workflow, knobs, flows) and carry forward RESEARCH with a Kubernetes-fork rationale section (design §14).

**Files:**
- Create: `$LAB/README.md`
- Create: `$LAB/RESEARCH.md`

- [ ] **Step 1: Create `$LAB/README.md`**

````markdown
# Redis → Redpanda Connect Stress Lab (Kubernetes fork)

Kubernetes-native fork of `../redis-redpanda-connect-stress/`. Same pipeline
(Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis), same
tier × mode × QoS verdict matrix — packaged as a Helm chart and driven by a
host `kubectl` harness.

## Prerequisites

`helm`, `kubectl`, `kind` (for local), `docker`, `go`, `python3`. A reachable
cluster context (`kubectl config current-context`).

## Quick start (kind / local)

```bash
# 1. Create a local cluster
kind create cluster --name rrcs

# 2. Build the writer + collector images and side-load them into kind
scripts/build-images.sh --kind --kind-name=rrcs

# 3. Run a small matrix (boots the chart, runs, tears down on no-arg full run)
scripts/stress-run.sh --tiers=10 --modes=throughput --profile=alo
```

`stress-run.sh` installs the chart with `chart/values-dev.yaml` (writer/collector
`pullPolicy: Never`, NATS on `emptyDir`), runs each tier × mode cell as a
collector Job, extracts the verdict JSON into `reports/`, and prints a summary.

## Portable / remote cluster

```bash
# Build, retag, and push to your registry
scripts/build-images.sh --registry=corp.example.com/team --push
# Optionally redirect base images to a mirror (airgapped)
scripts/build-images.sh --base-registry=corp.example.com/mirror/ --registry=corp.example.com/team --push

# Install with your registry prefix and default (portable) values
helm install rrcs ./chart -n rrcs-k8s --create-namespace \
  --set images.registry=corp.example.com/team/

# Then run against that namespace
RRCS_VALUES=chart/values.yaml scripts/stress-run.sh --tiers=10 --modes=throughput
```

## Plain YAML (no Helm in-cluster)

```bash
scripts/render.sh --profile=alo            # writes out/manifests.yaml
kubectl create namespace rrcs-k8s
kubectl apply -n rrcs-k8s -f out/manifests.yaml
```

## Knobs (`chart/values.yaml`)

| Key | Default | Purpose |
|---|---|---|
| `profile` | `alo` | QoS profile: `alo` / `amo` / `eoe` |
| `images.registry` | `""` | Prefix for every image (custom registry) |
| `images.pullPolicy` | `IfNotPresent` | Global pull policy (public images) |
| `writer.pullPolicy` / `collector.pullPolicy` | `""` (inherit) | Per-image override; dev sets `Never` |
| `nats.persistence.mode` | `emptyDir` | `emptyDir` (portable) or `pvc` (durable) |
| `nats.persistence.storageClassName` | `""` | Only for `pvc`; blank → cluster default |
| `nats.stream.maxBytes` | `256MB` | JetStream `APP_EVENTS` byte cap |
| `scheduling.{nodeSelector,tolerations,affinity}` | empty | Applied to every pod |
| `chaos.downSeconds` | `8` | Chaos outage length |

Run-window knobs (`DURATION_S`, `WARMUP_S`, `DRAIN_S`, `CHAOS_DOWN_S`) and tier
SLOs live in `scripts/lib/tier-defs.sh` (env-overridable), identical to the
compose lab.

## How the matrix runs

For each tier × mode the harness renders a uniquely-named collector Job
(`helm template -s templates/collector-job.yaml`), applies it, waits for it to
complete, and reads the single `RESULT_JSON:` line from `kubectl logs`. A
failing verdict is an expected outcome (the collector exits 0 and the verdict
lives in the JSON); only a genuine collector error fails the Job and surfaces as
an `ERROR`/missing cell. Chaos mode scales `connect-sink` to 0 and back, gated by
its `/ready` readiness probe.

## Teardown

```bash
helm uninstall rrcs -n rrcs-k8s
kind delete cluster --name rrcs   # if using kind
```
````

- [ ] **Step 2: Create `$LAB/RESEARCH.md`**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
cp ../redis-redpanda-connect-stress/RESEARCH.md RESEARCH.md
```

Then prepend a Kubernetes-fork rationale section at the top of `$LAB/RESEARCH.md` (above the carried-forward content):

```markdown
# RESEARCH — Kubernetes fork

This lab forks the Docker Compose stress lab to a Kubernetes substrate without
changing the pipeline or its measurement. Key substrate decisions:

- **Compose `depends_on` → initContainers + readiness probes.** Ordering that
  compose expressed declaratively becomes initContainer poll-loops (Redis ping,
  `APP_EVENTS` existence) plus real readiness probes (`/ready`, `/healthz`,
  `redis-cli ping`). The probes also make chaos recovery a true gate.
- **Stream init is a plain Job, not a Helm hook.** A `post-install` hook would
  deadlock against `helm --wait` (the Connect Deployments wait on the stream,
  the hook runs after wait). A plain Job gated by an initContainer avoids the
  circular wait.
- **Report extraction via stdout sentinel.** There is no portable shared mount
  in K8s (hostPath is non-portable), so the collector emits one compact
  `RESULT_JSON:` line and the harness reads it from `kubectl logs`. The exit
  code means "did it run", not "did it pass" — so an expected FAIL verdict
  doesn't trip Job failure/retry.
- **NATS persistence defaults to emptyDir.** Durability isn't load-bearing for a
  stress lab; emptyDir keeps the chart runnable on a bare cluster with no
  StorageClass. `pvc` mode is opt-in.

---

(Original compose-lab research follows.)
```

- [ ] **Step 3: Verify docs reference the real workflow**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
grep -q "build-images.sh --kind" README.md && grep -q "RESULT_JSON" README.md && echo "README OK"
grep -q "plain Job, not a Helm hook" RESEARCH.md && echo "RESEARCH OK"
```
Expected: `README OK` and `RESEARCH OK`.

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/README.md labs/redis-redpanda-connect-stress-k8s/RESEARCH.md
git commit -m "rrcs-k8s: README (workflow/knobs/flows) + RESEARCH fork rationale"
```

---

### Task 15: End-to-end smoke test on kind

Prove the whole lab works: create a kind cluster, build+load images, install the chart, run one throughput cell and one chaos cell, confirm a verdict JSON is produced. This is the integration test for everything above.

**Files:** none (verification only).

- [ ] **Step 1: Create cluster and load images**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
kind create cluster --name rrcs-e2e
scripts/build-images.sh --kind --kind-name=rrcs-e2e
```
Expected: cluster created; both images built and `kind load` reports "Image: …redis-rrcs/writer:dev … loaded".

- [ ] **Step 2: Install the chart and confirm all workloads become Ready**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm upgrade --install rrcs ./chart -n rrcs-k8s --create-namespace \
  --set profile=alo -f chart/values-dev.yaml --wait --timeout 5m
kubectl -n rrcs-k8s get deploy
kubectl -n rrcs-k8s get job nats-init -o jsonpath='{.status.succeeded}'; echo
```
Expected: `helm` reports the release deployed (no deadlock — fix #1 verified); all 5 Deployments show `1/1`; `nats-init` succeeded = `1`.

- [ ] **Step 3: Run one throughput cell and confirm a verdict JSON**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
RRCS_VALUES=chart/values-dev.yaml DURATION_S=15 scripts/stress-run.sh --tiers=10 --modes=throughput --profile=alo
python3 -c "import json;d=json.load(open('reports/10-throughput-alo.json'));print('verdict.pass=',d['verdict']['pass'],'tier=',d['tier'])"
```
Expected: the harness prints a summary table with a `10 throughput … PASS` row; the python line prints `verdict.pass= True tier= 10` (a clean report was extracted from collector stdout — fix #5 verified).

- [ ] **Step 4: Run one chaos cell and confirm the scale script ran**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
RRCS_VALUES=chart/values-dev.yaml DURATION_S=20 scripts/stress-run.sh --tiers=10 --modes=chaos --profile=alo
python3 -c "import json;d=json.load(open('reports/10-chaos-alo.json'));print('chaos block:',d.get('chaos'))"
```
Expected: harness logs show `[chaos] scaling connect-sink to 0 …` and `… recovered (ready)`; the report's `chaos` block is non-null with `action: kill-connect-sink` (the recovery readiness gate worked — fix #6 verified).

- [ ] **Step 5: Tear down**

Run:
```bash
helm uninstall rrcs -n rrcs-k8s || true
kind delete cluster --name rrcs-e2e
```
Expected: release uninstalled, cluster deleted.

- [ ] **Step 6: Final commit (lockfiles / any reports to keep out of git)**

Run:
```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git status --short labs/redis-redpanda-connect-stress-k8s/
```
If only `reports/*.json` show up, they are gitignored — nothing to commit. If the e2e surfaced any fixes you made to templates/scripts, commit them now with a message like `rrcs-k8s: fixes from kind e2e`.

---

## Self-Review (completed by plan author)

**1. Spec coverage** — every spec section maps to a task:
- §3 layout → Task 1; §4 mapping → Tasks 5-10; §5.1 NATS persistence → Task 7; §5.2 stream-init Job (fix #1) → Task 7; §5.3/5.4 connect+writer probes/initContainers (fix #4, #6) → Tasks 8-9; §5.5 namespace (fix #3) → Tasks 11/13 (`-n` everywhere, no Namespace resource); §5.6 image/scheduling helpers (fix #12) → Task 4; §6 collector `--out=-` + Job lifecycle (fix #5, #7) + failure semantics → Tasks 2, 10, 13; §7 harness incl. single PF + cleanup trap (fix #8) → Task 13; §7.1 chaos (fix #6 gate) → Task 13; §8 build-images (fix #9) → Tasks 3, 12; §9 render.sh → Task 11; §10 chaos config block (fix #13) → values in Task 4 + harness in Task 13; §11 values → Task 4; resource requests (fix #10) → Task 4 values + every template; §14 docs → Task 14. End-to-end proof → Task 15.
- Deliberate refinement vs spec: pullPolicy resolves **per-image** (global default + writer/collector override) instead of a single global `Never` in values-dev, because a global `Never` breaks public images on a fresh kind node. This satisfies fix #9's intent (built images never pulled) correctly.

**2. Placeholder scan** — no TBD/TODO/"add error handling"/"similar to Task N"; every code step shows complete content; every command shows expected output.

**3. Type consistency** — `writeReport(path string, stdout io.Writer, r Report) (exitFail bool, err error)` and `resultSentinel` are defined in Task 2 and used identically in the test; Service DNS names (`redis-central`, `redis-region`, `nats`, `connect-source`, `connect-sink`, `writer`) match the connect YAMLs, writer env, and collector defaults; values keys (`collector.jobName`, `collector.run`, `nats.persistence.mode`, `writer.pullPolicy`) match between `values.yaml` (Task 4), the templates (Tasks 7-10), and the harness `--set` flags (Task 13).
