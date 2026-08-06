# Why sharding and DLQ "refuse to combine" — and what coexistence took

Research for wayfinder #42 (child of map #41). READ-ONLY investigation on `master`
at `b7a05bc`. Every claim below cites `path:line` at that commit.

## TL;DR — the premise is stale

**The render guard the ticket asks about no longer exists.** The mutual exclusion
between `connect.deadLetter.enabled` and `connect.sharding.families` was **removed on
2026-07-21** by the multi-env mixed-sink work (commit `00f2c2f`, "feat(chart):
sharded-sink DLQ park-then-ack (multi-env P5)"). The sharded sink pipeline now carries
the same park-then-ack DLQ mechanism as the non-sharded pipeline, env-scoped on both the
subject and the msg-id. So:

- **FAB21 running both is not an anomaly — it is the supported, shipped configuration.**
  There is no contradiction to explain; the ticket was filed against a state of the world
  that predates the port.
- Empirically verified at `b7a05bc`:
  `helm template chart/ -f chart/examples/values-sharding.yaml -f chart/examples/values-dlq.yaml`
  renders cleanly (**exit 0**), no `fail`.
- The coexistence "decision" the map ticket wants is therefore **already made and
  shipped**. What remains for the decision ticket is confirming/ratifying the chosen
  option and its documented operational constraints — not choosing whether to build it.

Below: (1) the guard as it was, and what it protected against; (2) how DLQ works on the
non-sharded sink today; (3) how the sharded pipeline now routes DLQ (the "why it lacked
it" is now "how it got it"); (4) the coexistence options as they were weighed, with
which one shipped; (5) open questions for the decision ticket.

---

## 1. The guard, and what it protected against

### 1.1 Where it was and what it said

The guard lived in the `rrcs.nats.stream.subjects` helper, inside the `if $dl.enabled`
branch of `chart/templates/_helpers.tpl`. Its exact fail message (recovered from the
`00f2c2f` diff):

> `connect.deadLetter.enabled=true is not supported with subject-sharding v2
> (connect.sharding.families is set) — the sharded sink pipeline
> (cdc-reverse-sharded.yaml) has no DLQ routing, so a mixed topology would be silently
> half-protected (unsharded poison parked, sharded poison still loops). Disable one of
> them.`

The same rationale was duplicated in the all-in-one preset's G3 guard
(`rrcs.connect.validateAllInOne`), which referred back to "the DLQ+sharding exclusion at
the top of `rrcs.nats.stream.subjects`".

### 1.2 The concrete failure mode it protected against

The guard protected against a **silently half-protected topology**. Concretely:

- The DLQ is a per-reason park-then-ack escape valve that keeps a permanent poison
  message from head-of-line-blocking a consumer's ack floor forever
  (`docs/dlq.md:13-31`). Three failure classes are permanent: `decode_error`,
  `hash_decode_error`, `unknown_op` (`docs/dlq.md:18-24`).
- Before the port, only the **non-sharded** pipeline (`cdc-reverse.yaml`) had DLQ
  routing. The **sharded** pipeline (`cdc-reverse-sharded.yaml`) had **no DLQ branch**:
  its output was a bare `reject_errored: { drop: {} }` and its poison classes threw →
  nacked → redelivered forever.
- On the sharded sink this is *worse* than on the non-sharded sink, because each shard
  binds a durable with **`max_ack_pending=1`** (INV-1 row 13, `rules/05-invariants.md`).
  One poison message occupying that single in-flight slot **blocks its entire shard**
  under `maxDeliver: -1` — the shard stops advancing entirely (the designed DLQ-off
  fail-stop; see the sharded classifier comment at
  `chart/files/connect/cdc-reverse-sharded.yaml:166-167`).
- So a mixed topology with `deadLetter.enabled=true` would have parked poison on the
  non-sharded sinkGroups while **the sharded families' poison still nack-looped and
  stalled shards** — the operator would believe the DLQ was protecting the whole release
  when it was only protecting half of it. The design memo states this directly:
  `docs/design/multi-env-mixed-sink/design.md:§5` — "Removes the exclusion … fires today
  when `deadLetter.enabled` AND `sharding.families`."

The guard was a **fail-loud stand-in for missing pipeline code**, not a statement that
the two are fundamentally incompatible. It said "don't let an operator turn on a safety
valve that only covers part of the release." Once the sharded pipeline grew a real DLQ
branch, the reason to fail vanished and the guard was deleted.

### 1.3 What still fails (so the ticket's "guard" isn't confused with a live one)

There is still a `families`-vs-`deadLetter`-adjacent guard, but it is a **different**
one and it is **not** about the DLQ: `sinkAllInOne` remains mutually exclusive with
sharding (G3, `chart/templates/_helpers.tpl:699-708`). Its comment is explicit that this
is *no longer about DLQ support* — all-in-one is one whole-stream consumer and sharding
is K per-key durables, so a whole-stream drainer would double-consume every shard
subject. That topology conflict is unrelated to #42.

---

## 2. How DLQ works on the non-sharded sink today

Reference: `docs/dlq.md` (definitive operator/maintainer guide) and INV-1 row 14
(`rules/05-invariants.md`).

- **Classify → set meta → one output switch.** The op switch's failure branches count
  `cdc_unprocessable{reason}` and `cdc_dlq_forwarded{reason}`, then set `meta("dlq")="yes"`
  + `dlq_reason`/`dlq_error` instead of throwing
  (`chart/files/connect/cdc-reverse.yaml:172-333`). The DLQ-routed message then falls
  through the apply switch un-errored (`cdc-reverse.yaml:347-356`).
- **Park-then-ack at the output.** The output is `reject_errored:` wrapping, under
  `deadLetter.enabled`, a `switch{ meta("dlq")=="yes" → nats_jetstream(dlq_out) ; drop }`
  (`chart/files/connect/cdc-reverse.yaml:465-466` onward). The `nats_jetstream` send **is
  the write**: a publish failure is an output error → `reject_errored` nacks → the
  original retries. Nothing is acked until the park is PubAck-confirmed — this is what
  keeps INV-1 (at-least-once) intact (`docs/dlq.md:63-67`, INV-1 row 14).
- **Msg-id dedup contract.** The parked copy carries `Nats-Msg-Id: dlq.<event_id>`
  (env-scoped to `dlq.<envId>.<event_id>` when `connect.envId` is set). The `dlq.` stem
  is load-bearing: JetStream msg-id dedup is stream-wide and subject-independent, so
  reusing the original publish's bare `event_id` would `PubAck{duplicate}` → ack →
  **nothing parked** (a silent INV-1 hole). See `docs/dlq.md:68-75`, INV-1 row 14, and
  `chart/templates/_helpers.tpl:259-271` (`rrcs.nats.dlqMsgIdPrefix`).
- **Subject.** Poison goes to `<dlqRoot>.<reason>`. `dlqRoot` is either the legacy
  out-of-prefix `connect.deadLetter.subject` (default `dlq.cdc`) or, in segment mode, the
  in-prefix `<subjectPrefix>.<deadLetter.segment>` (`kv.cdc.dlq`) — with `.<envId>`
  appended when set (`chart/templates/_helpers.tpl:518-536`).
- **Observability.** `cdc_dlq_forwarded{reason}` (routed, counted in-pipeline before the
  publish) and `output_sent{label="dlq_out"}` (PubAck-confirmed parked) drive Grafana
  panel 18 and the `CDCDeadLetterPublishFailing` alert; `output_error{label="dlq_out"}`
  means the publish is failing and poison is still looping (`docs/dlq.md:188-213`).

---

## 3. How the sharded pipeline now routes DLQ (the "why it lacked it" → "how it got it")

The port (`00f2c2f`, 2026-07-21) is normatively specified in
`docs/design/multi-env-mixed-sink/design.md:§5` and captured as binding in INV-1 rows 13
and 15 (`rules/05-invariants.md`). Key facts, with sharded-pipeline citations:

- **Same park-then-ack, one GLOBAL switch.** The sharded output is
  `reject_errored:` → (under `deadLetter.enabled`) a single `switch` over the **broker
  fan-in**, never per-child: `check meta("dlq")=="yes" → nats_jetstream(dlq_out___POD__)`
  else `drop` (`chart/files/connect/cdc-reverse-sharded.yaml:361-433`). The DLQ-off shape
  is a bare `drop: {}`, byte-identical to the pre-DLQ sharded sink
  (`cdc-reverse-sharded.yaml:431-433`).
- **Env-scoped subject AND msg-id (both load-bearing).** Parked subject is
  `<dlqRoot>.<reason>` where `dlqRoot` already carries `.<envId>`; the header is
  `Nats-Msg-Id: dlq.<envId>.<event_id>` (`cdc-reverse-sharded.yaml:410-421`). Scoping
  BOTH means two envs parking the *same* poison event get distinct copies and distinct
  msg-ids, so neither dedups the other away (design §5.4/E2; INV-1 rows 1 statement + 15).
  Extra headers `dlq_env` / `dlq_shard` let a per-env drain tool correlate copies
  (`cdc-reverse-sharded.yaml:425-428`).
- **`event_id` had to be stashed.** The reverse leg never needed `event_id` before; the
  DLQ msg-id does, with a content-hash fallback so poison with no `event_id` still gets a
  deterministic-yet-disjoint id (`cdc-reverse-sharded.yaml:123-132`, mirroring
  `cdc-reverse.yaml:130-137`; design §5.1).
- **Hash guard now renders UNCONDITIONALLY.** Pre-port, the sharded pipeline threw an
  *un-counted* error on a non-object hash body (an INV-2 hole, VF-8). Now the
  `hash_decode_failed` guard + `cdc_unprocessable{shard,reason=hash_decode_error}` counter
  render whether or not the DLQ is on — only the PARK *action* gates on `deadLetter.enabled`
  (`cdc-reverse-sharded.yaml:106-111,199`, INV-1 row 15, INV-2 sharded row). With the DLQ
  off, sharded poison is now *counted* even though it still nack-loops.
- **Never parked:** transient region-Redis errors and the `sx` cross-shard rename lane —
  they keep nacking as the intended loud fail-stop (design §5.1 table;
  `cdc-reverse-sharded.yaml` output header 367-371).

### Why this is safe for ordering (O-6/O-7) and INV-1

This is the crux of the ticket's Q2 ("what per-shard-durable DLQ routing under
`max_ack_pending=1` means for O-6/O-7 and INV-1"). Answer, from design §5.3 and INV-1
row 13:

- **O-6 (per-shard delivery order == fetch order) is unchanged.** Each shard durable has
  `max_ack_pending=1` and a single active puller, so the next shard message is not
  delivered until the current one is acked. A parked message's ack is emitted by the
  output transaction, which completes **only after the DLQ PubAck** — exactly as a normal
  apply's ack completes only after the Redis write. So park-then-ack occupies the **same
  single-in-flight slot** a normal apply would; it does not add a second in-flight
  message and does not loosen `max_ack_pending`.
- **Ack routing stays per-shard.** The broker routes the park's ack back to the
  **originating shard child** (F3), so a parked poison advances only its own shard's ack
  floor and never another shard's (`cdc-reverse-sharded.yaml:370-382`, design §5.3/VF-10).
  One stuck-then-parked shard never blocks another.
- **O-7 (delivery order == apply order) holds trivially for parks.** A parked message is
  **poison that is never applied**, so occupying the slot cannot reorder any *valid*
  change for any key (design §5.3, INV-1 row 13).
- **INV-1 (at-least-once) holds** because park-then-ack is write-then-ack: no ack until
  the park is PubAck-confirmed; a park-send failure nacks and redelivers on the **same
  shard durable**, which is safe under `max_ack_pending=1` (INV-1 rows 8/15). Malformed
  messages are the owner-approved INV-1 exemption (park with confirmed PubAck instead of
  apply), and INV-1's statement says this exemption "applies identically to the sharded
  sink" (`rules/05-invariants.md:21-37`).
- **Proven:** `scripts/verify-sharded-dlq-e2e.sh` PASS 2026-07-21 (3 classes parked
  env-scoped, +9 PubAck, O-6 held; re-proven 2026-08-03 with the pod-suffixed label) and
  `scripts/verify-multi-env.sh` PASS 2026-07-21 (cross-park, no dedup-swallow) — cited in
  INV-1 rows 1/13/15.

**So there is no ordering or at-least-once penalty for per-shard DLQ routing.** The design
sidesteps the naive hazard (a per-child DLQ output that could reorder or double-count) by
using ONE global switch over the broker fan-in with ack routed back to the origin child,
and by parking only poison that would never have been applied anyway.

---

## 4. Coexistence options as weighed — and which shipped

The ticket asked for 2–3 realistic options. Here they are, framed against what actually
happened.

### Option A — Add DLQ routing branches to the sharded sink pipeline **[SHIPPED]**

Port park-then-ack into `cdc-reverse-sharded.yaml`: one global switch over the broker
fan-in, env-scoped subject + msg-id, unconditional hash guard.

- **Ordering / at-least-once:** No penalty. O-6/O-7 and INV-1 preserved as proven in §3
  (design §5.3; INV-1 rows 13/15; e2e PASS 2026-07-21).
- **Cost:** The pipeline gained a stash mapping (`event_id` + fallback), an unconditional
  hash guard, three classifier park branches, and a global output switch. `dlq_out`
  observability (panel 18, `CDCDeadLetterPublishFailing`) extended to sharded per-group
  jobs via `job=~".*connect-sink.*"` (INV-2 rows).
- **Verdict:** This is the option that was chosen and is on `master`. It is the only
  option that gives sharded families the *same* poison protection as non-sharded ones
  without a topology carve-out.

### Option B — Scope the DLQ to non-sharded sinkGroups; make the guard conditional

Allow `deadLetter.enabled` with `sharding.families`, but only wire DLQ into the
non-sharded groups; keep the sharded pipeline DLQ-less and turn the hard guard into a
conditional one (fail only if a *sharded* group would need parking).

- **Ordering / at-least-once:** The non-sharded half is fine. The sharded half is exactly
  the **silently half-protected** state the original guard existed to prevent (§1.2):
  sharded poison nack-loops and stalls shards under `max_ack_pending=1`, while the
  operator sees a DLQ "enabled." INV-1 is not *violated* (poison isn't lost, just stuck),
  but the head-of-line block on a shard is an availability failure and the mismatch
  between "DLQ on" and "half the release protected" is an operational trap.
- **Cost:** Requires a per-group notion of "DLQ applies here" and a conditional guard —
  arguably *more* chart complexity than Option A, for a strictly worse safety story.
- **Verdict:** Rejected implicitly by choosing A. Only defensible if porting the sharded
  pipeline had been infeasible; it wasn't.

### Option C — Keep the incompatibility; document the risk

Leave the hard render guard in place; sharded families run DLQ-off (poison nack-loops
forever, counted after the E3 hash-guard fix), with explicit risk docs telling operators
that a sharded family has no poison escape valve.

- **Ordering / at-least-once:** INV-1 not violated (nothing lost). But any single poison
  message in a sharded family **permanently stalls that shard** (`max_ack_pending=1`,
  `maxDeliver:-1`) — a hard availability cliff with no operator recourse short of manual
  stream surgery.
- **Cost:** Lowest chart-code cost; highest operational risk. Unacceptable for a
  high-volume sharded family (the exact case sharding exists for), where a poison event
  is more likely, not less.
- **Verdict:** This is essentially the *pre-2026-07-21* status quo. It was superseded.

**Prod context that made A the right call.** Prod JetStream is external NATS with a
**72h max-age** stream, and a **shared-stream DLQ design was previously owner-approved**
(`memory: prod-external-nats-dlq-rulings`, 2026-07-20). Under a 72h retention a stalled
shard is not just blocked — un-acked poison ages out of the stream, so "nack forever"
(Options B/C for sharded families) can become silent loss at the retention boundary. That
raises the stakes on Options B/C and further favours A (park-then-ack durably re-publishes
the poison onto the same stream before acking, within the same retention regime).

---

## 5. Open questions for the decision ticket (#41)

The build is shipped, so these are ratification / operational-hardening questions, not
design-choice questions.

1. **Is there a guard requiring "sharded SINK release only" (source off) when both are
   set?** Design §5 says "only a sharded SINK release may enable both (source off,
   families set, sharded groups covering all shards)." I did not find a render guard that
   *enforces* source-off in this combination — it appears to be an operational rule
   (draft-topology CC6), not a fail-loud check. The decision ticket should confirm whether
   that constraint needs a guard or stays a runbook rule.
2. **Coverage requirement.** Design §5 requires the sharded groups to cover **all**
   shards. Is there a render check that every shard `s0..sK-1` (+ `sx`) is claimed by some
   group when DLQ+sharding is on, or is an uncovered shard a silent gap? Worth confirming
   for FAB21's topology specifically.
3. **DLQ drain tooling is still open.** There is no automated consumer of the DLQ subtree
   (`docs/dlq.md:283-305`, §9). For a multi-env sharded release the parked copies are
   fanned across `<dlqRoot>.<envId>.<reason>` lanes with `dlq_env`/`dlq_shard` headers; a
   per-env drain/replay helper is still a "potential improvement," not shipped.
4. **External-NATS DLQ path is untested end-to-end.** `docs/dlq.md:283-289` flags that the
   external-creds path (which is what prod is) is not exercised by the e2e; before
   FAB21-class production reliance, staging must confirm the external subscriber creds
   grant pub on the DLQ root (`dlq.cdc.>` legacy / covered by `kv.cdc.>` in segment mode).
5. **Ratify Option A as the standing decision.** Since the guard is already gone and the
   sharded park-then-ack is on `master` and proven, the map ticket should record Option A
   as the accepted resolution and close the "why do they refuse to combine" question as
   *historically true, no longer the case*.

---

## Appendix — primary sources

- Guard removal: `chart/templates/_helpers.tpl:610-617` (removal note), commit `00f2c2f`
  ("feat(chart): sharded-sink DLQ park-then-ack (multi-env P5)"); old fail text recovered
  from `git show 00f2c2f -- chart/templates/_helpers.tpl`.
- Residual (non-DLQ) sharding guard: `chart/templates/_helpers.tpl:699-708` (G3, all-in-one).
- Non-sharded DLQ path: `chart/files/connect/cdc-reverse.yaml:104-137,172-333,347-356,465+`;
  operator guide `docs/dlq.md`.
- Sharded DLQ path: `chart/files/connect/cdc-reverse-sharded.yaml:106-132,160-228,306-335,361-433`.
- DLQ helpers: `chart/templates/_helpers.tpl:259-271` (msg-id prefix), `:518-536` (dlqRoot).
- Normative design: `docs/design/multi-env-mixed-sink/design.md:§5` (sharded DLQ, ordering
  proof §5.3); `docs/design/subject-sharding/design.md` (O-chain).
- Binding invariants: `rules/05-invariants.md` INV-1 rows 8/13/14/15, INV-2 sharded rows,
  operational invariants E1/E9.
- Render check at `b7a05bc`: `helm template chart/ -f chart/examples/values-sharding.yaml
  -f chart/examples/values-dlq.yaml` → exit 0 (no `fail`).
