# Design: `research-lab` skill

## Purpose

A skill that, given a topic involving a networked service (messaging system, database, proxy, service mesh, etc.), produces:

1. A short RESEARCH.md capturing the topic's essentials and the design decisions made for the lab.
2. A runnable, self-contained demo/lab directory under `./labs/<topic-slug>/` containing a server, a client, a `docker-compose.yml`, and a smoke test that validates the demonstrated property.

The skill teaches system-design discipline as it works — research, design, build, validate — and produces labs that respect a hard "containers only, no host modifications" boundary.

## Scope

**In scope:**
- Topics with a server/client wire protocol that can be containerized.
- Python or Go for demo code (skill recommends, user confirms).
- Single-service or small-multi-service labs (≤ 2 services beyond client) run inline.

**Out of scope (for v1):**
- Pure-frontend or browser-only topics.
- ML/data-science workflows (no client/server wire protocol).
- Topics that fundamentally require kernel-level features the user must enable on the host (e.g., specific kernel modules). The skill must decline these explicitly.

## Workflow stages

The skill walks the executing model through five stages. Each stage has an exit checklist and points to its reference file(s).

### 1. Clarify

- Invoke `superpowers:brainstorming` to confirm:
  - **Topic** (e.g., Redis pub/sub).
  - **Property to demonstrate** — a specific, observable behavior (e.g., "fanout delivery to N subscribers without persistence"), not a vague "demo X".
  - **Constraints** (architecture, port preferences, anything user-supplied).
- Recommend language (Python vs. Go) with reasoning grounded in the topic. Get user confirm.
- Mindset (from `system-design-mindsets.md`): *one demonstration concern per lab*.

### 2. Research

- Read primary sources (project docs, RFCs) first. Secondary sources only if primary is insufficient.
- Capture findings in `labs/<topic-slug>/RESEARCH.md` per `references/research-doc-format.md`.
- Mindset: *separate essential from accidental complexity*.

### 3. Design

- Sketch minimum topology: services, ports, volumes, healthchecks.
- **Escalation trigger:** if the design needs 3+ services or multi-node coordination, invoke `superpowers:writing-plans` to produce an implementation plan before coding. Otherwise inline.
- Output: design section appended to RESEARCH.md (decisions + rejected alternatives).
- Mindset: *minimal viable surface; design for failure-loudness*.

### 4. Build

- Scaffold `./labs/<topic-slug>/` per `references/lab-layout.md`.
- Generate `docker-compose.yml`, server, client, README, Dockerfile(s) per the chosen-language guide.
- Strictly honor `references/host-isolation-rules.md`.
- Mindset: *observability built in, graceful shutdown, explicit configuration*.

### 5. Validate

- Run `scripts/validate_lab.sh`.
- On failure: diagnose root cause from logs; do not paper over. After 3 failed attempts on the same root cause, escalate to `superpowers:systematic-debugging`.
- Mindset: *verify the demonstrated property, not just "container started"*.

## File structure (skill package)

```
research-lab/
├── SKILL.md                           # ~150-line orchestrator
├── references/
│   ├── system-design-mindsets.md      # mindsets per stage; the spine
│   ├── research-doc-format.md         # RESEARCH.md template + writing principles
│   ├── lab-layout.md                  # directory & docker-compose conventions
│   ├── host-isolation-rules.md        # forbidden patterns + pre-validation checklist
│   ├── validation-protocol.md         # smoke-test procedure + failure handling
│   ├── python-coding-guide.md         # Python idioms + design practices
│   └── go-coding-guide.md             # Go idioms + design practices
└── scripts/
    └── validate_lab.sh                # compose config → up → smoke → down
```

**Loading model:** SKILL.md always in context. Reference files loaded by the executing model only when their stage is reached. Per-language guide loaded once language is chosen.

## Lab output structure

Every lab follows this layout:

```
labs/<topic-slug>/
├── README.md           # what this lab demonstrates, how to run, expected output, teardown
├── RESEARCH.md         # research + design decisions
├── docker-compose.yml  # services, networks, volumes, healthchecks
├── .env.example        # documented env vars (never commit .env)
├── server/
│   ├── Dockerfile
│   ├── (source files)
│   └── (manifest: requirements.txt / go.mod)
├── client/
│   ├── Dockerfile
│   ├── (source files)
│   └── (manifest)
└── scripts/
    └── smoke-test.sh   # exercises the property; called by validate_lab.sh
```

## Host-isolation rules (summary; full list in `host-isolation-rules.md`)

**Forbidden:** `sudo`, host package installs, writes outside the lab dir, kernel-param changes, modifying `/etc/hosts`, privileged ports on host. In `docker-compose.yml`: `privileged: true`, `network_mode: host`, `pid: host`, `ipc: host`, bind mounts outside `./labs/<topic-slug>/`.

**Required:** All state inside lab dir, non-root user inside containers where supported, host ports ≥ 15000, healthcheck on every service.

**Pre-validation grep checklist** runs before bring-up; any hit fails the validation.

## Validation contract

`scripts/validate_lab.sh`:

1. `docker compose config -q` — schema/YAML check.
2. Run host-isolation grep checklist.
3. `docker compose up -d --wait` — relies on healthchecks.
4. `bash scripts/smoke-test.sh` — lab-specific property assertion.
5. `docker compose down -v` (always, via `trap`).
6. Exit code = smoke test's exit code.

**Smoke-test contract** (per lab):
- Exits 0 only if the demonstrated property was observed.
- Wall-clock timeout (default 60s).
- Plain-English success message.
- On failure, prints last 50 log lines from each service.

## System-design mindsets (the spine; full file separately)

Cross-stage:
- *Essential vs. accidental complexity.*
- *One concern per lab.*
- *Fail loud, fail early.*
- *Reproducibility over convenience* (pinned versions, no `latest`).

Per-stage mindsets are stated at the top of each stage in SKILL.md and elaborated in `system-design-mindsets.md`.

## Coding guides

Both `python-coding-guide.md` and `go-coding-guide.md` share the same shape: practices first, idioms second.

Sections: when to pick this language; project layout; server practices (bind `0.0.0.0`, env config, structured logs, SIGTERM shutdown, readiness vs. liveness); client practices (retry/backoff, timeouts, non-zero exit on failure, plain-English observation prints); error handling (surface with context); language-specific anti-patterns; small annotated server + client skeletons.

## Trigger description (for SKILL.md frontmatter)

Triggers when the user asks to research, demo, prototype, lab, or experiment with a networked service or protocol — including phrases like "show me how Kafka rebalances", "build a lab for NATS JetStream", "demo Postgres logical replication", "spin up a quick Redis cluster to test sentinel failover". Use this skill whenever the user wants a runnable client/server demo of a backend service, even if they don't say "skill" or "lab" explicitly.

## Open questions for future iterations

- Whether to bundle a topic-slug normalizer (kebab-case, strip versions) as a script vs. inline rule.
- Whether to support compose `profiles:` for optional/extended scenarios within one lab.
- Whether to add a per-language "structured logging" reference snippet when adoption proves uneven across labs.

These are non-blocking; v1 ships without.
