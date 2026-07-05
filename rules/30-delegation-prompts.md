# 30-delegation-prompts.md — Delegation Prompt Templates

Fill every field. If a field is genuinely empty, write "none" — don't delete the field.
All templates end with the return contract from `rules/10-model-dispatch.md` C4.
For Codex/MiniMax handoffs, simplify structured-output expectations (their response shapes
differ) and verify the shape before trusting it.

## Template: SEARCH (use agent type `Explore`; read-only)

```
Search breadth: <medium | very thorough>. Repo: /media/hp/secondary/projects/gam-redis-pubsub
GOAL: <what fact/location to find> — needed because <motivation>.
CONTEXT: chart in chart/, Go code in internal/, pipelines in chart/files/connect/,
  scripts in scripts/. <extra context>
SCOPE: <dirs/files to cover>   OUT OF SCOPE: <what to skip>
ACCEPTANCE: every claim carries file:line; items not found are listed as "not found".
RETURN: markdown list of findings with exact paths; no file dumps.
ESCALATE (return early, saying so) IF: the premise looks wrong (e.g. the named file/etc. does not exist).
```

## Template: IMPLEMENTATION

```
GOAL: <change to make> — motivation: <why>.
CONTEXT: read CLAUDE.md and rules/05-invariants.md first. Relevant files: <paths>.
SCOPE: <files allowed to change>   OUT OF SCOPE: <files that must not change — by default,
  any INV-1 load-bearing line in rules/05-invariants.md>
ACCEPTANCE: <observable criteria>; required verification level per rules/05-invariants.md:
  <L0/L1/L3/L4> — run it and capture output.
TOOLS/FILES REQUIRED: <e.g. helm, kind cluster name, go>
VERIFICATION: paste exact commands run, exit status, key result lines.
RETURN: changed files (paths), diff summary, verification evidence, remaining risks.
ESCALATE IF: acceptance cannot be met without touching an out-of-scope file, or the required
  test fails twice.
```

## Template: REFACTOR

```
GOAL: <structural change, no behavior change> — motivation: <why>.
CONTEXT: <paths>; behavior oracle: <tests that must stay green>.
SCOPE / OUT OF SCOPE: <...>  (metric names, values keys, and consumer/stream names are
  public interfaces here — renaming them is out of scope unless explicitly granted)
ACCEPTANCE: go test ./... green before AND after; helm template output diff is empty or
  explained line by line.
VERIFICATION: run the oracle; for chart refactors also `helm template` diff vs pre-change.
RETURN: file list, what moved where, oracle evidence, any output diff with justification.
ESCALATE IF: any oracle result changes.
```

## Template: RESEARCH (web or docs)

```
GOAL: <question> — decision it feeds: <what will be decided>.
CONTEXT: <what we already know / believe, with sources>.
SCOPE: <sources to prefer, e.g. official Redpanda Connect / NATS docs>   OUT OF SCOPE: <...>
ACCEPTANCE: each claim has a source URL or file path; contradictions between sources are
  surfaced, not resolved silently; unknowns stated as unknowns.
RETURN: findings table (claim | source | confidence), then a 3-sentence recommendation.
ESCALATE IF: sources conflict on a load-bearing fact.
```

## Template: REVIEW (route per the global provider rule: quality review → Codex when available)

```
GOAL: review <change/PR/diff> for <correctness | invariant compliance | chart quality>.
CONTEXT: read rules/05-invariants.md; the change claims: <author's summary>.
SCOPE: <files in the diff>   OUT OF SCOPE: style nits unless they hide bugs.
ACCEPTANCE: for each finding — severity, file:line, why it's wrong, concrete fix.
  Explicitly answer: (1) does any INV-1 load-bearing line change? (2) new component without
  an enabled toggle? (3) new failure path without a metric? (4) was the required test level
  run, with evidence?
RETURN: verdict (approve / request-changes) + findings list. No restating the diff.
ESCALATE IF: you cannot determine whether an invariant is affected — say so rather than guess.
```
