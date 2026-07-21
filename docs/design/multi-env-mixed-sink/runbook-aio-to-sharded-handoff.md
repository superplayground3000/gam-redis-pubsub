# Runbook — AIO→sharded per-env handoff (assert-only mode)

Migrate ONE downstream environment from an all-in-one (AIO) sink — a single whole-segment
durable `cdc_sink_<env>` filtering `kv.cdc.aio.>` — onto a **sharded** sink (per-shard
durables `cdc_sink_<env>_<fam>_s<K>`, each MAP=1, plus per-prefix and catch-all groups)
**without losing or reordering any change**, and without touching the publisher or any other
environment.

Companion to `design.md` §8.3 (normative) and E7, and `implementation-plan.md` P6. The knob is
`connect.sink.handoffAssertOnly` (`chart/values.yaml`), acted on by the **external**
`nats-init` job only (`chart/templates/nats-init-external-job.yaml`). This runbook is
**external-PROD-NATS only** — a bundled release fails render if the flag is set, because
bundled labs rebuild from scratch rather than migrate a live durable.

---

## Read this first — the go-forward-only limitation (R2)

**The handoff gives correct per-key order only for keys modified AFTER the cutover point F0.**
A key whose latest change predates F0 keeps whatever value the AIO region already holds —
possibly misordered, because the AIO sink applied changes unordered (VF-18). The sharded sink
cannot retroactively re-order history it never re-applies.

- If a **possibly-stale-but-consistent-going-forward** region is acceptable, this runbook is
  the path: it is sink-side, needs no forward pause, and no snapshot.
- If you need a **fully-correct** region as of an instant, do NOT use this runbook — snapshot-seed
  the sharded env at F0 instead (`runbook-new-env-bootstrap.md`, the strict `by-time` path). That
  rebuilds every key from a consistent snapshot, so pre-F0 keys are correct too.

State this to the owner before starting. It is the one property the handoff cannot give.

---

## Why an assert-only mode exists (do not skip)

The ordinary external `nats-init` is *create-if-absent*: if a durable is missing it creates one,
defaulting to `--deliver all`. During a handoff that default is a trap. The operator is supposed
to precreate each shard durable at a specific stream position (F0+1); a single typo in a durable
name, or one forgotten precreate, would leave the init to **auto-create that durable at
`--deliver all`** — replaying the entire 72h retained backlog (VF-16) the moment traffic moves,
a creation burst against the shared stream and a flood of stale re-applies into the region.

`handoffAssertOnly: true` removes the create path entirely. For every durable this release
derives, the init:

- **missing** → `exit 1` (never creates — you must precreate it), and
- **present** → runs the ordinary usability checks (PULL, filter, `ack_policy=explicit`,
  `max_deliver`, and `max_ack_pending=1` for shard durables) **plus** asserts
  `deliver_policy == by_start_sequence`, failing loud on anything else. The observed
  `start_seq` is logged for audit (any value is accepted — F0+1 is discovered at runtime, so
  the mode asserts the *policy*, not the exact sequence).

It deliberately does **not** honour `connect.sink.bootstrap.allowStartMismatch` — the mode
exists precisely to catch precreate mistakes, so an escape hatch would defeat it. It is also
mutually exclusive with `bootstrap.deliver` (a handoff release must not also declare a bootstrap
start policy); setting both fails render.

---

## Preconditions

- The sharded env's values are ready (`connect.envId=<env>`, `connect.sharding.families`
  matching the publisher's N, sharded `sinkGroups` covering `{0..N-1, x}` **and** a catch-all
  group **and** a matching prefixed group for every configured publisher prefix — see the F1
  coverage check below). `connect.source.enabled: false`.
- The publisher has `prefixRouting` ON (families enabled), so non-family keys already publish
  under `kv.cdc.aio.<prefix|others>.<op>`. If it does not, that is a forward-side (GLOBAL)
  change — do the first-sharded-env onboarding (§8.2) first; it is not part of this per-env
  handoff.
- You can run `nats` CLI against the external stream with a credential that carries
  `$JS.API.CONSUMER.*` (info + create + delete) grants on the stream.

---

## Steps (each names its observable GATE — do not proceed until it holds)

### 1. Quiesce env A's sink and read F0

Stop only **this env's sink** — the forward leg and every other env keep running.

```sh
# scale the sharded/AIO sink Deployment(s) for this env to 0, or helm upgrade with
# connect.sink.enabled=false on this release only.
```

Wait for a FULL quiesce before reading F0: the sink is down **and** `ackWait` has elapsed
**and** the AIO durable's `num_ack_pending` has reached 0 and is stable. Under
`maxAckPending: 1024`, scaling to 0 drives `num_ack_pending → 0` by ackWait **timeout** — the
in-flight deliveries move back to `num_pending` **UN-applied**. They are not lost: step 3's
`by_start_sequence F0+1` re-delivers all of `(F0, ∞)`, so every timed-out in-flight message is
redelivered to the sharded durables.

Read F0 from the AIO durable's **ack_floor**:

```sh
nats consumer info KV_CDC cdc_sink_<env> --json \
  | jq '{ack_floor: .ack_floor.stream_seq, delivered: .delivered.stream_seq, pending: .num_pending, ack_pending: .num_ack_pending}'
# F0 = ack_floor.stream_seq
```

**Safety rationale (E7 / OC2 correction — this is the load-bearing bit):** `ack_floor.stream_seq`
is the **contiguous APPLIED prefix** — every message up to and including F0 was acked, i.e.
durably applied to the region. Everything `> F0` will be redelivered by the new durables, so
anchoring the new start at **F0+1** loses nothing.

> **NEVER anchor at `delivered.stream_seq` (`max_delivered_seq`).** The delivered head can be
> ahead of the applied floor by exactly the timed-out, un-applied in-flight messages from the
> quiesce. Starting the new durables past those sequences would skip messages that were
> delivered but never acked/applied — a silent INV-1 (at-least-once) breach. The floor, not the
> head, is the only safe anchor.

- **GATE:** the sink is down, `num_ack_pending == 0` and stable across two reads a few ackWaits
  apart, and you have recorded a single integer **F0 = `ack_floor.stream_seq`**. Record it where
  step 3 and step 6's audit can both see it.

### 2. Assert filter coverage (F1) — BEFORE deleting the old AIO durable

The old AIO durable matched `kv.cdc.aio.>` — a superset. The sharded env's filter set must cover
**all** of that traffic, enumerated as **three disjoint classes** (design §3.3 is normative):

| Class | Old AIO durable matched | Sharded env must carry |
|---|---|---|
| (a) Family shards | `kv.cdc.aio.<fam>.s<K>.>` for every K in `0..N-1` **and** the isolation lane `sx` | a shard sinkGroup per shard (durable `cdc_sink_<env>_<fam>_s<K>`) |
| (b) **Prefixed routes** | `kv.cdc.aio.<prefix>.>` for **every configured publisher prefix** | a matching prefixed sinkGroup per prefix |
| (c) Catch-all | `kv.cdc.aio.others.>` (non-family, non-prefixed keys) | a catch-all sinkGroup |

**Class (b) is the trap.** Prefixed routes render as their own DISJOINT durables
(`_helpers.tpl:640-665`) and are **NOT absorbed by the catch-all** `others.>`. A "shards +
catch-all" check that omits the prefixes will pass while silently losing **all** prefixed
traffic (e.g. `kv.cdc.aio.tg.caveat.<op>`) until it expires at 72h. Enumerate the publisher's
configured prefixes and confirm one prefixed group each — OR hold a single explicit superset
wildcard migration filter (`kv.cdc.aio.>`) across the cutover.

Concretely, list the publisher's declared prefixes (from the topology manifest or the publisher
values) and diff against the sharded release's rendered filters:

```sh
# rendered sharded filters this release will assert/precreate:
helm template chart -f <env-sharded-values> -s templates/nats-init-external-job.yaml \
  | grep -oE 'kv\.cdc\.aio\.[^ "]+' | sort -u
# publisher's declared prefixes (must each appear as kv.cdc.aio.<prefix>.> above):
nats kv get cdc_topology current --raw | jq -r '.prefixes[]'
```

- **GATE:** `union(sharded filters) ⊇ {every shard s0..sN-1, sx} ∪ {every configured prefix} ∪
  {others}`. Every class (a)/(b)/(c) is covered. If any prefix is uncovered, STOP and add the
  group — do not delete the old durable.

### 3. Precreate the shard durables at F0+1, then delete the old AIO durable

Precreate **every** durable the sharded release derives, at `by_start_sequence` `F0+1`, MAP=1.
Compute `F0+1` from step 1 (shell: `SSEQ=$((F0+1))`):

```sh
SSEQ=$((F0 + 1))
# one per shard s0..sN-1 and the sx isolation lane, plus each prefixed group and the catch-all —
# use the exact durable names the chart derives (helm template ... | grep 'consumer info'):
for D in cdc_sink_<env>_<fam>_s0 cdc_sink_<env>_<fam>_s1 ... cdc_sink_<env>_<fam>_sx \
         cdc_sink_<env>_<prefix> ... cdc_sink_<env>_others; do
  nats consumer add KV_CDC "$D" \
    --pull \
    --filter '<the exact filter the chart asserts for this durable>' \
    --ack explicit \
    --deliver by_start_sequence --start-sequence "$SSEQ" \
    --replay instant \
    --wait <ackWait> \
    --max-pending 1 \
    --max-deliver=-1 \
    --defaults
done
```

`--max-pending 1` is not optional for shard durables — MAP≠1 lets a redelivery overtake a later
message and breaks per-shard apply order silently (ordering link O-6; the init also asserts this).
Take the exact durable names and filters from the rendered init job so they match byte-for-byte
what assert-only mode will check:

```sh
helm template chart -f <env-sharded-values> --set nats.external.enabled=true \
  --set connect.sink.handoffAssertOnly=true -s templates/nats-init-external-job.yaml \
  | grep -E "consumer info|--filter"
```

Once **all** durables are precreated (and only then, per the F1 gate), delete env A's old AIO
durable so old and new never run concurrently (the AIO `kv.cdc.aio.>` filter is a superset of the
shard subjects):

```sh
nats consumer rm KV_CDC cdc_sink_<env> --force
```

- **GATE:** `nats consumer info KV_CDC cdc_sink_<env>_<fam>_s<K> --json | jq
  '{p:.config.deliver_policy, s:.config.opt_start_seq, mp:.config.max_ack_pending}'` reports
  `{"p":"by_start_sequence","s":<F0+1>,"mp":1}` for **every** derived durable, and
  `nats consumer info KV_CDC cdc_sink_<env>` reports **not found** (the old AIO durable is gone).

### 4. Turn the handoff toggle ON and helm upgrade

Set on this env's values (external NATS):

```yaml
connect:
  envId: <env>
  sink:
    handoffAssertOnly: true    # ON only for this cutover window; turn OFF in step 6
```

`helm upgrade --install`. The external `nats-init` runs as a pre-install/pre-upgrade hook and, in
assert-only mode, **verifies** each precreated durable rather than creating anything. If any
durable is missing or is not `by_start_sequence`, the hook **fails the release closed** — this is
the safety net catching a precreate you missed in step 3.

- **GATE (render, L1):** `helm template chart -f <values> --set connect.sink.handoffAssertOnly=true
  -s templates/nats-init-external-job.yaml` shows, in the ensure-consumer script, the
  `deliver_policy == by_start_sequence` assertion and a MISSING-durable `exit 1`, and **no**
  `nats ... consumer add` call anywhere (the create path is compiled out).
- **GATE (deploy):** the `nats-init-ext` hook Job **completes** (`kubectl get job`). Its log shows,
  for every durable, `[handoff assert-only] ... deliver_policy=by_start_sequence` and
  `start_seq observed = [<F0+1>]`. A hook FAILURE here means a durable is missing or wrong —
  re-check step 3, fix the precreate, and re-run; do not force past it.

### 5. Bring env A's sink up sharded, and verify no gap at the boundary

Scale the sharded sink Deployment(s) back up (or `connect.sink.enabled=true`). Because the old
AIO durable is gone, there is no cross-durable concurrency; boundary re-applies (a message at
exactly F0+... delivered to both the old applied prefix and the new durable) are idempotent
(INV-1 allows duplicates).

- **GATE:** `cdc_apply` on the env's sharded sink increments and each shard durable's `num_pending`
  drains toward 0 as the post-F0 backlog applies. A spot-check of a key changed just after F0 shows
  the region reflecting the post-F0 value.
- **GATE (no reorder):** `cdc_forward_cross_shard_rename` stays 0 and the sx lane shows no
  unexpected traffic (INV-S7); per-shard order holds because every shard durable is MAP=1.

### 6. Turn the handoff toggle OFF

Assert-only mode is a **one-window** switch. Once the handoff is verified (step 5 GATEs hold),
turn it back off and `helm upgrade` again:

```yaml
connect:
  sink:
    handoffAssertOnly: false   # back to create-if-absent for ordinary redeploys
```

Leaving it on would make any future redeploy that legitimately needs a new durable (e.g. adding a
prefixed group) fail closed instead of provisioning it.

- **GATE:** `helm template ... -s templates/nats-init-external-job.yaml` again shows the ordinary
  create path (`nats ... consumer add`) restored, and a normal redeploy's `nats-init-ext` hook
  completes.

---

## Rollback (only BEFORE step 3's delete of the old AIO durable)

While the old AIO durable still exists, the handoff is fully reversible: re-point env A's sink at
the AIO durable (revert the sharded values / scale the AIO sink back up). Idempotent re-applies
absorb anything the aborted sharded durables applied. After the old durable is deleted, rollback
means re-onboarding the env (recreate an AIO durable at F0+1, or snapshot-seed) — plan the delete
as the point of no easy return.

## See also

- `design.md` §8.3 (normative handoff), E7 (safety = ack_floor is the applied prefix), §3.3
  (subject layout / why prefixed routes are disjoint from the catch-all).
- `runbook-new-env-bootstrap.md` — the strict `by-time` snapshot path, and the shared
  start-semantics validation machinery this mode reuses.
- `rules/05-invariants.md` INV-1 (at-least-once — the F0 anchor and boundary-idempotence
  arguments rely on it) and row 13 (shard durable MAP=1).
