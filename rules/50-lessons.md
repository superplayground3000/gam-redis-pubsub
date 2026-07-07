# 50-lessons.md — Accumulated Process Lessons

Append-only (format and compression policy: `rules/40-maintenance-protocol.md`). Newest first.

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
