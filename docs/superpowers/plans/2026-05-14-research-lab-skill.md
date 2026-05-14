# research-lab Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude skill named `research-lab` that, given a networked-service topic, produces a RESEARCH.md and a runnable docker-compose lab (Python or Go) at `./labs/<topic-slug>/`, with system-design mindsets woven into every stage and a hard "containers only, no host modifications" boundary.

**Architecture:** Progressive-disclosure skill. A thin `SKILL.md` orchestrates five stages (clarify → research → design → build → validate). Each stage references a focused file under `references/`. One bundled helper (`scripts/validate_lab.sh`) performs deterministic validation. Per-language coding guides loaded only after language is chosen.

**Tech Stack:** Markdown (skill content), bash (validation script), shellcheck (lint), Python 3.12 + Go 1.23 (target languages for generated labs), docker compose v2 (lab runtime).

---

## File Structure

Skill package built at `./skills/research-lab/`. Workspace for eval iterations at `./skills/research-lab-workspace/` (sibling).

```
skills/research-lab/
├── SKILL.md                            # ~150-line orchestrator with stage workflow
├── references/
│   ├── system-design-mindsets.md       # cross-stage + per-stage mindsets (the spine)
│   ├── research-doc-format.md          # RESEARCH.md template + writing principles
│   ├── lab-layout.md                   # dir layout, docker-compose, Dockerfile conventions
│   ├── host-isolation-rules.md         # forbidden patterns + pre-validation checklist
│   ├── validation-protocol.md          # validate_lab.sh contract + failure handling
│   ├── python-coding-guide.md          # Python idioms + design practices
│   └── go-coding-guide.md              # Go idioms + design practices
├── scripts/
│   └── validate_lab.sh                 # compose config → up → smoke → down
└── evals/
    └── evals.json                      # test prompts for skill-creator eval loop
```

Each file has one responsibility — `SKILL.md` orchestrates, each reference covers one topic deeply, the script does deterministic work.

---

## Task 1: Scaffold the skill directory

**Files:**
- Create: `skills/research-lab/` (directory)
- Create: `skills/research-lab/references/` (directory)
- Create: `skills/research-lab/scripts/` (directory)
- Create: `skills/research-lab/evals/` (directory)

- [ ] **Step 1: Create directories**

Run:
```bash
mkdir -p skills/research-lab/references skills/research-lab/scripts skills/research-lab/evals
```

- [ ] **Step 2: Verify**

Run:
```bash
find skills/research-lab -type d
```

Expected output (order may vary):
```
skills/research-lab
skills/research-lab/references
skills/research-lab/scripts
skills/research-lab/evals
```

- [ ] **Step 3: Commit (empty dirs become tracked via .gitkeep)**

Run:
```bash
touch skills/research-lab/references/.gitkeep skills/research-lab/scripts/.gitkeep skills/research-lab/evals/.gitkeep
git add skills/research-lab
git commit -m "Scaffold research-lab skill directory"
```

---

## Task 2: Write `references/system-design-mindsets.md`

This file is the spine. Other files reference it; SKILL.md links to it from each stage.

**Files:**
- Create: `skills/research-lab/references/system-design-mindsets.md`

- [ ] **Step 1: Write the file**

Write `skills/research-lab/references/system-design-mindsets.md` with this exact content:

```markdown
# System Design Mindsets

This file is the spine of the research-lab skill. SKILL.md links to it from each stage. The mindsets here are not rules to recite — they are lenses that change *what you build*. Apply them; the rules in other reference files exist to enforce them.

## Cross-stage principles

### Essential vs. accidental complexity (Fred Brooks)

Every topic has irreducible complexity (the wire protocol, the consistency model) and incidental complexity (the choice of config file format, the default port number). A good lab makes the essential complexity *visible* and keeps the accidental complexity *out of the way*. When in doubt, ask: "If I removed this, would the demonstrated property still be observable?" If yes, remove it.

### One concern per lab

A Redis pub/sub lab shows pub/sub. It does not also show persistence, ACL, clustering, and Lua scripting. Each of those deserves its own lab. A lab that demonstrates five things demonstrates none of them clearly. When the user asks for "a Kafka demo", push back until they name the *specific* property — partition assignment? consumer-group rebalance? exactly-once semantics? — and build only that.

### Fail loud, fail early

Demos that hide failure mislead the reader. Surface errors with context, exit non-zero on failure, log to stdout in plain English. A demo that silently retries forever, a smoke test that prints "success" when nothing happened, a server that swallows exceptions — these are worse than a demo that doesn't run, because they teach the wrong mental model.

### Reproducibility over convenience

Pin image tags. Pin language versions. Pin dependency versions. No `:latest`. The reader running the lab six months from now should get the same behavior you saw. Convenience features (auto-update, "smart" defaults) destroy reproducibility; they belong in production tooling, not in demos.

## Per-stage mindsets

### Clarify stage

The work here is to find the **smallest specific property** that captures what the user is trying to learn. "Show me Redis" is too broad. "Show me Redis pub/sub" is still too broad — does the user want to see fanout? subscriber-disconnect behavior? pattern matching? Push until one specific, observable behavior is named. Resist the urge to demonstrate "everything important about X" — that's a tutorial series, not a lab.

### Research stage

Read the primary source first. Project documentation, RFCs, the source code — these tell you what is *load-bearing* about the system. Blog posts and tutorials are secondary; they reflect one person's mental model, often outdated. Capture the wire format / API contract precisely enough that someone could re-implement a minimal client from your RESEARCH.md alone.

### Design stage

The smallest topology that demonstrates the property. If a single server and a single client suffice, do not add a second client "for completeness". Explicit ports, named networks, healthchecks on every service. A reader looking only at `docker-compose.yml` should be able to tell what each service is for; if they can't, the service names or the topology are wrong.

Boundary check: every service has exactly one job. If a single container is running both the server *and* a sidecar that does setup, split them or move setup into a healthcheck-gated init. Mixed responsibilities hide where things go wrong.

### Build stage

Server and client code are **small, readable, and honest**. No clever abstractions. No frameworks where stdlib suffices. Logs in the foreground — `docker compose logs <service>` should tell a coherent story. Graceful shutdown on SIGTERM so `docker compose down` is clean (no zombie state, no truncated writes). Configuration via environment variables with documented defaults. Never hardcode hostnames; service names from compose are the contract.

If you're tempted to add a config-reload mechanism, an admin endpoint, or a metrics exporter, ask whether it demonstrates the property. Usually not — leave it out.

### Validate stage

The smoke test asserts the **property**, not "the container started". A Redis pub/sub smoke test that only checks `redis-cli ping` returns PONG is useless — it doesn't observe pub/sub. The test must publish, must subscribe, must verify delivery. Where cheap, also test one unhappy path: server killed → client sees connection refused with a clear error message.

If the smoke test passes but you cannot point to the line where it observed the property, the smoke test is wrong.

## Anti-patterns commonly seen in demos

These appear constantly in tutorials and blog posts. Recognize them; do not reproduce them.

- **`network_mode: host`** — couples the demo to the user's host, breaks isolation, only ever needed for very specific networking topics.
- **Secrets baked into images** — passwords in Dockerfile `ENV`, API keys in committed `.env`. Use `.env.example` instead.
- **Running as root inside the container** — most upstream images support a non-root user; use it.
- **No healthchecks** — `depends_on` without `condition: service_healthy` is "fingers crossed" ordering and creates flaky demos.
- **Swallowed exceptions** — `except: pass`, `if err != nil { /* nothing */ }`. A demo that hides errors is worse than one that crashes.
- **Sleep-as-synchronization** — `sleep 5 && do_thing`. Replace with a healthcheck or a retry loop with a clear timeout.
- **Smoke tests that don't observe the property** — checking the process exists is not the same as checking it works.
```

- [ ] **Step 2: Verify file written**

Run:
```bash
wc -l skills/research-lab/references/system-design-mindsets.md
```

Expected: roughly 70-90 lines.

- [ ] **Step 3: Commit**

Run:
```bash
git add skills/research-lab/references/system-design-mindsets.md
git commit -m "Add system-design-mindsets spine for research-lab skill"
```

---

## Task 3: Write `references/research-doc-format.md`

**Files:**
- Create: `skills/research-lab/references/research-doc-format.md`

- [ ] **Step 1: Write the file**

Write `skills/research-lab/references/research-doc-format.md` with this exact content:

````markdown
# RESEARCH.md format

The RESEARCH.md inside every lab captures what was learned and what was decided. It is the durable artifact a future reader (often: future-you) reaches for first.

**Writing principle:** terse, primary-source-led, no marketing prose. The audience is a developer trying to understand the lab — not a marketing reader, not a recruiter.

## Required template

Use this exact section order. Each section header is `##`.

```markdown
# Research: <Topic>

## Topic

One sentence: what is this system?

## Property demonstrated

One sentence: the specific, observable behavior this lab shows. Not "demo X" — the *thing* the reader will see happen.

## Concept summary

Three to five bullets covering the essential mental model. No history, no comparisons to alternatives, no "X was created in YYYY by Z". Each bullet should be load-bearing for understanding the lab.

## Wire / API contract

The minimum a client implementer needs to know:
- Protocol (TCP/HTTP/gRPC/custom)
- Message or request/response format
- Commands or endpoints used by *this* lab (not the full surface)

Cite primary-source docs inline as `[name](url)`.

## Design decisions

Bullet list. For each decision, state the choice and the *reason*:
- Version pinned: `<image>:<tag>` because <reason>.
- Single server, single client because <reason>.
- Deliberately excluded: <feature> because <reason>.

The "deliberately excluded" entries matter — they show the essential/accidental cut.

## References

Primary sources first, then secondary, then code links. Each is a bullet with title + URL.
```

## What good looks like

- Each section answers its own question and stops. No section sprawls beyond what it needs.
- The "Property demonstrated" sentence and the smoke test in `scripts/smoke-test.sh` are in 1:1 correspondence. If you can't trace one to the other, one of them is wrong.
- "Deliberately excluded" is honest: include the obvious next questions the reader will ask ("what about persistence? clustering? auth?") and say why this lab does not address them.

## What bad looks like

- A "Background" or "History" section. Cut it.
- A "Why X over Y" comparison. Belongs in a separate writeup; not in this lab's research.
- Wire-protocol section that just paraphrases the upstream README. Either cite and link, or distill — don't restate at length.
- "Future work" section. The lab is done when the property is demonstrated.
````

- [ ] **Step 2: Verify**

Run:
```bash
test -s skills/research-lab/references/research-doc-format.md && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

Run:
```bash
git add skills/research-lab/references/research-doc-format.md
git commit -m "Add research-doc-format reference"
```

---

## Task 4: Write `references/lab-layout.md`

**Files:**
- Create: `skills/research-lab/references/lab-layout.md`

- [ ] **Step 1: Write the file**

Write `skills/research-lab/references/lab-layout.md` with this exact content:

````markdown
# Lab layout & docker-compose conventions

Every lab generated by this skill follows the same shape. Consistency makes labs comparable and reduces cognitive load when reading a new one.

## Directory layout

```
labs/<topic-slug>/
├── README.md           # what this lab demonstrates, how to run, expected output, teardown
├── RESEARCH.md         # research + design decisions (see research-doc-format.md)
├── docker-compose.yml  # services, networks, volumes, healthchecks
├── .env.example        # documented env vars; never commit a real .env
├── server/
│   ├── Dockerfile
│   ├── (source files)
│   └── (manifest: requirements.txt / go.mod + go.sum)
├── client/
│   ├── Dockerfile
│   ├── (source files)
│   └── (manifest)
└── scripts/
    └── smoke-test.sh   # exercises the property; called by validate_lab.sh
```

**topic-slug** is kebab-case, lowercase, no version numbers. Examples: `redis-pubsub-fanout`, `nats-jetstream-consumer`, `postgres-logical-replication`. The slug names the property when reasonable, not just the system.

## README.md template

Five sections, in this order:

```markdown
# <Topic slug>

## What this demonstrates

One sentence. Identical to the "Property demonstrated" line in RESEARCH.md.

## Run it

```bash
cp .env.example .env       # only if you want to override defaults
docker compose up -d --wait
docker compose logs -f client    # or: docker compose logs server
```

## Expected output

A short example of what success looks like. Quote actual log lines the demo produces.

## Teardown

```bash
docker compose down -v
```

## Further reading

Links lifted from RESEARCH.md. Most useful first.
```

## docker-compose.yml conventions

- `name: lab-<topic-slug>` at the top so containers are easy to identify across multiple labs.
- Pinned image tags. No `:latest`. Prefer digest pins for production-mimicking labs.
- A named bridge network per lab: `networks: { lab: { driver: bridge } }`.
- Named volumes scoped to the lab: `volumes: { <topic-slug>-data: {} }`.
- Service-to-service communication uses **service names** (`server:6379`), never `localhost`.
- `restart: "no"` everywhere. Demos should expose crashes, not silently respawn.
- Every service has a `healthcheck:` block, or a single-line comment explaining why one is not needed for that service.
- Client uses `depends_on: { server: { condition: service_healthy } }`. No `sleep` for synchronization.
- Host port mappings use the high range (≥ 15000) to avoid colliding with the user's other services. Default ports listed in `.env.example`.

## Dockerfile conventions

- Multi-stage where there's a compile step (Go always, Python only if building wheels).
- Pinned base image: `python:3.12-slim` or `python:3.12-slim@sha256:...` is fine; `python:latest` is not. For Go, `golang:1.23-alpine` for build, `gcr.io/distroless/static-debian12` or `alpine:3.20` for runtime.
- A non-root `USER` for the runtime stage where the image supports it.
- `HEALTHCHECK` Dockerfile instruction only if compose-level healthcheck is impractical (rare).
- `COPY` for local files; never `ADD` from URLs.
- `WORKDIR` set explicitly, not relying on default `/`.

## smoke-test.sh contract

- Exits 0 only if the demonstrated property was observed.
- Wall-clock timeout (default 60s). Never hangs forever. Use `timeout 60s` wrapping or explicit loop bounds.
- Prints what it observed in plain English on success (e.g., `"3 subscribers each received message 'hello'"`).
- On failure, prints `docker compose logs --tail=50` for each service so the reader can diagnose.
- Runs against the lab from outside the containers (via `docker compose exec` or by hitting exposed ports). Treats the lab as a black box.
````

- [ ] **Step 2: Verify**

Run:
```bash
test -s skills/research-lab/references/lab-layout.md && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

Run:
```bash
git add skills/research-lab/references/lab-layout.md
git commit -m "Add lab-layout reference"
```

---

## Task 5: Write `references/host-isolation-rules.md`

**Files:**
- Create: `skills/research-lab/references/host-isolation-rules.md`

- [ ] **Step 1: Write the file**

Write `skills/research-lab/references/host-isolation-rules.md` with this exact content:

````markdown
# Host isolation rules

**Hard constraint:** Everything the lab does happens inside containers. The host OS is read-only from the lab's perspective. This isn't a style preference — it's a safety contract with the user.

## Forbidden — never do these

- `sudo` anything. Any command requiring host root.
- Install host packages: `apt`, `apt-get`, `yum`, `dnf`, `brew`, `pacman`, `pip install` *outside* a container or venv.
- Write to host system paths: `/etc/`, `/usr/`, `/var/` (outside container layers), `/boot/`, `/lib/`, `/lib64/`, `/opt/`.
- Modify systemd units, write to `~/.config/systemd/`, run `systemctl`.
- Change kernel parameters: `sysctl`, writes to `/proc/sys/*`, writes to `/sys/*`.
- Edit shell rc files on the host: `~/.bashrc`, `~/.zshrc`, `~/.profile`, `~/.bash_profile`.
- Bind to privileged host ports (< 1024).
- Modify `/etc/hosts`, `/etc/resolv.conf`, or DNS resolver config on the host.

In `docker-compose.yml`, the following are forbidden unless the topic *is* that capability and the use is justified in RESEARCH.md "Design decisions":

- `privileged: true`
- `network_mode: host`
- `pid: host`
- `ipc: host`
- `cap_add` for `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, or `ALL`
- Bind mounts whose source is outside `./labs/<topic-slug>/`. Particularly: no `/var/run/docker.sock`, no `/etc/`, no `$HOME`, no `/` itself.

## Required — always do these

- All state lives inside the lab directory. Use named volumes scoped to the lab, or relative bind mounts (e.g., `./data:/var/lib/...`).
- Run as a non-root user inside containers wherever the upstream image supports it.
- Host port mappings use the high range (≥ 15000). Default values surfaced in `.env.example` so users can change them.
- Every service has `healthcheck:` or a one-line comment explaining why none is needed (rare; almost always a code smell).

## Pre-validation checklist

Run these greps before invoking `scripts/validate_lab.sh`. Any hit must be resolved at the root — do not delete the check.

```bash
cd labs/<topic-slug>

# 1. Forbidden compose flags
grep -nE 'privileged:|network_mode:.*host|pid:.*host|ipc:.*host' docker-compose.yml && echo "FAIL: forbidden compose flag" && exit 1

# 2. Forbidden bind-mount sources (anything starting with absolute system path)
grep -nE '^\s*-\s+(/etc|/var|/usr|/home|/root|/boot|/lib|/proc|/sys)(/|:)' docker-compose.yml && echo "FAIL: forbidden bind source" && exit 1

# 3. docker.sock mount
grep -n 'docker.sock' docker-compose.yml && echo "FAIL: docker socket mount" && exit 1

# 4. sudo anywhere in lab files
grep -rn 'sudo ' . && echo "FAIL: sudo in lab files" && exit 1

# 5. Privileged host ports
grep -nE '^\s+-\s+"[0-9]{1,3}:' docker-compose.yml && echo "FAIL: privileged host port" && exit 1

echo "Pre-validation checks passed."
```

(The checklist is run as part of `scripts/validate_lab.sh`; the script aborts if any check fails.)

## When a topic genuinely needs more

Some topics are *about* capabilities normally forbidden — e.g., demonstrating a packet-capture proxy may need `cap_add: NET_ADMIN`. In those cases:

1. State the requirement in RESEARCH.md "Design decisions" with a one-paragraph justification.
2. Use the minimum capability needed (prefer specific `cap_add` over `privileged: true`).
3. Document the implication in README.md so the user running the lab knows what they are granting.

If the topic requires modifying the host OS to work at all (kernel module load, sysctl change), the skill must decline the topic and explain why to the user.
````

- [ ] **Step 2: Verify**

Run:
```bash
test -s skills/research-lab/references/host-isolation-rules.md && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

Run:
```bash
git add skills/research-lab/references/host-isolation-rules.md
git commit -m "Add host-isolation-rules reference"
```

---

## Task 6: Write `references/validation-protocol.md`

**Files:**
- Create: `skills/research-lab/references/validation-protocol.md`

- [ ] **Step 1: Write the file**

Write `skills/research-lab/references/validation-protocol.md` with this exact content:

````markdown
# Validation protocol

A lab is not done until `scripts/validate_lab.sh` exits 0 against it. The script is the single source of truth for "does it work."

## What `validate_lab.sh` does

```
1. docker compose config -q                  # schema/YAML check, fail fast
2. host-isolation grep checklist             # see host-isolation-rules.md
3. docker compose up -d --wait               # relies on healthchecks; bounded by compose timeout
4. bash scripts/smoke-test.sh                # lab-specific property assertion
5. docker compose down -v                    # always runs, via trap, even on failure
6. exit ${SMOKE_EXIT_CODE}                   # propagates the smoke test's exit
```

Step 5 runs unconditionally — a failed run does not leave dangling state.

## Smoke test contract (recap)

Each lab provides its own `scripts/smoke-test.sh`. The script must:

- Exit 0 only if the **demonstrated property** was observed. Not "the process is running" — the actual property.
- Bound its wall-clock runtime to 60s by default. Use `timeout` or an explicit loop with a counter.
- On success, print a single sentence describing what it observed.
- On failure, print the last 50 log lines from each service.

If the property is "subscriber receives messages from publisher", the smoke test publishes a known payload, subscribes, and asserts the payload was delivered — by reading actual logs or by running a verifier client. Checking `redis-cli ping` returns PONG is *not* a smoke test for pub/sub.

## Failure handling discipline

When `validate_lab.sh` fails:

1. **Read logs first.** `docker compose logs --tail=100 <service>`. Form a hypothesis from evidence, not from guessing.
2. **Fix the root cause.** Forbidden shortcuts:
   - Increasing timeouts to mask a race condition.
   - Removing healthchecks to "fix" startup.
   - Weakening the smoke test to make it pass.
   - Adding `restart: always` to make a flaky service look stable.
   These are all forms of hiding the failure.
3. **Tear down between attempts.** `docker compose down -v` before retrying with code changes, so stale volumes can't mask a fix.
4. **Three-strike rule.** After 3 failed attempts on the same root cause, escalate: invoke `superpowers:systematic-debugging` rather than continuing to guess.
5. **If the property genuinely cannot be demonstrated as designed,** go back to the Design stage. Adjust the topology or the property statement — don't paper over.

## What "validated" means

The lab is validated when:

- `validate_lab.sh` exits 0.
- The smoke test's success message accurately describes what was observed.
- No containers, volumes, or networks remain on the host after the run.
- `git status` in the lab dir is clean (no debug artifacts left behind).

Anything less and the lab ships unfinished.
````

- [ ] **Step 2: Verify**

Run:
```bash
test -s skills/research-lab/references/validation-protocol.md && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

Run:
```bash
git add skills/research-lab/references/validation-protocol.md
git commit -m "Add validation-protocol reference"
```

---

## Task 7: Write `references/python-coding-guide.md`

**Files:**
- Create: `skills/research-lab/references/python-coding-guide.md`

- [ ] **Step 1: Write the file**

Write `skills/research-lab/references/python-coding-guide.md` with this exact content:

````markdown
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
````

- [ ] **Step 2: Verify**

Run:
```bash
test -s skills/research-lab/references/python-coding-guide.md && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

Run:
```bash
git add skills/research-lab/references/python-coding-guide.md
git commit -m "Add python-coding-guide reference"
```

---

## Task 8: Write `references/go-coding-guide.md`

**Files:**
- Create: `skills/research-lab/references/go-coding-guide.md`

- [ ] **Step 1: Write the file**

Write `skills/research-lab/references/go-coding-guide.md` with this exact content:

````markdown
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
````

- [ ] **Step 2: Verify**

Run:
```bash
test -s skills/research-lab/references/go-coding-guide.md && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

Run:
```bash
git add skills/research-lab/references/go-coding-guide.md
git commit -m "Add go-coding-guide reference"
```

---

## Task 9: Write `scripts/validate_lab.sh`

**Files:**
- Create: `skills/research-lab/scripts/validate_lab.sh`

- [ ] **Step 1: Write the script**

Write `skills/research-lab/scripts/validate_lab.sh` with this exact content:

```bash
#!/usr/bin/env bash
# validate_lab.sh - bring up a lab, run its smoke test, tear down. Always exits cleanly.
#
# Usage:
#   scripts/validate_lab.sh <lab-dir>
#
# Exit code:
#   0  - lab passed smoke test
#   1  - validation failed (any step)
#   2  - usage error

set -u
set -o pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <lab-dir>" >&2
    exit 2
fi

LAB_DIR="$1"

if [ ! -d "$LAB_DIR" ]; then
    echo "FAIL: lab dir not found: $LAB_DIR" >&2
    exit 1
fi

if [ ! -f "$LAB_DIR/docker-compose.yml" ]; then
    echo "FAIL: no docker-compose.yml in $LAB_DIR" >&2
    exit 1
fi

if [ ! -f "$LAB_DIR/scripts/smoke-test.sh" ]; then
    echo "FAIL: no scripts/smoke-test.sh in $LAB_DIR" >&2
    exit 1
fi

cd "$LAB_DIR"

# Always tear down, even on failure or interrupt.
cleanup() {
    echo "--- teardown ---"
    docker compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== validate_lab.sh: $LAB_DIR ==="

# --- 1. compose schema check ---
echo "--- step 1: docker compose config ---"
if ! docker compose config -q; then
    echo "FAIL: docker compose config rejected the file" >&2
    exit 1
fi

# --- 2. host-isolation grep checklist ---
echo "--- step 2: host-isolation checks ---"

if grep -nE 'privileged:[[:space:]]*true|network_mode:[[:space:]]*("|'\'')?host|pid:[[:space:]]*("|'\'')?host|ipc:[[:space:]]*("|'\'')?host' docker-compose.yml; then
    echo "FAIL: forbidden compose flag (privileged / host networking / host pid / host ipc)" >&2
    exit 1
fi

if grep -nE '^[[:space:]]*-[[:space:]]+(/etc|/var|/usr|/home|/root|/boot|/lib|/proc|/sys)(/|:)' docker-compose.yml; then
    echo "FAIL: forbidden bind-mount source (system path)" >&2
    exit 1
fi

if grep -n 'docker\.sock' docker-compose.yml; then
    echo "FAIL: docker socket mount detected" >&2
    exit 1
fi

if grep -rn --include='*.sh' --include='*.yml' --include='*.yaml' --include='Dockerfile*' 'sudo ' . 2>/dev/null; then
    echo "FAIL: 'sudo' detected in lab files" >&2
    exit 1
fi

if grep -nE '^[[:space:]]+-[[:space:]]+"?[0-9]{1,3}:' docker-compose.yml; then
    echo "FAIL: privileged host port (<1024) detected" >&2
    exit 1
fi

echo "host-isolation checks passed."

# --- 3. bring up ---
echo "--- step 3: docker compose up -d --wait ---"
if ! docker compose up -d --wait; then
    echo "FAIL: services did not become healthy" >&2
    docker compose ps
    docker compose logs --tail=50
    exit 1
fi

# --- 4. smoke test ---
echo "--- step 4: smoke test ---"
SMOKE_EXIT=0
bash scripts/smoke-test.sh || SMOKE_EXIT=$?

if [ "$SMOKE_EXIT" -ne 0 ]; then
    echo "FAIL: smoke test exited $SMOKE_EXIT" >&2
    docker compose logs --tail=50
    exit 1
fi

echo "=== validate_lab.sh: PASS ==="
exit 0
```

- [ ] **Step 2: Make executable**

Run:
```bash
chmod +x skills/research-lab/scripts/validate_lab.sh
```

- [ ] **Step 3: Shellcheck**

Run:
```bash
shellcheck skills/research-lab/scripts/validate_lab.sh && echo "shellcheck OK"
```

Expected: `shellcheck OK`. If shellcheck reports issues, fix them and re-run.

If `shellcheck` is not installed, install it inside a container or skip this step with a note in the commit message. Do **not** install shellcheck on the host (host-isolation rule).

- [ ] **Step 4: Smoke-test the script's argument handling**

Run:
```bash
bash skills/research-lab/scripts/validate_lab.sh
echo "exit: $?"
```

Expected: usage error message, `exit: 2`.

Run:
```bash
bash skills/research-lab/scripts/validate_lab.sh /tmp/does-not-exist-xyz
echo "exit: $?"
```

Expected: `FAIL: lab dir not found`, `exit: 1`.

- [ ] **Step 5: Commit**

Run:
```bash
git add skills/research-lab/scripts/validate_lab.sh
git commit -m "Add validate_lab.sh helper script"
```

---

## Task 10: Write `SKILL.md` (the orchestrator)

This is the entry point. It must be tight (~150 lines), name the five stages, and point to the right reference file at each stage.

**Files:**
- Create: `skills/research-lab/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

Write `skills/research-lab/SKILL.md` with this exact content:

````markdown
---
name: research-lab
description: Use when the user wants to research, prototype, demonstrate, or learn about a networked service or protocol — phrases like "build a lab for X", "show me how Kafka rebalances", "demo Redis pub/sub fanout", "spin up a Postgres logical replication example", or any request for a runnable client/server demo of a backend system. Produces a RESEARCH.md plus a self-contained docker-compose lab under ./labs/<topic-slug>/ in Python or Go. Trigger this skill whenever the user asks for a hands-on experiment with a server/client wire protocol — even if they don't say "skill" or "lab" explicitly. Skip only for purely-frontend topics, ML training pipelines, or topics that fundamentally require host OS changes.
---

# research-lab

Given a topic that has a server/client wire protocol, this skill produces:

1. **RESEARCH.md** — a tight (1–2 page) document capturing the topic's essentials and the design decisions for this lab.
2. **A runnable lab** at `./labs/<topic-slug>/` — `docker-compose.yml`, server, client, smoke test. Validated end-to-end before declaring done.

## Hard constraints

- **Containers only.** No host OS changes. No `sudo`. No host package installs. No writes to `/etc/`, `/usr/`, `/var/`, kernel params, shell rc files, or systemd units. See `references/host-isolation-rules.md` for the full forbidden/required list.
- **One concern per lab.** Demonstrate one specific, observable property. Push back on vague requests until the property is named.
- **Validated before "done".** Run `scripts/validate_lab.sh` against the lab. Exit 0 or the work is not finished.

## Workflow (five stages)

Apply the mindsets in `references/system-design-mindsets.md` throughout. Each stage below names its mindset and the reference files to load.

### Stage 1 — Clarify

**Mindset:** *one demonstration concern per lab.* See `references/system-design-mindsets.md` § Clarify.

Invoke `superpowers:brainstorming` to nail down:

- **Topic** (e.g., "Redis pub/sub").
- **Property to demonstrate** — a specific, observable behavior, not a vague survey. "Fanout to N subscribers without persistence" ✓. "Demo Redis" ✗.
- **Constraints** — anything the user mentions about architecture, ports, image choices.

Then recommend a language (Python or Go) with reasoning grounded in the topic. The decision rubric is in `references/python-coding-guide.md` and `references/go-coding-guide.md` ("When to pick this language"). Get user confirm before proceeding.

**Stage exit checklist:**
- [ ] Topic written down.
- [ ] Property to demonstrate is one sentence, names an observable behavior.
- [ ] Language chosen and confirmed by user.

### Stage 2 — Research

**Mindset:** *separate essential from accidental complexity.* See `references/system-design-mindsets.md` § Research.

Read primary sources (project docs, RFCs, source code) first. Secondary sources only to fill gaps. Capture findings in `labs/<topic-slug>/RESEARCH.md` using the template in `references/research-doc-format.md`.

**Stage exit checklist:**
- [ ] RESEARCH.md exists with all required sections filled in.
- [ ] "Property demonstrated" line is verbatim what was agreed in Stage 1.
- [ ] "Deliberately excluded" list names the obvious next questions and why this lab does not address them.

### Stage 3 — Design

**Mindset:** *minimal viable surface; design for failure-loudness.* See `references/system-design-mindsets.md` § Design.

Sketch the smallest topology that demonstrates the property. Decide services, ports, volumes, healthchecks.

**Escalation trigger:** if the design requires **3 or more services beyond the client**, or multi-node coordination, **invoke `superpowers:writing-plans`** to produce an implementation plan before coding. Smaller designs (1 server + 1 client, optionally + 1 dependency like a DB) proceed inline.

Append a "Design" subsection to RESEARCH.md capturing the chosen topology and the rejected alternatives with reasons.

**Stage exit checklist:**
- [ ] Topology fits on a small diagram in your head — services, ports, healthcheck on each.
- [ ] Escalation decision made (inline or invoke writing-plans).
- [ ] RESEARCH.md "Design decisions" section updated.

### Stage 4 — Build

**Mindset:** *observability built in, graceful shutdown, explicit configuration.* See `references/system-design-mindsets.md` § Build.

Scaffold `./labs/<topic-slug>/` per `references/lab-layout.md`. Generate:

- `docker-compose.yml` per the conventions in `references/lab-layout.md` (pinned tags, named network, healthchecks, host ports ≥ 15000).
- `server/` and `client/` per the chosen-language guide (`references/python-coding-guide.md` or `references/go-coding-guide.md`).
- `Dockerfile`s per the lab-layout Dockerfile conventions (multi-stage for Go, non-root user, pinned base).
- `.env.example` documenting every env var.
- `scripts/smoke-test.sh` that exercises the property (not just liveness).
- `README.md` per the lab-layout template.

**Before invoking validation:** mentally run the pre-validation grep checklist in `references/host-isolation-rules.md`. If anything would fail, fix it now — don't make the script find it.

**Stage exit checklist:**
- [ ] All files from the lab-layout structure exist.
- [ ] No `:latest` image tags.
- [ ] Every service has a `healthcheck`.
- [ ] Client uses `depends_on: { server: { condition: service_healthy } }`.
- [ ] Host ports are ≥ 15000.
- [ ] Smoke test asserts the *property*, not just that the process started.

### Stage 5 — Validate

**Mindset:** *verify the demonstrated property, not just "container started".* See `references/system-design-mindsets.md` § Validate. Failure-handling rules in `references/validation-protocol.md`.

Run:

```bash
bash <skill-root>/scripts/validate_lab.sh labs/<topic-slug>
```

On failure: read logs, diagnose root cause, fix, retry. **Do not** mask failures (longer timeouts, weaker smoke test, removing healthchecks). After 3 failed attempts on the same root cause, invoke `superpowers:systematic-debugging`.

**Stage exit checklist:**
- [ ] `validate_lab.sh` exits 0.
- [ ] Smoke test's success message accurately describes what was observed.
- [ ] No leftover containers/volumes (`docker ps -a` and `docker volume ls` are clean of lab artifacts).
- [ ] `git status` in the lab dir is clean of debug artifacts.

## Reference files

- `references/system-design-mindsets.md` — the spine; load at the start of any stage.
- `references/research-doc-format.md` — RESEARCH.md template (Stage 2).
- `references/lab-layout.md` — directory, docker-compose, Dockerfile conventions (Stage 4).
- `references/host-isolation-rules.md` — forbidden/required patterns + pre-validation checklist (Stage 4–5).
- `references/validation-protocol.md` — what `validate_lab.sh` does, failure-handling rules (Stage 5).
- `references/python-coding-guide.md` — Python practices + skeletons (Stage 4, if Python chosen).
- `references/go-coding-guide.md` — Go practices + skeletons (Stage 4, if Go chosen).

## When to decline

If the topic *fundamentally* requires modifying the host OS (loading a kernel module, changing sysctls, installing a host service) to work at all, decline and explain why. Containers can demonstrate a great deal, but not everything — being honest about the boundary is part of the skill's contract.
````

- [ ] **Step 2: Verify line count is reasonable**

Run:
```bash
wc -l skills/research-lab/SKILL.md
```

Expected: roughly 100-160 lines. If above 200, identify content that belongs in a reference file and move it.

- [ ] **Step 3: Verify frontmatter is parseable**

Run:
```bash
python3 -c "
import sys
with open('skills/research-lab/SKILL.md') as f:
    text = f.read()
assert text.startswith('---\n'), 'no frontmatter'
end = text.index('\n---\n', 4)
front = text[4:end]
print('frontmatter OK, body starts at line', text[:end].count('\n')+2)
print('description length:', len([l for l in front.split('\n') if l.startswith('description:')][0]))
"
```

Expected: `frontmatter OK, body starts at line ...` and a description-length value (should be > 200 chars — descriptive).

- [ ] **Step 4: Commit**

Run:
```bash
git add skills/research-lab/SKILL.md
git commit -m "Add SKILL.md orchestrator for research-lab"
```

---

## Task 11: Write `evals/evals.json` with test prompts

These prompts drive the skill-creator eval loop. They should sound like real users — concrete topics, some casual phrasing.

**Files:**
- Create: `skills/research-lab/evals/evals.json`

- [ ] **Step 1: Write the file**

Write `skills/research-lab/evals/evals.json` with this exact content:

```json
{
  "skill_name": "research-lab",
  "evals": [
    {
      "id": 1,
      "name": "redis-pubsub-fanout",
      "prompt": "I want to actually see how Redis pub/sub fanout works — set up a lab where one publisher sends to three subscribers and I can watch the messages arrive at each one. Python is fine.",
      "expected_output": "A ./labs/<slug>/ directory with RESEARCH.md, docker-compose.yml (redis + publisher + 3 subscribers, or 1 subscriber service scaled to 3, with healthchecks and pinned images), server/client Python code with logging, a smoke-test.sh that publishes a known message and verifies all subscribers received it, README, and a successful validate_lab.sh run.",
      "files": []
    },
    {
      "id": 2,
      "name": "nats-jetstream-consumer",
      "prompt": "Build me a quick demo of NATS JetStream with a durable consumer that survives a restart. I want to publish 10 messages, have the consumer process 5, restart it, and see that it picks up where it left off. Use Go.",
      "expected_output": "A ./labs/<slug>/ directory with RESEARCH.md covering JetStream's durable-consumer semantics, docker-compose.yml (nats with -js flag, publisher, consumer, pinned tags, healthchecks), Go server/client with structured logging and graceful shutdown, smoke-test.sh that asserts the consumer resumes from message 6 after restart, README, and a successful validate_lab.sh run.",
      "files": []
    },
    {
      "id": 3,
      "name": "postgres-logical-replication",
      "prompt": "demo postgres logical replication between a primary and a replica, I want to insert a row on primary and see it on replica",
      "expected_output": "A ./labs/<slug>/ directory with RESEARCH.md covering logical replication setup (publication, subscription, wal_level=logical), docker-compose.yml with two postgres services (pinned versions) with healthchecks and named volumes, init SQL scripts to create publication/subscription, a smoke-test.sh that inserts on primary and asserts the row appears on replica within a bounded wait, README, and a successful validate_lab.sh run. Language: Python (psql via container exec is also acceptable).",
      "files": []
    }
  ]
}
```

- [ ] **Step 2: Validate JSON**

Run:
```bash
python3 -m json.tool skills/research-lab/evals/evals.json > /dev/null && echo "JSON valid"
```

Expected: `JSON valid`.

- [ ] **Step 3: Commit**

Run:
```bash
git add skills/research-lab/evals/evals.json
git commit -m "Add evals.json with three real-user test prompts"
```

---

## Task 12: Final structural sanity check

- [ ] **Step 1: Tree listing**

Run:
```bash
find skills/research-lab -type f | sort
```

Expected (allowing for the `.gitkeep` files from Task 1, which can now be deleted since real files exist in each dir):
```
skills/research-lab/SKILL.md
skills/research-lab/evals/evals.json
skills/research-lab/references/go-coding-guide.md
skills/research-lab/references/host-isolation-rules.md
skills/research-lab/references/lab-layout.md
skills/research-lab/references/python-coding-guide.md
skills/research-lab/references/research-doc-format.md
skills/research-lab/references/system-design-mindsets.md
skills/research-lab/references/validation-protocol.md
skills/research-lab/scripts/validate_lab.sh
```

- [ ] **Step 2: Clean up `.gitkeep` placeholders**

Run:
```bash
rm -f skills/research-lab/references/.gitkeep skills/research-lab/scripts/.gitkeep skills/research-lab/evals/.gitkeep
git add -A skills/research-lab
git diff --cached --stat
```

Expected: three deletions, nothing else.

- [ ] **Step 3: Commit**

Run:
```bash
git commit -m "Remove .gitkeep placeholders now that all dirs have content"
```

- [ ] **Step 4: Cross-reference check**

Confirm every `references/*.md` file mentioned in SKILL.md exists:

Run:
```bash
for f in system-design-mindsets research-doc-format lab-layout host-isolation-rules validation-protocol python-coding-guide go-coding-guide; do
    if [ -f "skills/research-lab/references/$f.md" ]; then
        echo "OK: $f.md"
    else
        echo "MISSING: $f.md"
    fi
done
```

Expected: seven `OK:` lines, no `MISSING`.

If any are missing, the relevant earlier task was skipped — go back and complete it.

---

## Self-review (already performed)

**Spec coverage:** Each spec requirement maps to a task:
- Five workflow stages → Task 10 (SKILL.md).
- File structure → Task 1 (scaffold) + Tasks 2–9 (content).
- system-design-mindsets spine → Task 2.
- RESEARCH.md format → Task 3.
- Lab layout & compose conventions → Task 4.
- Host-isolation rules → Task 5.
- Validation contract → Task 6 (reference) + Task 9 (script).
- Coding guides → Tasks 7–8.
- Trigger description → Task 10 (frontmatter).
- Evals for skill-creator loop → Task 11.

**Placeholder scan:** None of the tasks contain TBD/TODO/"fill in". Every file's content is given verbatim.

**Type consistency:** File names referenced in SKILL.md (Task 10) match the files created in Tasks 2–9. Stage exit checklists match the mindsets/files they reference.

---

## After plan execution: hand back to skill-creator

When all twelve tasks above are complete, return to the skill-creator workflow already in progress:

1. Run the eval loop (with-skill + baseline subagents for each prompt in `evals/evals.json`).
2. Grade, aggregate to `benchmark.json`, launch `eval-viewer/generate_review.py`.
3. Read user feedback, iterate.
4. Optionally run description optimization.
5. Package via `python -m scripts.package_skill skills/research-lab/`.

The skill-creator's instructions cover these steps — this plan only owns the file-creation part.
