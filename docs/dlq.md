# Dead-Letter Queue (DLQ) — operator & maintainer guide

The DLQ is an opt-in safety valve on the sink (reverse) leg. When enabled, a
message that can never be applied to region Redis is re-published to a separate
subject on the same JetStream stream and then acked, instead of nacking and
redelivering forever. This page is the definitive reference for what it does, how
to turn it on safely, and how to confirm it is working.

Every factual claim below is traceable to a file in the repo; the source is cited
inline as `path:line`. Where the exact behavior lives in a rendered pipeline, the
citation points at the template that produces it.

## 1. Purpose and scope

The sink applies each NATS message to region Redis and then acks it. The
consumer's ack floor sits at the oldest un-acked message, so a single message that
can *never* succeed is more than a lost record — it head-of-line-blocks every
newer message queued behind it. Three failure classes are permanent in this sense:

- `decode_error` — the CDC body cannot be decoded (`chart/files/connect/cdc-reverse.yaml:198`).
- `hash_decode_error` — a create/update hash body is not a valid JSON object, so
  the `HSET` args mapping would throw (`chart/files/connect/cdc-reverse.yaml:204-223`).
- `unknown_op` — the `op` field is not one the sink knows how to apply
  (`chart/files/connect/cdc-reverse.yaml:332`).

Without the DLQ, each of these throws, nacks, and redelivers under `maxDeliver=-1`
forever (`chart/files/connect/cdc-reverse.yaml:201`, and the `nats.stream.consumer.maxDeliver: -1`
setting in `chart/values.yaml`). The DLQ breaks that loop: the poison message is
published to a sibling subject and acked, so the ack floor advances and healthy
traffic keeps flowing, while the poison is preserved — never dropped — for
inspection.

**Scope.** The DLQ only covers the non-sharded sink pipeline
(`chart/files/connect/cdc-reverse.yaml`). It is deliberately incompatible with
per-key sharding v2 — see §5. This page documents the feature as it exists today
on `master`; the design spec
`docs/superpowers/specs/2026-07-13-hash-decode-dlq-design.md` is a dated session
artifact (background rationale, not current requirements — several of its
decisions were revised during the port, recorded in that file's own
"Port addendum").

## 2. Operator-facing behavior

This section describes the **default (legacy) out-of-prefix layout**, which is what
ships unless you opt into the in-prefix segment layout described in §10. When
`connect.deadLetter.enabled=true`:

- **Where poison goes.** Messages are published per-reason to
  `<subject>.<reason>` — for example `dlq.cdc.decode_error`,
  `dlq.cdc.hash_decode_error`, `dlq.cdc.unknown_op`
  (`chart/files/connect/cdc-reverse.yaml:429`, subject built from the computed DLQ
  root + the `dlq_reason` meta; in legacy mode the root is
  `connect.deadLetter.subject`). In the opt-in segment layout the root instead
  becomes `<nats.stream.subjectPrefix>.<connect.deadLetter.segment>` (e.g.
  `kv.cdc.dlq.<reason>`) — see §10.
- **Stream binding.** In legacy mode the JetStream stream binds `<subject>.>` so all
  reasons land on it, and enabling the DLQ extends the reconciled subject list from
  `kv.cdc.>` to `kv.cdc.>,dlq.cdc.>` (`chart/templates/nats-init-job.yaml:15-25,75`).
  In segment mode the DLQ already lives under `kv.cdc.>`, so the binding stays
  `kv.cdc.>` alone and never needs a second subject added (§10).
- **Write-then-ack is preserved.** The DLQ publish *is* the write; a publish
  failure surfaces as an output error, so `reject_errored` nacks and the original
  message retries — nothing is acked until it is safely parked
  (`chart/files/connect/cdc-reverse.yaml:412-418`). This keeps INV-1 (at-least-once)
  intact.
- **Header contract on the parked message**
  (`chart/files/connect/cdc-reverse.yaml:439-442`):
  - `Nats-Msg-Id: dlq.<event_id>` — the `dlq.` prefix is load-bearing. JetStream
    msg-id dedup is stream-wide, and the original `kv.cdc.*` publish already used
    `event_id` as its `Nats-Msg-Id` on this same stream. A bare reuse would dedupe
    the DLQ publish against the original inside the dupe window and park *nothing*
    (a silent hole); the prefix keeps the id deterministic yet disjoint
    (`chart/files/connect/cdc-reverse.yaml:431-438`).
  - `dlq_reason` — the failure reason.
  - `dlq_error` — a human-readable description of what went wrong.
  - `dlq_orig_subject` — the subject the poison originally arrived on.

When the DLQ is disabled (the default), the rendered chart is byte-identical to
the pre-DLQ chart and poison redelivers forever exactly as before
(`chart/files/connect/cdc-reverse.yaml:445-447`, `chart/values.yaml:160-161`).

## 3. Configuration reference

The two core keys are under `connect.deadLetter` in `chart/values.yaml:169-199`; the
opt-in segment layout (§10) adds one more here plus two under `nats.stream`:

| Key | Default | Meaning |
|---|---|---|
| `connect.deadLetter.enabled` | `false` | Turn the DLQ on for the sink leg. |
| `connect.deadLetter.subject` | `"dlq.cdc"` | **Legacy mode** base subject; poison is published as `<subject>.<reason>`, stream binds `<subject>.>`. Ignored when `segment` is set (guard N4). |
| `connect.deadLetter.segment` | `""` | **Segment mode** (§10). When set (e.g. `"dlq"`), the DLQ root becomes `<nats.stream.subjectPrefix>.<segment>` (`kv.cdc.dlq.<reason>`); requires `nats.stream.normalSegment`. Empty = legacy mode. |
| `nats.stream.normalSegment` | `""` | **Segment mode** (§10). When set (e.g. `"aio"`), ALL normal publishes and ALL sink filters move under `<subjectPrefix>.<segment>.`. Empty = default layout. |
| `nats.stream.consumer.migrationFilter` | `""` | **Migration only** (§10). A superset wildcard (e.g. `"kv.cdc.>"`) that temporarily replaces the whole-stream sink filter during the two-phase migration. Empty except mid-migration. |

Render-time guards for **legacy mode** (all in `chart/templates/_helpers.tpl`):

- The subject must be a literal dot-separated NATS subject — tokens of
  `[A-Za-z0-9_-]` only, no wildcards, no empty segments
  (`chart/templates/_helpers.tpl:256`).
- **Legacy mode only:** the subject **must live outside**
  `nats.stream.subjectPrefix` (`kv.cdc.*`), otherwise a whole-stream sink would
  re-consume its own dead letters; the render fails loud if it is not disjoint
  (`chart/templates/_helpers.tpl:259`). This out-of-prefix rule is *the* structural
  disjointness guarantee of the default layout. Segment mode deliberately puts the
  DLQ *inside* the prefix and replaces this structural rule with the render-time
  guards N1–N6 in §10 (chiefly `normalSegment ≠ deadLetter.segment`).
- `connect.deadLetter.enabled=true` together with `connect.sharding.families`
  fails the render (`chart/templates/_helpers.tpl:246` — see §5).

**Do not duplicate the values here — use the worked example.** A complete,
heavily commented enablement file lives at `chart/examples/values-dlq.yaml`,
indexed in `chart/examples/README.md`. Install it with:

```bash
helm upgrade --install rrcs ./chart -n rrcs-k8s --create-namespace \
  -f chart/examples/values-dlq.yaml
```

## 4. Design rationale

**Why opt-in (default off).** Dropping a message off the main consumer is a
deliberate operational choice, not something to switch on by accident. With the
toggle off the render is byte-identical to the pre-DLQ chart, so an upgrade is
backward-safe by default; turn it on only once you have somewhere to watch the DLQ
subject and a plan to drain it (`chart/values.yaml:160-164`).

**Why park instead of drop.** A dropped poison message is lost, which would
violate INV-1's no-loss guarantee. Parking re-publishes it to a durable subject on
the same stream and only acks the original after the park is PubAck-confirmed, so
the message is always recoverable (`chart/files/connect/cdc-reverse.yaml:412-418`).

**Why fail-safe on a missing grant.** The DLQ publishes with the subscriber creds,
which must grant pub on `<subject>.>`. If that grant is ever missing, the publish
is permission-denied, which surfaces as an output error → `reject_errored` nacks →
the original retries. So a misconfiguration cannot lose data; it just leaves the
DLQ inert while poison keeps looping (`chart/values.yaml:184-188`).

**Why incompatible with sharding v2.** The sharded sink pipeline
(`chart/files/connect/cdc-reverse-sharded.yaml`) has the same poison hole but no
DLQ routing yet. Enabling both would silently protect only the unsharded half of a
mixed topology, so the chart makes it a loud render error rather than shipping a
half-protected system (`chart/templates/_helpers.tpl:246`).

## 5. Sharding incompatibility (hard error)

Setting `connect.deadLetter.enabled=true` while `connect.sharding.families` is
configured **fails the render** with:

```
connect.deadLetter.enabled=true is not supported with subject-sharding v2
(connect.sharding.families is set) — the sharded sink pipeline
(cdc-reverse-sharded.yaml) has no DLQ routing, so a mixed topology would be
silently half-protected (unsharded poison parked, sharded poison still loops).
Disable one of them.
```

(`chart/templates/_helpers.tpl:246`.) Use `chart/examples/values-dlq.yaml` **or**
`chart/examples/values-sharding.yaml`, never both at once. Combined DLQ + sharding
support is a documented follow-up (§9).

## 6. Operational notes

### Metrics and the Grafana panel

Watch panel 18, **"DLQ: routed vs confirmed parked"**
(`chart/files/grafana/cdc-dashboard.json`). It plots three series that together
tell the truth about parking:

- **routed** — `cdc_dlq_forwarded{reason}`. This counter increments in the
  pipeline at *routing* time, before the publish is attempted (a switch-output
  case cannot count post-write on this Connect build), so on its own it does **not**
  prove a message actually landed in the DLQ — it moves in lockstep with
  `cdc_unprocessable` (`chart/files/connect/cdc-reverse.yaml:187-195`).
- **confirmed parked** — `output_sent{label="dlq_out"}`. This is the trustworthy
  "it really parked" signal, PubAck-counted by the DLQ output itself (the output
  carries `label: dlq_out`, `chart/files/connect/cdc-reverse.yaml:423`).
- **publish failures** — `output_error{label="dlq_out"}`. Each failure nacks the
  original, so poison keeps redelivering.

`cdc_unprocessable{reason=...}` also increments for every poison message
(`chart/files/connect/cdc-reverse.yaml:182-186,210-214`).

**Healthy** looks like `routed == confirmed parked` with `publish failures` at 0.
If **routed climbs while confirmed parked stays flat**, the DLQ publish is failing
— most often the subscriber creds are missing the `dlq.cdc.>` pub grant — and
poison is still looping even though the panel is moving.

### Rollout

- **Fresh install.** The committed `chart/files/nats-auth/` creds were regenerated
  with the `dlq.cdc.>` pub grant on 2026-07-16 (PR #22 — commits `26e156a`,
  `037bb82`, `1d0f03f`, `0cf2f37`), so enabling the DLQ on a fresh install is just
  flipping the toggle, nothing else to do (`chart/values.yaml:173-176`).
- **CAUTION — releases installed with pre-2026-07-16 creds.** That regeneration
  also rotated the operator and account identities. Redeploying these creds onto
  such a release orphans its existing `KV_CDC` stream state, so plan a fresh NATS
  (new install or namespace) or a migration rather than an in-place upgrade
  (`chart/values.yaml:178-182`).
- **External NATS.** If you run external NATS, make sure the subscriber creds you
  supply carry pub on `dlq.cdc.>` (re-run `scripts/gen-nats-auth.sh --force`, or
  add the grant in your own account config). The commented external block in
  `chart/examples/values-dlq.yaml` shows the placeholders.

### Rollback

Set `connect.deadLetter.enabled=false` and upgrade. The render returns to the
pre-DLQ pipeline (`chart/files/connect/cdc-reverse.yaml:445-447`) and poison
resumes redelivering — which is the original, no-loss-but-blocking behavior.
Anything already parked on `dlq.cdc.>` remains on the stream subject to its
retention limits.

### Failure modes

- **Missing pub grant** → permission-denied publish → fails safe (nack/retry, no
  loss), DLQ inert, "routed" diverges from "confirmed parked" (see above).
- **In-place enable within the previous nats-init Job's TTL window** — handled:
  `connect.deadLetter` joins the Job's name hash only when enabled, so enabling
  always yields a fresh reconcile Job that binds `dlq.cdc.>`
  (`chart/templates/nats-init-job.yaml:15-25`).

## 7. Testing performed

Both proofs below were run against this exact page's claims on 2026-07-16
(kind cluster `cdc` for the e2e, the pinned Connect image in docker for the
guard test; chart at the commit that introduced this doc) and passed. The only
path not exercised is external NATS — see §8.

- **End-to-end (L3 kind, ~5 min) — RUN 2026-07-16, PASS (exit 0).**
  ```bash
  scripts/build-images.sh --kind --kind-name=cdc
  RRCS_NS=cdc-dlq RRCS_RELEASE=cdc-dlq scripts/verify-dlq-e2e.sh
  ```
  What it proved, in the script's own result lines: the embedded baseline
  `verify-cdc.sh` passed with the DLQ enabled ("PASS — dedup + per-op + replay
  all green"); the stream bound `kv.cdc.>,dlq.cdc.>` (§2's binding claim); and
  the final verdict — "PASS — poison parked (dlq +5), confirmed
  (output_sent{dlq_out} +5, error 0), consumer unblocked (ack_pending->0,
  redeliver +0), normal delivered, headers OK" — i.e. 5 poison hash bodies
  parked on `dlq.cdc.hash_decode_error`, parking PubAck-confirmed with zero
  publish failures, the ack floor advanced with no redelivery loop, a normal
  message injected afterward still reached region Redis, and the §2 header
  contract held on the parked messages.
- **Guard behavior (no cluster needed) — RUN 2026-07-16, PASS (exit 0).**
  `scripts/test-dlq-guard.sh` extracts the reverse pipeline's stash+guard mapping
  from the DLQ-enabled render and runs it in the pinned Connect image against a
  case table (plain and gzip:base64 poison, valid object bodies, skip paths),
  asserting `hash_decode_failed` / `event_id` including the fallback value
  (`scripts/test-dlq-guard.sh` header). All 8 cases matched
  (`hash_decode_failed` and `event_id` exact-match on every row, including
  `poison_no_event_id`, the fallback-id case); final line `[test-dlq-guard] PASS`.
- **Render check (L1, seconds).**
  ```bash
  helm template chart/ -f chart/examples/values-dlq.yaml >/dev/null   # expect exit 0
  ```

## 8. Untested areas

- **External NATS with the DLQ.** The bundled-mode path is what
  `scripts/verify-dlq-e2e.sh` exercises; the external-creds path is not covered
  here. Before production, verify in staging that your external subscriber creds
  really grant pub on `dlq.cdc.>` — a missing grant fails safe but leaves the DLQ
  inert.
- **Draining or replaying parked messages.** There is no automated consumer of
  `dlq.cdc.>` today. Deciding what to do with parked poison (inspect, fix upstream,
  replay) is a manual operational step.
- **Custom subjects.** Only the default `dlq.cdc` is exercised by the e2e test. If
  you change it, re-run `scripts/verify-dlq-e2e.sh` against your value and confirm
  it stays outside `nats.stream.subjectPrefix`.

## 9. Potential improvements

- Add DLQ routing to the sharded sink pipeline so the DLQ and sharding are no
  longer mutually exclusive (removes the render-time incompatibility in §5).
- Ship a "DLQ drain" helper or runbook for inspecting and replaying parked
  messages, so operators are not left with a growing `dlq.cdc.>` subject and no
  tooling.
- Emit a post-write "parked" counter so the dashboard no longer needs to lean on
  the `output_sent{label="dlq_out"}` proxy to prove parking (the `cdc_dlq_forwarded`
  counter cannot count post-write on this Connect build —
  `chart/files/connect/cdc-reverse.yaml:188-190`).

## 10. In-prefix segment mode (shared fixed-prefix layout)

Everything above §10 describes the **default, out-of-prefix DLQ layout** — normal
traffic on `kv.cdc.<op>`, poison on `dlq.cdc.<reason>` — which is unchanged and stays
the default. This section documents the **opt-in** alternative for the one case the
default cannot serve: a JetStream stream whose subject prefix is externally FIXED at
`kv.cdc` (a PROD stream bound `kv.cdc.>` that operators cannot re-bind). There, a DLQ
at `dlq.cdc.>` is unbindable, so both normal and DLQ traffic must be separated by the
SECOND subject segment under the shared prefix. Full design and rationale:
`docs/superpowers/plans/2026-07-20-shared-prefix-subject-layout.md` (owner-approved
2026-07-20).

### What changes

Setting `nats.stream.normalSegment` (e.g. `"aio"`) inserts that segment after the
prefix for ALL normal publishes and ALL sink filters; setting
`connect.deadLetter.segment` (e.g. `"dlq"`) moves the DLQ root in-prefix. The result:

| | Default (legacy, unchanged) | Segment mode |
|---|---|---|
| Normal publish subject | `kv.cdc.<op>` | `kv.cdc.aio.<op>` |
| DLQ publish subject | `dlq.cdc.<reason>` (outside prefix) | `kv.cdc.dlq.<reason>` (inside prefix) |
| Stream binding | `kv.cdc.>` (+ `dlq.cdc.>` when DLQ on) | `kv.cdc.>` alone |
| Whole-stream sink filter | `kv.cdc.>` | `kv.cdc.aio.>` |
| Subscriber DLQ pub grant | `dlq.cdc.>` | `kv.cdc.dlq.>` (covered by the `kv.cdc.>` grant) |

The `Nats-Msg-Id` dedup contract is unchanged: the DLQ copy still carries
`Nats-Msg-Id: dlq.<event_id>`, disjoint from the original publish's `event_id`, so
relocating the subject does not touch the §2 header semantics (INV-1 row 14, amended
to reference the *computed DLQ root* rather than a literal subject).

**The trade being made.** In the default layout the DLQ is *physically* outside the
sink filter's universe, so it can never be re-consumed — the disjointness is
structural and unconditional. Segment mode puts the DLQ inside the prefix and replaces
that structural guarantee with a render-time guard (`normalSegment ≠ deadLetter.segment`).
That guard is therefore load-bearing and ships in the same change as the layout.

### Render guards N1–N6 (all fail-loud; opt-in only)

These fire only when the segment keys are set; legacy mode keeps its existing guards
(§3) untouched. (Exact `_helpers.tpl` locations land with the helper change — verify
with `helm template` after W1 lands.)

| # | Fails the render when… | Why |
|---|---|---|
| N1 | `deadLetter.segment` == `normalSegment` | THE disjointness guard — replaces the structural out-of-prefix guarantee; equal segments would let the whole-stream sink re-consume its own dead letters |
| N2 | `deadLetter.segment` set AND `deadLetter.enabled` AND `normalSegment` empty | the sink filter would stay `kv.cdc.>` and re-consume `kv.cdc.<dlq>.>` — a self-consumption loop |
| N3 | `normalSegment` or `deadLetter.segment` is not a single literal token (`[A-Za-z0-9_-]+`, no dots or wildcards) | same grammar rule as the legacy DLQ-subject token guard |
| N4 | `deadLetter.segment` set AND `deadLetter.subject` != its default `"dlq.cdc"` | the two modes are mutually exclusive; silently ignoring a customised `subject` would be a trap |
| N5 | Segment mode AND any explicit `connect.sinkGroups[*].filterSubject` not strictly under `<prefix>.<normalSegment>.` | `filterSubject` is passed through verbatim; a value like `kv.cdc.>` or `kv.cdc.<dlq>.>` would bind the sink to its own DLQ/output space — self-consumption. Legacy mode keeps current behaviour (structural disjointness protects it) |
| N6 | `migrationFilter` set AND `deadLetter.segment` set with the DLQ enabled | the migration superset (`kv.cdc.>`) would match the in-prefix DLQ subtree — the two must never be active together (see the phase ordering below) |

### Two-phase migration runbook (existing install → segment mode)

The hazard is consumer-side: narrowing the durable `cdc_sink` filter from `kv.cdc.>`
to `kv.cdc.aio.>` in one step would stop matching any retained/pending messages still
on the bare `kv.cdc.<op>` subjects, silently skipping them — an at-least-once loss
window. The op space is OPEN (the forward leg publishes whatever `meta("op")` carries),
so an enumerated transitional filter (`create|update|delete|rename`) would silently
drop any `kv.cdc.<other-op>` message, and JetStream forbids overlapping
`filter_subjects` so `[kv.cdc.aio.>, kv.cdc.>]` is not expressible as a union. The
migration therefore uses a **wildcard replacement filter in two phases** that never let
the superset filter coexist with an in-prefix DLQ (guard N6). The stream binding is
NEVER narrowed (it stays `kv.cdc.>`), so nothing is rejected at publish time.

1. **Phase A — move normal traffic.** Upgrade with `nats.stream.normalSegment: aio`
   and `nats.stream.consumer.migrationFilter: "kv.cdc.>"`. Leave the DLQ in its
   previous mode (off, or legacy `dlq.cdc` — both outside the superset's overlap).
   The sink filter stays the superset `kv.cdc.>`, matching BOTH the old bare
   `kv.cdc.<op>` retained/pending messages AND the new `kv.cdc.aio.<op>` publishes —
   nothing is skipped, regardless of op token. (Migrating from prefix-routed
   `sinkGroups`? Drain those groups first, per the topology-collapse runbook in
   `chart/examples/values-all-in-one.yaml`.)
2. **Drain.** Wait until the old-subject backlog is gone: the forward leg has rolled
   to the new `kv.cdc.aio.*` publish subject AND
   `nats consumer info KV_CDC cdc_sink` shows `num_ack_pending==0` with `num_pending`
   only advancing on `kv.cdc.aio.*` traffic.
3. **Phase B — narrow and move the DLQ in-prefix.** Upgrade with
   `migrationFilter: ""` and `connect.deadLetter.segment: "dlq"` (+ `enabled: true`).
   The filter narrows to `kv.cdc.aio.>`; every old-subject message was already acked
   in phase A, so the narrow skips nothing. The in-prefix DLQ activates only now,
   when no superset filter can see it.

Greenfield/fresh installs skip all of this — set the segment keys from the start and
the layout is correct on first render.

**External NATS branch.** The bundled nats-init applies filter drift via in-place
`nats consumer edit` (`chart/templates/nats-init-job.yaml:181-201`), but the EXTERNAL
init job never mutates user-owned consumers — it creates-if-absent or fails loud on a
stale filter (`chart/templates/nats-init-external-job.yaml:102,123`). So on external
NATS each phase is: the operator edits the durable's filter FIRST
(`nats consumer edit KV_CDC cdc_sink --filter <desired>`), then runs the helm upgrade
whose external job ASSERTS that same desired filter (which must incorporate
`migrationFilter`). The stream binding needs no operator action at any point — the
wildcard `kv.cdc.>` already covers the new segments (owner-confirmed).

### Labs are legacy-layout and intentionally unchanged

The behavioural labs exercise only the default (legacy) layout and stay correct as-is:
`labs/redis-cdc-error-alerting` hardcodes `dlq.cdc.*` in its alert proof
(`labs/redis-cdc-error-alerting/scripts/verify-alert.sh`), and
`labs/by-key-prefix-split-topic` demos the default `kv.cdc.<op>` split. Both are the
legacy-mode proof and are deliberately NOT updated for segment mode — the segment-mode
end-to-end proof lives in the parameterised L3 e2e (`scripts/verify-dlq-e2e.sh`, made
mode-aware), not in the labs.

## See also

- `chart/examples/values-shared-prefix-aio.yaml` — the runnable segment-mode (in-prefix DLQ) example.
- `chart/examples/values-dlq.yaml` — the runnable, commented enablement example.
- `chart/examples/README.md` — index of chart examples and the tests that prove them.
- `chart/values.yaml:169-199` — the `connect.deadLetter` keys with inline notes.
- `docs/superpowers/specs/2026-07-13-hash-decode-dlq-design.md` — original design
  spec (dated session artifact; see its "Port addendum" for what changed).
