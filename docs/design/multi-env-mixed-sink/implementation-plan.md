# Multi-Env Mixed-Sink — phased implementation plan

Companion to `design.md` in this directory. Derived from the ops draft §(3) phase list, amended by
cross-critique CO-2 (publisher-taxonomy fix becomes an early blocking phase), R1 (gen-versioning
phase dropped), E2–E4 (sharded-DLQ phase added), and the 2026-07-21 Codex review (`design.md §16`):
the drift-manifest gate moves AHEAD of the taxonomy phase (F2), start-semantics validation folds
into the bootstrap phase (F3), and the assert-only handoff mode gets its own phase (F4). Every
load-bearing claim keeps its `file:line` citation from `design.md`.

**Ordering law:** envId naming (P1) gates all multi-env work; the manifest/drift gate (P2) must be
live and every sink registered on it BEFORE the publisher-taxonomy rewrite (P3) can roll traffic
onto new subjects; the DLQ phase (P5) depends on envId + taxonomy; the assert-only handoff mode (P6)
depends on the bootstrap phase's start-semantics validation (P4); verification + observability +
runbooks (P7–P8) come last. Each phase cites the INV-4 ladder row (`05-invariants.md:164-179`);
"strictest matching row wins".

---

## Phase 0 — Release split & presets (docs + example values)

- **Scope:** document source-only (publisher) / sink-only shapes via existing
  `connect.{source,sink}.enabled`; ship `values-publisher.yaml` + `values-sink-only.yaml` examples.
  Set `deadLetter.enabled:false` on the publisher (it parks nothing, `draft-topology CC6`).
- **Depends on:** nothing.
- **Test level:** L1 (renders) now; full L3 via `verify-multi-env.sh` once P7 lands. NOTE (design
  §3.2): this split is FREE for AIO envs but NOT for any sharded topology — that needs P3.
- **Rollback:** docs/examples only; delete the files.

## Phase 1 — `connect.envId` env-scoping (PREREQUISITE, gates all)

- **Scope:** one top-level `connect.envId` (default `""`) feeding durable base `cdc_sink_<envId>` +
  shard `cdc_sink_<envId>_<fam>_s<K>`, DLQ subject/msg-id via `rrcs.nats.dlqRoot` (`_helpers.tpl:248-257`)
  + new `rrcs.nats.dlqMsgIdPrefix`, `resourcePrefix` default `<envId>-`, and the Prometheus `env`
  label. DNS-1123 grammar guard `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`, ≤16-char length guard; keep the
  existing 57-char resource-name guard (`_helpers.tpl:691-693`), ADD a durable-length guard (cap 64).
  Thread through bundled + external init jobs and sink templates. Immutable across redeploys (design §4).
- **Files:** `_helpers.tpl`, `values.yaml`, `nats-init-job.yaml`, `nats-init-external-job.yaml`,
  `connect-sink.yaml`, sink pipeline templates.
- **Depends on:** P0.
- **Test level:** L1 (empty=byte-identical; bad grammar/length fail-loud) + L2 (`test-shard-mapping.sh`)
  + L3 `RUN_SHARDING=1` + L4 sharding (nats-init consumer creation + INV-1 row 13,
  `05-invariants.md:172-173`). +L0 if the guards get unit tests.
- **Rollback:** `connect.envId=""` on every release → byte-identical legacy names; but a durable
  already renamed must be recreated/re-adopted (immutability caveat — plan the split, don't rename live).

## Phase 2 — Topology manifest / drift gate (BEFORE any taxonomy rewrite, F2)

- **Scope (design §7, E6):** publisher writes `{normalSegment, families+N, prefixes}` to a NATS KV
  bucket `cdc_topology` (new component, `enabled:` toggle, INV-3); sink init reads it: MISMATCH →
  fail-closed always; UNREADABLE → fail-closed on first install of a new env, fail-open +
  `CDCTopologyManifestUnverified` on redeploy. Needs a user-provisioned `$KV.cdc_topology.>` grant.
  **This phase precedes P3 (F2):** live consumers are only filter-validated at init time
  (`nats-init-external-job.yaml:123-135`), so without the gate a taxonomy rollout in a later window
  can move traffic onto subjects no running sink matches → 72h silent loss (VF-16). The gate must be
  live and every sink release registered on it before P3 rolls.
- **Files:** new manifest publish/read templates, `nats-init-external-job.yaml` (read hook),
  `cdc-alerts.yaml` (new alert), `values.yaml` (toggle).
- **Depends on:** P1. (Manifest content is the resolved taxonomy even in its legacy/empty form — it
  does NOT need the P3 refactor to ship.)
- **Test level:** L1 (`enabled:` toggle — off emits nothing, INV-3) + L3 (mismatch fail-closed;
  unreadable fail-mode by env-age).
- **Rollback:** `enabled:false` disables the check (reintroduces the drift risk — document it; do NOT
  disable it while P3 is mid-rollout).

## Phase 3 — Publisher-taxonomy decoupling (BLOCKING for sharded multi-env)

- **Scope (design §3.2, E5):** publish taxonomy becomes a publisher-side declaration; `prefixRouting`
  returns true when `shardingEnabled`; INV-S4 shard-coverage (`_helpers.tpl:759-766`) scoped to
  sink-carrying releases. NEW render assertion `shardingEnabled ⇒ (publishSubject contains kv_prefix
  ∧ forward threads==1 ∧ MIF==1)` binding the two predicates (`_helpers.tpl:776-781` vs `:791-794`) so
  they cannot re-drift (closes the VF-5 black-hole permanently). **Rollout guard (F2):** a taxonomy
  change is forbidden to roll unless the manifest (P2) shows every registered sink release already on
  the compatible filter set — the publisher must not shift subjects ahead of the consumers.
- **Files:** `_helpers.tpl` (`prefixRouting`, `shardingEnabled`, INV-S4 scoping, new assertion),
  `cdc-forward.yaml`, `values.yaml` (publisher taxonomy keys), manifest rollout-guard check.
- **Depends on:** P1 + **P2** (the manifest gate must exist and be populated first, F2).
- **Test level:** L1 (legacy byte-identical; sink-less publisher with families now renders EXIT 0 and
  emits shard tokens; the new assertion fires on a mismatched render) + L3 (`chart/files/connect/*`
  touched, `05-invariants.md:171`).
- **Rollback:** revert the helper/forward changes; the existing co-located-sink expression still works.

## Phase 4 — Sink bootstrap start policy + start-semantics validation (R3, F3)

- **Scope:** `connect.sink.bootstrap.deliver: new | all | by-time` (default `new`) passed to the
  external job's `consumer add`; document that `all` is a 72h partial replay of CHANGES
  (`nats-init-external-job.yaml:171`), not a snapshot. **Also extend the external init to validate an
  EXISTING consumer's start semantics (F3):** the init today validates only
  PUSH/filter/ack_policy/max_deliver/max_ack_pending (`:123-164`) and accepts any existing consumer as
  "usable" (`:170`) without inspecting `deliver_policy`/`start_sequence`/`start_time` — so a stale
  `--deliver all` durable replays 72h even when values ask for `new`. Add: compare existing start
  semantics to the requested mode → fail closed on mismatch (delete/recreate or explicit
  `bootstrap.allowStartMismatch`). Snapshot-seed `by_start_time` runbook in scope.
- **Files:** `values.yaml`, `nats-init-external-job.yaml` (start-policy on create + start-semantics
  validation on existing), runbook doc.
- **Depends on:** P1.
- **Test level:** L1 + L3 (new-env bootstrap e2e; a stale `--deliver all` durable now fails closed
  against `deliver:new`). Touches nats-init consumer creation → L4 sharding where consumer creation is
  shared (`05-invariants.md:172`).
- **Rollback:** default `new`; delete the env's durables + disposable region Redis.

## Phase 5 — Sharded DLQ (depends on P1 + P3)

- **Scope (design §5, E2–E4):** remove the exclusion `_helpers.tpl:323-325`; port the park-then-ack
  switch output into `cdc-reverse-sharded.yaml` as ONE global switch over the broker fan-in (mirror
  `cdc-reverse.yaml:420-447`); park classes decode/hash/unknown, sx unchanged. The hash guard
  counter+throw renders UNCONDITIONALLY (E3, closes VF-8 at `cdc-reverse-sharded.yaml:173-179`); only
  the PARK action gates on `deadLetter.enabled`. Env-scope subject AND msg-id (E2); add `dlq_env` +
  `dlq_shard` headers; stash `event_id`. Also env-scope msg-id on `cdc-reverse.yaml` (AIO) so two AIO
  envs don't collide.
- **Files:** `cdc-reverse-sharded.yaml`, `cdc-reverse.yaml`, `_helpers.tpl` (remove exclusion, extend
  `dlqRoot`, add `dlqMsgIdPrefix`), `cdc-alerts.yaml` (widen `CDCDeadLetterPublishFailing` selector
  preserving per-namespace scoping), `cdc-dashboard.json` (panel 18), `values.yaml`.
- **Depends on:** P1 (envId feeds the DLQ subject/msg-id) + P3 (families must render on the publisher).
- **Test level:** L1 (sharded+DLQ renders; non-DLQ sharded byte-identical INV-S1; env tokens present
  when envId set, absent when empty) + L2 (`test-shard-mapping.sh` + `verify-alert.sh`) + L3
  `RUN_SHARDING=1` + a new sharded-DLQ e2e (park on `kv.cdc.dlq.<envId>.<reason>`, PubAck-confirmed,
  shard unblocked) + a multi-env cross-park test (two env-scoped copies, no dedup-swallow) + L4
  sharding (INV-1 row 13 + new row 15, `05-invariants.md:172-173`).
- **Rollback:** `deadLetter.enabled=false` → sharded output returns to `reject_errored:{drop:{}}`
  (`cdc-reverse-sharded.yaml:273-274`); the unconditional hash counter stays (E3 — it is a bug fix,
  not gated). Anything already parked remains on the stream to its 72h retention.

## Phase 6 — Assert-only handoff mode for named durables (NEW, F4/E7)

- **Scope (design E7, §8.3 step 3):** a handoff mode that makes the external init REFUSE to
  auto-create shard durables — for named durables it asserts the target consumer exists and is
  `--deliver by_start_sequence` at `F0+1`, failing loud if missing or wrong, NEVER falling back to
  create `--deliver all` (`nats-init-external-job.yaml:166-180`). Required by the AIO→sharded handoff
  (§8.3) but provided by no baseline phase. Reuses P4's start-semantics validation machinery.
- **Files:** `nats-init-external-job.yaml` (assert-only branch), `values.yaml` (handoff-mode toggle).
- **Depends on:** P1 + P4 (start-semantics validation).
- **Test level:** L1 (mode renders; assert-only branch present) + L3 (a missing / `--deliver all`
  target durable fails closed instead of being auto-created) + L4 sharding (nats-init consumer
  creation touching INV-1 row 13, `05-invariants.md:172-173`).
- **Rollback:** disable the handoff-mode toggle → init returns to create-if-absent (only safe when NOT
  mid-handoff; document it).

## Phase 7 — Multi-env verification into the ladder

- **Scope:** `scripts/verify-multi-env.sh` (publisher + AIO + sharded in one kind cluster: fan-out,
  disjoint durables, poison isolation, env-scoped metrics); `scripts/verify-env-reshard-handoff.sh`
  (§8.3 sink-pause + start-sequence via the P6 assert-only mode, no-loss + no-reorder, and the F1
  coverage check that prefixed routes are carried before the old AIO durable is deleted). Wire fast
  tiers into `scripts/run-all-tests.sh`.
- **Files:** new scripts, `scripts/run-all-tests.sh`, CI workflow.
- **Depends on:** P1–P6.
- **Test level:** L3 + L4 sharding; run the entrypoint itself (`05-invariants.md:177`).
- **Rollback:** scripts only; revert.

## Phase 8 — Observability & runbooks (last)

- **Scope (design §9, §8):** single ops-owned NATS exporter (`enabled:` toggle, publisher release,
  E10); A1/A6 `label_replace` env-extraction from the durable name; `$namespace`/`$env`-templated
  Grafana; write all runbooks (release split, first-sharded-env onboarding incl. catch-all sequencing
  + capacity re-baseline, AIO→sharded handoff with the R2 go-forward-only limitation AND the F1
  prefixed-route coverage check stated prominently, new-env bootstrap, per-env DLQ drain,
  rollback-per-phase).
- **Files:** exporter template + toggle, `cdc-alerts.yaml`, `cdc-dashboard.json`, runbook docs.
- **Depends on:** P1–P7.
- **Test level:** L1 + INV-2 grep + L2 + L3.
- **Rollback:** docs + `enabled:false` on the exporter.

---

**Dropped (R1):** the per-family subject generation-versioning phase (ops draft §8 Phase 5) — reshard-N
stays a global pause-drain event; N is over-provisioned once (32) and never reshaped.

**Invariant amendments** (`design.md §11`) are applied at the END of the phase that makes them true,
under that phase's required test evidence — never as standalone edits to `rules/`.
