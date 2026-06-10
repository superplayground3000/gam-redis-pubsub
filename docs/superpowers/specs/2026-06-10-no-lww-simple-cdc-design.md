# no-lww-simple-cdc — Design

> Kubernetes/Helm fork of `labs/redis-connect-lww-multi-k8s`, with the
> last-write-wins fence **removed**. Demonstrates end-to-end CDC propagation of
> four key operations through a single-source / single-sink Redpanda Connect
> relay, accepting (and visualizing) the stale-overwrite tradeoff that dropping
> the fence implies.

Primary inputs:

- `no-lww-simple-cdc/research-design.md` — the upstream wire/pipeline design
  (the specific spec for this lab; authoritative for the data path).
- `no-lww-simple-cdc/lab-requirements.md` — the lab's functional requirements
  (key patterns, op behaviors, deliverables).

## Property demonstrated

The no-LWW simplified CDC pipeline propagates `create` / `update` / `delete` /
`rename` end-to-end —
`writer → redis-central(Streams) → connect-source → NATS JetStream →
connect-sink → redis-region(KV)` — with **at-least-once** delivery, JetStream
`Nats-Msg-Id` **dedup**, and **idempotent replay**, while showing central- and
region-KV key changes live in a dashboard and an HTML run report.

There is **no version fence**: same-key reordered or late arrivals overwrite
newer values (stale overwrite), and a late `create`/`update` can resurrect a
deleted key. These are *accepted and observed*, never failures (research-design
§7, §10).

## Why this is the right question / single concern

The parent lab (`redis-connect-lww-multi-k8s`) proves an LWW compare-and-set
fence survives inter-pod concurrency. This lab takes the opposite design point:
**what does the same pipeline give you when you deliberately drop the fence and
rely only on op-level idempotency + JetStream dedup?** The one observable
concern is *four-op CDC propagation correctness under at-least-once*, not
throughput and not correctness-under-reorder (there is no correctness claim
under reorder — that is the whole point).

## Topology

Single source pod + single sink pod (requirement: "single redpanda source and
sink"), a simplification from the parent's 3+3 fan-out.

```
writer(s) ── dual write per op ──► redis-central
              │  (1) apply op to central KV (SET / DEL / rename)  ── authoritative intent
              │  (2) XADD app.events  ── CDC envelope (transport)
                                      │
                            connect-source (1 pod)
                                      │ publish subject kv.cdc.<op>
                                      │ header Nats-Msg-Id = event_id
                                      ▼
                              NATS JetStream  (stream KV_CDC, dupe-window)
                                      │ durable pull consumer (cdc_sink)
                            connect-sink (1 pod)
                                      │ switch on meta("op")
                                      ▼
                              redis-region (Redis KV — CDC-materialized mirror)
```

Central Redis holds **both** the materialized KV (the 3 key patterns — the
authoritative *intent of record*, per requirement "a server periodically updates
KV in central Redis") **and** the `app.events` CDC stream. The writer
**dual-writes** each op: it applies the op to the central KV (`SET`/`DEL`/rename)
and emits the matching CDC envelope to `app.events`. Region Redis is the
CDC-materialized mirror produced by the fence-free pipeline.

The dashboard and HTML report compare **central (intent) vs region (no-LWW
result)**: under quiescence they converge; under concurrency their divergence is
the *visible stale-overwrite cost* of dropping the fence. Dual-write atomicity is
not claimed — that looseness is itself part of the no-guarantees story and is
why divergence is observed, never asserted as a failure.

## Components

### Writer (Go, multi-writer, 4 ops, 3 key patterns)

**Dual-write per op** (satisfies requirement "a server periodically updates KV in
central Redis"): for every operation the writer (1) applies it to the **central
Redis KV** — `create`/`update` → `SET kv_key body`, `delete` → `DEL kv_key`,
`rename` → `DEL old_key; SET new_key body` — and (2) emits a CDC envelope to the
`app.events` stream. (1) makes central Redis the authoritative intent of record;
(2) is the CDC transport that drives the region mirror. Atomicity across the two
writes is intentionally not guaranteed (no-LWW ethos).

Emits CDC envelope events via `XADD app.events` per research-design §3. One XADD
entry per CDC event; fields become Redpanda Connect metadata (`body_key=body`):

| field | ops | meaning |
|---|---|---|
| `event_id` | all | producer-minted UUID; the `Nats-Msg-Id` dedup key |
| `op` | all | `create` \| `update` \| `delete` \| `rename` |
| `kv_key` | create/update/delete | target KV key |
| `old_key` | rename | rename source key |
| `new_key` | rename | rename target key |
| `ts` | all | producer event time (epoch ms); observation only (e2e latency) |
| `body` | all (empty for delete) | JSON snapshot; `body_key` points here |

Key patterns (hash-tagged so multi-key rename Lua stays in one Redis slot):

- pattern 1: `lb:company:active:{employees:<id>}`
- pattern 2: `lb:funtions:active:{groups:<id>}`  *(spelling preserved verbatim
  from requirements)*
- pattern 3: `lb:general:active:{items:<id>}`

Op behaviors (from lab-requirements "Key update behavior"):

- **create** — a new group/item/employee → `SET` a new active key.
- **update** — periodic updates to existing keys.
- **delete** — a user is deleted → `DEL` `lb:company:active:{employees:<id>}`.
- **rename (standby→active)** — info added but not enabled: writer first creates
  `lb:company:standby:{employees:<id>}`, then emits a `rename` event
  `old_key=...:standby:{employees:<id>}` → `new_key=...:active:{employees:<id>}`
  carrying the full snapshot. Sink lands it as `DEL old + SET new` (the
  requirement's "a delete followed by set might do the trick"), replay-safe.

**Multi-writer:** multiple writer pods/goroutines may target the same key. With
no fence this is the accepted no-LWW behavior; there is **no shared version
counter and no local version counter** — `event_id` (UUID) is the only minted
identity, used solely for dedup.

Removed from the fork's writer: `version.go` (in-memory per-key monotonic
counter), single-owner-per-key ownership math, and version-stamping of XADD
entries.

### connect-source (`chart/files/connect/cdc-forward.yaml`)

`redis_streams` input on `app.events`, consumer group `cdc_propagator`,
`client_id: ${HOSTNAME}`. Maps envelope fields to metadata, then publishes to
NATS:

- subject = `{{ include "rrcs.nats.stream.publishSubject" . }}`, which resolves
  to `<subjectPrefix>.${! meta("op") }`. **The prefix is not hardcoded** — it is
  `.Values.nats.stream.subjectPrefix` (default `kv.cdc`), reusing the parent's
  helper (changed only from a `pattern` suffix to an `op` suffix). Changing the
  Helm value re-scopes the whole subject namespace.
- header `Nats-Msg-Id: ${! meta("event_id") }` (dedup; requires Connect ≥ 4.1.0)
- forwards `op`/`kv_key`/`old_key`/`new_key`/`ts` as headers/metadata
- `event_id` fallback = `content().hash("sha256").encode("hex")` if producer
  omitted it.

### NATS JetStream

Stream `KV_CDC`, subjects `<subjectPrefix>.>` (default `kv.cdc.>`), file storage,
`duplicate_window` (e.g. 5m), limits retention. Durable pull consumer `cdc_sink`
(filter `<subjectPrefix>.>`, explicit ack, `max_deliver -1`). The subject
namespace is driven entirely by **`.Values.nats.stream.subjectPrefix`** — a
single source of truth shared by: the stream's bound subjects
(`rrcs.nats.stream.subjects`), the source publish subject
(`rrcs.nats.stream.publishSubject`), the sink consumer filter, and the
publisher/subscriber JWT `--allow-pub`/`--allow-sub` grants minted by
`scripts/gen-nats-auth.sh` (so the grants cannot drift from the prefix). Reuses
the parent's nsc/JWT auth fixtures, re-scoped to the new stream/consumer names.

### connect-sink (`chart/files/connect/cdc-reverse.yaml`)

`nats_jetstream` durable pull input → `switch` on `meta("op")`:

- `create` / `update` → `redis SET [kv_key, body]`
- `delete` → `redis DEL [kv_key]`
- `rename` → `redis EVAL` Lua `DEL KEYS[1]; SET KEYS[2], ARGV[1]; return 1`
  (`old_key`, `new_key`, body) — atomic, replay-idempotent. Lua embedded at Helm
  render time via `toJson` from `chart/files/connect/cdc_rename.lua` (same
  pattern the parent uses for `lww_set.lua`).
- unknown op → `mapping` `throw(...)` → errored → nack.

Output `reject_errored: { drop: {} }`: success → ack JetStream; processor
failure → nack → JetStream redelivers after `ack_wait`. Redelivery is absorbed
by SET/DEL/Lua idempotency.

Per-op apply counter exported as a Prometheus `metric` (`cdc_apply_total{op=...}`)
for the dashboard/report. No `lww_apply`/stale/duplicate fence metrics.

### redis-central (KV + Streams) and redis-region (KV)

Two plain Redis instances; values stored as Redis **strings** via `SET` (per
research-design §6.2). **redis-central** holds the authoritative KV (writer
dual-write target) plus the `app.events` CDC stream. **redis-region** holds the
CDC-materialized mirror. Both KVs are read by the dashboard/report for the
central-vs-region comparison; the region KV is the pipeline's output under test.

### Verifier (Go) — the PASS bar

The design is **order-insensitive** (reordering and stale overwrite are
accepted), so the verifier must **not** assert any ordered state sequence or
convergence-under-reorder. It proves the property with three checks that are each
*order-independent by construction* (research-design §11):

1. **Dedup** — push the same `event_id` 5×; JetStream stream `Messages`
   increases by exactly 1 (within `duplicate_window`). Order-independent.
2. **Per-op mechanism under quiescence** — apply **one op at a time**, and after
   each op **wait for pipeline quiescence** (JetStream `num_pending == 0`, source
   PEL drained) *before* asserting. With no concurrency in flight, each op's
   effect is deterministic regardless of pipeline ordering: `create` → key
   present with body; `update` → body replaced; `rename` → old key absent & new
   key present; `delete` → key absent. This tests the **op mechanism**, and makes
   **no ordering claim under concurrent load** — under load, stale overwrite is
   *observed* (central-vs-region divergence), never asserted.
3. **Idempotent replay** — redeliver the sink consumer (reset deliver) after
   quiescence; region KV terminal state is unchanged (`SET`/`DEL`/Lua are all
   idempotent). Order-independent.

Verifier exits 0 only when all three pass. This replaces the docker-compose
`validate_lab.sh` (not applicable — this is a k8s lab, same convention as the
parent's `README` validation note).

### Dashboard (Go, live)

Adapt the fork's Go dashboard: real-time key-change view polling **both** central
and region Redis (the 3 key patterns), side by side, so central-vs-region
divergence is visible live; plus op-rate counters scraped from Connect Prometheus
(`input_received`, `output_sent`, `output_error`, `cdc_apply_total{op}`).
Satisfies "show real time key changes in dashboard."

### HTML report generator

Post-run static HTML visualizing the run: per-op event counts, per-pattern key
counts, **central-vs-region divergence** (keys present in one but not the other,
or differing bodies — the stale-overwrite / delete-resurrection tally), dedup
ratio (PubAck `duplicate=true` rate), and end-to-end latency distribution (from
`ts` vs apply time). Satisfies "a html report generator which can visualize lab
result." Driven by `scripts/gen-report.sh`.

## Scripts

- `scripts/build-images.sh` — local Go binary + image builds (writer, verifier,
  dashboard), `--kind` load. Forked from parent.
- `scripts/insert-msgs.sh` — **forms** `redis-cli XADD` command strings for each
  op (create / update / delete / standby→active rename) and the dedup test, and
  **prints them for the user to copy and run manually**. It does not execute
  them (requirement: "the scripts must just form commands, user need to copy and
  run output commands manually").
- `scripts/verify-cdc.sh` — runs the three-assertion PASS bar; exits 0 on pass.
  The lab's validation entry point.
- `scripts/gen-report.sh` — produces the HTML report.
- `scripts/dashboard-forward.sh` — port-forward the live dashboard (forked).
- `scripts/gen-nats-auth.sh` — regenerate nsc/JWT fixtures on fresh checkout
  (forked; fixtures committed).

## Helm chart

Portable chart forked from the parent, re-scoped:

- Rename `lww-forward.yaml`/`lww-reverse.yaml` → `cdc-forward.yaml`/
  `cdc-reverse.yaml`; replace `lww_set.lua` with `cdc_rename.lua`.
- `connect.source.replicas` / `connect.sink.replicas` default **1** (single
  source + sink).
- values.yaml: `nats.stream.subjectPrefix` (default `kv.cdc`) — the **single
  configurable knob** for the JetStream subject namespace; stream name (`KV_CDC`),
  consumer (`cdc_sink`), `duplicate_window`, key-pattern counts, writer op mix,
  rates. The subject prefix drives the stream subjects, the source publish
  subject, the sink consumer filter, and the JWT grants (see NATS JetStream
  component); changing it + `gen-nats-auth.sh --force` + `helm upgrade` re-scopes
  everything coherently.
- Keep `redis-central` (Streams) + `redis-region` (KV), NATS, connect
  source/sink, writer, verifier, dashboard templates; drop fence-specific
  template wiring.
- No hardcoded cluster assumptions — deployable on different k8s clusters
  (requirement: "portable helm chart").

## Validation strategy

`scripts/verify-cdc.sh` against a `kind` cluster is the definitive validation
(exit 0). The research-lab skill's `validate_lab.sh` (docker-compose) does not
apply — documented in the README exactly as the parent lab documents it. No
throughput or pass numbers are written into docs until an actual validated run
produces them.

## Rejected alternatives

- **Keep the LWW fence / measure throughput-vs-correctness.** Explicitly removed
  from `lab-requirements.md` by the user; out of scope. This lab is the no-fence
  design point.
- **Keyspace-notification-based CDC** (writer just SETs central KV, source
  reads keyspace events). Rejected: research-design specifies an explicit XADD
  envelope (durable, replayable, carries op semantics); keyspace notifications
  are fire-and-forget and lose the `op`/`event_id` contract.
- **3-source / 3-sink fan-out (parent topology).** Dropped per the
  single-source/single-sink requirement; removes the queue-deliver-group and
  headless-Service per-pod metric summing the parent needed.
- **Native Redis `RENAME` for rename op.** Rejected (research-design §6.2): not
  replay-idempotent (second delivery errors when old key is gone). Lua
  `DEL old + SET new(snapshot)` is replay-safe.

## Deliberately excluded

- **Any correctness-under-reorder guarantee.** Stale overwrite and
  delete-resurrection are accepted and observed, not fenced.
- **LWW version fence, CAS, version counters** (the parent's concern).
- **Cross-slot rename** without hash tags (the patterns are all hash-tagged →
  single slot; cross-slot two-step is a research-design caveat, not built here).
- **PEL-reclaim supervisor, DLQ tooling, autoscaling, chaos/pod-kill** —
  research-design ops items; out of scope for the demonstration lab.

## Further reading

- `no-lww-simple-cdc/research-design.md` — wire/pipeline design + ops/monitoring.
- `no-lww-simple-cdc/lab-requirements.md` — functional requirements.
- `labs/redis-connect-lww-multi-k8s/` — the parent (LWW) lab forked here.
