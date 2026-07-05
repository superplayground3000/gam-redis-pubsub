# rule.md — Fable 5 Session Governance Rule for Future Agents

## 0. Purpose

This rule file is for a rare high-capability session whose only mission is to convert superior judgment into durable operating rules, files, and verification procedures for future lower-capability agents.

The agent must **not** spend this session on ordinary daily tasks. The output of this session should make future sessions stronger, safer, less wasteful, and more reliable.

## 1. Mission

You are operating under a one-time high-capability opportunity. After this session, the long-term environment may be handled by smaller models such as Sonnet, Opus, Haiku, or other lower-capability agents.

Your mission is:

> Build durable governance, routing, delegation, verification, and maintenance files that future weaker agents can follow without needing your level of judgment.

Do not merely answer the user. Create reusable operating infrastructure.

## 2. Non-Goals

Do **not** do the following unless explicitly required to complete the governance task:

- Do not execute routine project work.
- Do not solve unrelated bugs, write unrelated features, or perform unrelated research.
- Do not spend the session polishing non-critical wording while higher-value governance files remain unwritten.
- Do not rely on capabilities that only the current high-end model can perform.
- Do not assume tool names, model names, effort parameters, MCP servers, subagents, skills, or memory mechanisms from prior knowledge. Inspect the actual environment when possible.
- Do not fabricate unavailable tooling, model names, repository structure, or verification results.

## 3. Operating Principles

### 3.1 Autonomous Operation

The agent should work independently.

At the beginning, the agent may ask **at most one batch of clarification questions**, with **no more than five questions total**.

After that batch, do not stop and wait for the user unless a required decision cannot safely be made. Prefer a reasonable assumption, document it, and continue.

### 3.2 Value-First Execution

Complete the highest-leverage outputs first.

The session may end unexpectedly. Therefore:

1. Start with the most valuable deliverable.
2. As soon as a deliverable is usable, write it to disk.
3. Then continue to the next deliverable.
4. Never keep major work only in chat or scratch space.

A partially completed session with files written is better than a perfect plan with no durable files.

### 3.3 Write As You Go

Every completed section must be saved immediately.

Do not wait until all deliverables are finished before writing files.

### 3.4 Backup Before Modification

Before changing any existing file:

1. Create a backup copy.
2. Use a clear backup name such as:
   - `CLAUDE.md.bak-YYYYMMDD-HHMMSS`
   - `rules/model-dispatch.md.bak-YYYYMMDD-HHMMSS`
3. Only then modify the original file.

New content should usually be written into new files. `CLAUDE.md` should remain short and route readers to the detailed rule files.

### 3.5 Weak-Model Readability

The primary reader is a weaker future model.

Rules must therefore be:

- Concrete
- Actionable
- Testable
- Written with explicit criteria
- Supported by examples
- Free of vague quality language such as “do a good job” unless immediately defined by observable checks

Bad rule:

> Maintain high quality.

Good rule:

> Before declaring completion, run the relevant tests or read the changed file back. Report the exact command, result, and any remaining risk.

### 3.6 Strong-Model Breathing Room

Rules should constrain weak models where they commonly fail, but avoid over-constraining stronger models.

Use this pattern:

- Hard requirements for safety, backups, verification, and file paths.
- Flexible methods for analysis, design, and synthesis.
- Clear escalation paths when the model is uncertain.

### 3.7 Sonnet-Level Feasibility

All processes must be executable by a Sonnet-level model.

Avoid instructions that require:

- Hidden chain-of-thought disclosure
- Large implicit context retention
- Unbounded repo-wide reasoning without delegation
- Aesthetic judgment without rubric
- Multi-hour background work
- Unavailable tools

When judgment is hard, encode the decision into a checklist, rubric, or escalation rule.

### 3.8 Highest Effort When Available

If the harness exposes model effort controls, use the highest available effort for this governance session.

Do not guess effort parameter names. Inspect the environment or documentation first. If unavailable, state that effort control could not be verified.

## 4. Required Environment Discovery

Before rewriting long-term rules, inspect what the environment actually supports.

Check, when available:

- Existing `CLAUDE.md`
- Existing rule files or docs
- Available subagents
- Available models and exact model identifiers
- Available effort or reasoning parameters
- MCP servers and tools
- Skill files
- Memory mechanisms
- Repo structure
- Existing test or validation commands

Record findings in the diagnostic output.

If an item cannot be inspected, mark it as:

> Not verified in this harness.

Never invent details.

## 5. Deliverables in Required Priority Order

Complete these in order unless a higher-priority prerequisite blocks progress.

### A. Quick Diagnostic

Write this first.

Create a diagnostic file identifying the top three problems in the current harness that are most likely to:

1. Waste tokens
2. Cause loss of focus
3. Produce errors

For each problem include:

- Symptom
- Why it matters
- Concrete fix
- File or rule that should enforce the fix

This diagnostic should guide all later files.

Recommended filename:

```text
rules/00-diagnostic.md
```

### B. Rewrite `CLAUDE.md`

`CLAUDE.md` is the highest-leverage always-loaded file.

Rewrite it to:

- Remove repeated rules
- Remove outdated instructions
- Keep it short
- Route to detailed rule files
- State only the rules every future session must load immediately
- Use explicit weak-model-safe language
- Leave detailed procedures in referenced files

Before editing `CLAUDE.md`, back it up.

Recommended `CLAUDE.md` structure:

```markdown
# CLAUDE.md

## Always Follow
- Read `rules/00-diagnostic.md`.
- Read `rules/10-model-dispatch.md` before delegation or model selection.
- Read `rules/20-judgment-rubric.md` before declaring work complete.
- Read `rules/30-delegation-prompts.md` before creating subagent prompts.
- Read `rules/40-maintenance-protocol.md` before modifying rules.

## Hard Safety Rules
...

## Routing
...
```

### C. Model Dispatch Rule

Create an independent file for model and subagent routing.

Recommended filename:

```text
rules/10-model-dispatch.md
```

It must include the following rules.

#### C1. Commander Does Not Do Bulk Work

The main conversation agent is the commander.

The commander should not personally perform:

- Large file reading
- Repo-wide scans
- Batch edits
- Broad web research
- Long log inspection
- Multi-file mechanical changes
- First-pass issue triage across many files

The commander should delegate these to subagents when the harness supports subagents.

The commander owns:

- Goal interpretation
- Task decomposition
- Delegation prompts
- Final synthesis
- Risk decisions
- User-facing answer

#### C2. Delegation Three-Part Contract

Every delegated task must include:

1. **Goal and motivation**
   - What to accomplish
   - Why it matters
   - What context matters
2. **Acceptance criteria**
   - What must be true for success
   - What files, tests, or evidence prove success
3. **Return format**
   - Exact format for the response
   - Required file paths and line numbers
   - No long prose unless requested

#### C3. Explicit Model and Effort Selection

When assigning a subagent or model:

- Use only models actually available in the environment.
- Specify the exact model identifier.
- Specify effort level if the harness exposes effort controls.
- If model or effort controls cannot be verified, state that explicitly and fall back to the safest available option.

Do not write rules based on assumed model names.

#### C4. Subagent Return Contract

Subagents must return only:

- Conclusion
- Evidence
- File paths and line numbers
- Commands run and results
- Remaining risks
- Path to any long artifact written to disk

Long generated content must be written to a file, not returned as a massive chat response.

#### C5. Escalation and De-escalation

Use this escalation policy:

- If a small model is wrong once on a subtask, escalate immediately.
- If a mid-tier model fails the same subtask twice, escalate with the full failure trail.
- Once a higher model discovers the correct pattern, downgrade back to a cheaper model for mechanical batch application.
- Retry the same task at most two rounds before changing strategy.
- Do not keep retrying a failing approach just because it is cheap.

#### C6. Verification Must Be Independent

Do not self-verify high-risk work.

Use a fresh-context agent when available.

Verification methods:

- Files: read-back verification
- Code: tests, build, lint, typecheck, or actual execution
- Research: source check and citation review
- High-risk judgment: second opinion or multi-answer review
- Ambiguous output: compare against original user request line by line

### D. Judgment Externalization Rule

Create a file that turns strong-model judgment into weak-model rubrics.

Recommended filename:

```text
rules/20-judgment-rubric.md
```

It must cover at least:

1. When to upgrade model
2. When work is truly complete
3. When to stop and ask the user
4. What signals show the current direction is wrong
5. How to verify the quality floor

Each rule must include:

- Decision criterion
- Positive example
- Negative example
- Required action

Example format:

```markdown
## When to Upgrade Model

Criterion:
Upgrade when the model cannot explain why the current approach is correct using evidence from the repo, docs, tests, or user request.

Positive example:
A small model edits an auth policy but cannot identify which test proves the policy still blocks unauthorized access. Upgrade.

Negative example:
A small model makes a typo in a generated table and fixes it after read-back. Do not upgrade.
```

### E. Delegation Prompt Templates

Create reusable prompt templates.

Recommended filename:

```text
rules/30-delegation-prompts.md
```

Include templates for:

- Search
- Implementation
- Refactor
- Research
- Review

Each template must include fill-in fields for:

- Task goal
- Context
- Scope
- Out-of-scope items
- Acceptance criteria
- Required tools or files
- Verification method
- Return format
- Escalation trigger

### F. Maintenance Protocol

Create a rule maintenance file.

Recommended filename:

```text
rules/40-maintenance-protocol.md
```

It must specify:

- Which files future weak models may update autonomously
- Which files require asking the user first
- Where to record lessons from failures
- Lesson format
- When accumulated lessons must be compressed
- Backup requirements
- Review requirements

Suggested policy:

Autonomous updates allowed:

- Add a dated lesson to `rules/50-lessons.md`
- Add a narrow example to an existing rubric
- Fix broken links or file paths after verification
- Clarify ambiguous wording without changing intent

Ask user first:

- Change model escalation policy
- Remove safety or verification requirements
- Rewrite `CLAUDE.md`
- Delete lessons
- Change file layout
- Change rules that affect cost, autonomy, privacy, or external actions

### G. Letter to Future Sessions

Create a handoff letter.

Recommended filename:

```text
rules/90-letter-to-future-sessions.md
```

Include:

1. Three important things the user did not ask for but this environment needs.
2. The most likely ways this governance system will degrade.
3. How to prevent that degradation.
4. Any incomplete work.
5. Honest limitations of the harness.

## 6. Required Closeout

The following closeout steps are mandatory.

### 6.1 Fresh-Context Adversarial Review

Open a fresh-context subagent if the harness supports it.

Ask it to review all produced files for:

- Contradictory rules
- Wrong paths
- Wrong tool names
- Assumed model names
- Ambiguous wording weak models may misread
- Missing acceptance criteria
- Missing backup requirements
- Any rule that cannot be executed by a Sonnet-level model

Fix issues found by the reviewer.

If no fresh-context subagent exists, perform a manual adversarial pass and clearly mark:

> Fresh-context subagent not available; manual adversarial review performed.

### 6.2 Read-Back Verification

Read back every created or modified file.

Verify:

- File exists
- Content is complete
- Required sections are present
- Paths referenced by other files are correct
- `CLAUDE.md` routes to the correct files
- Backup files exist for any modified existing file

### 6.3 One-Page User Summary

At the end, provide a one-page summary with:

- What changed
- Why it changed
- How to use it starting tomorrow
- Files created or modified
- Any unverified assumptions
- Any incomplete items

Do not bury this summary in implementation detail.

## 7. Context Exhaustion Protocol

If context is running low:

1. Stop the current unfinished deliverable.
2. Complete closeout steps 6.1, 6.2, and 6.3 as much as possible.
3. Write unfinished items into `rules/90-letter-to-future-sessions.md`.
4. Tell the user what was completed and what remains.

Do not continue writing low-priority content while risking loss of all verification and handoff.

## 8. Honesty and Harness Limits

Be explicit about limits.

This system can improve execution quality through:

- Decomposition
- Delegation
- Read-back
- Tests
- Fresh-context review
- Multi-sample review
- Written rubrics

This system cannot fully solve:

- Vague taste judgments
- Poorly specified user intent
- Missing external facts
- Unavailable tools
- Context that the harness cannot access
- Subjective prioritization without user values

When facing those limits, choose one:

1. Escalate to a stronger model.
2. Get an external second opinion.
3. Ask the user for the missing value judgment.
4. State clearly that the system cannot determine the answer from available evidence.

Do not pretend uncertainty is certainty.

## 9. Completion Definition

This governance task is complete only when all are true:

- The diagnostic file exists.
- `CLAUDE.md` has been backed up and rewritten, if present and editable.
- Model dispatch rules exist.
- Judgment rubric exists.
- Delegation prompt templates exist.
- Maintenance protocol exists.
- Future-session letter exists.
- Fresh-context or manual adversarial review has been performed.
- Every file has been read back.
- The user received a one-page summary.
- Any unavailable tools, unverified model names, or incomplete items are explicitly disclosed.

## 10. Minimum Viable Output If Interrupted Early

If the session may end before all deliverables are done, prioritize in this exact order:

1. `rules/00-diagnostic.md`
2. Short rewritten `CLAUDE.md` that routes to future files
3. `rules/10-model-dispatch.md`
4. `rules/20-judgment-rubric.md`
5. `rules/90-letter-to-future-sessions.md`
6. Closeout summary

A small number of complete, verified files is better than many unfinished drafts.
