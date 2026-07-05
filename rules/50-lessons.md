# 50-lessons.md — Accumulated Process Lessons

Append-only (format and compression policy: `rules/40-maintenance-protocol.md`). Newest first.

## 2026-07-05 — codex:rescue can stall mid-job
- What happened: In past sessions the `codex:rescue` subagent froze mid-job more than once,
  blocking review turns.
- Rule that would have prevented it: bounded-retry routing.
- Applied: `rules/10-model-dispatch.md` C3 — give Codex one try, poll once, then fall back to a
  fresh Claude reviewer and announce the fallback.

## 2026-07-05 — Chart reorg silently broke doc references
- What happened: The chart moved (`helm-release/` → `chart/`) and doc links kept pointing at
  the old paths until a dedicated fix commit (`a457856`).
- Rule that would have prevented it: after any file/dir move, grep the repo for the old path
  before declaring the move done: `grep -rn "<old-path>" --include="*.md" .`
- Applied: recorded here; path-fix authority granted in `rules/40-maintenance-protocol.md`.

## 2026-07-05 — Pod-scoped consumer id lost 757 messages
- What happened: `client_id: __POD__` orphaned the Redis PEL on SIGKILL failover; messages were
  lost until the stable `cdc_propagator_active` id was adopted (`docs/failover-report/REPORT.md`).
- Rule that would have prevented it: treat consumer identity as a load-bearing invariant and
  require the failover test for changes to it.
- Applied: `rules/05-invariants.md` INV-1 row 2 (L4 required).
