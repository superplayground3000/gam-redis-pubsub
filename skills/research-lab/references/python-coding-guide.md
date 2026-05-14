# Python coding guide (research-lab)

Design practices first; idioms second. The practices apply whether you write 30 lines or 300.

## When to pick Python

Pick Python when:
- The topic's mature client library is Python-first (e.g., many ML serving, scientific protocols, AMQP/MQTT in some ecosystems).
- The demo is small, mostly synchronous, and readability beats performance.
- The reader is more likely to be familiar with Python than Go (e.g., data-engineering topics).

Pick Go when (see go-coding-guide.md):
- The demo benefits from goroutines (many concurrent connections, structured concurrency).
- Static binary in a distroless image matters for the lab.
- The topic's reference client is Go.

## Project layout

```
server/
├── Dockerfile
├── requirements.txt        # pinned versions, one per line
└── server.py               # single file unless the demo grows
```

Pin Python: `python:3.12-slim` base. Pin dependencies: `redis==5.0.7`, not `redis>=5`. Use `pip install --no-cache-dir -r requirements.txt`.

## Server practices

- **Bind `0.0.0.0`, not `localhost`.** A server bound to `localhost` inside a container is unreachable from other containers. This is the single most common bug in containerized Python demos.
- **Config from env vars.** Use `os.environ.get("KEY", "default")` with documented defaults. Surface every var in `.env.example` with a comment.
- **Structured logs to stdout.** Use the `logging` module, never bare `print` for diagnostic output. A minimal config:
  ```python
  import logging
  logging.basicConfig(
      level=os.environ.get("LOG_LEVEL", "INFO"),
      format="%(asctime)s %(levelname)s %(name)s %(message)s",
  )
  ```
  Stdout, not files. Docker captures stdout; files inside containers are invisible to `docker compose logs`.
- **Graceful shutdown on SIGTERM.** Register a handler that closes connections and exits cleanly so `docker compose down` doesn't kill mid-write.
  ```python
  import signal
  shutdown = False
  def handle_sigterm(signum, frame):
      global shutdown
      shutdown = True
  signal.signal(signal.SIGTERM, handle_sigterm)
  ```
- **Readiness vs. liveness.** A healthcheck that just checks the process exists is liveness. A healthcheck that checks the server actually accepts connections is readiness. Use readiness for `depends_on` synchronization.
- **Never log secrets.** Mask tokens and passwords; if the demo prints them at startup, future users will leak them.

## Client practices

- **Retry with backoff on initial connect.** `depends_on: service_healthy` reduces but does not eliminate race conditions. Wrap the first connect in a bounded retry loop (e.g., 10 attempts, 1s sleep between).
- **Timeouts on every network call.** No `requests.get(url)` without `timeout=`. No `redis.Redis()` without `socket_timeout=`. A demo with no timeouts is a demo that hangs forever when something is wrong.
- **Exit non-zero on observable failure.** The smoke test relies on the client's exit code. If the client failed to demonstrate the property, `sys.exit(1)`.
- **Plain-English observation prints.** `print(f"received message: {msg}")` — the reader watching `docker compose logs client` should see a story, not a hex dump.

## Error handling

- Surface errors with context. Never bare `except:`. Catch the narrowest exception type that handles the case.
- Wrap external operations in `try`/`except`, log the error with the operation that triggered it, then re-raise or exit.
- Do not retry forever. Bounded retries with a clear "giving up" log line.

## Anti-patterns

- `print` for log lines that should be structured. (Acceptable: `print` of *demo output* the reader is meant to watch.)
- `requests` calls with no `timeout=`.
- `time.sleep` as synchronization between services (use healthchecks/retries).
- Mutable module-level state shared across handlers.
- Mixing `async` and sync I/O without understanding the consequences (this is a common Python gotcha; if you're not sure, use sync).

## Server skeleton (annotated)

```python
import logging
import os
import signal
import sys

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("server")

HOST = "0.0.0.0"
PORT = int(os.environ.get("PORT", "8080"))

shutdown = False
def handle_sigterm(signum, frame):
    global shutdown
    log.info("SIGTERM received, shutting down")
    shutdown = True

signal.signal(signal.SIGTERM, handle_sigterm)

def main():
    log.info("starting on %s:%d", HOST, PORT)
    # ... bind, accept loop, etc.
    while not shutdown:
        # serve one unit of work
        pass
    log.info("stopped cleanly")

if __name__ == "__main__":
    sys.exit(main() or 0)
```

## Client skeleton (annotated)

```python
import logging
import os
import sys
import time

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                    format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("client")

SERVER = os.environ.get("SERVER", "server")
PORT = int(os.environ.get("PORT", "8080"))

def connect_with_retry(attempts=10, delay=1.0):
    for i in range(attempts):
        try:
            # ... attempt connection
            log.info("connected on attempt %d", i + 1)
            return  # return the connection
        except Exception as e:
            log.warning("connect attempt %d failed: %s", i + 1, e)
            time.sleep(delay)
    log.error("could not connect after %d attempts", attempts)
    sys.exit(1)

def main():
    conn = connect_with_retry()
    # demonstrate the property; print plain-English observations
    print(f"observed: <what happened>")
    return 0

if __name__ == "__main__":
    sys.exit(main())
```
