# 50-lessons.md — Accumulated Process Lessons

Append-only (format and compression policy: `rules/40-maintenance-protocol.md`). Newest first.

## 2026-07-15 — Three Bloblang/Helm value-passing traps that lint+template cannot catch
- What happened: the subject-sharding forward mapping passed `helm lint`, `helm template`, and
  `rpk connect lint`, yet routed EVERY key to the wrong subject at runtime. Three independent
  causes, all invisible until the behavioral docker test (`scripts/test-shard-mapping.sh`) ran:
  (1) sprig's `quote` is `%q`-style and already doubles backslashes — adding a manual
  `replace "\\" "\\\\"` pass rendered `"\\\\{employees:…"` and the regex silently matched
  nothing; (2) Bloblang `.get("lb.company")` treats `.` as a PATH separator (`obj["lb"]["company"]`),
  so a map keyed by dotted subject tokens never matches — key such maps by the raw (colon) form;
  (3) metadata assigned an empty string reads back as ABSENT in later processors
  (`meta("x").or("fallback")` fires), so branch flags must use a non-empty sentinel ("none"),
  never "".
- Rule that would have prevented it: any new Helm-templated Bloblang must ship, in the same
  change, a behavioral test that runs the REAL rendered pipeline in the connect image with a
  got-vs-want case table (pattern: `scripts/test-forward-routing.sh`). Render-level greps prove
  presence, never semantics.
- Applied: `scripts/test-shard-mapping.sh` (wired into L2) caught all three on first run;
  fixes in `_helpers.tpl` (keyPatternLit, shardMap keying) and `cdc-forward.yaml` ("none"
  sentinel), each with a comment naming the trap.
## 2026-07-14 — L1 renders the chart but never LINTS the enabled pipeline on the real Connect binary
- What happened: The DLQ feature's reverse output put a per-case `processors:` block under the
  `switch` output (to count `cdc_dlq_forwarded`). `helm lint` + `helm template` accept it (valid
  YAML/Helm), and Task 2's L3 ran with `deadLetter.enabled=false`, so the enabled output block
  never rendered. `redpanda-connect lint` on the RENDERED enabled pipeline
  (`hpdevelop/connect:4.92.0-claudefix`) rejected it — `field processors not recognised` — meaning
  the sink would fail to load whenever the feature is turned on. Caught only when the L2 lab (which
  uses the enabled shape) was built.
- Rule that would have prevented it: a Connect pipeline-YAML change is NOT verified by
  `helm template` alone — render the pipeline in its ENABLED/feature-on configuration and run
  `redpanda-connect lint` against the pinned image. `switch`-output cases take only
  `check`/`continue`/`output`; per-message counting for a routed branch belongs in the pipeline,
  not the output case. Expected standalone-lint noise: the `__POD__` label placeholder (the elector
  substitutes it before POSTing) is not a real error.
- Applied: `chart/files/connect/cdc-reverse.yaml` emits `cdc_dlq_forwarded{reason}` from the three
  pipeline DLQ branches (commit 999b32f); enabled pipeline now lints clean. Added a best-effort
  enabled-pipeline lint to the test suite (Task 6 of the DLQ plan).

## 2026-07-07 — `helm template | grep -q` under pipefail flakes CI once the render tops the pipe buffer
- What happened: CI's L1 went red on master and PR #12 with "multi-group render missing
  lab-connect-sink-a" / "two-seg render missing name: cdc_forward_others" — but chart-identical
  adjacent commits passed (9270ca3 PASS 03:01 vs ace230f FAIL 03:00), and three failures landed
  on three different grep items. Root cause: `scripts/run-all-tests.sh` sets `set -o pipefail`;
  `grep -q` exits at the first match, and once the multi-group renders grew past the 64 KB pipe
  buffer (~105 KB, match near line 1000), helm's remaining write takes SIGPIPE → exit 141 →
  pipefail reports the pipeline failed on a GOOD render. Proven locally: `helm template … |
  dd bs=1024 count=1` → PIPESTATUS `141 0` on both helm 3.21 and 4.2.2. The negated checks
  (`if helm … | grep -q; then fail`) had the worse polarity: the same race silently PASSES a
  broken render.
- Rule that would have prevented it: in any pipefail script, never pipe a producer into
  `grep -q` (or any early-exit reader) when the producer's output can exceed the pipe buffer —
  capture once (`OUT=$(cmd)`) and grep the variable, or drop `-q` so grep drains its input.
  A CI-only "missing X" that passes locally and moves between items is a SIGPIPE flake, not a
  render bug.
- Applied: `scripts/run-all-tests.sh` L1 now captures every render once and greps herestrings;
  header comment in the L1 block warns against reintroducing live pipes.

## 2026-07-07 — Redpanda Connect's JetStream pull does NOT fill the ack window
- What happened: The `by-key-prefix-split-topic` lab was built on the design's assumption that a
  bind-mode `nats_jetstream` pull consumer keeps up to `maxAckPending` messages in flight, so
  throughput under delay ≈ `maxAckPending / RTT`. Measurement refuted it: `nats consumer info`
  showed `Outstanding Acks: 1 out of maximum 1024`, and `maxAckPending` 1024 vs 8192 gave the
  SAME rate (3 msg/s under 370 ms RTT). Connect keeps ~1 fetch in flight per consumer pod;
  throughput under delay is **concurrency ÷ RTT**, not window ÷ RTT. Splitting to N groups scales
  linearly because it adds N concurrent consumers, not because it multiplies a window.
- Rule that would have prevented it: never model pull-consumer throughput from `maxAckPending`
  without measuring `Outstanding Acks`; treat consumer-pod count (concurrency), not the ack
  window, as the throughput lever under latency. Reaching rate R under one-way delay d needs
  ~`R·(2d+t_proc)` concurrent pods.
- Applied: recorded in `labs/by-key-prefix-split-topic/VALIDATION.md` (F1–F3) and the D3 spec
  `docs/superpowers/specs/2026-07-06-multi-subject-connect-groups-chart-design.md` (§10 capacity
  model is concurrency-based; the `maxAckPending`-as-throughput-knob formula was withdrawn).

## 2026-07-07 — NATS user JWTs are scoped to the EXACT durable name; keys are gitignored
- What happened: The lab's per-prefix durables (`cdc_sink_<prefix>`) were rejected with
  "permissions violation" — the chart's baked subscriber creds
  (`chart/files/nats-auth/subscriber.creds`, minted by `scripts/gen-nats-auth.sh:150-158`) grant
  JS-API perms bound to the literal durable `cdc_sink` (`$JS.API.CONSUMER.INFO.KV_CDC.cdc_sink`,
  `$JS.ACK.KV_CDC.cdc_sink.>`, …). The account signing key lives under a gitignored `keys/`, so a
  new user cannot be minted under the existing account either.
- Rule that would have prevented it: before renaming/adding a NATS durable, check the subscriber
  JWT's allowed subjects — they hard-code the durable name. Multi-consumer work needs the grant
  regenerated with wildcard consumer perms (`$JS.API.CONSUMER.*.KV_CDC.*`, `$JS.ACK.KV_CDC.>`).
- Applied: `labs/by-key-prefix-split-topic/scripts/setup-nats-auth.sh` regenerates a
  wildcard-subscriber auth set and injects it at the k8s-object level (ConfigMap + Secrets), so
  `chart/` stays byte-for-byte untouched; the D3 spec makes the grosser grant a first-class
  requirement for native multi-group support.

## 2026-07-07 — Calling a function via $(...) drops its global assignments (subshell)
- What happened: The lab entrypoint gated its harness check with
  `v=$(run_scenario S0 …)`; `run_scenario` sets the global `HARNESS_OK=1` on success, but command
  substitution runs the function in a SUBSHELL, so `HARNESS_OK` never propagated — the S0 gate
  aborted with rc 3 every run regardless of the measured numbers. Cost several full ~30-min lab
  runs and a long detour re-tuning rates/targets that were never the problem. The sibling
  `run_scenario S1 … >/dev/null` calls (plain redirect, no `$(...)`) worked fine.
- Rule that would have prevented it: a bash function that mutates globals must be called
  directly (optionally `>/dev/null`), never via `$(...)`/pipe/`&` — those fork a subshell and
  discard the mutation. When a "gate never flips" despite correct data, suspect a subshell first.
- Applied: fixed to a plain-redirect call; recorded here (generic bash trap, no repo rule change).

## 2026-07-06 — Subagents "complete" without delivering their final report
- What happened: During the robustness-lab build, every reviewer subagent (and one Codex proxy)
  went idle without its final message reaching the controller; each needed a follow-up
  SendMessage nudge, costing a round-trip per task.
- Rule that would have prevented it: tell every dispatched agent, in the prompt, to deliver its
  report via SendMessage to "main" (idle ≠ delivered), and treat an idle notification with no
  report as "nudge once, then read its report file from disk".
- Applied: later dispatches in that session included the SendMessage instruction; pattern
  recorded here for future multi-agent sessions.

## 2026-07-06 — decode_error poison is not injectable via XADD; poison counters over-count by design
- What happened: While designing `labs/robustness-test`, injection of undecodable bodies via the
  central Redis stream silently produced VALID messages — the forward leg re-encodes `body` per
  `connect.bodyEncoding`, so decode failures can only be created by publishing directly to
  `kv.cdc.<op>` on NATS. Also, `maxDeliver: -1` + immediate NAK redelivery means one poison
  message increments `cdc_unprocessable` thousands of times per minute until the stream is
  purged — "delta == injected count" oracles are wrong by construction; use `>=` + purge.
- Rule that would have prevented it: read the pipeline's encode/decode path end-to-end before
  designing fault injection; assert `>=` for any counter tied to a redelivering failure branch.
- Applied: `labs/robustness-test/RESEARCH.md` documents both; the lab's phase-4 oracle uses
  `>=` then purges `KV_CDC`.

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

## 2026-07-07 — `GROUPS` is a bash special variable; chart-embedded shell must avoid it
- What happened: The D3 multi-subject nats-init Job stored its per-group record list in a shell
  var named `GROUPS`. Harmless in production (nats-box runs busybox `sh`, where `GROUPS` is a
  normal variable) but latent: under bash, `GROUPS` is the read-only supplementary-GID array, so
  `GROUPS="…"` is silently ignored and `$GROUPS` expands to the primary GID (`1000`). A local
  behavioral test run under bash reconciled a consumer literally named `1000` before the cause
  was found.
- Rule that would have prevented it: when embedding shell in chart templates, never name a
  variable after a shell special/reserved name (`GROUPS`, `PWD`, `UID`, `IFS`, `PPID`, `RANDOM`,
  `SECONDS`, `LINENO`, …), even when the target image uses busybox — the script may later run
  under bash. Renamed to `SINK_GROUPS`.
- Applied: recorded only (naming hygiene; no rule file gained a new binding clause).

## 2026-07-07 — Bloblang `let` vars need `$`; render/L1/L2 can't catch it — L3 did
- What happened: The D3 forward-leg prefix derivation wrote `raw_key.split(...)` /
  `if seg == ...` instead of `$raw_key` / `$seg`. Bloblang reads a bare identifier
  as `this.<field>` (JSON field access on the message), not the `let` variable, so
  it threw at runtime ("unable to reference message as structured (with
  'this.raw_key')") and NOTHING routed. `helm template`, `helm lint`, and the L2
  docker lab all passed — none execute the pipeline. Only the kind L3 (verify-cdc)
  surfaced it. The design spec's own pseudocode carried the same omission, so
  copying it propagated the bug.
- Rule that would have prevented it: existing — `05-invariants.md` "Connect
  pipeline YAML → L1 + L3". Bloblang edits are semantically unverified until L3;
  never trust a spec's Bloblang snippet without running it. When referencing a
  `let x`, it is ALWAYS `$x`; a bare `x` means `this.x`.
- Applied: recorded only (reinforces the existing L3 requirement for pipeline edits).

## 2026-07-07 — Test-quiescence heuristics must outlast the ackWait redelivery horizon
- What happened: `verify-failover-prefix.sh` declared the region "settled" after the key count
  was stable for 3 polls × 3 s = 9 s, then asserted zero loss. A message that was in-flight
  (delivered, unacked) on the SIGKILLed sink leader redelivers only after the consumer's
  ackWait (30 s), so the count legitimately sat at 19999/20000 for longer than the settle
  window — a FALSE FAIL blamed on INV-1 while a post-hoc scan showed all 20000 keys present.
  The script had passed the previous day by timing luck (kill landed elsewhere in the window).
- Rule that would have prevented it: any "stopped growing" heuristic in a delivery test must
  either (a) break early only on the COMPLETE expected count, or (b) require stability strictly
  longer than the slowest recovery mechanism it waits on (here: ackWait redelivery, 30 s).
  Fixed to complete-count fast-path + 45 s stability before concluding shortfall.
- Applied: `scripts/verify-failover-prefix.sh` settle loop (commit 49ba20d); recorded here for
  any future settle/quiesce loops (verify-failover.sh has a similar loop if ever refactored).

## 2026-07-07 — Cross-model final review caught a validation gap all same-model reviews missed
- What happened: seven per-task Claude reviews approved the two-seg routing work; the Codex
  whole-branch review then found a real Important gap — an implicit whole-stream sink group
  (filter kv.cdc.>) could coexist with prefix-routed groups, double-delivering every routed
  subject, and the L1 fixture itself blessed that shape. Probe-confirmed, then fixed
  (fail-loud; explicit filterSubject stays the operator-owned escape hatch).
- Rule that would have prevented it: none purely — task-scoped reviews can't see cross-config
  interactions the plan never mentioned. The provider-routing rule's mandatory cross-model
  final review is what caught it; keep it.
- Applied: `_helpers.tpl` whole-stream guard (commit 344ef76); reinforces
  `~/.claude/rules/subagent-provider-routing.md` (final review → Codex).

## 2026-07-13 — Verify a metric's actual series shape before asserting against it
- What happened: the sync-latency plan asserted `sync_count <= cdc_apply_count` at L3; it false-failed because `cdc_apply` has NO delete/rename series (pre-existing `{op,type}` vs `{op}` label-set inconsistency silently rejects the second shape — same quirk the 2026-07-07 run logged as a minor). The new histogram counted ops that cdc_apply cannot.
- Rule that would have prevented it: new — before writing an assertion that compares two metrics, curl/dump the live series of BOTH and compare per-label-set, not whole-metric totals; treat a ledger "minor, pre-existing" note as an input to later plans.
- Applied: plan step fixed to per-op create/update equality (commit b875315); recorded only, no rule file change.

## 2026-07-16 — At-least-once pipelines forbid equality oracles; scope every fault-phase counter
- What happened: the new e2e matrix (`scripts/verify-e2e-matrix.sh`) false-failed twice on a
  healthy pipeline: (a) an isolation gate asserted per-group `cdc_apply == emitted` and tripped
  on 2 legal redelivery duplicates; (b) a "nothing applied during the outage" gate read the
  GLOBAL `cdc_apply` delta and absorbed 34 straggler duplicate applies from the PREVIOUS fault
  phase. A third failure was pure bash: tab-delimited op-log fields collapse under `IFS=$'\t'
  read` (tab is whitespace), which emptied a rename's newkey and crashed on `SEEN[""]` —
  and that fatal error unwound the enclosing compound, silently skipping the next phase.
- Rules that would have prevented it: (1) counts in an at-least-once system may only gate as
  `>= expected` (liveness) or `== 0` (isolation/foreign lanes); exact equality is a false-FAIL
  generator. Authoritative loss checks must be key-scoped terminal-state reconciliation.
  (2) any cross-phase metric baseline needs a settle barrier (poll until steady) and, where
  possible, a key-scoped probe instead of a global counter. (3) multi-field logs need a
  non-whitespace delimiter (e.g. $'\037'); phase runners must isolate fatal aborts per phase
  (flat top-level dispatch, ABORT status distinct from SKIP).
- Applied: design §1.2/§5 amendments + verify-e2e-matrix.sh (run 3 = 21/21 green); also
  confirmed the cross-model review rule again — Codex caught a cleanup-trap bug that would have
  left a node-level iptables DROP to NATS after an aborted run.
