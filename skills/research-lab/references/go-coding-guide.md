# Go coding guide (research-lab)

Design practices first; idioms second. The practices apply whether you write 50 lines or 500.

## When to pick Go

Pick Go when:
- The demo benefits from concurrent connections (goroutines + channels).
- A small static binary in a distroless image matters (typical container size: <20MB).
- The topic's reference client is Go (e.g., Kubernetes APIs, gRPC, NATS, etcd).

Pick Python (see python-coding-guide.md):
- For data/ML protocols where the Python client is canonical.
- When the demo is simple and synchronous.

## Project layout

```
server/
├── Dockerfile
├── go.mod
├── go.sum
└── main.go             # single file unless the demo grows
```

Pin Go: `golang:1.23-alpine` build stage, `gcr.io/distroless/static-debian12` or `alpine:3.20` runtime stage. Pin module versions in `go.mod`; never use `latest` in imports.

Multi-stage Dockerfile is mandatory for Go — the build image is large, the runtime image should not be.

## Server practices

- **Bind `0.0.0.0`, not `localhost`.** Same issue as Python. A `net.Listen("tcp", ":8080")` (empty host) is correct; `net.Listen("tcp", "localhost:8080")` is the bug.
- **Config from env vars.** Use `os.Getenv` with a small helper for defaults. Surface every var in `.env.example`.
- **Structured logs to stdout.** Use `log/slog` (Go 1.21+). Default to JSON or text handler at info level:
  ```go
  logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
  slog.SetDefault(logger)
  ```
- **Plumb `context.Context` everywhere.** Every blocking call (network, db) takes a context. The root context comes from `signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)`; cancel propagates through the call tree on shutdown.
- **Graceful shutdown.** When the root context is cancelled, stop accepting new work, drain in-flight work with a timeout, then return.
  ```go
  ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
  defer stop()
  // ...
  <-ctx.Done()
  shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
  defer cancel()
  server.Shutdown(shutdownCtx)
  ```
- **Readiness vs. liveness.** Same distinction as Python. A `GET /health` handler that returns 200 if listening is liveness; one that returns 200 only once the server can do real work is readiness.

## Client practices

- **Retry with backoff on initial connect.** Wrap the first connect in a bounded loop. Use a real backoff (e.g., constant 1s for demos is fine; exponential for production).
- **Set deadlines on every network call.** `ctx, cancel := context.WithTimeout(ctx, 5*time.Second); defer cancel()`. Never call a network function with `context.Background()` directly.
- **Exit non-zero on observable failure.** `os.Exit(1)` so the smoke test can detect it. `log.Fatal` works but skips deferreds.
- **Plain-English observation prints.** `fmt.Printf("received message: %s\n", msg)` — the demo output the reader is meant to watch goes through `fmt`, not `slog`.

## Error handling

- **Never ignore errors.** No `_ = doThing()`. If the error genuinely doesn't matter (rare in demos), state it in a comment: `// best-effort; ignore`.
- **Wrap with context.** `fmt.Errorf("connecting to %s: %w", addr, err)`. The caller can `errors.Is` / `errors.As` if needed.
- **No `panic` for expected errors.** Panic is for programmer errors (nil pointer that shouldn't be possible), not for "server is down."
- **No naked `panic` in goroutines** — they kill the process without unwinding deferreds and produce inscrutable stack traces. If a goroutine can fail, return the error via a channel.

## Anti-patterns

- Ignored errors (`_ = err` or `err :=` followed by no check).
- Goroutine leaks: a goroutine with no cancellation path. Every goroutine should observe a context or have a clear termination condition.
- `context.Background()` deep in the call stack instead of plumbed through. Background context belongs at `main()` only.
- `time.Sleep` as inter-service synchronization.
- Returning interface types from functions when a concrete type would do (premature abstraction).
- Naked `panic` for control flow.

## Server skeleton (annotated)

```go
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := getenv("PORT", "8080")
	logger.Info("starting", "port", port)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	srv := &http.Server{Addr: ":" + port, Handler: mux}
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	logger.Info("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown error", "err", err)
		os.Exit(1)
	}
	logger.Info("stopped cleanly")
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
```

## Client skeleton (annotated)

```go
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	server := getenv("SERVER", "server")
	port := getenv("PORT", "8080")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := connectWithRetry(ctx, server, port, 10, time.Second)
	if err != nil {
		logger.Error("could not connect", "err", err)
		os.Exit(1)
	}
	_ = conn // demonstrate the property

	fmt.Printf("observed: <what happened>\n")
}

func connectWithRetry(ctx context.Context, host, port string, attempts int, delay time.Duration) (any, error) {
	for i := 0; i < attempts; i++ {
		// attempt connect; on success, return conn, nil
		// on failure, log and sleep
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil, fmt.Errorf("could not connect to %s:%s after %d attempts", host, port, attempts)
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
```
