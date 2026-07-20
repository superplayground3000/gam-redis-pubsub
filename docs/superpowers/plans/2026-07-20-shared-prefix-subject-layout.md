# Plan — Shared-prefix subject layout (normal `kv.cdc.<aio>.>` / DLQ `kv.cdc.<dlq>.>`)

Date: 2026-07-20. Status: DESIGN — panel-validated, owner decisions incorporated.
Driver: `docs/requests/all-msg-in-one-stream/request.md` — PROD external NATS stream's
subject prefix is FIXED at `kv.cdc`; a shared-stream DLQ therefore cannot live at
`dlq.cdc.>` (unbindable). Normal and DLQ traffic must be separated by the SECOND subject
segment under the fixed prefix, both segments customizable.

Panel: read-only explorer (full subject-taxonomy map), delivery-semantics refuter
(adversarial premise validation), ops/migration reviewer (blast radius). Verdict:
**premise holds, with binding conditions** folded into this design.

Revision 2 (2026-07-20): Codex cross-model review (GPT-5-based, request-changes) — all
four findings folded in: (1) external-NATS consumer migration procedure added (the
external init job never edits user-owned durables); (2) enumerated union-filter
migration replaced by a two-phase wildcard `migrationFilter` (op space is open —
enumeration loses unknown ops); (3) new guard N5 closes the explicit
`sinkGroups[*].filterSubject` self-consumption hole; (4) L2 scope claim corrected
(the alerting lab is legacy-layout-bound; it remains the legacy-mode proof).

## 0. Owner decisions (2026-07-20, this session)

1. **Global taxonomy** — when the normal segment is set, ALL modes (single-sink,
   prefix-routing, sharding) publish under `kv.cdc.<seg>.…`. One rule set, no per-mode
   taxonomy fork. (This also dissolves the refuter's `kv_prefix=="dlq"` collision: prefix
   tokens move to the third segment, disjoint from the DLQ's second segment by the
   `aio ≠ dlq` guard alone.)
2. **Opt-in, default unchanged** — default render stays byte-identical (`normalSegment`
   empty = today's layout; DLQ default stays out-of-prefix `dlq.cdc`). New layout is
   enabled explicitly via values; PROD example ships with the change.
3. **External binding is `kv.cdc.>` (wildcard)** — the new sub-segments are automatically
   covered; the operator no longer needs to touch the external stream binding at all
   (that is the point of the request).

## 1. Why the premise holds (panel evidence, condensed)

- Today the DLQ subject is REQUIRED to live outside `nats.stream.subjectPrefix`
  (`chart/values.yaml:194-198`, render guard `_helpers.tpl:258-259`) so the whole-stream
  sink filter `kv.cdc.>` can never re-consume its own dead letters. Under a fixed external
  prefix this is unsatisfiable — direct contradiction.
- No alternative survives: the op set is OPEN (forward publishes
  `<prefix>.${!meta("op").or("update")}`, `cdc-forward.yaml:98,111`), so enumerated
  `filter_subjects` cannot exclude the DLQ subtree safely; JetStream has no negative
  filters; a separate DLQ stream was ruled out by the owner 2026-07-20
  (`docs/superpowers/plans/2026-07-20-all-in-one-sink-group.md` header).
- Msg-id dedup is subject-independent (`Nats-Msg-Id: event_id` vs `dlq.<event_id>`),
  so relocation does not touch INV-1 rows 4/5/14 dedup semantics.

**The trade being made (record it):** today's disjointness is structural and
unconditional (DLQ physically outside the sink filter's universe). The new layout makes
it guard-enforced (`aio ≠ dlq` at render time). The guards in §3 are therefore
load-bearing and ship in the same change — this is the refuter's binding condition 1-2.

## 2. Values schema (opt-in)

```yaml
nats:
  stream:
    subjectPrefix: "kv.cdc"      # unchanged
    normalSegment: ""            # NEW. e.g. "aio". Empty = legacy layout (default).
                                 # When set, ALL normal publishes and ALL sink filters
                                 # move under <prefix>.<normalSegment>.
    consumer:
      migrationFilter: ""        # NEW. When set (e.g. "kv.cdc.>"), REPLACES the
                                 # synthesized whole-stream/default group's filter for
                                 # the duration of a migration (see §6 two-phase
                                 # runbook). Single subject — JetStream forbids
                                 # overlapping filter_subjects, so a superset wildcard
                                 # replaces rather than unions. Default empty.

connect:
  deadLetter:
    enabled: false               # unchanged — sole DLQ source of truth
    subject: "dlq.cdc"           # unchanged — LEGACY out-of-prefix mode (default)
    segment: ""                  # NEW. e.g. "dlq". In-prefix mode: DLQ subject becomes
                                 # <subjectPrefix>.<segment>; requires normalSegment.
```

The PROD/all-in-one target: `normalSegment: "aio"`, `deadLetter.segment: "dlq"` →
normal `kv.cdc.aio.<op>`, DLQ `kv.cdc.dlq.<reason>`, stream binding stays `kv.cdc.>`.

Mode resolution: `deadLetter.segment` non-empty ⇒ in-prefix mode (`subject` must be left
at its default; computed DLQ root = `<prefix>.<segment>`). Empty ⇒ legacy mode, exactly
today's behavior.

## 3. Render guards (all fail-loud; replaces nothing silently)

| # | Condition (when it fails) | Why |
|---|---|---|
| N1 | `deadLetter.segment` set AND == `nats.stream.normalSegment` | THE disjointness guard — replaces the structural out-of-prefix guarantee |
| N2 | `deadLetter.segment` set AND `deadLetter.enabled` AND `normalSegment` empty | filter would stay `kv.cdc.>` and re-consume `kv.cdc.<dlq>.>` — self-consumption loop |
| N3 | `normalSegment` or `deadLetter.segment` not a single literal token (`[A-Za-z0-9_-]+`, no dots/wildcards) | same grammar rule as today's DLQ token guard (`_helpers.tpl:255-256`) |
| N4 | `deadLetter.segment` set AND `deadLetter.subject` != `"dlq.cdc"` (its default) | the two modes are mutually exclusive; silently ignoring `subject` would be a trap |
| N5 | Segment mode (`normalSegment` set) AND any explicit `connect.sinkGroups[*].filterSubject` that is not strictly under `<prefix>.<normalSegment>.` | Codex blocker: `filterSubject` is passed through verbatim today (`_helpers.tpl:446,534`); a user value of `kv.cdc.>` or `kv.cdc.<dlq>.>` binds the sink to its own DLQ/output space — self-consumption. Legacy mode keeps current behavior (structural disjointness protects it) |
| N6 | `migrationFilter` set AND `deadLetter.segment` set (with DLQ enabled) | the migration superset (`kv.cdc.>`) would match the in-prefix DLQ subtree — the two must never be active together (see §6 phase ordering) |
| — | Existing legacy guards (subject outside prefix, token grammar) unchanged for legacy mode | opt-in promise |

`rrcs.connect.validateAllInOne` messages get updated to describe both layouts.
Existing reserved-token set (`others`/`unknown`, `_helpers.tpl:522-523`) is unaffected:
under global insertion those live at the third segment.

## 4. Template changes (all inside existing helpers; nats-init job templates untouched)

- `rrcs.nats.stream.publishSubject` (`_helpers.tpl:276-283`): insert `<normalSegment>.`
  after the prefix in every branch (default, prefix-routing; verify the sharded publish
  path in `cdc-forward.yaml` also flows through helper-derived shapes and cover it).
- `rrcs.nats.stream.subjects` (`_helpers.tpl:240-265`): in-prefix mode ⇒ binding is the
  superset `<prefix>.>` alone (no stream edit ever needed — ops recommendation; old and
  new subjects both covered during migration). Legacy mode ⇒ unchanged
  (`<prefix>.>,<subject>.>`).
- `rrcs.connect.sinkGroups` (`_helpers.tpl:345-606`): every derived filter shifts under
  the segment when set — whole-stream `<prefix>.<seg>.>` (`:540`), prefix groups
  `<prefix>.<seg>.<token>.>` (`:531`), catch-all `<prefix>.<seg>.others.>` (`:538`),
  shard filters (`:508`). Explicit `filterSubject` entries are validated per guard N5.
  `migrationFilter`, when set, replaces the synthesized default/whole-stream group's
  filter (guard N6 keeps it mutually exclusive with in-prefix DLQ).
- `cdc-reverse.yaml:429`: DLQ publish subject becomes the computed DLQ root
  (`<prefix>.<segment>` or legacy `subject`) + `.${! meta("dlq_reason")}` — introduce a
  `rrcs.nats.dlqRoot` helper so values, creds script, and pipeline agree on one source.
  `Nats-Msg-Id: dlq.<event_id>` (`:439`) and its rationale comment stay (update the
  comment text: original publishes are now `kv.cdc.<aio>.*`).
- `nats-init-external-job.yaml`: assertions auto-follow the helpers — including
  `migrationFilter` (the asserted desired filter must reflect it, or the external job
  would fail loud mid-migration). NOTE (Codex blocker 1): the external job never edits
  user-owned durables (`nats-init-external-job.yaml:102,123`) — "no operator action"
  applies to the STREAM binding only; the external CONSUMER filter change is an
  explicit operator step (§6 external branch). Update the guidance text accordingly.
- `NOTES.txt:8`, `validateAllInOne` doc block in `values.yaml:200-247`: text updates.

**Constraint for implementers: keep `chart/templates/nats-init-job.yaml` logic
untouched** (filters arrive via the helper). If it must be edited, INV-1's "nats-init
consumer creation" L4 trigger fires — escalate to the lead before doing it.

## 5. Creds (`scripts/gen-nats-auth.sh` + committed `chart/files/nats-auth/*`)

- Script: compute `DLQ_SUBJECT` from the mode (in-prefix ⇒ `<prefix>.<segment>`; legacy
  ⇒ `connect.deadLetter.subject`), extending the awk parser (`:100-108,119-125`).
- Subscriber grant: regenerate committed creds ONCE with BOTH pub grants
  (`dlq.cdc.>` and `kv.cdc.dlq.>`) so the same committed creds serve legacy and
  segment-mode installs (kind e2e always fresh-installs; superset grant is harmless —
  only the sink publishes DLQ). Document the R3 in-place-swap trap
  (`values.yaml:178-182`): regenerated creds require a fresh NATS/namespace, never an
  in-place swap on an existing release. README updated.
- Publisher grant `kv.cdc.>` now incidentally covers the DLQ subtree — accepted
  least-privilege wart (source never publishes there); note it in the README.

## 6. Migration (existing install → segment mode)

Hazard (refuter): narrowing durable `cdc_sink`'s filter `kv.cdc.>` → `kv.cdc.aio.>` is
applied via in-place `consumer edit` (`nats-init-job.yaml:181-201`); retained/pending
messages on old bare `kv.cdc.<op>` subjects then no longer match and are silently
skipped = at-least-once loss window. Stream binding is NOT narrowed (§4), so nothing is
rejected at publish time; the exposure is consumer-side only.

**Why not an enumerated union filter (Codex blocker 2):** the op space is OPEN
(`cdc-forward.yaml:95,111` publishes whatever `meta("op")` carries, default `update`),
so a transitional filter list naming `create|update|delete|rename` silently loses any
retained `kv.cdc.<other-op>` message — an INV-1 hole. And JetStream forbids overlapping
`filter_subjects`, so `[kv.cdc.aio.>, kv.cdc.>]` is not expressible as a union. The
migration therefore uses a wildcard REPLACEMENT filter, in two phases that never let
the superset filter coexist with an in-prefix DLQ (guard N6):

**Two-phase runbook (zero-loss, no writer pause, no op enumeration):**
1. **Phase A — move normal traffic.** Upgrade with `normalSegment: aio` and
   `nats.stream.consumer.migrationFilter: "kv.cdc.>"`. DLQ stays in its previous mode
   (off, or legacy `dlq.cdc` — both outside the superset's overlap concern). The
   consumer filter stays the superset `kv.cdc.>`, matching old bare `kv.cdc.<op>`
   retained/pending messages AND new `kv.cdc.aio.<op>` publishes — nothing is skipped,
   regardless of op token. (Migrating from prefix-routed groups: drain those groups
   first per the §8b pattern in `2026-07-20-all-in-one-sink-group.md`.)
2. Wait until the old-subject backlog is drained: forward leg has rolled to the new
   publish subject AND `nats consumer info KV_CDC cdc_sink` shows `num_ack_pending==0`
   with `num_pending` only advancing on `kv.cdc.aio.*` traffic.
3. **Phase B — narrow + move the DLQ in-prefix.** Upgrade with `migrationFilter: ""`
   and `deadLetter.segment: "dlq"` (+ `enabled: true`). Filter narrows to
   `kv.cdc.aio.>`; every old-subject message was already acked in phase A, so the
   narrow skips nothing. In-prefix DLQ activates only now, when no superset filter can
   see it.

**External NATS branch (Codex blocker 1):** the bundled nats-init applies filter drift
via in-place `consumer edit` (`nats-init-job.yaml:181-201`), but the EXTERNAL init job
never mutates user-owned consumers — it creates-if-absent or fails loud on stale
filters (`nats-init-external-job.yaml:102,123`). So on external NATS each phase is:
operator edits the durable's filter first (`nats consumer edit KV_CDC cdc_sink
--filter <desired>`), then runs the helm upgrade whose external job ASSERTS the same
desired filter (which must incorporate `migrationFilter`, §4). Stream binding needs no
operator action at any point (wildcard `kv.cdc.>`, owner-confirmed).

Greenfield installs skip all of this. UNKNOWN to verify during L3: exact PEL treatment
on live filter-narrow in the pinned 2.10 build — the two-phase runbook is safe
regardless (the narrow only ever happens after the backlog is fully acked), which is
why it is the documented path.

## 7. Invariants impact

- **INV-1:** no behavioral row changes. Row 14's wording references
  `<deadLetter.subject>.<reason>` — amend to "the computed DLQ root" (backup
  `rules/05-invariants.md` first, CLAUDE.md hard rule 2; cite this plan). Ack ordering,
  dedup, reject-on-publish-failure all untouched. `cdc-reverse.yaml` IS edited (subject
  line + comments) ⇒ pipeline-YAML row ⇒ **L1 + L3 required**.
- **INV-2:** no new metrics, no new failure branches; dashboard/alerts reference no
  subject literals (annotation text in `cdc-alerts.yaml:52-83` mentions subjects —
  update text only). INV-2 grep unchanged.
- **INV-3:** no new component ⇒ no new `enabled:` toggle owed. Opt-in keys default to
  legacy; default render byte-identical (existing default-clean checks must stay green).
- **INV-4:** required ladder = L1 + L3 (pipeline YAML row). L0 trivial (no Go change —
  panel confirmed no production Go builds subjects). **L2 scope, corrected per Codex
  finding 4:** the alerting lab is legacy-layout-bound (`verify-alert.sh` hardcodes
  `dlq.cdc.*`, `labs/redis-cdc-error-alerting/scripts/verify-alert.sh:111`) — since
  the default stays legacy, L2 remains the valid legacy-mode proof and MUST stay
  green unchanged; the segment-mode proof lives in the parameterized L3 e2e (§8), not
  L2. Standalone labs (`labs/by-key-prefix-split-topic/*`) demo the legacy default
  and stay correct as-is — consistency updates are out of scope, noted in docs. L4
  NOT required IF nats-init job templates stay untouched (§4 constraint) —
  `migrationFilter`/N5 must be implemented in `_helpers.tpl`, not in the job scripts;
  re-assess at review if that constraint broke.

## 8. Test plan

New L1 cases in `scripts/run-all-tests.sh` (existing DLQ-guard block pattern):
- Segment-mode render: publish subject `kv.cdc.aio.${!meta("op")}` present; default
  group filter `kv.cdc.aio.>`; DLQ output subject `kv.cdc.dlq.${! meta("dlq_reason") }`;
  stream subjects exactly `kv.cdc.>` (no `dlq.cdc`, no second root).
- Guard fails: N1 (aio==dlq), N2 (segment+DLQ without normalSegment), N3 (bad token,
  e.g. `a.b` / `a>`), N4 (segment set + non-default subject), N5 (segment mode +
  explicit `filterSubject: kv.cdc.>` and `filterSubject: kv.cdc.dlq.>` both fail;
  `filterSubject: kv.cdc.aio.foo.>` renders), N6 (migrationFilter + in-prefix DLQ).
- `migrationFilter` render: default group's `--filter` is exactly the override; the
  external job's asserted desired filter reflects it too.
- Prefix-routing + segment: group filter `kv.cdc.aio.<token>.>`; sharding + segment
  renders (DLQ⊕sharding exclusion unchanged).
- Default render: byte-identical (existing checks `run-all-tests.sh:59-61` untouched
  and green).

L3: (a) default-mode `verify-cdc.sh` (regression proof); (b) segment-mode DLQ e2e —
`verify-dlq-e2e.sh` parameterized (or a values overlay) to run with
`normalSegment=aio`/`segment=dlq`, asserting: poison lands on `kv.cdc.dlq.<reason>`,
normal traffic on `kv.cdc.aio.*`, sink filter `kv.cdc.aio.>`, and the script's
hardcoded `DLQ_SUBJECT`/binding assertions (`verify-dlq-e2e.sh:39,107-108`) made
mode-aware.

## 9. Work breakdown (sub-agent dispatch)

| # | Task | Files | Independent? |
|---|---|---|---|
| W1 | Helpers + guards (N1-N6) + `migrationFilter` + `dlqRoot` helper + pipeline subject line | `_helpers.tpl`, `values.yaml`, `cdc-reverse.yaml`, `NOTES.txt` | core — first |
| W2 | Creds script mode-awareness + regenerate committed creds + README | `gen-nats-auth.sh`, `chart/files/nats-auth/*` | after W1 (needs dlqRoot semantics) |
| W3 | run-all-tests L1 cases + verify-dlq-e2e mode-awareness | `scripts/run-all-tests.sh`, `scripts/verify-dlq-e2e.sh` | after W1 |
| W4 | Docs + examples + INV-1 row-14 wording (backup first) + alert annotation text | `docs/dlq.md`, `docs/nats-jetstream-and-redis-kv-message-flow.md`, `chart/examples/*`, `rules/05-invariants.md`, `cdc-alerts.yaml` | after W1 |
| W5 | Verification: L0/L1/L2 via entrypoint + L3 both proofs; evidence pasted | — | last |
| W6 | Cross-model code-quality review (Codex) of the full diff | — | after W1-W4 |

## 10. Risk register

| # | Risk | Mitigation |
|---|---|---|
| K1 | Guard-enforced disjointness weaker than structural | N1-N6 ship in same change + L1 fail-case tests; Codex design review already forced N5/N6 |
| K2 | Filter-narrow migration loss on existing installs | §6 two-phase wildcard runbook (no op enumeration); stream binding kept superset; external branch documented |
| K3 | Committed-creds regen hits R3 trap | Superset grants in one regen; fresh-NATS requirement documented; kind e2e fresh-installs |
| K4 | A publish path misses the segment (e.g. sharded inline subject) | L1 render greps across all modes + L3 e2e; implementer must enumerate every `publishSubject`/inline subject use |
| K5 | nats-init edit needed after all (L4 trigger) | Explicit escalation constraint in §4 |
