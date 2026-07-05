# 10-model-dispatch.md — Model & Subagent Routing

Applies whenever the main session delegates work or chooses a model. The user's global rule
`~/.claude/rules/subagent-provider-routing.md` (cross-provider review, Codex/MiniMax routing)
**takes precedence** where the two overlap; this file adds the repo-local mechanics.

## Verified harness facts (2026-07-05 — re-verify if the harness looks different)

- Subagents: Claude Code `Agent` tool. Useful types here: `Explore` (read-only search),
  `general-purpose`, `Plan`, plus plugin agents (e.g. `codex:codex-rescue`).
- Model override values accepted by the `Agent` tool: `sonnet`, `opus`, `haiku`, `fable`.
  If an override is unavailable in your harness, omit it and say so — never invent model names.
- Effort/reasoning-level controls: **not exposed in this harness.** Do not reference effort
  parameters in prompts or rules.
- External providers (via user's global setup): Codex (`codex:rescue` skill) and MiniMax
  (`minimax-subagent` skill, 1M context). Availability can vary — if a skill is missing from
  the session's skill list, fall back to Claude and note the fallback.

## C1 — The commander does not do bulk work

The main conversation agent owns: goal interpretation, decomposition, delegation prompts,
risk decisions, final synthesis, and the user-facing answer.

Delegate to subagents (read-only `Explore` for searches): repo-wide scans, reading many files,
long log inspection, batch mechanical edits, broad research, first-pass triage.
Rule of thumb: if the task means opening more than ~5 files just to look, delegate it.

## C2 — Every delegation carries the three-part contract

1. **Goal & motivation** — what, why, and the minimum context (this repo: name the exact paths
   from `CLAUDE.md`; don't make the subagent rediscover them).
2. **Acceptance criteria** — what must be true; which command/file proves it.
3. **Return format** — exact shape; require file:line references; long artifacts go to disk
   with the path returned, not pasted into chat.

Templates: `rules/30-delegation-prompts.md`.

## C3 — Explicit model selection

- Default: omit the model override (subagent inherits the session model). This is correct for
  most tasks in this repo.
- `haiku`/`sonnet` override: mechanical batch edits or simple lookups, only after the pattern
  is proven once.
- Code-quality review of non-trivial changes: **Codex** per the global routing rule (announce
  the switch in one sentence). Known failure mode: `codex:rescue` can stall mid-job — give it
  one try, poll once, then fall back to a fresh Claude reviewer and say you did.
- Very large context (>10 files to actually read, whole-repo reasoning): MiniMax per the
  global rule.
- If you cannot verify a provider/model exists in this session, state that and use the safest
  available option (default Claude, no override).

## C4 — Subagent return contract

Subagents return only: conclusion, evidence, file:line references, commands run + results,
remaining risks, and paths to any long artifacts written to disk. No essay-length prose.

## C5 — Escalation / de-escalation

- Small model wrong once on a subtask → escalate immediately (don't retry small).
- Mid-tier model fails the same subtask twice → escalate with the full failure trail.
- Once a stronger model finds the pattern → downgrade back for mechanical application.
- Max two retry rounds of the same approach, then change strategy (different decomposition,
  different provider, or ask the user).

## C6 — Verification is independent

High-risk work (anything touching the INV-1 table in `rules/05-invariants.md`, or claimed-done
features) is not self-verified:

- Files → read-back by a fresh agent or explicit Read of final state.
- Code → run the ladder level required by `rules/05-invariants.md` (the test run IS the
  independent check; paste output).
- Reviews → cross-provider per the global routing rule.
- Judgment calls → second opinion (fresh-context agent) before irreversible actions.
