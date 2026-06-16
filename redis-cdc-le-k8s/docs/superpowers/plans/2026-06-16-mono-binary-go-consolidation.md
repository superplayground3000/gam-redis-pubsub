# Mono-binary Go Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the 5 separate Go modules in `redis-cdc-le-k8s/` into one module that builds a single binary (`app`), which selects a workload by subcommand (`app <mode>`).

**Architecture:** One root `go.mod` + `main.go` dispatcher. Each former `package main` workload becomes an internal subpackage (`internal/{writer,verifier,elector,latency,dashboard}`) exposing `func Run(args []string)`. Subpackages keep symbols isolated (no `env`/`envInt` collisions). Dockerfile does one `go build`; the Helm chart calls `app <mode>` instead of per-binary paths.

**Tech Stack:** Go 1.25, go-redis v9, client-go (elector), gorilla/websocket + go:embed (dashboard), HdrHistogram (verifier); Docker multi-stage; Helm.

---

## File Structure

After this plan, the Go tree is:

```
redis-cdc-le-k8s/
  go.mod                 # single module: redis-cdc-le-k8s (replaces 5 go.mod + go.work)
  main.go                # subcommand dispatch
  internal/
    writer/    *.go + *_test.go            package writer    func Run(args []string)
    verifier/  *.go + *_test.go            package verifier  func Run(args []string)
    elector/   *.go + *_test.go            package elector   func Run(args []string)
    latency/   *.go + *_test.go            package latency   func Run(args []string)
    dashboard/ *.go + *_test.go + static/  package dashboard func Run(args []string)
  Dockerfile             # single `go build -o /out/app .`
  chart/templates/*.yaml # command: ["/usr/local/bin/app","<mode>"]
```

Deleted: `go.work`, `writer/go.mod`, `verifier/go.mod`, `elector/go.mod`, `latency-calculator/go.mod`, `dashboard/go.mod`, the per-dir `.gitignore` files.

---

## Task 1: Restructure into one module with subcommand dispatch

**Files:**
- Move: `writer/` → `internal/writer/`, `verifier/` → `internal/verifier/`, `elector/` → `internal/elector/`, `latency-calculator/` → `internal/latency/`, `dashboard/` → `internal/dashboard/`
- Delete: `go.work`, all 5 old `go.mod`, `verifier/.gitignore`, `elector/.gitignore`, `dashboard/.gitignore`
- Create: `go.mod`, `main.go`
- Modify: each subpackage's `*.go` + `*_test.go` (package clause), each `main.go` (`func main` → `func Run`), root `.gitignore`

- [ ] **Step 1: Move the five directories into `internal/` (preserve history)**

```bash
cd redis-cdc-le-k8s
mkdir -p internal
git mv writer internal/writer
git mv verifier internal/verifier
git mv elector internal/elector
git mv latency-calculator internal/latency
git mv dashboard internal/dashboard
```

- [ ] **Step 2: Delete the workspace file, old module files, and stale per-dir gitignores**

```bash
git rm go.work internal/*/go.mod
git rm internal/verifier/.gitignore internal/elector/.gitignore internal/dashboard/.gitignore
```

Note: `go.work.sum` / `go.sum` are gitignored repo-wide; nothing to remove there.

- [ ] **Step 3: Create the root `go.mod`** (direct requires = union of the 5 modules)

Create `redis-cdc-le-k8s/go.mod`:

```
module redis-cdc-le-k8s

go 1.25.0

require (
	github.com/HdrHistogram/hdrhistogram-go v1.2.0
	github.com/google/uuid v1.6.0
	github.com/gorilla/websocket v1.5.3
	github.com/redis/go-redis/v9 v9.19.0
	golang.org/x/time v0.15.0
	k8s.io/apimachinery v0.31.0
	k8s.io/client-go v0.31.0
)
```

(Indirect requires are filled in by `go mod tidy` in Step 8.)

- [ ] **Step 4: Rename the package clause in every file of each subpackage**

`package main` → the subpackage name, for all `.go` files (including `_test.go`):

```bash
cd redis-cdc-le-k8s
sed -i 's/^package main$/package writer/'    internal/writer/*.go
sed -i 's/^package main$/package verifier/'  internal/verifier/*.go
sed -i 's/^package main$/package elector/'   internal/elector/*.go
sed -i 's/^package main$/package latency/'   internal/latency/*.go
sed -i 's/^package main$/package dashboard/' internal/dashboard/*.go
```

Verify none remain: `grep -rl '^package main$' internal/` should print nothing.

- [ ] **Step 5: Rename `func main()` → `func Run(args []string)` in the four env-driven workloads**

In each of `internal/writer/main.go`, `internal/elector/main.go`, `internal/latency/main.go`, `internal/dashboard/main.go`, change the single line:

```go
func main() {
```
to:
```go
func Run(args []string) {
```

These four read only environment variables, so `args` is intentionally unused (Go allows unused function parameters). No other change in these files.

- [ ] **Step 6: Convert `verifier` to a local FlagSet over `args`**

In `internal/verifier/main.go`, replace the function signature and the global-flag block. The full new top of `Run`:

```go
func Run(args []string) {
	fs := flag.NewFlagSet("verifier", flag.ExitOnError)
	epoch := fs.String("epoch", "", "unique per-run epoch token (required)")
	central := fs.String("redis-central", "redis-central:6379", "central Redis host:port")
	region := fs.String("redis-region", "redis-region:6379", "region Redis host:port")
	natsURL := fs.String("nats", "http://nats:8222", "NATS monitoring URL")
	stream := fs.String("nats-stream", "KV_CDC", "JetStream stream name")
	// --nats-consumer is accepted (the verifier Job passes --nats-consumer=cdc_sink)
	// but intentionally discarded: quiescence keys off stream-wide MaxPending, which
	// equals the sink durable's pending because KV_CDC has exactly one JetStream
	// consumer. The value is informational only — not an oversight.
	_ = fs.String("nats-consumer", "cdc_sink", "sink durable name (informational)")
	sourceGroup := fs.String("source-group", "cdc_propagator", "source consumer group")
	quiesce := fs.Duration("quiesce-timeout", 15*time.Second, "per-op quiescence deadline")
	_ = fs.Parse(args)

	if *epoch == "" {
		log.Fatal("--epoch is required")
	}
```

Everything from `ctx, cancel := context.WithTimeout(...)` onward is unchanged. The `flag` import stays (now used for `NewFlagSet`/`ExitOnError`).

- [ ] **Step 7: Create the dispatcher `main.go`**

Create `redis-cdc-le-k8s/main.go`:

```go
// redis-cdc-le-k8s mono binary: one module, one build, one image. The first
// argument selects which lab workload to run; each k8s manifest sets
// `command: [".../app","<mode>"]`. Remaining args are forwarded to the workload
// (only `verifier` parses flags; the others are env-driven and ignore them).
package main

import (
	"fmt"
	"os"

	"redis-cdc-le-k8s/internal/dashboard"
	"redis-cdc-le-k8s/internal/elector"
	"redis-cdc-le-k8s/internal/latency"
	"redis-cdc-le-k8s/internal/verifier"
	"redis-cdc-le-k8s/internal/writer"
)

func usage() {
	fmt.Fprint(os.Stderr, "usage: app <mode> [args]\n\nmodes:\n"+
		"  writer\n  verifier\n  elector\n  latency-calculator\n  dashboard\n")
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	mode, args := os.Args[1], os.Args[2:]
	switch mode {
	case "writer":
		writer.Run(args)
	case "verifier":
		verifier.Run(args)
	case "elector":
		elector.Run(args)
	case "latency-calculator":
		latency.Run(args)
	case "dashboard":
		dashboard.Run(args)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode %q\n", mode)
		usage()
		os.Exit(2)
	}
}
```

- [ ] **Step 8: Update root `.gitignore` and tidy the module**

Replace the per-binary lines in `redis-cdc-le-k8s/.gitignore`:

```
# Built Go binaries
writer/writer
verifier/verifier
dashboard/dashboard
collector/collector
latency-calculator/latency-calculator
```
with the single binary:
```
# Built Go binary
/app
```

Then resolve dependencies (uses the module cache populated by the old builds):

```bash
cd redis-cdc-le-k8s
go mod tidy
```

Expected: `go.mod` gains the indirect-require block; no errors.

- [ ] **Step 9: Build the single binary**

```bash
cd redis-cdc-le-k8s
go build -o /tmp/app .
```

Expected: exits 0, produces `/tmp/app`. No "package main" / duplicate-symbol / import errors.

- [ ] **Step 10: Run the full test suite**

```bash
cd redis-cdc-le-k8s
go test ./...
```

Expected: all packages `ok` (the migrated `internal/*` tests pass; the dispatcher has no tests). No `package main` mismatch errors.

- [ ] **Step 11: Smoke-test dispatch**

```bash
/tmp/app;            echo "no-arg exit=$?"   # expect usage on stderr, exit=2
/tmp/app bogus;      echo "bad-mode exit=$?" # expect "unknown mode", exit=2
/tmp/app verifier;   echo "verifier exit=$?" # expect "--epoch is required" log.Fatal, exit=1
```

Expected: exit codes 2, 2, 1 respectively; usage lists all five modes.

- [ ] **Step 12: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add -A redis-cdc-le-k8s
git commit -m "redis-cdc-le-k8s: consolidate 5 Go modules into one mono binary (subcommand dispatch)"
```

---

## Task 2: Single `go build` in the Dockerfile

**Files:**
- Modify: `redis-cdc-le-k8s/Dockerfile`

- [ ] **Step 1: Replace the workspace copy + per-app build loop with one module build**

In `redis-cdc-le-k8s/Dockerfile`, replace the build-stage body (the `COPY go.work` line through the end of the `RUN ... go build` loop) with:

```dockerfile
# Single module → single binary. go.sum is gitignored and never copied in, so the
# build runs in module mode and resolves/verifies deps in-layer (BuildKit cache
# mounts reuse the module + build cache across builds).
COPY go.mod ./
COPY main.go ./
COPY internal/ ./internal/
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .
```

The header comment block referencing `go work sync` / per-module Dockerfiles is now stale — replace it with the two-line comment above.

- [ ] **Step 2: Confirm the runtime stage ships one binary**

The runtime stage already does `COPY --from=build /out/ /usr/local/bin/`, which now copies only `app`. Leave the `apk add ... ca-certificates tini wget`, the `app` user, and `ENTRYPOINT ["sleep", "infinity"]` unchanged. No edit needed if the COPY line is `/out/` → `/usr/local/bin/`; verify it reads exactly that.

- [ ] **Step 3: Build the image**

```bash
cd redis-cdc-le-k8s
docker build -t rrcs-app:plan-check .
```

Expected: build succeeds; final stage has `/usr/local/bin/app` and no `writer`/`verifier`/etc.

- [ ] **Step 4: Verify the image runs the dispatcher**

```bash
docker run --rm --entrypoint /usr/local/bin/app rrcs-app:plan-check; echo "exit=$?"
```

Expected: usage text on stderr, `exit=2`.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add redis-cdc-le-k8s/Dockerfile
git commit -m "redis-cdc-le-k8s: single go build in Dockerfile (one binary)"
```

---

## Task 3: Point the Helm chart at `app <mode>`

**Files:**
- Modify: `chart/templates/writer.yaml`, `chart/templates/verifier-job.yaml`, `chart/templates/dashboard.yaml`, `chart/templates/latency-calculator.yaml`, `chart/templates/connect-source.yaml`, `chart/templates/connect-sink.yaml`, `chart/templates/NOTES.txt`

- [ ] **Step 1: Update the four direct command overrides**

Make these exact replacements (only the Go-workload command lines; leave redis-server / nsc / benthos commands untouched):

- `chart/templates/writer.yaml` — the writer container line
  `command: ["/usr/local/bin/writer"]` → `command: ["/usr/local/bin/app", "writer"]`
- `chart/templates/verifier-job.yaml:28`
  `command: ["/usr/local/bin/verifier"]` → `command: ["/usr/local/bin/app", "verifier"]`
  (the `args:` block with `--epoch=…` stays exactly as-is — verifier's FlagSet parses it)
- `chart/templates/dashboard.yaml:23`
  `command: ["/usr/local/bin/dashboard"]` → `command: ["/usr/local/bin/app", "dashboard"]`
- `chart/templates/latency-calculator.yaml:24`
  `command: ["/usr/local/bin/latency-calculator"]` → `command: ["/usr/local/bin/app", "latency-calculator"]`

- [ ] **Step 2: Update the two elector (tini-wrapped) overrides**

- `chart/templates/connect-source.yaml` elector container
  `command: ["/sbin/tini", "--", "/usr/local/bin/elector"]` → `command: ["/sbin/tini", "--", "/usr/local/bin/app", "elector"]`
- `chart/templates/connect-sink.yaml` elector container
  `command: ["/sbin/tini", "--", "/usr/local/bin/elector"]` → `command: ["/sbin/tini", "--", "/usr/local/bin/app", "elector"]`

- [ ] **Step 3: Update `NOTES.txt` wording**

In `chart/templates/NOTES.txt`, the lines describing the convention currently say the default entrypoint is `sleep infinity` and "Each workload overrides `command:` to run its binary." Update to reflect the single binary, e.g.:

```
entrypoint is `sleep infinity`. Each workload overrides `command:` to run the
shared `app` binary with its mode, e.g. ["/usr/local/bin/app","writer"]. If you
add a new Go workload, you MUST set `command:` (and the mode) or the pod idles.
```

- [ ] **Step 4: Render the chart and confirm every Go workload calls `app <mode>`**

```bash
cd redis-cdc-le-k8s
helm template chart/ | grep -nE '/usr/local/bin/(app|writer|verifier|elector|dashboard|latency-calculator)'
```

Expected: every match is `/usr/local/bin/app` followed by a mode; **no** bare `/usr/local/bin/{writer,verifier,elector,dashboard,latency-calculator}` remains. Command must exit 0 (template renders without error).

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add redis-cdc-le-k8s/chart
git commit -m "redis-cdc-le-k8s: chart invokes shared app binary via subcommand"
```

---

## Notes for the executor

- Tasks are sequential: Task 1 must be green (build + tests) before Task 2/3. The repo does **not** build between Steps 1–8 of Task 1 — that is expected; the first green checkpoint is Step 9/10.
- If `go mod tidy` (Task 1 Step 8) fails to reach the network, the module cache from the previous per-module builds should already hold every dependency; run `go build ./...` once to surface any genuinely missing module before assuming a tidy bug.
- Keep `git mv` (not delete+create) so file history follows the move.
