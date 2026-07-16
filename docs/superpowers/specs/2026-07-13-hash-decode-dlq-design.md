# Hash-decode guard + Dead-Letter Queue — Design

- **Date:** 2026-07-13
- **Branch:** `investigate-sink-ack` (worktree `connect-sink-ack`, from `master`)
- **Status:** Approved for planning
- **Invariants touched:** INV-1 (ack semantics, rows 7–8), INV-2 (new failure branch + panels), INV-3 (toggle); plus NATS auth grant and stream subjects.

## Port addendum (2026-07-16, branch `feat/dlq-port`)

PR #17 rotted against master (subject-sharding v2 rewrote the sink surface), so this design
was re-implemented on `feat/dlq-port` rather than rebased. Deviations from the text below —
each one fixes a defect found during the port, the design intent is unchanged:

1. **Sharding v2 exclusion (new fail-loud).** `connect.deadLetter.enabled=true` together with
   a configured `connect.sharding.families` fails the render: `cdc-reverse-sharded.yaml` has
   the same hash-poison hole but no DLQ routing, and a half-protected mixed topology must be
   an explicit error, not a silent state. Sharded DLQ support is a follow-up.
2. **`meta event_id` stash (bug fix).** The reverse pipeline never stashed `event_id`, so the
   DLQ output's `Nats-Msg-Id` header (§4.3) would have interpolated EMPTY — a silent dedup
   no-op in the original PR. The enabled render now stashes the envelope's `event_id`,
   falling back to `content().hash("sha256")` when it is missing OR empty-string (`.or()`
   alone misses `""`, which would collapse all such poisons onto one dedup id); same
   fallback the forward leg mints. `scripts/test-dlq-guard.sh` asserts the exact fallback
   value for both cases.
3. **DLQ msg-id is `dlq.<event_id>`, not bare `event_id` (bug fix to Decision 5).**
   JetStream msg-id dedup is STREAM-wide; the original publish already used `event_id` as its
   `Nats-Msg-Id` on the same stream, so a bare reuse would dedupe the DLQ publish against the
   original within `dupeWindow` → `PubAck{duplicate}` → ack → nothing parked. The `dlq.`
   prefix keeps redelivery-dedup of DLQ republishes while staying disjoint.
4. **Guard gates on lets, not same-mapping meta (bug fix).** At runtime this Connect build
   reads `meta("x")` as-of mapping ENTRY, so the §4.3 guard precondition
   `meta("decode_failed") == "no"` is always false and the guard would never fire (the L2
   lab documents the trap; `blobl` CLI masks it). The chart guard now derives the
   precondition from the `$is_encoded`/`$decoded` lets and coerces `$decoded.string()`
   before `parse_json()` (bytes-typed decode output), matching the lab-proven form.
5. **Sync-latency interaction (master divergence).** Master gained a post-apply
   `cdc_sync_latency_seconds` recording switch. DLQ'd poison no longer errors, so the
   enabled render extends that switch's guard with `meta("dlq") != "yes"` — un-applied
   poison must not record sync latency. Disabled render is untouched (poison throws there,
   `!errored()` already excludes it).
6. **`connect.deadLetter` joins the nats-init Job name hash when enabled (§4.5 fix,
   found in spec review).** The §4.5 claim "the existing subject-reconcile picks up the
   extended subjects" held only via Job TTL reaping: `connect.deadLetter` was not a hash
   input, so an in-place enable within the previous Job's `ttlSecondsAfterFinished`
   window would patch-fail the immutable Job or skip the reconcile, leaving `dlq.cdc.>`
   unbound (fail-safe nack loop — no loss, but the DLQ inert). Enabled now appends the
   deadLetter block to the hash (same only-when-configured rule sharding uses), so the
   disabled hash input — and default render — stay byte-identical while enabling always
   yields a fresh Job.
7. **`cdc_dlq_forwarded` semantics deviate from §4.6, compensated on the dashboard
   (found in quality review).** §4.6 says the counter "increments on successful DLQ
   publish"; the implementation increments at ROUTING time, before the publish — a
   switch-output case cannot count post-write on this build (rules/50-lessons.md
   2026-07-14), so the counter moves in lockstep with `cdc_unprocessable` and cannot
   prove parking. With a misconfigured DLQ (e.g. creds missing the `dlq.cdc.>` pub
   grant) it would keep climbing while poison still loops — false operator confidence.
   The dashboard panel therefore plots it as "routed" alongside
   `output_sent{label="dlq_out"}` ("confirmed parked", PubAck-counted by the output
   itself — label verified present on the pinned build) and
   `output_error{label="dlq_out"}` ("publish failures"): healthy = routed == confirmed,
   failures 0; routed climbing with confirmed flat = DLQ publish failing, poison still
   looping.
8. **Creds regen executed; §4.4's deferral is closed (2026-07-16).** `gen-nats-auth.sh
   --force` was run and the rotated fixtures committed — the subscriber JWT now carries
   the `dlq.cdc.>` pub grant (decoded and verified). The enabled path is proven
   end-to-end in kind by `scripts/verify-dlq-e2e.sh`: fresh install with
   `connect.deadLetter.enabled=true`, verify-cdc happy path green, 5 injected hash
   poisons → exactly 5 on `dlq.cdc.hash_decode_error` with PubAck-confirmed
   `output_sent{label="dlq_out"}`=+5 / `output_error`=0, ack floor +6 (5 poison + 1
   control), zero redeliveries, header contract verified on a parked message. The L1
   merge-base byte-identical check now normalizes creds-derived material (JWT blobs,
   nkeys, the creds-hashed nats-init Job name) since the fixtures legitimately rotate.

## Problem

The reverse (sink) pipeline's authoritative apply switch is deliberately un-wrapped
(`chart/files/connect/cdc-reverse.yaml`, "NOT wrapped — a failure must nack/redeliver").
For `type=hash` create/update, the HSET `args_mapping` calls `meta("body").parse_json()`.
A malformed hash body (verified example: a trailing comma
`{"employee::144000":"5566","employee::155666":"55123",}`) makes `parse_json()` throw:

```
failed to parse value as JSON: invalid character '}' looking for beginning of object key string
```

Consequences today:

1. The throw errors the message → `reject_errored` nacks → with `maxDeliver: -1` it
   **redelivers forever** (poison loop).
2. **No `cdc_unprocessable{reason=...}` counter fires** for this branch (unlike
   `decode_error` and `unknown_op`), so it is an INV-2 gap — a permanent-failure branch
   with no metric.
3. Because JetStream's `ack_floor` is the *contiguous* ack sequence, the stuck message
   **pins the ack floor and head-of-line-blocks** the consumer — the whole group looks
   like "not acking, no errors."

### Provenance (established during investigation)

The malformed body originates from the **upstream stream producer**, not the pipeline and
not the lab writer:

- Source/forward leg reads `body` as raw content (`body_key: body`) and encodes it as
  `content().compress("gzip").encode("base64")` — opaque byte passthrough, no JSON parse
  or re-serialize (`cdc-forward.yaml:75`). It cannot introduce or remove a comma.
- Sink/reverse leg decodes back the identical bytes, then `parse_json()` is the first thing
  that inspects the JSON.
- The lab writer builds hash bodies with `json.Marshal(map[string]string{...})`
  (`internal/writer/payload.go:74`, fields `name`/`tier`/`rev`) — strictly valid JSON,
  never a trailing comma.

So the data fix is upstream. This change makes the poison **visible and non-blocking** on
the sink side (INV-2), and adds an operator-configurable DLQ so poison is parked instead of
looping.

## Goals / Non-goals

**Goals**
- Close the INV-2 gap: `cdc_unprocessable{reason=hash_decode_error}` fires on malformed hash bodies.
- Add an opt-in Dead-Letter Queue: permanently-unprocessable messages are published to a
  configurable subject on the same JetStream stream, then acked (loop stops, ack floor unblocks).
- Preserve at-least-once: nothing is dropped; a message is acked only after its DLQ PubAck
  succeeds (write-then-ack). Transient failures still nack/retry.
- Keep the default install render byte-identical (toggle default off).

**Non-goals**
- Fixing the upstream producer (separate owner).
- A DLQ *consumer*/replayer. The DLQ is a durable parking lot for manual inspection/replay;
  automated redrive is a future follow-up.
- Changing behavior for transient (retryable) apply failures.

## Decisions (locked)

1. **Delivery semantics:** DLQ-publish-then-ack (write-then-ack). Publish to the DLQ subject;
   ack the original only after the DLQ PubAck. If the DLQ publish fails → nack (retry). This
   is the explicit INV-1 sign-off and is why L4 is required.
2. **DLQ subject placement:** a **sibling subject outside `kv.cdc.>`** (default `dlq.cdc`,
   published per-reason as `dlq.cdc.<reason>`), bound as a *second* subject on the same
   `KV_CDC` stream. No sink consumer filters `dlq.*`, so it is never re-consumed in any
   install shape (default, prefix-routed, catchAll).
3. **Scope:** all three permanent-failure reasons route to the DLQ when enabled —
   `decode_error`, `unknown_op`, and the new `hash_decode_error`.
4. **Toggle default:** `connect.deadLetter.enabled: false`. All changes are gated behind it;
   default render stays byte-identical. Enabling activates the guard + counter + DLQ routing
   together.
5. **Per-reason subject tokens** under one configurable base subject; DLQ payload = the
   original NATS envelope; dedup via `Nats-Msg-Id: event_id`.

## Behavior

With `connect.deadLetter.enabled=true`:

| Path | Today | New |
|---|---|---|
| Applied to region Redis (happy) | ack | unchanged — ack |
| Transient apply failure (region Redis down, etc.) | nack → retry | unchanged — nack → retry |
| Permanent poison (`decode_error`, `unknown_op`, `hash_decode_error`) | throw → nack → loop forever | count `cdc_unprocessable{reason}` → publish to `dlq.cdc.<reason>` → ack after PubAck; nack only if DLQ publish fails |

With `connect.deadLetter.enabled=false` (default): the pipeline renders **byte-identical to
today**. The entire feature — hash guard, `hash_decode_error` counter, and DLQ output — is
gated behind the toggle. So when disabled there is no new failure branch: a malformed hash
body behaves exactly as today (throws in the HSET `args_mapping` → nack → loop, uncounted).
The pre-existing INV-2 gap is therefore closed **by enabling the feature**, not in the
disabled path. This is consistent with INV-2: the only *newly added* failure branch
(present only when enabled) ships with its `reason` counter in the same change.

> Byte-identical default is the L1 gate. Because everything is inside
> `{{- if .Values.connect.deadLetter.enabled }}`, the pure-default render (deadLetter off)
> is unchanged; the existing L1 byte-identical render check must still pass untouched.

## Component changes

### 4.1 `chart/values.yaml` — new config under `connect:`

```yaml
connect:
  deadLetter:
    enabled: false          # opt-in; default keeps render byte-identical
    subject: "dlq.cdc"      # base subject; published per-reason as <subject>.<reason>
                            # MUST be outside nats.stream.subjectPrefix (kv.cdc) so no
                            # sink consumer re-consumes it. Bound as a 2nd stream subject.
```

### 4.2 `chart/templates/_helpers.tpl`

- `rrcs.nats.stream.subjects`: when `connect.deadLetter.enabled`, return
  `"<subjectPrefix>.>,<deadLetter.subject>.>"` (e.g. `kv.cdc.>,dlq.cdc.>`); else unchanged
  (`kv.cdc.>`).
- New helper `rrcs.connect.deadLetter.enabled` (bool passthrough) for template gating, plus
  a fail-loud validation that `deadLetter.subject` does **not** start with
  `nats.stream.subjectPrefix` (prevents re-consumption).

### 4.3 `chart/files/connect/cdc-reverse.yaml` — pipeline (INV-1/INV-2 load-bearing)

- **Guard (mapping stage):** for `create/update` + `type=hash`, pre-validate
  `$decoded.parse_json().catch(null)`; set `meta hash_decode_failed = "yes"|"no"`.
  Mirrors the existing `decode_failed` pattern; skip when `decode_failed=="yes"`.
- **Switch:** add branch `check: meta("hash_decode_failed") == "yes"` →
  `metric cdc_unprocessable{reason: hash_decode_error}` → (enabled: set DLQ meta; disabled:
  throw). The existing HSET `args_mapping` can then trust valid JSON.
- **Poison branches** (`decode_error`, `unknown_op`, `hash_decode_error`): when enabled, set
  `meta dlq="yes"`, `meta dlq_reason=<reason>`, and `meta dlq_error` instead of `throw`;
  when disabled, `throw` as today. `dlq_error` is a reason-appropriate string: for
  `unknown_op` include the offending op; for `decode_error`/`hash_decode_error` a static
  description (the guards use `.catch(null)`, so no live parser error string is captured) —
  e.g. `"hash body is not valid JSON"`.
- **Output restructure (gated):**
  - Enabled:
    ```yaml
    output:
      reject_errored:
        switch:
          cases:
            - check: meta("dlq") == "yes"
              output:
                nats_jetstream:
                  urls: [ <nats url> ]
                  auth: { user_credentials_file: <subscriber creds> }
                  subject: '{{ deadLetter.subject }}.${! meta("dlq_reason") }'
                  headers:
                    Nats-Msg-Id: ${! meta("event_id") }     # dedup DLQ republishes
                    dlq_reason:  ${! meta("dlq_reason") }
                    dlq_error:   ${! meta("dlq_error") }
                    dlq_orig_subject: ${! meta("nats_subject") }   # set by the nats_jetstream input
            - output:
                drop: {}
      # cdc_dlq_forwarded{reason} counter increments on the DLQ case's successful send.
    ```
    A DLQ publish failure surfaces as a write error → `reject_errored` nacks → retry
    (write-then-ack). Unprocessable messages are caught by earlier switch branches and never
    reach the redis apply, so `content()` at DLQ time is still the original envelope.
  - Disabled: `reject_errored: { drop: {} }` — byte-identical to today.

### 4.4 `scripts/gen-nats-auth.sh` + `chart/files/nats-auth/`

- Add `--allow-pub '<deadLetter.subject>.>'` (default `dlq.cdc.>`) to the **subscriber**
  user (the sink publishes the DLQ with its subscriber creds).
- Regenerate committed creds (`subscriber.creds`, JWTs). ⚠️ Requires `nsc`; if unavailable in
  the implementation env, this becomes a documented operator step (same footgun class as the
  per-group durable creds at `values.yaml:243`).

### 4.5 `chart/templates/nats-init-job.yaml`

- No logic change: the existing subject-reconcile (`nats stream edit --subjects "$DESIRED_SUBJECTS"`)
  picks up the extended `rrcs.nats.stream.subjects`. Confirm the reconcile path handles the
  two-subject value (comma-joined) correctly.

### 4.6 Observability (INV-2)

- `cdc_unprocessable{reason=hash_decode_error}` — new reason value; existing
  "unprocessable-by-reason" panel + `CDCUnprocessableMessages` alert cover it by label.
- New counter `cdc_dlq_forwarded{reason}` (increments on successful DLQ publish) + a new
  Grafana panel in `chart/files/grafana/cdc-dashboard.json` (INV-2: new metric ⇒ new panel).
- `chart/files/prometheus/cdc-alerts.yaml`: document in the rule header that with DLQ enabled,
  poison increments `cdc_unprocessable` once (then parked) rather than every `ackWait`; the
  alert still fires on new poison. The `increase[...] ≥ 2× ackWait` coupling is unchanged.

## Data flow (enabled)

```
NATS deliver ─▶ decode(base64/gzip) ─▶ hash JSON validate ─▶ op switch
                     │ fail                    │ fail              │ apply ok ─▶ drop ─▶ ACK
                     ▼                          ▼                  │ transient fail ─▶ (error) ─▶ reject_errored ─▶ NACK
              reason=decode_error        reason=hash_decode_error  │
                     └──────────────┬───────────┘                  └─ unknown op ─▶ reason=unknown_op
                                    ▼
                     set dlq meta (no throw)
                                    ▼
                 output switch: nats_jetstream ─▶ dlq.cdc.<reason>
                                    │ PubAck ok ─▶ ACK original + cdc_dlq_forwarded{reason}++
                                    │ PubAck fail ─▶ reject_errored ─▶ NACK (retry)
```

## Testing (per `rules/05-invariants.md`)

- **L1** — `helm lint` + renders:
  - default (`deadLetter` off) byte-identical to master (the existing L1 byte-identical check).
  - `--set connect.deadLetter.enabled=true`: reverse pipeline shows the DLQ output switch;
    `rrcs.nats.stream.subjects` = `kv.cdc.>,dlq.cdc.>`; subscriber grant includes `dlq.cdc.>`;
    fail-loud fires when `deadLetter.subject` starts with `kv.cdc`.
- **INV-2 grep** — `cdc_unprocessable`, `cdc_dlq_forwarded` present in dashboard + alerts.
- **L3** — `verify-cdc.sh` (pipeline behavior unaffected on happy path).
- **L4** — `verify-failover.sh` (**required**: ack/commit semantics change). Plus a new lab
  assertion: inject a malformed hash body, confirm it lands in `dlq.cdc.hash_decode_error`
  (durable, PubAck'd) and the consumer ack floor advances past it (no loop, no head-of-line
  block).

## Rollout / safety notes

- Reader-first, like `bodyEncoding`: the DLQ output and the subscriber pub grant must be in
  place before any producer of poison — but since the DLQ is sink-internal (the sink both
  detects and publishes), enabling is a single sink-side change + stream subject + creds.
- `nsc`-regenerated creds must be committed and pods must remount them before enabling
  (otherwise the DLQ publish is permission-denied — which would nack/retry, i.e. fail safe,
  not lose data).
- INV-1 load-bearing lines edited (rows 7–8 area, output topology): L3 + L4 run and output
  pasted before completion, per the hard safety rules.
