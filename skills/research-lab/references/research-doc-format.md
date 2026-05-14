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
