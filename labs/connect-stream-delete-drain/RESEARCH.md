# Research: Redpanda Connect JetStream pull-consumer drain on stream close

## Topic

Redpanda Connect (`hpdevelop/connect:v4.92.0-batch-nats`) running a `nats_jetstream`
input in **pull-consumer bind mode** as the reverse leg of a CDC pipeline: it fetches
messages from a pre-created durable pull consumer, applies each to a region Redis, and
acks JetStream only on apply success.

## Property demonstrated

Split into a **safety** and a **liveness** claim so each has a causal oracle (Codex review,
axis 1 — count-based completeness alone cannot prove either):

- **(S) No permanent loss under interrupted close.** Under a **one-message-per-key** invariant
  (each key published once, its `event_id` embedded in the applied value), any message
  fetched-but-unapplied when the stream is killed must still be un-acked, so it redelivers and
  eventually applies — every one of the N keys is present *carrying its own message's `event_id`*
  after a `SIGKILL` + restart. Proven causally two ways, **robust to duplicates/redelivery and to
  per-key aliasing** (unlike any aggregate counter invariant): (i) *post-kill identity
  completeness* — all N keys present-with-correct-`event_id` ⟺ nothing was acked-before-applied;
  (ii) *apply-fault injection* — a message whose apply deterministically fails on first delivery
  must redeliver and eventually apply (apply-then-ack) rather than vanish (ack-before-apply).
- **(L) Close is loss-free; drain-on-close is `fetch_batch_size`-bounded (empirically corrected).**
  On a Streams-API `DELETE` (the elector's leadership-loss path) or `SIGTERM`, the build does *not*
  drain the whole in-hand batch: only the message(s) in the pipeline finish; the rest of the
  `fetch_batch_size` prefetch is abandoned **un-acked** and recovered by redelivery. So the
  observable claim is **no loss** — region reaches identity-checked N after re-bind — with a
  **redelivery window ≈ the prefetched in-flight set**. Only at `fetch_batch_size:1` is close
  effectively drain-clean (≤1 redelivered; per-key `applied` all == 1). The lab *demonstrates this
  tradeoff* across `fetch_batch_size` rather than treating redelivery as a failure.

**Proof composition (Codex Q(e) — avoid over-claiming any single experiment).** Experiment 0 +
Controls A/B establish the ordering *mechanism* and validate the harness on the **normal path**
(fault → redeliver → apply for uniquely-identified messages), with no close event. The
**close-path** claims are carried separately: scenario 1 (`DELETE`) proves drain-during-close
(L), and scenario 3 (`SIGKILL`) proves the safety floor (S). Experiment 0 alone is the normal-path
validity anchor — *not* the close-path proof; the two close scenarios complete it.

## Concept summary

- **Pull consumer, explicit ack.** The durable `cdc_sink` is created server-side (`--pull
  --ack explicit`). Connect `bind:true` attaches; `ack_wait` / `max_ack_pending` / `max_deliver`
  are the server's, not the input YAML's.
- **Ordering is apply-then-ack; prove it per-message, not by aggregate counters.** Correct
  Connect commits the Redis apply *then* acks JetStream. Sampling an aggregate `acked ≤ applied`
  is tempting but **unsound under redelivery** (Codex stop-review): JetStream's ack counters are
  delivery-sequence based (`ack_floor` contiguous, `consumer_seq` counts every redelivery) while
  applies are per-key and idempotent, so redelivery/duplicates inflate the two sides
  asymmetrically — able to both mask a real violation and fake a false one. The sound probes are
  per-message: apply-fault injection (does a failed apply nack, or vanish?) and post-kill key
  completeness. `output.reject_errored.drop` maps a processor failure to nack → redelivery,
  absorbed by SET idempotency — exactly what the fault-injection probe exploits.
- **Batch fetch is the risk surface — and the probe cleared it.** The build fetches up to
  `fetch_batch_size` messages per pull (prefetch; `num_ack_pending` jumps to the batch size) and
  applies them one at a time. The feared failure — acking the batch on fetch, so a close drops the
  un-applied-but-acked remainder (permanent loss) — was **tested and ruled out**: the prefetched
  remainder is left **un-acked** on close and redelivers. The residual, benign effect is a
  redelivery window ≈ `fetch_batch_size` on every close, not loss.
- **Stream close is a first-class event.** In streams mode the reverse pipeline is POSTed to
  `/streams/reverse`; the elector `DELETE`s it on leadership loss. A correct build drains
  (finishes + acks in-flight) before teardown. Whether `DELETE` is graceful- or hard-close on
  *this* build is verified during Stage 4, not assumed (Codex axis 4).
- **Redelivery is the at-least-once floor and the drain discriminator.** Un-acked messages
  redeliver after `ack_wait`; a per-key apply counter makes each redelivery/duplicate
  countable per message (not inferred from a global `consumer_seq` delta, which conflates
  first-delivery with redelivery — Codex axis 2/5).

## Wire / API contract

- **NATS JetStream**, TCP `nats://nats:4222` (host `14222`), no auth (lab-local).
  Stream `KV_CDC`, subjects `kv.cdc.*`, file storage. Durable **pull** consumer `cdc_sink`,
  `--ack explicit --deliver all --max-pending <MAX_ACK_PENDING> --wait <ACK_WAIT>`. Created by
  a one-shot `nats-box` init container, mirroring the chart's `nats-init-job`.
- **Publish contract.** Each message: subject `kv.cdc.update`, header `Nats-Msg-Id=<event_id>`
  (JetStream dedup), body = self-contained JSON envelope
  `{"event_id","op":"update","type":"string","kv_key":"kv:<i>","body":"val:<i>:<event_id>"}`.
  **One-message-per-key invariant (Codex re-review ×3):** within a single experiment each key
  `kv:<i>` is published **exactly once**, with a unique `event_id`, and the applied value embeds
  that `event_id`. The harness enforces it at publish (its key→event_id map is injective) and
  verifies it post-run (each region value carries *that key's* event_id). This gives every proof
  **per-message-instance identity**: a key present with the right embedded `event_id` can only
  have come from redelivery/apply of its own original message — never a re-publication or a
  different message aliasing the same key.
- **Connect Streams REST API**, HTTP `connect:4195` (host `14195`):
  - `POST /streams/reverse` — install the reverse pipeline. The **exact POST body is persisted
    as a run artifact** and asserted to contain `threads: 1` (Codex axis 3/6).
  - `DELETE /streams/reverse` — close it; triggers the drain under test. HTTP 2xx is **not**
    treated as drain-complete: the harness then polls until `GET /streams/reverse` is 404 and
    consumer counters settle, under a bounded timeout (Codex axis 4). The production elector
    caps this DELETE at a 5s HTTP timeout — a real interaction the lab records (Codex axis 8).
  - `GET /ready` — 200 even with zero streams (empty-boot).
  Ref: [Redpanda Connect streams mode](https://docs.redpanda.com/redpanda-connect/guides/streams_mode/using_config_files/).
- **Apply contract (reverse pipeline, `threads:1`).** stash envelope — including
  `num_delivered`, sourced from the JetStream **broker** delivery count in the input's
  delivery-count metadata (e.g. the `Nats-Num-Delivered` header), parsed **at message receipt** so
  it reflects a broker delivery *event*, not an internal within-delivery retry counter (Codex Q(c))
  → `sleep SLEEP_MS` (widens the in-flight window) → optional **fault gate** (for keys marked
  `fault:true`, throw while `num_delivered == 1`, so the first delivery nacks and the redelivery
  succeeds; on that first delivery the gate emits `fault-gate fired key=<k> num_delivered=1`,
  making gate evaluation *directly observable*) → **atomic apply**: a single Redis `EVAL` (Lua)
  doing `SET kv_key body` **and** `INCR applied:kv_key` in one transaction — not a pipeline, so the
  counter can never advance without the write and no partial-success can distort `applied:*`; any
  `EVAL` error is a hard processor error (nack), never a silent half-write — and on success emits
  `apply key=<k> num_delivered=<n>` carrying the *same broker-sourced* `<n>`, so a delivery-2 apply
  is provably tied to a second broker delivery → ack. `reject_errored.drop`. The exact
  delivery-count meta key this build's `nats_jetstream` input exposes (e.g. `nats_num_delivered`)
  and its first-delivery value are confirmed in Stage 4 (Control B) before the gate relies on it.
- **Oracle inputs.**
  - Redis: `DBSIZE` over `kv:*`, value compare, and `applied:kv:*` counters (all must == 1 for
    scenario 1; ≥ 1 with recorded duplicates for SIGKILL/redelivery scenarios).
  - JetStream: `nats consumer info KV_CDC cdc_sink --json` → `num_pending`, `num_ack_pending`
    (distinct delivered-unacked — used for **arming**, not as an ordering proof),
    `num_redelivered`, and `ack_floor` / `delivered` (logged as coarse observability only, per
    the ordering caveat above — never gated on). Ref:
    [NATS JetStream consumers](https://docs.nats.io/nats-concepts/jetstream/consumers).

## Design decisions

- **Minimal surface, reverse leg only.** The drain property is entirely on the pull-consumer →
  region path. Central Redis, the forward leg, nsc auth, and HA electors are excluded (they add
  nothing and obscure the signal). The Go `harness publish` substitutes for the forward leg.
- **Version pinned: `hpdevelop/connect:v4.92.0-batch-nats`** — the exact build under test and
  the *unknown*: the lab makes no assumption about its fetch/ack semantics and is built to fail
  loudly (via apply-fault injection + post-kill identity completeness) if it acks-before-apply.
  Support images pinned:
  `nats:2.10-alpine`, `redis:7.4-alpine`, `natsio/nats-box:0.14.5`.
- **Streams mode (empty boot) + POST/DELETE**, not `connect -c file.yaml`, so scenario 1
  reproduces the elector's real `DELETE /streams/reverse` path — not a proxy for it.
- **Per-message causal proofs, not an aggregate invariant (Codex CRITICAL #1 + stop-review).**
  The ordering claim rests on two duplicate/redelivery-robust experiments: (a) **apply-fault
  injection** — a marked subset F deterministically fails its Redis apply on first delivery; an
  apply-then-ack build nacks→redelivers→eventually applies F (F ends present, `applied:F ≥ 2`),
  while an ack-before-apply build acks the fetched-but-failed F so it never redelivers and ends
  **permanently missing** — a per-key presence signal immune to counter arithmetic; and (b)
  **post-kill completeness** (SIGKILL scenario). The aggregate `acked ≤ applied` sampler is kept
  only as coarse, non-gating observability because it is unsound under redelivery.
- **Preflight validity gate — isolated positive controls make experiment 0 self-proving (Codex
  re-review ×2).** Experiment 0's proof is conditional on four runtime facts; the smoke test
  enforces them **in-run** on a *quiescent, single-key* stream (no other traffic, so no unrelated
  redelivery can satisfy a control) and aborts loud if any fails:
  - **Control A — faulted messages are not drop-and-acked (precond #3, the causal hinge).**
    Publish exactly ONE always-faulting key `ctrlA` to an empty stream. Within a bounded
    `2×ACK_WAIT` window, assert `ctrlA` is *absent from region while faulting* AND its own
    stream-seq is redelivered. This proves exactly what experiment 0 needs — a faulted message is
    **not acked/dropped before apply; it is redelivered.** To also pin the *mechanism* (explicit
    nack vs `ack_wait` timeout — Codex Q1), the harness also records the
    `$JS.EVENT.ADVISORY.CONSUMER.MSG_NAKED` advisory for ctrlA's stream-seq as **corroborating
    observability only** — the design does *not* assert this advisory is exclusive to an explicit
    nack, so no mechanism claim rests on it. The gating verdict is the not-drop-and-acked-but-
    redelivered claim above, which is sound on its own. If
    `ctrlA` is instead dropped-and-acked (stream-seq acked, region absent, no redelivery within
    the window), experiment 0 is invalid ⇒ abort. Verdict declared only *after* the timeout.
  - **Control B — gate fires on delivery 1, apply tied to a distinct delivery 2 (precond #2).**
    Publish ONE fault-on-first-delivery key `ctrlB` to an empty stream. Assert (i) a
    `fault-gate fired key=ctrlB num_delivered=1` log line AND (ii) a *distinct*
    `apply key=ctrlB num_delivered=2` log line — the successful apply is bound to a **second
    delivery event**, excluding a within-delivery retry that could apply twice on logical
    delivery 1 (Codex Q2) — and (iii) `ctrlB` ends present with `applied:ctrlB == 2` carrying
    ctrlB's own `event_id`. A missing delivery-1 line, `applied==1`, or two applies without a
    delivery-2 line ⇒ meta wrong / within-delivery double-apply / gate misfired ⇒ abort.
  - **Config gate (precond #1), secondary.** `GET /streams/reverse` is asserted to contain
    `threads: 1` + fault gate + apply-`EVAL`. Because some Connect builds may return a stored
    template rather than the live effective graph, this is a *secondary* check — Controls A/B are
    the *primary* behavioral evidence that the gate and counter actually execute. Whether GET
    returns the live config on this build is a recorded Stage-4 probe.
  - **Atomic write+counter (precond #4).** The apply is a single Lua `EVAL` (`SET` + `INCR` in one
    transaction), so partial success cannot distort `applied:*` and the counter never advances
    without the write.
  Experiments 0/1/2/3 are trusted only after Controls A and B pass.
- **Deterministic arming (Codex CRITICAL #2).** Triggers fire only when JetStream
  `num_ack_pending ≥ ARM_INFLIGHT` (an externally verifiable non-empty in-flight set), and the
  value at the trigger instant is recorded. If it is 0/undersized, the run is reported
  **inconclusive**, never pass — closing the "trivial no-op close" hole. `threads:1 + sleep
  SLEEP_MS` plus a burst publish create and hold that window; `fetch_batch_size` prefetch makes the
  in-flight set large, and arming gates on real consumer state (`num_ack_pending`), not apply
  progress.
- **`fetch_batch_size` is the central lab parameter (probe-confirmed).** `.env` `FETCH_BATCH_SIZE`
  maps to the input's `fetch_batch_size` (default 10). The lab sweeps it (e.g. 1 / 16 / 256): it
  governs the un-acked-on-close window and thus the redelivery blip on every close/failover. `1` =
  drain-clean-on-close; large = throughput at the cost of a bigger redelivery replay. **No setting
  loses messages** — abandoned in-flight is always un-acked, never acked-before-apply.
- **Close is non-blocking + non-draining; recovery is re-bind→redelivery (probe-corrected, was
  Codex CRITICAL #3).** `DELETE` returns in ~0.4s without draining, and `SIGTERM` exits ~0.6s
  without draining the prefetch buffer. So the barrier is *not* "wait for drain": after `DELETE`,
  poll `GET /streams/reverse == 404` (close done), record the abandoned `num_ack_pending`, then
  **re-POST** the stream and wait until `num_ack_pending → 0` (redelivery drained by the re-bound
  consumer) before the identity oracle. "Loss" = a key permanently missing/identity-mismatched
  after re-bind; it is never conflated with "still redelivering."
- **Computed drain bound with a concrete margin (Codex HIGH #4, re-review ×6) — applies to the
  `fetch_batch_size:1` drain-clean regime.** In that regime (and only there) scenario 1 also
  asserts region reaches N within
  `bound = (inflight_at_trigger × SLEEP_MS / threads) + margin`, where
  **`margin = max(2 × SLEEP_MS, 500ms)`** — a fixed allowance for per-op Redis apply latency and
  scheduler jitter, floored so a correct build cannot spuriously fail on a tight tolerance. The
  bound is derived from the recorded pre-close in-flight count, with exact `DELETE`-send,
  first-apply, first-redelivery, and completion timestamps logged per run. Two guards remove the
  residual ambiguity: (i) the *primary* drain-vs-redelivery discriminator is the counter, not the
  clock — `applied:*==1` already means zero redelivery (a redelivery makes `applied ≥ 2`), so a
  non-draining build cannot pass merely by waiting long enough; (ii) the harness requires
  `bound < ACK_WAIT` — if the armed in-flight set makes `bound ≥ ACK_WAIT` the timing can no
  longer separate a genuine drain from a first redelivery, so the run is reported
  **MISCONFIGURED** (raise `ACK_WAIT` or lower `ARM_INFLIGHT` / `SLEEP_MS`), never a silent
  pass/fail.
- **Per-key apply counter for redelivery/duplicate (Codex HIGH #5, MEDIUM #7).** `applied:kv:i`
  makes each apply countable per message. Scenario 1 asserts all == 1 (drained, no redelivery,
  no duplicate); SIGKILL/redelivery scenarios record duplicates as expected at-least-once cost.
  Replaces the non-robust `consumer_seq` delta.
- **Persist POST body, assert `threads:1`, document divergence (Codex HIGH #6).** The chart's
  `cdc-reverse.yaml` runs `threads:4` for throughput; the lab POSTs a `threads:1` variant to
  make arming/drain timing deterministic. This divergence is deliberate and recorded in the run
  artifact; `PIPELINE_THREADS` is parameterized so a `threads:4` confirmatory run can check the
  property under concurrent apply too.
- **Count-based, create/update only (Codex LOW #9 — sound).** N distinct keys `kv:1..kv:N`
  removes no-LWW last-write ambiguity and keeps final-state verification crisp. It sharpens
  end-state detection; the causal oracle above supplies the ordering evidence it cannot.
- **Four experiments, escalating severity.**
  0. **Apply-fault injection (ordering proof, no close).** Mark subset F (e.g. every 10th key) to
     fail its Redis apply on first delivery. Under one-message-per-key, assert every F key ends
     **present with its own `event_id` embedded** and `applied:F == 2` (its single message nacked
     once, redelivered, applied — exactly twice, tied to two deliveries per the Control-B log
     pattern). A missing F key, or one whose value carries the *wrong* `event_id`, is a direct
     ack-before-apply verdict — immune to duplicate/redelivery counter distortion and to same-key
     aliasing (there is no second message for the key).
  1. **Streams `DELETE`** — *liveness (L)*: armed on `num_ack_pending ≥ ARM_INFLIGHT`, **swept over
     `fetch_batch_size`**. Assert **no loss**: after re-POST/re-bind, region reaches identity-checked
     N (every key present carrying its own `event_id`). Measure the **redelivery window**
     (Σ `applied:* − N`, expected ≈ prefetched in-flight): ~0 at `fetch_batch_size:1` (drain-clean),
     growing with the batch — *demonstrating* the tradeoff, not failing on it. An ack-before-apply
     build instead ends region `< N` (identity gap) — the hard failure. (Empirically this build is
     loss-free; the strict "zero-redelivery drain" only holds at `fetch_batch_size:1`.)
  2. **`SIGTERM`** — `docker kill -s TERM`, restart, re-POST: process graceful drain; region
     eventually N (identity-checked); redeliveries tolerated but counted per key.
  3. **`SIGKILL`** (control, *safety (S)*) — armed the same way, `docker kill -s KILL`, restart:
     assert every one of the N keys is present **carrying its own message's `event_id`** (not just
     `DBSIZE==N`). Under one-message-per-key a key can be present-with-correct-identity *only* via
     redelivery/apply of its unique original message, so a lost acked-before-applied message
     cannot be masked by a different un-acked message recreating the same key (Codex Q4). With no
     drain possible, reaching full identity-checked N is *only* possible if un-applied msgs were
     un-acked — a direct causal proof of apply-then-ack. Any shortfall or identity mismatch
     indicts ack-before-apply.
- **Worst-case drain sub-check (Codex MEDIUM #8).** One run sizes the in-flight set so drain
  plausibly exceeds 5s, to observe whether the elector's 5s DELETE timeout truncates the drain
  and how the build behaves — recorded as a production-relevant finding.
- **Host-orchestrated triggers.** `docker kill -s TERM|KILL` and the Streams `DELETE` are driven
  by `scripts/smoke-test.sh` on the host (a container can't signal a sibling cleanly); the
  in-container Go `harness` owns publish / probe / monitor / verify.
- **Deliberately excluded:** forward leg & central Redis (off the drain path); delete/rename ops
  (parity ambiguity; count-based create/update is unambiguous); HA/leader election (single
  consumer isolates drain; multi-pod double-consume is a different property); gzip/base64 body
  transport (orthogonal; bodies here are short ASCII so encoding can't mask loss); persistence
  across `docker compose down` (each run starts clean).

## Review outcomes (Codex, 2026-07-02)

All nine findings plus the stop-time follow-up folded in above. Status:
- CRITICAL #1 (oracle can't prove ordering) → **resolved** by per-message apply-fault injection
  (experiment 0) + post-kill completeness; the aggregate `acked ≤ applied` monitor was demoted to
  non-gating observability.
- STOP-REVIEW (aggregate `acked ≤ applied` still unsound under duplicate/redelivery) →
  **resolved** by that demotion and by making apply-fault injection the ordering proof: a per-key
  presence test that redelivery can only satisfy, never mask.
- RE-REVIEW (experiment 0's proof is conditional on 4 unverified runtime facts — real posted
  config, delivery-count meta key, throw⇒nack-not-drop, INCR-in-same-path) → **resolved** by the
  Preflight validity gate above: the four preconditions are now in-run positive controls that
  abort loud, so experiment 0 can only "pass" after its own validity is demonstrated in the same
  run. This converts Codex's runtime-validity gap into a self-checking property.
- RE-REVIEW ×2 (the controls could pass for wrong reasons — a control satisfied by *unrelated*
  redelivery, gate-firing *inferred* not observed, non-atomic pipeline skewing `applied:*`,
  unbounded timing windows) → **resolved** by making both controls single-key and isolated on a
  quiescent stream, bounding verdicts to `2×ACK_WAIT`, emitting a direct gate-decision log line on
  delivery 1, and making the write+counter one atomic Lua `EVAL`. The `GET` config check is
  demoted to secondary because a build may return a template, not the live graph; Controls A/B are
  the primary behavioral evidence.
- RE-REVIEW ×3 (per-key/per-counter oracle overclaims vs per-message-instance identity: Q1 nack
  vs timeout-redelivery, Q2 within-delivery double-apply, Q3 F-key presence via a different
  message, Q4 SIGKILL N reached via a different message aliasing a lost key) → **resolved** by one
  unifying invariant: **one message per key with its `event_id` embedded in the applied value**,
  enforced at publish and identity-verified post-run, plus delivery-event anchors (Control A narrows
  its claim to not-drop-and-acked and adds the `MSG_NAKED` advisory; Control B binds the apply to a
  distinct delivery-2 log line). Every presence assertion is now per-message-instance, so no proof
  can be satisfied by a causally unrelated path.
- RE-REVIEW ×4 ((b) MSG_NAKED over-claimed as explicit-nack proof; (c) Control B `num_delivered=2`
  source field left implicit; (e) risk of framing experiment 0 as the whole close-path proof) →
  **resolved**: the `MSG_NAKED` advisory is demoted to corroborating observability with no
  mechanism claim resting on it; `num_delivered` is explicitly sourced from the JetStream broker
  delivery count (`Nats-Num-Delivered`) parsed at receipt and carried to both the gate and apply
  log lines, so a delivery-2 apply is tied to a real second broker delivery, not a within-delivery
  retry; and a "Proof composition" note fixes experiment 0 as the *normal-path anchor* with
  scenarios 1/3 carrying the close-path proof. (a) one-message-per-key and (d) atomicity/barriers
  confirmed **sound** by the reviewer.
- RE-REVIEW ×5 (internal contradiction: `acked ≤ applied` declared non-gating observability yet
  reused as a scenario-1/2 pass condition — "never violated" / "holds") → **resolved** by removing
  it from every scenario pass condition (scenario 1 now gates on identity-checked N + `applied:*==1`;
  scenario 2 on identity-checked N) and fixing the one remaining prose that credited it with the
  loud-fail role (now: apply-fault injection + post-kill identity completeness). `acked ≤ applied`
  survives only in the explicitly non-gating observability role. Reviewer confirmed rounds-1–3
  fixes correctly reflected.
- PROBE (Stage-4 empirical, 2026-07-02 — see `PROBE-FINDINGS.md`) → the design's one assumption
  that survived review (that `DELETE` drains) was **falsified**: neither `DELETE` nor `SIGTERM`
  drains the `fetch_batch_size` prefetch; the remainder is abandoned un-acked and redelivered (no
  loss). Folded in: (L) reframed to loss-free-with-`fetch_batch_size`-bounded-redelivery, scenario 1
  now sweeps `fetch_batch_size` and asserts identity-N-after-rebind (drain bound scoped to fb=1),
  the drain barrier became a re-bind→redelivery barrier, and `fetch_batch_size`/`nats_num_delivered`
  are confirmed. Confirms the core claim: **the build never acks-before-apply → no msg loss.**
- RE-REVIEW ×6 (scenario-1 drain bound `margin` unspecified — too tight ⇒ spurious fail, too loose
  ⇒ non-draining build passes) → **resolved** by fixing `margin = max(2×SLEEP_MS, 500ms)`, keeping
  the `applied:*==1` counter as the primary drain-vs-redelivery discriminator (a non-draining build
  can't pass by waiting), and adding a `bound < ACK_WAIT` precondition that reports MISCONFIGURED
  rather than a silent verdict when timing can't discriminate. Reviewer confirmed (checks 1/3/4) the
  rest of the file passes an adversarial full-file scan with no other holes.
- CRITICAL #2 (arming race / trivial pass) → **resolved** by arming on `num_ack_pending`, inconclusive-on-empty.
- CRITICAL #3 (DELETE drain semantics unverified) → **resolved** by drain-completion barrier + Stage-4 doc/canary confirmation.
- HIGH #4 (≪ ack_wait vague) → **resolved** by computed drain bound + timestamped events.
- HIGH #5 (consumer_seq conflation) → **resolved** by per-key apply counter.
- HIGH #6 (threads:1 vs chart threads:4) → **resolved** by persisting the POST body + assert + documented divergence.
- MEDIUM #7 (duplicate-apply hidden) → **resolved** by the same per-key counter.
- MEDIUM #8 (elector 5s timeout vs drain) → **deferred to a recorded sub-check**, not a blocker.
- LOW #9 (create/update-only sound) → kept.

**Stage-4 probe results (2026-07-02) — see `PROBE-FINDINGS.md`.** The empirical unknowns are now
resolved against `hpdevelop/connect:v4.92.0-batch-nats`:
- Delivery-count meta key = **`nats_num_delivered`** (Control B key confirmed).
- `throw` under `reject_errored.drop` ⇒ **nack ⇒ redelivery** (Control A hinge confirmed; explicit
  nack redelivers *immediately* with no `ack_wait` backoff, so an always-fault msg hot-loops —
  Control A is bounded/purged accordingly).
- Input batch knob = **`fetch_batch_size`** (default 10) on the `nats_jetstream` input — this *is*
  the "batch-nats" feature.
- **`DELETE /streams/{id}` does NOT drain** — it returns in ~0.4s (non-blocking) and abandons the
  prefetched in-flight set **un-acked** (recovered by redelivery on re-bind ⇒ no loss). **`SIGTERM`
  likewise does not drain** the prefetch buffer (exits ~0.6s despite `shutdown_timeout:20s`). The
  un-acked-on-close window ≈ `fetch_batch_size` (fb=1 ⇒ ~1 abandoned / drain-clean; fb=256 ⇒ ~23).
  This **corrects the earlier assumption that `DELETE` drains** — see the revised (L) claim and
  scenario 1. It also makes the elector's 5s DELETE HTTP timeout (Codex #8) a non-issue: `DELETE`
  never blocks on a drain, so there is nothing for the timeout to truncate.

## References

- [Redpanda Connect — streams mode / REST API](https://docs.redpanda.com/redpanda-connect/guides/streams_mode/using_config_files/)
- [Redpanda Connect — `nats_jetstream` input](https://docs.redpanda.com/redpanda-connect/components/inputs/nats_jetstream/)
- [NATS JetStream — consumers (pull, ack, ack_wait, max_ack_pending)](https://docs.nats.io/nats-concepts/jetstream/consumers)
- Chart reverse pipeline: `redis-cdc-le-k8s/chart/files/connect/cdc-reverse.yaml`
- Chart consumer creation: `redis-cdc-le-k8s/chart/templates/nats-init-job.yaml`
- Elector DELETE path (+5s HTTP timeout): `redis-cdc-le-k8s/internal/elector/streams.go`
- Prior half-started design: `labs/connect-stream-delete-drain/.env`
