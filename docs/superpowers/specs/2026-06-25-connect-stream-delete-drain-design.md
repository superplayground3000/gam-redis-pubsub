# connect-stream-delete-drain — Design Spec

**Date:** 2026-06-25
**Topic:** Detect message loss when a Redpanda Connect streams-mode pipeline is
deleted (`DELETE /streams/<id>`) mid-flight — the teardown the leader elector
performs on handover.
**Lab:** `labs/connect-stream-delete-drain/` (docker-compose isolation lab)
**Builds on:** `redis-cdc-le-k8s` (leader-election CDC) and its
`internal/elector` handover.

---

## 1. Problem statement

On leader handover the losing leader runs `OnStoppedLeading → DELETE
/streams/source_leg` against its local Redpanda Connect
(`redis-cdc-le-k8s/internal/elector/main.go`). At that instant the pipeline may
hold messages already pulled from the JetStream consumer but not yet written to
region Redis. We must verify whether any such in-flight message is **lost**.

Two distinguishable outcomes for an in-flight message at DELETE time:

- **applied-but-not-acked** → JetStream redelivers after `ack_wait` → re-applied
  by the next stream → **duplicate** (safe, idempotent `SET`). Quantify it.
- **acked-but-not-applied** → gone from JetStream, never reached Redis → **true
  loss**. Fail loudly.

## 2. Property (verbatim, the PASS claim)

> When a Connect streams-mode pipeline bound to a JetStream pull consumer is torn
> down by `DELETE /streams/<id>` while a batch is in-flight, no message is
> acked-without-apply (lost); every in-flight message is either drained-and-
> applied or left un-acked and healed by redelivery.

## 3. Topology

| Service | Image (pinned) | Role | Host port |
|---|---|---|---|
| `nats` | `nats:2.10-alpine` | JetStream durable log + pull consumer | 15422 |
| `redis` | `redis:7.4-alpine` | destination sink | 16379 |
| `connect` | `hpdevelop/connect:4.92.0-claudefix` | streams mode, REST `:4195`, **no stream at boot** | 14195 |
| `controller` | Go multi-stage, non-root | experiment driver + reconciler + verdict | 18080 |

- Named bridge network. All host ports ≥ 15000.
- Every service has a `healthcheck`. `controller` depends on `nats`, `redis`,
  `connect` all `service_healthy`.
- `connect` runs with `--streams` (or equivalent) and an empty config dir so the
  REST API owns the stream lifecycle; healthcheck hits `/ping`.

## 4. Wire contract

- JetStream stream `CDC`, subject `cdc.kv`.
- Durable **pull** consumer `sink`: `ack_wait=${ACK_WAIT}` (default `5s`),
  `max_ack_pending` bounded (e.g. 1000), `ack_policy=explicit`.
- Each message: header `Nats-Msg-Id: <i>` (`i ∈ 1..N`), body `{"i": <i>}`.
- Connect pipeline POSTed by the controller (`application/x-yaml`, the
  Content-Type proven in the k8s lab):
  ```
  input:    nats_jetstream { stream: CDC, durable: sink, bind: true }
  pipeline: threads: ${PIPELINE_THREADS}
            processors: [ sleep { duration: ${SLEEP_MS}ms },
                          redis { command: set,  args: [kv:<i>, i] },
                          redis { command: incr, args: [applied:<i>] } ]
  output:   reject_errored { drop: {} }
  ```
  (`i` comes from the `Nats-Msg-Id` / body via Bloblang `meta`/`this`.)

## 5. Experiment sequence (controller)

1. **Setup** — create stream `CDC` + pull consumer `sink` (idempotent; delete +
   recreate for a clean epoch).
2. **Publish** `N` messages with `Nats-Msg-Id: 1..N` at `PUBLISH_RATE` (0 =
   burst).
3. **POST** stream `source_leg` to `connect`.
4. **Arm & fire** — poll consumer info; when the arm condition holds
   (`deterministic`: `applied:* count >= ARM_FRACTION*N`; `throughput`:
   `num_ack_pending >= ARM_INFLIGHT`), **capture `num_ack_pending` (= inflight at
   delete)**, then `DELETE /streams/source_leg`.
5. **Re-POST** a fresh `source_leg` (new leader) to drain the remainder.
6. **Quiesce** — wait until `num_pending == 0 && num_ack_pending == 0`, stable
   across 3 consecutive polls.
7. **Reconcile** the `applied:*` ledger → verdict JSON, exit 0/1.

## 6. PASS bar (smoke test asserts the property)

Exit 0 iff **all**:

1. **Zero loss** — `∀ i ∈ 1..N: applied:<i> >= 1`. Any `== 0` (drained) → FAIL,
   print lost indices.
2. **Fully drained** — `num_pending == 0 && num_ack_pending == 0`, stable ×3.
3. **DELETE landed mid-flight** — `inflight_at_delete > 0`, else FAIL
   **inconclusive** (no silent pass).

Findings (reported, not failed): `dup_count = Σ(applied:<i> − 1)`, max redelivery
depth. Verdict JSON:
`{profile, n, inflight_at_delete, lost:[...], dup_count, drained, verdict:{pass}}`.

## 7. Config knobs (`.env.example`, all documented)

| Var | deterministic | throughput | Meaning |
|---|---|---|---|
| `PROFILE` | `deterministic` | `throughput` | profile selector |
| `MSG_COUNT` | `200` | `20000` | N messages |
| `PUBLISH_RATE` | `0` (burst) | `5000` | msgs/s |
| `SLEEP_MS` | `500` | `25` | per-msg pipeline sleep (in-flight window) |
| `PIPELINE_THREADS` | `1` | `8` | Connect concurrency |
| `ACK_WAIT` | `5s` | `5s` | redelivery healing window |
| `ARM_FRACTION` | `0.3` | — | fire DELETE after this fraction applied |
| `ARM_INFLIGHT` | — | `200` | fire DELETE at this `num_ack_pending` |
| `MAX_ACK_PENDING` | `1000` | `1000` | consumer bound |

## 8. Failure-loudness by construction

Distinct keys + per-index `INCR` ledger → a lost message is a missing index, not
a silent overwrite. Inconclusive runs (DELETE not mid-flight) fail rather than
pass. Quiescence requires `num_ack_pending == 0` (not just `lag == 0`) — the
exact false-positive the parent lab hit.

## 9. Files (lab layout)

```
labs/connect-stream-delete-drain/
  docker-compose.yml
  .env.example
  README.md
  RESEARCH.md                      # already written
  controller/                      # Go: Dockerfile, main.go, jetstream.go,
                                    #     connect.go (REST), reconcile.go, *_test.go
  connect/                         # empty streams config dir + pipeline template
  scripts/smoke-test.sh            # runs controller, asserts property
```

## 10. Phase 2 (separate, after phase-1 validates) — k8s end-to-end verifier

Carry the conclusion into `redis-cdc-le-k8s`: a new mode/verifier that, during a
**real** leader flip, reconciles writer-emitted vs region-applied vs JetStream
ack state across the handover. Scoped and planned separately once the isolation
lab's drain behavior is known. **Out of scope for the phase-1 plan.**

## 11. Deliberately excluded

Leader-election/k8s (phase 2), ordering guarantees, LWW/CAS fence, eliminating
duplicates (only quantified), the freezable-valve "half-applied" mode (deferred).
