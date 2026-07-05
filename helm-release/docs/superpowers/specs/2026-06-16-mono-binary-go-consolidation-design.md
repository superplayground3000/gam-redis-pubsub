# Mono-binary Go consolidation — design

**Date:** 2026-06-16
**Scope:** `redis-cdc-le-k8s/` — Go sources, Dockerfile, Helm chart.

## Goal

Replace the current 5-module / 5-binary build with a **single Go module that
produces one binary via one `go build`**. The binary picks which workload to run
from a **subcommand** (`app <mode>`). This removes the per-app build loop in the
Dockerfile and the `go work sync` workspace step.

## Current state

- 5 independent modules tied together by `go.work`: `writer`, `verifier`,
  `elector`, `latency-calculator`, `dashboard`. Each is `package main` with its
  own `go.mod` and `func main()`.
- One shared Docker image builds all 5 into `/usr/local/bin/{name}`; the Helm
  chart selects one per workload via `command: ["/usr/local/bin/<name>"]`
  (elector wrapped in `tini`). Default ENTRYPOINT is `sleep infinity`.
- Symbol collisions prevent a flat single-package merge: `envInt` (writer +
  latency), `env` (elector + latency), plus `getenv` (dashboard) and `envStr`
  (writer). Only `verifier` uses the `flag` package; the other four are
  env-var driven.
- `dashboard` embeds `static/index.html` via `//go:embed`.

## Design

### 1. Layout — single module, internal subpackages

```
redis-cdc-le-k8s/
  go.mod                 # single module (replaces 5 go.mod + go.work)
  main.go                # subcommand dispatch (~40 lines)
  internal/
    writer/    *.go + *_test.go            package writer
    verifier/  *.go + *_test.go            package verifier
    elector/   *.go + *_test.go            package elector
    latency/   *.go + *_test.go            package latency
    dashboard/ *.go + *_test.go + static/index.html   package dashboard
```

`go build -o app .` → single executable `app`. Delete `go.work` and the 5 old
`go.mod` files. The `latency-calculator` directory becomes `internal/latency`;
the **subcommand string stays `latency-calculator`** (chart compatibility).

Internal subpackages keep each workload's symbols isolated — no renames of
`env`/`envInt`/`getenv`/`envStr` needed.

### 2. Dispatch contract

Each package renames `func main()` → **`func Run(args []string)`**. Body is
otherwise unchanged; existing `log.Fatal` / `os.Exit` behavior is preserved
(they terminate the process, which is correct for these one-shot/long-running
workloads).

`main.go`:

```go
func main() {
    if len(os.Args) < 2 {
        usage(); os.Exit(2)
    }
    mode, args := os.Args[1], os.Args[2:]
    switch mode {
    case "writer":             writer.Run(args)
    case "verifier":           verifier.Run(args)
    case "elector":            elector.Run(args)
    case "latency-calculator": latency.Run(args)
    case "dashboard":          dashboard.Run(args)
    default:
        usage(); os.Exit(2)
    }
}
```

- **verifier** is the only package with a real logic change: replace global
  `flag.String(...)` + `flag.Parse()` with
  `fs := flag.NewFlagSet("verifier", flag.ExitOnError)` + `fs.String(...)` +
  `fs.Parse(args)`.
- The other four ignore `args` (env-var driven) but accept the parameter for a
  uniform signature.

### 3. Tests

Each `_test.go` is currently `package main`. Change only the package clause to
match its new subpackage (`package writer`, etc.). Test logic is unchanged.
`go test ./...` must pass.

### 4. Dependencies

One `go.mod` (module path `redis-cdc-le-k8s`), `go 1.25.0`. Direct requires are
the union of the 5 modules:

- `github.com/redis/go-redis/v9 v9.19.0` (writer, verifier, latency, dashboard)
- `github.com/google/uuid` (writer)
- `golang.org/x/time` (writer)
- `github.com/HdrHistogram/hdrhistogram-go` (verifier)
- `k8s.io/apimachinery`, `k8s.io/client-go` (elector)
- `github.com/gorilla/websocket` (dashboard)

Version convergence: `golang.org/x/time` resolves to v0.15.0 (writer's direct
version; elector only used v0.3.0 indirectly — upward compatible). `go mod tidy`
resolves the final set. `go.sum` stays gitignored repo-wide.

### 5. Dockerfile

Replace the `go work sync` + per-app build loop with a single build:

```dockerfile
COPY go.mod ./
COPY main.go ./
COPY internal/ ./internal/
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .
```

Runtime stage copies the single `/out/app` to `/usr/local/bin/app`. ENTRYPOINT
stays `sleep infinity`; runtime apk deps (tini, wget, ca-certificates) unchanged.

### 6. Helm chart — command overrides

Only the 5 Go workloads change (infra commands — redis-server, nsc, benthos —
are untouched):

| File | From | To |
|---|---|---|
| `writer.yaml` (main container) | `["/usr/local/bin/writer"]` | `["/usr/local/bin/app","writer"]` |
| `verifier-job.yaml` | `["/usr/local/bin/verifier"]` | `["/usr/local/bin/app","verifier"]` |
| `dashboard.yaml` | `["/usr/local/bin/dashboard"]` | `["/usr/local/bin/app","dashboard"]` |
| `latency-calculator.yaml` | `["/usr/local/bin/latency-calculator"]` | `["/usr/local/bin/app","latency-calculator"]` |
| `connect-source.yaml` elector | `["/sbin/tini","--","/usr/local/bin/elector"]` | `["/sbin/tini","--","/usr/local/bin/app","elector"]` |
| `connect-sink.yaml` elector | `["/sbin/tini","--","/usr/local/bin/elector"]` | `["/sbin/tini","--","/usr/local/bin/app","elector"]` |

verifier's `--epoch` and other flags continue to travel via `args:`; they are
parsed by verifier's new local `FlagSet`. Update `NOTES.txt` wording that
references the per-binary command convention.

## Risks / trade-offs

- **Dependency convergence**: single version of `golang.org/x/time` (v0.15.0).
  Upward-compatible, low risk; verified by `go build` + `go test ./...`.
- **Binary name `app`**: aligns with the existing Dockerfile comment. Changing
  it later means re-touching the 6 chart command lines.
- **go.sum regeneration in-layer**: single-module mode allows `go build` to
  resolve deps; mirrors the previous `go work sync` approach (go.sum gitignored,
  never copied in).

## Verification

1. `go build -o /tmp/app .` succeeds (single binary).
2. `go test ./...` passes (all migrated tests green).
3. `/tmp/app` with no args prints usage and exits 2; each known subcommand
   dispatches to the right workload (smoke-check `app verifier --epoch=x ...`
   or `--help`).
4. `docker build` produces an image with a single `/usr/local/bin/app`.
5. `helm template chart/` renders with the updated command arrays.
