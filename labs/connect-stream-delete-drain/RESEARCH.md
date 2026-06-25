# connect-stream-delete-drain — RESEARCH

## Property demonstrated

When a Redpanda Connect **streams-mode** pipeline bound to a NATS JetStream
**pull** consumer is torn down by `DELETE /streams/<id>` while a batch is
in-flight — already fetched into the pipeline, sleeping, not yet applied to the
destination Redis — **no message is acked-without-apply (lost)**. Every in-flight
message is either drained-and-applied before teardown, or left **un-acked** and
healed by JetStream redelivery to the next stream. This is exactly the teardown
the leader elector performs on handover (`redis-cdc-le-k8s/internal/elector`:
`OnStoppedLeading → DELETE /streams/source_leg`).

The single observable concern is **message conservation across a mid-flight
stream delete** — not throughput, not ordering, not leader-election timing.

## Why this is the right question

The k8s leader-election CDC lab (`redis-cdc-le-k8s`) gates exactly one active
Connect pod by POST/DELETE of a streams-mode stream. On every handover the losing
leader issues `DELETE /streams/source_leg` against its local Connect. The open
question that benchmark does **not** answer: at the instant of that DELETE, what
happens to messages the pipeline had already pulled from the JetStream consumer
but not yet written to region Redis? Two failure modes are possible and must be
distinguished:

1. **applied-but-not-acked** ("處理完沒 ack") → JetStream redelivers after
   `ack_wait` → next stream re-applies → a **duplicate**, absorbed by idempotent
   `SET`. Safe, but a real at-least-once cost worth quantifying.
2. **acked-but-not-applied** ("ack 了但實際沒做完") → the message is gone from
   JetStream (won't redeliver) yet its effect never reached Redis → **true loss**.
   This is the failure we are hunting.

Isolating the property to a single Connect + JetStream + Redis, driven by the
same REST `DELETE`, removes Kubernetes/leader-election from the variables: the
drain-or-drop behavior of `DELETE /streams` is a property of Redpanda Connect, so
we test it directly. (Phase 2 carries the conclusion back into the k8s harness as
an end-to-end handover verifier.)

## Essentials (what is load-bearing)

- **REST lifecycle owned by the controller.** `connect` boots with an empty
  streams API (no static config); the controller `POST`s the stream, fires the
  `DELETE` mid-flight, then `POST`s a fresh stream to act as the new leader and
  drain the remainder — faithful to `internal/elector`.
- **`sleep` processor = the in-flight window.** A per-message `sleep` before the
  Redis write guarantees a known cohort is fetched-but-not-applied when DELETE
  lands. `SLEEP_MS` tunes the window; `deterministic` profile uses a wide window,
  `throughput` a narrow one under a large backlog.
- **Distinct keys + INCR ledger make loss loud.** Each message `i` applies
  `SET kv:<i>` **and** `INCR applied:<i>`. A lost message is then a *missing
  index* (`applied:<i> == 0`), not a silent overwrite — it cannot hide. A
  redelivered message shows `applied:<i> >= 2`.
- **Small `ack_wait`** (default `5s`) so un-acked in-flight messages redeliver
  fast and the run completes quickly; the consumer's `num_pending` /
  `num_ack_pending` are the authoritative ack-state oracle.
- **`reject_errored: drop`** — success acks JetStream; output failure nacks →
  redelivery (absorbed by `SET`/`INCR` idempotency). Mirrors the k8s sink.

## Wire contract

JetStream stream `CDC`, subject `cdc.kv`, durable **pull** consumer `sink` with
`ack_wait`, bounded `max_ack_pending`. Each published message:

- header `Nats-Msg-Id: <i>` (dedup key, `i ∈ 1..N`),
- body `{"i": <i>}`.

Connect pipeline (`jetstream pull input, bind:true → sleep(SLEEP_MS) → redis`):
applies `SET kv:<i> = i` and `INCR applied:<i>`. Controller reconciles the
`applied:*` ledger against `1..N` plus final consumer state.

## Validation strategy (PASS bar)

`scripts/smoke-test.sh` runs the controller, which exits 0 only when **all three**
hold:

1. **Zero loss** — for every `i ∈ 1..N`, `applied:<i> >= 1`. One `== 0` with a
   drained consumer → FAIL, printing the lost indices.
2. **Fully drained** — consumer ends `num_pending == 0 && num_ack_pending == 0`,
   stable across 3 consecutive polls (the parent lab's quiescence lesson: never
   trust a single poll — `lag` drops before the ack lands).
3. **DELETE landed mid-flight** — `num_ack_pending > 0` captured immediately
   before the DELETE, else the test proved nothing → FAIL as **inconclusive** (no
   silent pass).

Reported as findings, not failures: duplicate count `Σ(applied:<i> − 1)` and max
redelivery depth — the quantified at-least-once cost of a mid-flight handover.
Verdict JSON: `{profile, n, inflight_at_delete, lost[], dup_count, drained,
verdict:{pass}}`.

The research-lab skill's `validate_lab.sh` (docker-compose) **does** apply here —
this is a self-contained compose lab. `validate_lab.sh` exit 0 is the gate.

## Design decisions / rejected alternatives

- **`sleep` processor** over a freezable Redis valve proxy: pure Connect config,
  no extra service, deterministic window. The valve would model "apply done
  half-way then killed" more literally but adds a service and control plane for a
  marginal mode; deferred.
- **Real REST `DELETE /streams`** over `SIGKILL`/pod delete: faithful to the
  elector's actual handover action and isolates Connect's *graceful-shutdown*
  semantics from kubelet/container kill semantics.
- **INCR ledger** over relying on final `SET` state: `SET` is idempotent and
  hides duplicates and (via order) some losses; the per-index counter exposes
  both delivery count and gaps.
- **Pull(bind) consumer** over push: matches the k8s lab and gives a server-side
  `ack_wait` / `num_ack_pending` oracle independent of Connect.
- **`throughput` profile as a knob** (not a separate lab): same ledger and PASS
  bar, large `N` + high publish rate + more `pipeline.threads`, DELETE lands mid-
  firehose under real load.

## Deliberately excluded

- **Leader-election / k8s** — phase 2 carries the conclusion into
  `redis-cdc-le-k8s` as an end-to-end handover verifier; this lab isolates the
  Connect DELETE behavior.
- **Ordering guarantees** — `pipeline.threads > 1` may reorder within a batch;
  the property is conservation (every index applied ≥1), not order.
- **LWW / version fence, CAS** — the parent LWW lab's concern; here `SET` is
  intentionally idempotent and order-insensitive.
- **The applied-but-not-acked window beyond counting** — duplicates are observed
  and quantified, not eliminated; eliminating them is not this lab's claim.

## Design — topology

| Service | Image (pinned) | Role | Host port |
|---|---|---|---|
| `nats` | `nats:2.10-alpine` (JetStream) | durable log + pull consumer | 15422 |
| `redis` | `redis:7.4-alpine` | destination sink (region KV) | 16379 |
| `connect` | `hpdevelop/connect:4.92.0-claudefix` | streams mode, REST `:4195`, empty at boot | 14195 |
| `controller` | Go (multi-stage, non-root) | drives experiment + reconciles + verdict | 18080 (health) |

Four service types (controller is also the smoke driver) → per the research-lab
escalation rule, an implementation plan is produced via `writing-plans` before
coding.
