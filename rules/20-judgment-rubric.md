# 20-judgment-rubric.md — Judgment Rubrics for Weaker Models

Each rubric: criterion → positive example → negative example → required action.
When a rubric and your instinct disagree, follow the rubric or escalate — don't improvise.

## 1. When to upgrade model / escalate

**Criterion:** Escalate when you cannot explain, citing repo files, docs, tests, or the user's
request, why your current approach is correct — or when you've failed the same subtask twice.

**Positive example (escalate):** You edited `chart/files/connect/cdc-reverse.yaml` and cannot
say which verifier check (`internal/verifier/checks.go`) proves messages still ack only after
the region write. Escalate (or stop and run L3) before proceeding.

**Negative example (don't escalate):** `helm template` fails with a YAML indent error you
introduced; the error names the line. Fix it and re-render.

**Action:** State what you tried, what failed, and the evidence gap; then escalate per
`rules/10-model-dispatch.md` C5.

## 2. When work is truly complete

**Criterion:** Complete only when (a) the change matches the request line by line, (b) the
ladder level required by `rules/05-invariants.md` was run **in this session** with the command,
exit status, and key result line reported, and (c) any modified rules/CLAUDE.md file has a
backup.

**Positive example:** "Added `writer.enabled` toggle. `helm template chart/ --set
writer.enabled=false | grep -c 'name: lab-writer'` → 0; default render → 2; `helm lint` clean;
`verify-cdc.sh` exit 0, RESULT_JSON.pass=true." → Complete.

**Negative example:** "Added the toggle; templates look right so it should work." → Not
complete. "Should work" without a render check is a completion failure.

**Action:** If any of (a)-(c) is unmet, the status is "in progress" — say exactly what remains.

## 3. When to stop and ask the user

**Criterion:** Ask when the decision changes a guarantee, cost, or scope the user owns:
weakening any INV in `rules/05-invariants.md`, deleting data/history, changing defaults that
affect deployments, or when two of the user's requirements conflict. Do NOT ask for things a
render/test can answer.

**Positive example (ask):** A fix would require changing `maxDeliver: -1` to a finite value —
that converts poison-message redelivery into silent drop, weakening INV-1's visibility story.

**Negative example (don't ask):** "Should the new panel be a timeseries or a stat?" — pick the
convention already used in `cdc-dashboard.json` and note the choice.

**Action:** One concise question with your recommended option first; continue other work if any
is independent.

## 4. Signals the current direction is wrong

**Criterion:** Any of: two consecutive fix attempts each created a new failure; you are editing
files not named in your own plan; you are about to modify an INV-1 load-bearing line "just to
make the test pass"; the diff keeps growing while the failing check stays the same.

**Positive example (stop):** `verify-cdc.sh` dedup check fails; your second attempt edits the
verifier's assertion instead of the pipeline. Editing the oracle to match broken behavior is
the classic wrong turn.

**Negative example (continue):** First attempt failed, the error message points at a specific
missing values key, and your second attempt addresses exactly that key.

**Action:** Stop, write down the failure trail, re-read the invariant table, then either
re-plan from the evidence or escalate per C5.

## 5. Quality floor verification

**Criterion:** Before handing anything to the user: files you created were written to disk and
read back (existence + required sections); commands you quote were actually run; paths you cite
exist (`ls` or Read them); numbers you report come from tool output, not memory.

**Positive example:** After writing a new dashboard panel, you re-render the ConfigMap and grep
the panel title in the output.

**Negative example:** Reporting "the alert window is 2m" from recollection after editing the
alerts file — quote the line from the file instead.

**Action:** Any unverifiable claim gets labeled "not verified" in your report, never stated as
fact.
