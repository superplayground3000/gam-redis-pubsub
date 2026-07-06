# 50-lessons.md — Accumulated Process Lessons

Append-only (format and compression policy: `rules/40-maintenance-protocol.md`). Newest first.

## 2026-07-05 — "helm upgrade succeeded" does not mean the new pipeline is running
- What happened: L3 failed after a pipeline edit. The connect pods were 2 days old: helm
  upgraded the pipeline ConfigMap, but nothing rolled the pods, and the elector POSTs the
  pipeline only when it wins the Lease — so verification ran against stale config. Separately,
  two stale PEL entries owned by a dead `__POD__`-era consumer (old failover experiment) made
  the verifier's `pending==0` quiescence gate unsatisfiable, failing every check with
  "pipeline did not quiesce".
- Rule that would have prevented it: check what is RUNNING, not what was rendered — pod age
  vs. change time is the 5-second tell; and after chaos experiments, clean the consumer
  group's stale PEL before relying on quiescence-based verifiers.
- Applied: `checksum/connect-config` pod annotation (INV-1 row 12) + rollout-wait in
  `verify-cdc.sh`; stale entries XACKed and the dead consumer deleted.

## 2026-07-05 — One-shot metric assertions right after traffic are flaky
- What happened: the L2 lab's healthy-phase check queried `increase(cdc_apply[2m])` once,
  5 s after traffic ended; with a 15 s scrape interval the new counter series had a single
  sample and `increase()` returned nothing — false FAIL on a healthy pipeline.
- Rule that would have prevented it: poll metric assertions with a deadline (samples ≥ 2
  scrape intervals), never a fixed short sleep.
- Applied: `verify-alert.sh` Phase 1 polls up to 60 s; pattern noted here for future harnesses.

## 2026-07-05 — Softening an invariant needs owner approval, even when a reviewer demands it
- What happened: A stop-time review fix (commit 19480d2) relabeled invariant statements in
  `rules/05-invariants.md` from binding to target-with-gaps — exactly the "ask user first"
  case in `rules/40-maintenance-protocol.md` — with only reviewer feedback, no owner approval.
- Rule that would have prevented it: existing — 40 §ask-first. Reviewer/hook feedback is not
  owner approval.
- Applied: owner approved the ratchet regime afterwards as temporary, with a pre-approved
  reversion to strict gates once the gap lists are empty (05 header; 90 §4.7).

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
