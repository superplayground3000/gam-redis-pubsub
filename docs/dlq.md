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

When `connect.deadLetter.enabled=true`:

- **Where poison goes.** Messages are published per-reason to
  `<subject>.<reason>` — for example `dlq.cdc.decode_error`,
  `dlq.cdc.hash_decode_error`, `dlq.cdc.unknown_op`
  (`chart/files/connect/cdc-reverse.yaml:429`, subject built from
  `connect.deadLetter.subject` + the `dlq_reason` meta).
- **Stream binding.** The JetStream stream binds `<subject>.>` so all reasons land
  on it. Enabling the DLQ extends the reconciled subject list from `kv.cdc.>` to
  `kv.cdc.>,dlq.cdc.>` (`chart/templates/nats-init-job.yaml:15-25,75`).
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

Two keys, both under `connect.deadLetter` in `chart/values.yaml:169-199`:

| Key | Default | Meaning |
|---|---|---|
| `connect.deadLetter.enabled` | `false` | Turn the DLQ on for the sink leg. |
| `connect.deadLetter.subject` | `"dlq.cdc"` | Base subject; poison is published as `<subject>.<reason>`, stream binds `<subject>.>`. |

Render-time guards (all in `chart/templates/_helpers.tpl`):

- The subject must be a literal dot-separated NATS subject — tokens of
  `[A-Za-z0-9_-]` only, no wildcards, no empty segments
  (`chart/templates/_helpers.tpl:256`).
- The subject **must live outside** `nats.stream.subjectPrefix` (`kv.cdc.*`),
  otherwise a whole-stream sink would re-consume its own dead letters; the render
  fails loud if it is not disjoint (`chart/templates/_helpers.tpl:259`).
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

The end-to-end proof below was run against this exact page's claims on
2026-07-16 (kind cluster `cdc`, chart at the commit that introduced this doc) and
passed. The guard-behavior script was **not** run in that session — its coverage
is described from its own header, and the pipeline/template behavior is verified
by the source citations throughout this page.

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
- **Guard behavior (no cluster needed).** `scripts/test-dlq-guard.sh` extracts the
  reverse pipeline's stash+guard mapping from the DLQ-enabled render and runs it in
  the pinned Connect image against a case table (plain and gzip:base64 poison,
  valid object bodies, skip paths), asserting `hash_decode_failed` / `event_id`
  including the fallback value (`scripts/test-dlq-guard.sh` header).
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

## See also

- `chart/examples/values-dlq.yaml` — the runnable, commented enablement example.
- `chart/examples/README.md` — index of chart examples and the tests that prove them.
- `chart/values.yaml:169-199` — the `connect.deadLetter` keys with inline notes.
- `docs/superpowers/specs/2026-07-13-hash-decode-dlq-design.md` — original design
  spec (dated session artifact; see its "Port addendum" for what changed).
