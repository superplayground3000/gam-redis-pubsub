# Plan — All-in-one sinkGroups option (whole-stream sink + DLQ for bad messages)

Date: 2026-07-20, revision 2. Status: DESIGN — owner decisions incorporated, ready to implement.
Produced by a 3-role design team (architect / delivery-semantics / ops-verification) with a
cross-critique round and a Codex cross-model review (request-changes; findings folded in).
Revision 2 records the owner's rulings (2026-07-20):

- **No separate DLQ stream.** The DLQ stays a subject (`dlq.cdc.>`) on the same stream the
  sink uses. Rationale: real PROD serves JetStream from **external NATS configured with
  max-age 72h**; parked-poison aging within that window is an accepted operational bound, not
  a defect to engineer around. The team's shared-retention escalation is hereby
  **owner-accepted risk**, documented in §6/§10 — do not re-litigate it in implementation.
- **INV-1 amendment approved** (resolves former blocking Q0). Owner's wording: "Applied at
  least once is mainly for valid messages; if a message is malformed (unprocessable), just
  send it to the dead letter queue." At-least-once binds valid messages; malformed →
  `dlq.cdc.>` by design.

## 1. Summary and recommendation

Requested feature: "an all-in-one sinkGroups option that consumes all messages, except bad
messages which are sent to the dead letter queue."

Key discovery: the chart already almost has this. The default render (`connect.sinkGroups: []`)
synthesizes exactly one whole-stream group `default` (durable `cdc_sink`, filter `kv.cdc.>` —
`chart/templates/_helpers.tpl:357-360,491-501`), and the opt-in `connect.deadLetter` block
already parks the three permanent poison classes to `dlq.cdc.<reason>` on the shared stream
with a correct write-then-ack path (`chart/files/connect/cdc-reverse.yaml:418-444`). So
"all-in-one" is functionally `sinkGroups: []` + `deadLetter.enabled: true`.

**Recommendation — one small work item:** a **thin validating alias**
`connect.sinkAllInOne.enabled` (default `false`) that asserts the all-in-one topology at
render time. It does NOT introduce a new pipeline, deployment, durable, stream, or DLQ code
path — it *requires* `deadLetter.enabled: true` and an empty `sinkGroups`, failing the render
loudly otherwise. Ship the `CDCDeadLetterPublishFailing` alert and the approved INV-1 doc
amendment in the same change.

## 2. What the option adds (and what it deliberately does not)

Adds:
- A single named, discoverable switch expressing the owner's intent ("one consumer drains
  everything; poison is parked, never head-of-line-blocks").
- Fail-loud guards against every incoherent combination (see §4).
- Documentation surface: the values comment is where the whole topology is explained.

Deliberately does not:
- **Create a separate DLQ stream.** Owner ruling (header). The DLQ subject binding stays the
  existing in-place stream-subject extend `kv.cdc.>` → `kv.cdc.>,dlq.cdc.>`
  (`_helpers.tpl:240-261`, reconcile at `nats-init-job.yaml:83-91`).
- **Force** the DLQ on via an "effective enabled" helper. Primary reason (Codex review):
  **semantic blast radius** — `cdc-reverse.yaml` branches on `deadLetter.enabled` in five
  load-bearing places (`:176-200,203-224,324-335,348-359,412-445`); repointing all of them to
  a compound flag touches the INV-1 ack file for a one-switch UX gain. "Require + fail render"
  keeps `deadLetter.enabled` the sole DLQ source of truth with zero repointed conditionals.
  Secondary, contingent hazard: the nats-init Job-name hash is keyed on
  `toYaml .Values.connect.deadLetter` gated by `deadLetter.enabled`
  (`chart/templates/nats-init-job.yaml:15-27`); a second enable path that forgot to feed that
  hash would leave the completed Job un-renamed, the subject reconcile would never re-run, and
  the DLQ would look enabled but be inert (publishes nack-loop). Avoidable by folding the flag
  into the hash — but "require" makes the mistake impossible.
- Create a new durable name. All-in-one keeps the synthesized `default` group and durable
  `cdc_sink` verbatim, which is what makes enabling it on a default install rolling and
  byte-stable on the sink side.

## 3. Values schema

New keys (comments in the values.yaml voice, rationale-first):

```yaml
connect:
  deadLetter:
    enabled: false          # unchanged — remains the single DLQ source of truth
    subject: "dlq.cdc"      # unchanged; disjointness guard stays (_helpers.tpl:248-260)

  # ── All-in-one sink (validating preset) ───────────────────────────────────────
  # ONE consumer drains the entire stream (kv.cdc.>) and poison is parked to the
  # DLQ subject (dlq.cdc.<reason>, same stream) instead of redelivering forever.
  # This is the default single-sink shape made explicit: enabling it REQUIRES
  # deadLetter.enabled=true and an empty sinkGroups, and the render fails loud on
  # any contradiction (prefix/shard routing, sharding families).
  # Parked messages share the stream's retention — drain the DLQ within the
  # stream max-age (72h on the PROD external NATS; the bundled lab default is
  # nats.stream.maxAge, see §6 note). Safe default: DISABLED — render stays
  # byte-identical to today.
  sinkAllInOne:
    enabled: false
```

Naming: top-level `connect.sinkAllInOne` (sibling of `deadLetter`), not nested under the legacy
`connect.sink` block it supersedes.

## 4. Render guards (all fail-loud, exact conditions)

When `connect.sinkAllInOne.enabled=true`:

| # | Condition | Message must point at |
|---|---|---|
| G1 | `connect.deadLetter.enabled != true` | "all-in-one requires the DLQ: set connect.deadLetter.enabled=true" (otherwise one poison head-of-line-blocks the single whole-stream ack floor forever — `values.yaml:148-157`) |
| G2 | `len(connect.sinkGroups) > 0` | all-in-one owns the whole stream; any explicit group contradicts it (subsumes the whole-stream+prefix double-receive guard `_helpers.tpl:563-565`) |
| G3 | `len(connect.sharding.families) > 0` | sharding is the opposite of one-consumer-drains-all; DLQ+sharding is already mutually excluded (`_helpers.tpl:244-247`) — keep that exclusion, do not build DLQ into the sharded pipeline in this change |

Implementation: one `rrcs.connect.validateAllInOne` template invoked from
`rrcs.connect.sinkGroups`. Existing guards (DLQ subject literal + disjointness,
`_helpers.tpl:248-260`) apply unchanged.

## 5. nats-init / stream impact

**Bundled NATS:** nothing new. Enabling the DLQ extends the stream subjects in place
(`kv.cdc.>` → `kv.cdc.>,dlq.cdc.>`, reconcile at `nats-init-job.yaml:83-91`; `$dlqHash` at
`:23-27` already re-runs it on enable). `DESIRED_DURABLES`/`SINK_GROUPS` untouched — enabling
the mode does not delete or recreate `cdc_sink` on an install already running the default
group. `sinkAllInOne.enabled` does NOT need to enter the Job hash (it changes no NATS state —
guards only).

**External NATS (the PROD case) — ops note, must go in the values comment:** the external
nats-init variant does **not** reconcile external streams; it only checks the stream binds the
expected subjects and fails loud otherwise (`chart/templates/nats-init-external-job.yaml:96`).
So the operator must add `dlq.cdc.>` to the external stream's subject binding before enabling
the DLQ/all-in-one — otherwise the init job fails (correctly) at install time.

INV-3: no new component template — a preset over existing toggles owes no new `enabled:`
(INV-3 rule fires for new component templates, `rules/05-invariants.md:122-123`). The default
render must stay byte-identical (existing default-clean checks, `scripts/run-all-tests.sh:61,89`).

## 6. Delivery semantics (what the invariants pass established)

- **Bad-message rule (binding):** DLQ only the three deterministic-permanent classes —
  `decode_error` (`cdc-reverse.yaml:173-202`), `hash_decode_error` (`:204-224`),
  `unknown_op` (`:318-336`). Transient apply failures (region Redis down, etc.) must keep
  nacking: the authoritative apply is deliberately un-wrapped (`cdc-reverse.yaml:255,416-417`).
  Any "DLQ every error" implementation acks un-applied messages = data loss. REJECT.
- **Ack ordering is already correct and unchanged:** message acked to `cdc_sink` only after the
  DLQ publish PubAck (`reject_errored` wraps the DLQ output, `cdc-reverse.yaml:418-444`);
  publish failure nacks (fail-safe, `values.yaml:184-188`); crash between PubAck and ack is
  deduped by `Nats-Msg-Id: dlq.<event_id>` within `dupeWindow: 5m` (`:434-439`,
  `values.yaml:95`).
- **No existing INV-1 table row (1-13) changes — the INV-1 *statement* changes, with owner
  approval recorded in this file's header.** Required doc amendments to
  `rules/05-invariants.md` in the same change (backup-first per CLAUDE.md rule 2):
  1. Amend the INV-1 statement: "…applied to region Redis at least once. Malformed
     (unprocessable) messages are exempt: when `connect.deadLetter.enabled` they are parked on
     the dead-letter subject with a confirmed PubAck instead of being applied (owner-approved
     2026-07-20, this plan)."
  2. Add one NEW load-bearing row: DLQ path is publish-to-DLQ-then-ack; send failure nacks;
     `Nats-Msg-Id: dlq.<event_id>` dedup keeps replays from double-parking.
- **Owner-accepted retention bound (record it, don't fix it):** parked messages share the
  stream's retention (`--retention limits --discard old`, lab default `max-age 1h` at
  `nats-init-job.yaml:93-104` / `values.yaml:92-93`; PROD external NATS: 72h). A parked
  message not drained within the stream max-age is discarded — accepted per the header ruling.
  Document the drain expectation ("DLQ drain SLA = stream max-age") in the values comment; the
  lab's 1h is fine for lab purposes.
- **Blast radius note:** all-in-one makes the DLQ *more* necessary, not less — a single
  whole-stream consumer has one ack floor for every key family, so one poison without a DLQ
  blocks everything (`maxDeliver: -1`). Hence guard G1.

## 7. Observability (INV-2)

- Existing coverage reused: `cdc_unprocessable{reason}`, `cdc_dlq_forwarded{reason}`,
  `output_sent/output_error{label=dlq_out}`; dashboard panel 18 "DLQ: routed vs confirmed
  parked" (`chart/files/grafana/cdc-dashboard.json:149-154`). No new pipeline metric is
  emitted, so INV-2's letter forces nothing new.
- **Ship in-change anyway: `CDCDeadLetterPublishFailing`** on
  `output_error{label=dlq_out} > 0` in `chart/files/prometheus/cdc-alerts.yaml` + the INV-2
  grep list. Rationale: the publish-failure nack-loop (creds grant missing, or `dlq.cdc.>`
  not bound on an external stream) is the one path where "parked" is untrue, and today nothing
  pages on it (verified: only `CDCUnprocessableMessages` and `CDCForwardUnrouted` exist).
- **Not shipping:** a DLQ depth/oldest-age metric. No NATS/JetStream Prometheus exporter
  exists in the chart (ServiceMonitor scrapes connect legs, writer, latency-calculator,
  electors only) — it would be a new component. Parked-message aging is owner-accepted (§6),
  so there is nothing this signal must guard.

## 8. Migration and cutover

- **(a) Default install → all-in-one (rolling, safe):** set `deadLetter.enabled=true` +
  `sinkAllInOne.enabled=true`. Sink Deployment/durable unchanged; nats-init reconciles the
  stream subjects in place (bundled) or asserts them (external — bind `dlq.cdc.>` first, §5).
  Requires the post-2026-07-16 subscriber creds (pub grant on `dlq.cdc.>`,
  `values.yaml:174-176`); the pre-2026-07-16 in-place creds caveat (`values.yaml:178-182`)
  applies.
- **(b) Prefix-routed → all-in-one (topology collapse — follow the runbook):** the non-sharded
  orphan prune deletes `cdc_sink_<name>` durables **unconditionally, no drain gate**
  (`nats-init-job.yaml:247-268`). Messages are only loss-free if every un-applied message is
  still retained on the stream when the fresh `cdc_sink` (`--deliver all`,
  `nats-init-job.yaml:204-213`) re-scans — the stream max-age (1h lab / 72h prod) is the
  window. Runbook:
  1. Quiesce the forward leg / stop the writer.
  2. Wait until every per-prefix durable is drained:
     `nats consumer info KV_CDC cdc_sink_<name> --json | jq '{p:.num_pending,a:.num_ack_pending}'`
     must be `{0,0}` for all groups.
  3. `helm upgrade` to all-in-one (`sinkGroups` removed, both flags on). Prune now removes
     empty durables (safe); fresh `cdc_sink` re-scans; expect an idempotent redelivery burst
     (rename is EXISTS-guarded, INV-1 row 9).
  4. Verify: `cdc_sink` ack floor advances; run `verify-cdc.sh` on the new topology.
  5. Resume the writer.
  Decision: document-only in this change (gating the unconditional prune would change all
  multi-group downscales — disproportionate). Optional hardening noted in §10.

## 9. Test plan (INV-4 — strictest matching rows)

Touched files: `_helpers.tpl` (guard template only), `values.yaml`, `cdc-alerts.yaml`,
`scripts/run-all-tests.sh`, `rules/05-invariants.md`. **No `cdc-reverse.yaml` or nats-init
behavioral edits.** Matching rows (`rules/05-invariants.md:161-172`): chart templates/values →
**L1** (default render unchanged ⇒ no L3 forced by that row); metrics/alerts → **L1 + INV-2
grep + L2**. So required: **L0 (trivial) + L1 + L2.** Recommended once as the enabled-mode
proof: **L3** `verify-dlq-e2e.sh` — it already runs the exact all-in-one topology
(whole-stream `cdc_sink` + DLQ, `DURABLE="cdc_sink"` line 41) and needs **no changes** under
the shared-stream design. **L4 NOT required** — no consumer id/group, lease, elector,
ack/commit, or nats-init consumer-creation change (`rules/05-invariants.md:54-55`); keep it
that way during implementation.

Commands:
```bash
go test ./...                                                    # L0
helm lint chart/ && helm template chart/ >/dev/null              # L1 base
scripts/run-all-tests.sh SKIP_L3=1                               # entrypoint (fast tiers + L2)
labs/redis-cdc-error-alerting/scripts/verify-alert.sh            # L2 (new alert case)
# recommended enabled-mode proof (L3):
scripts/build-images.sh --kind --kind-name=cdc
RRCS_NS=cdc-dlq RRCS_RELEASE=cdc-dlq scripts/verify-dlq-e2e.sh
```

New L1 cases in `scripts/run-all-tests.sh` (pattern of the existing DLQ render-fail block,
`run-all-tests.sh:106-127`):
- G1: `--set connect.sinkAllInOne.enabled=true` alone → render FAILS (DLQ off).
- G2: all-in-one + a `sinkGroups` entry → render FAILS.
- G3: all-in-one + `connect.sharding.families` → render FAILS.
- Happy path: all-in-one + `deadLetter.enabled=true` → renders; exactly one
  `durable: cdc_sink`; stream subjects `kv.cdc.>,dlq.cdc.>` (existing assertion at
  `run-all-tests.sh:59-60` stays valid — shared-stream design keeps it).
- Default render unchanged: no `dlq` hits (`run-all-tests.sh:61`).

INV-2 grep list extended with `CDCDeadLetterPublishFailing`; the L2 lab gains the new alert
case (the lab bind-mounts the chart alert file — may need wiring).
`scripts/test-dlq-guard.sh` and `scripts/verify-dlq-e2e.sh` unchanged.

## 10. Risk register

| # | Risk | Mitigation |
|---|---|---|
| R1 | Undrained prune on prefix→all-in-one collapse (loss window = stream retention) | §8(b) runbook: pause writer + drain check before upgrade. Optional hardening (owner call): extend the `pruneOrphans` gate (`nats-init-job.yaml:229`) to the non-sharded branch |
| R2 | DLQ pub grant missing (pre-2026-07-16 creds) → parked-looking-but-nacking loop | Fail-safe (no loss); `CDCDeadLetterPublishFailing` pages on it; `scripts/gen-nats-auth.sh --force` + commit creds |
| R3 | Creds-rotation trap: redeploying regenerated creds onto a pre-2026-07-16 release orphans its KV_CDC state (`values.yaml:178-182`) | Fresh NATS or migration; never in-place creds swap |
| R4 | Subject overlap → self-consumption loop (maximal in whole-stream mode) | Disjointness render guard (`_helpers.tpl:259`); keep the default `dlq.cdc` subject |
| R5 | External stream not bound to `dlq.cdc.>` in PROD → DLQ publish denied/no-stream, poison nack-loops | External init job fails loud at install (`nats-init-external-job.yaml:96`); ops note in values comment (§5); `CDCDeadLetterPublishFailing` catches drift after install |
| R6 | Parked message ages out before drain (shared retention) | **Owner-accepted** (header ruling; 72h in PROD). Documented drain SLA = stream max-age; not engineered around |

## 11. Open questions for the owner

1. ~~INV-1 statement amendment approval~~ — **RESOLVED 2026-07-20** (approved; wording in
   header and §6).
2. ~~Separate DLQ stream / retention defaults~~ — **RESOLVED 2026-07-20** (no separate stream;
   shared retention accepted).
3. **Prune hardening:** document-only runbook (recommended, §8b) or also gate the non-sharded
   orphan prune behind `pruneOrphans` (changes existing downscale behavior). Default if no
   answer: document-only.
4. **Naming:** `connect.sinkAllInOne` (recommended) vs `connect.sink.allInOne`. Default if no
   answer: `connect.sinkAllInOne`.

## 12. Work breakdown (implementation order)

1. `_helpers.tpl`: `rrcs.connect.validateAllInOne` guards G1-G3, invoked from
   `rrcs.connect.sinkGroups`.
2. `values.yaml`: `sinkAllInOne` block with the full topology + drain-SLA + external-NATS
   binding comments (§3, §5).
3. `cdc-alerts.yaml`: `CDCDeadLetterPublishFailing`; extend the INV-2 grep list
   (`rules/05-invariants.md:96`).
4. `rules/05-invariants.md`: INV-1 statement amendment + new DLQ load-bearing row (§6) —
   backup first (CLAUDE.md hard rule 2); cite this plan's header as the owner approval.
5. `scripts/run-all-tests.sh`: G1-G3 fail cases + happy-path/single-durable assertions (§9).
6. `chart/examples/`: an all-in-one example values file (matches the existing
   `values-dlq.yaml` / `values-sharding.yaml` convention).
7. docs: migration runbook (§8) into the values comment and/or docs/.
8. Verification: L0 + L1 + L2 required; one L3 `verify-dlq-e2e.sh` run as the enabled-mode
   proof; paste command + exit status per the reporting rule.
