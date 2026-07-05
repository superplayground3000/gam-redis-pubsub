# 40-maintenance-protocol.md — Maintaining the Rules

## Backup requirement (always)

Before modifying `CLAUDE.md` or any file under `rules/`:
```bash
cp <file> <file>.bak-$(date +%Y%m%d-%H%M%S)
```
Then edit the original. Verify the backup exists (`ls`) before declaring the edit done.
Backups are working-tree safety nets; they do not need to be committed.

## What future agents may update autonomously

- Append a dated lesson to `rules/50-lessons.md` (format below).
- Add a narrow, concrete example to an existing rubric in `rules/20-judgment-rubric.md`.
- Fix a broken path or stale line number in any rule file **after verifying the correct value**
  (e.g. the file moved — cite the new location). This includes path corrections *inside* the
  invariant tables of `rules/05-invariants.md`, provided the "What must stay true" and
  "Required"/verification columns are unchanged; changing what a row requires is still
  ask-first.
- Clarify ambiguous wording without changing intent.
- Update the "Known gaps" lists in `rules/05-invariants.md` when a gap is closed — with
  verification evidence in the same session.

## What requires asking the user first

- Changing or removing any invariant, load-bearing-line entry, or required test level in
  `rules/05-invariants.md`.
- Changing the escalation policy or provider routing (`rules/10-model-dispatch.md`; the global
  `~/.claude/rules/subagent-provider-routing.md` is user-owned — never edit it).
- Rewriting `CLAUDE.md` beyond fixing a stale path.
- Deleting lessons or entire rule files, or renumbering/relocating the `rules/` layout.
- Any rule change that affects cost, autonomy, safety, privacy, or external actions.

## Lessons: where and how

Record process lessons (not code facts — those belong in code/docs) in `rules/50-lessons.md`:

```markdown
## YYYY-MM-DD — <one-line title>
- What happened: <1-3 sentences, concrete>
- Rule that would have prevented it: <existing rule to strengthen, or "new">
- Applied: <what was changed, or "recorded only">
```

**Compression trigger:** when `rules/50-lessons.md` exceeds ~30 lessons or ~300 lines,
consolidate recurring themes into the relevant rule file (with user approval if the change is
in the ask-first list), then move the raw entries to `rules/50-lessons-archive.md`. Never
silently delete a lesson.

## Review requirement

Any session that edits two or more rule files must end with a read-back pass: every edited file
Read in full, cross-file paths checked, and `CLAUDE.md` routing confirmed to match reality.
A fresh-context reviewer (see `rules/10-model-dispatch.md` C6) is required if an invariant file
changed.
