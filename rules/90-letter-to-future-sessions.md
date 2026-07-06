# 90-letter-to-future-sessions.md — Handoff Letter

Written 2026-07-05 by the governance session that created `rules/` and `CLAUDE.md`.

## 1. Three things the user did not ask for, but this environment needs

1. **A single test entrypoint (`scripts/run-all-tests.sh` or a Makefile).** The verification
   ladder currently relies on agents choosing the right script. One command running
   L0 → L1 → L3 (L4 behind `RUN_FAILOVER=1`) would turn a judgment call into a habit, and is
   the prerequisite for CI. Highest-value follow-up in this repo.
2. **CI (even minimal).** No workflow runs anything on push. L0+L1 per PR is cheap and would
   mechanically enforce INV-4; L3 needs a kind-capable runner and can start as a nightly.
3. **The L2 docker-compose lab.** INV-4 (`rules/05-invariants.md`) records the owner's
   2026-07-05 requirement for container-based fast verification, and it does not exist yet.
   A complete spec is already written:
   `docs/superpowers/plans/2026-07-05-redis-cdc-observability-lab.md` (target
   `labs/redis-cdc-error-alerting/`). Building it also closes part of the INV-2 gap
   (alert/dashboard behavior verification).

## 2. How this governance system will most likely degrade

- **Stale line numbers and paths.** The invariant tables cite file:line as of 2026-07-05. The
  chart has been reorganized before; numbers will drift and weak models may trust them blindly.
- **Known-gaps lists rotting.** Once the histogram panels / toggles / L2 lab are built, the gap
  lists in `rules/05-invariants.md` become wrong in the safe-but-confusing direction — or worse,
  a gap is closed without evidence and the list stays.
- **CLAUDE.md growth.** Each session is tempted to append "one more rule" to the always-loaded
  file until it becomes noise.
- **Verification erosion.** Under time pressure, "L3 required" quietly becomes "L1 and it
  rendered fine". The first unpunished skip normalizes the second.

## 3. How to prevent that degradation

- When a cited line number is wrong, fix it in the same session (allowed autonomously per
  `rules/40-maintenance-protocol.md`) — search for the quoted key, don't guess.
- When you close a gap, update the gap list in the same change, with evidence.
- Keep CLAUDE.md ≤ ~60 lines; new detail goes into `rules/`, routed from CLAUDE.md.
- If you catch yourself (or a subagent) skipping a required ladder level, record it as a lesson
  in `rules/50-lessons.md` — the record is the deterrent.

## 4. Incomplete work as of 2026-07-05 (priority order)

**Status update (2026-07-05, gap-closure session): items 1–7 are DONE.**

1. ~~`scripts/run-all-tests.sh` / Makefile~~ — done (`scripts/run-all-tests.sh`, ladder
   L0→L4 with SKIP_L2/SKIP_L3/RUN_FAILOVER knobs).
2. ~~L2 docker-compose lab~~ — done (`labs/redis-cdc-error-alerting/`, `verify-alert.sh`
   proof passed: healthy-clean / poison-fires-both-reasons+webhook / recovery-clears).
3. ~~Missing chart toggles~~ — done (`connect.source.enabled`, `connect.sink.enabled`,
   `writer.enabled`, `dashboard.enabled`, `rbac.enabled`; pipeline ConfigMaps guarded too).
4. ~~Latency/histogram panels + forward-leg publish-failure metric~~ — done
   (`cdc_forward_publish_failed` via output fallback-reject; p50/p95/p99 panels; note the
   `_ns`-named histograms record **seconds** in the pinned build).
5. ~~CI workflow~~ — done (`.github/workflows/ci.yaml`, L0+L1 per push/PR via the same
   entrypoint). L3 nightly remains a worthwhile strengthening (needs a kind-capable runner).
6. ~~Writer/elector metrics scraping~~ — done (ServiceMonitor selects writer +
   latency-calculator, `elector` endpoint scrapes the sidecars; panels added; latency
   percentiles also exposed as `cdc_latency_seconds`).
7. ~~Strict-gate reversion~~ — **executed 2026-07-05** under the owner pre-approval that was
   recorded in the 05 header (commit 59dcf6d) and in this item; `rules/05-invariants.md` is
   binding-only again, with the ratchet history preserved in its header note.

Remaining follow-up ideas (not gaps): L3 nightly CI; pruning old `__POD__`-era consumer
names from the central stream's group after failover experiments (stale PEL entries block
the verifier's quiescence check — see `rules/50-lessons.md` 2026-07-05).

## 5. Honest limitations of this harness and rule set

- Model effort controls are not exposed here; only model selection. Rules referencing "effort"
  would be fiction — none do.
- Only L0+L1 run automatically (CI, since 2026-07-05): the docker/kind tiers (L2-L4) are still
  enforced solely by agents following the rules. A non-compliant session can break INV-1 and
  nothing will catch it before the next manual L3/L4 run.
- The at-least-once guarantee is conditional by design: it assumes Redis Stream and NATS
  JetStream storage are intact, and cross-key reordering (delete-vs-rename) is an accepted
  non-guarantee of the fence-free design — do not let a future session "fix" it into a fence
  without the user asking.
- External provider skills (Codex, MiniMax) come from the user's global setup and may be absent
  in some sessions; the dispatch rule already defines the fallback.
- These rules were adversarially reviewed by a fresh-context agent and read back, but they have
  not yet survived contact with a real weak-model session. Expect to add the first real lessons
  quickly.
