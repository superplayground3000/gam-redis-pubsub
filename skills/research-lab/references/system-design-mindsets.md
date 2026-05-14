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
