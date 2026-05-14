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
