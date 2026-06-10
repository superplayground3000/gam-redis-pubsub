# no-lww-simple-cdc — RESEARCH

## Property demonstrated

The no-LWW simplified CDC pipeline propagates `create` / `update` / `delete` /
`rename` end-to-end —
`writer → redis-central(Streams) → connect-source → NATS JetStream →
connect-sink → redis-region(KV)` — with at-least-once delivery, JetStream
`Nats-Msg-Id` dedup, and idempotent replay, while showing central- and region-KV
key changes live in a dashboard and an HTML run report.

There is **no version fence**: same-key reordered or late arrivals overwrite
newer values (stale overwrite), and a late `create`/`update` can resurrect a
deleted key. These are accepted and observed (central-vs-region divergence),
never failures.

## Why this is the right question

This is a fork of `../redis-connect-lww-multi-k8s`, which proves an LWW
compare-and-set fence survives inter-pod concurrency. This lab takes the opposite
design point: with the fence removed, the only correctness levers are op-level
idempotency (`SET`/`DEL`/`DEL+SET`) and JetStream `Nats-Msg-Id` dedup. The single
observable concern is four-op CDC propagation under at-least-once — not
throughput, not correctness-under-reorder (there is no such claim; that is the
point).

## Essentials (what is load-bearing)

- **Writer dual-writes**: each op is applied to the central KV (authoritative
  intent) and emitted as a CDC envelope to `app.events`. Region KV is the mirror.
- **Single source + sink** (one pod each). No queue deliver-group, no per-pod
  metric summing.
- **Subject namespace is one knob**: `nats.stream.subjectPrefix` (default
  `kv.cdc`) drives the stream subjects, source publish subject (`<prefix>.<op>`),
  sink consumer filter, and the publisher/subscriber JWT grants.
- **Sink switch on `op`**: create/update → `SET`; delete → `DEL`; rename →
  `EVAL cdc_rename.lua` (`DEL old + SET new`, replay-safe); unknown → throw →
  nack. `reject_errored: drop` acks on success, nacks on failure (redelivery
  absorbed by idempotency).

## Wire contract

XADD `app.events` fields (all but `body` become Connect metadata; `body_key=body`):
`event_id` (UUID, dedup key), `op`, `kv_key` | `old_key`+`new_key`, `ts`, `body`.
Source republishes to `kv.cdc.<op>` with header `Nats-Msg-Id: <event_id>`.

## Validation strategy (order-insensitive PASS bar)

`scripts/verify-cdc.sh` runs the Go verifier Job, which proves three
order-independent properties (the design is order-insensitive, so it asserts no
ordered state sequence):

1. **Dedup** — same `event_id` ×5 → JetStream stream `Messages` grows by exactly 1.
2. **Per-op under quiescence** — create→update→rename→delete, one at a time, each
   asserted only after the pipeline quiesces (source group lag 0 + sink pending
   0). No concurrency in flight → each op's effect is deterministic.
3. **Idempotent replay** — a rename re-delivered leaves the region terminal state
   unchanged.

The research-lab skill's `validate_lab.sh` (docker-compose) does not apply — this
is a Kubernetes lab; `verify-cdc.sh` exit 0 is the validation.

## Design decisions / rejected alternatives

- **Central KV first-class (dual write)** over stream-only: lab-requirements
  mandates "a server periodically updates KV in central Redis"; the central KV is
  the intent of record the dashboard compares region against.
- **Explicit XADD envelope** over keyspace notifications: durable, replayable,
  carries `op`/`event_id`.
- **`durable` consumer** (single sink) over the parent's queue deliver-group:
  no multi-pod sharing needed.
- **Lua `DEL+SET` rename** over native `RENAME`: replay-idempotent.

## Deliberately excluded

- Any correctness-under-reorder guarantee (stale overwrite / delete-resurrection
  accepted and observed).
- LWW fence, CAS, version counters (the parent's concern).
- Cross-slot rename (patterns are hash-tagged → single slot).
- PEL-reclaim supervisor, DLQ tooling, autoscaling, chaos.

## Validated result

Validated on a `kind` cluster (`cdc`, namespace `cdc-k8s`, `profile=cdc`),
`scripts/verify-cdc.sh` exit 0. All three order-insensitive checks pass — verbatim
verifier `RESULT_JSON`:

```json
{"cdc":{"epoch":"run-1781068485","dedup_delta":1,"dedup_ok":true,"create_ok":true,"update_ok":true,"rename_ok":true,"delete_ok":true,"ops_ok":true,"replay_ok":true},"verdict":{"pass":true}}
```

- **Dedup:** the same `event_id` ×5 grew the JetStream stream by exactly 1
  (`dedup_delta=1`).
- **Per-op under quiescence:** create→update→rename→delete each materialized
  correctly in region Redis after the pipeline drained.
- **Idempotent replay:** a rename re-delivered left region terminal state
  unchanged.

Under a ~800 msg/s continuous 4-op load (op-mix 40/40/10/10), the writer emitted
create 4160 / update 3950 / delete 970 / rename 970 and the sink applied
create 4167 / update 3957 / delete 973 / rename 979 (`cdc_apply` by op) — full
four-op propagation end to end. Central `lb:*` held 2459 keys vs region's 2466:
the **central-vs-region divergence is real and visible** — the expected, accepted
no-LWW stale-overwrite / delete-resurrection cost under fence-free concurrent
writes, surfaced live in the dashboard and the HTML report.

> Note (quiescence): the verifier's first kind run exposed a false-positive
> quiescence bug — `XINFO GROUPS` `lag` drops to 0 the instant an entry is
> delivered to the source consumer's PEL, before it is published to NATS and
> ACKed, so the per-op assertions raced. Fixed to require `lag==0 AND pending==0`
> (PEL empty) plus sink `MaxPending==0`, stable across consecutive polls.

## Further reading

- `no-lww-simple-cdc/research-design.md` — upstream wire/pipeline design.
- `no-lww-simple-cdc/lab-requirements.md` — functional requirements.
- `../redis-connect-lww-multi-k8s/` — the parent (LWW) lab.
