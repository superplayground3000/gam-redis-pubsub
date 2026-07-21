# Chart examples

Worked, commit-safe `values.yaml` overlays for the trickier parts of the CDC
chart. Each file is heavily commented — read it top to bottom and you get both the
"what" and the "why" of the configuration, not just the keys. None of them contain
real credentials; anything sensitive is a clearly-marked placeholder you replace.

Use an example by passing it to `helm` with `-f`:

```bash
helm upgrade --install rrcs ./chart -n rrcs-k8s --create-namespace \
  -f chart/examples/<example-file>.yaml
```

## What each example shows

### `values-sharding.yaml` — per-key subject sharding (subject-sharding v2)

Splits one high-volume Redis key family across many NATS shard lanes so multiple
sinks apply different entities in parallel, while every key for a given entity
still applies in strict order. Shows a sharded `lp:m2g` family (8 shards + the
`sx` isolation lane) running side by side with non-sharded prefix groups and a
catch-all, plus the credential and DLQ-incompatibility notes.

- **Try it:**
  ```bash
  helm upgrade --install rrcs ./chart -n rrcs-k8s --create-namespace \
    -f chart/examples/values-sharding.yaml
  ```
- **Render check (L1, seconds):**
  ```bash
  helm template chart/ -f chart/examples/values-sharding.yaml >/dev/null
  ```
- **Proven by (L3 kind e2e, ~5 min):**
  ```bash
  RRCS_NS=cdc-shard RRCS_RELEASE=cdcsh scripts/verify-sharding.sh
  ```
  Asserts every shard durable exists with `max_ack_pending==1`, keys route by
  id-mod-N, interleaved updates to one entity apply in source order, and the `sx`
  isolation lane applies unparseable keys instead of dropping them.
- **Design reference:** `docs/design/subject-sharding/design.md` (spec) and
  `docs/design/subject-sharding/cutover.md` (re-sharding a live family).

### `values-dlq.yaml` — opt-in Dead-Letter Queue on the sink leg

Turns on the DLQ so a poison message that can NEVER be applied (undecodable body,
unknown op, or a hash body that is not a valid JSON object) is re-published to a
sibling subject on the same JetStream stream and then acked, instead of nacking
and head-of-line-blocking every message behind it forever. Shows the subject
naming (`dlq.cdc.<reason>`), the stream/consumer expectations, which credentials
carry the publish grant, and which Grafana panel confirms parking.

- **Try it:**
  ```bash
  helm upgrade --install rrcs ./chart -n rrcs-k8s --create-namespace \
    -f chart/examples/values-dlq.yaml
  ```
- **Render check (L1, seconds):**
  ```bash
  helm template chart/ -f chart/examples/values-dlq.yaml >/dev/null
  ```
- **Proven by (L3 kind e2e, ~5 min):**
  ```bash
  RRCS_NS=cdc-dlq RRCS_RELEASE=cdc-dlq scripts/verify-dlq-e2e.sh
  ```
  Asserts N poison bodies park on `dlq.cdc.hash_decode_error`, the ack floor
  advances, no redelivery loop forms, and a normal message injected afterward
  still reaches region Redis.
- **Confirm in Grafana:** panel 18, "DLQ: routed vs confirmed parked" — healthy is
  `routed == confirmed parked` with `publish failures` at 0. See the observability
  note inside the example for how to read a stuck DLQ.
- **Full operator/maintainer guide:** `docs/dlq.md` (rationale, rollout incl. the
  pre-2026-07-16 creds caution, failure modes, and per-claim source citations).
- **In-prefix alternative:** if your stream prefix is externally fixed and the DLQ
  cannot live outside it, see `values-shared-prefix-aio.yaml` below.

### `values-shared-prefix-aio.yaml` — opt-in shared-prefix segment layout (in-prefix DLQ)

The PROD-shaped alternative to `values-dlq.yaml` for the one case the default
out-of-prefix DLQ cannot serve: a JetStream stream whose subject prefix is
externally FIXED at `kv.cdc` (bound `kv.cdc.>`, not re-bindable), where a DLQ at
`dlq.cdc.>` is unbindable. It separates normal and dead-letter traffic on the
*second* subject segment instead — normal `kv.cdc.aio.<op>`, DLQ
`kv.cdc.dlq.<reason>`, stream binding unchanged at `kv.cdc.>` — via
`nats.stream.normalSegment` + `connect.deadLetter.segment`, composed with the
all-in-one sink preset. The default out-of-prefix layout stays the default; this is
opt-in. Shows the render guards (N1–N6), the two-phase zero-loss migration from a
legacy install, and the external-NATS operator step (edit the durable filter,
because the external init job never mutates user-owned consumers).

- **Try it (bundled NATS):**
  ```bash
  helm upgrade --install rrcs ./chart -n rrcs-k8s --create-namespace \
    -f chart/examples/values-shared-prefix-aio.yaml
  ```
- **Render check (L1, seconds):**
  ```bash
  helm template chart/ -f chart/examples/values-shared-prefix-aio.yaml >/dev/null
  ```
- **Proven by (L3 kind e2e):** the parameterised `scripts/verify-dlq-e2e.sh` run in
  segment mode (`normalSegment=aio` / `segment=dlq`) — poison on
  `kv.cdc.dlq.<reason>`, normal traffic on `kv.cdc.aio.*`, sink filter `kv.cdc.aio.>`.
- **Full guide:** `docs/dlq.md` §10 and
  `docs/superpowers/plans/2026-07-20-shared-prefix-subject-layout.md`.

### `values-publisher.yaml` — a PUBLISHER release (forward leg only)

The source-only half of the multi-env mixed-sink split
(`docs/design/multi-env-mixed-sink`): exactly ONE publisher release owns the
forward leg (central Redis → NATS) and binds no sink consumer, applies to no region
Redis, and parks nothing (`deadLetter.enabled=false`, explicit). One shared stream
is fanned out server-side to many downstream sink-only envs, so a publisher never
does N publishes — it publishes once and JetStream copies it to each env's durable.
Includes the P0 caveat: declaring sharding families on a publisher does NOT render
until P3 (the shard-coverage guard needs an enabled sink group), so the family
block is left commented out with the reason.

- **Try it (bundled NATS):**
  ```bash
  helm upgrade --install rrcs-pub ./chart -n rrcs-pub --create-namespace \
    -f chart/examples/values-publisher.yaml
  ```
- **Render check (L1, seconds):**
  ```bash
  helm template chart/ -f chart/examples/values-publisher.yaml >/dev/null
  ```
- **Pairs with:** `values-sink-only.yaml` (the downstream env half).

### `values-sink-only.yaml` — a SINK-ONLY release (one env, env-scoped)

The sink half of the split: one downstream environment that binds an env-scoped
durable on the shared stream and applies to its OWN region Redis, publishing
nothing. Shows `connect.envId` — the single knob that scopes this env's durable
base (`cdc_sink_enva`), DLQ lane and dedup msg-id (`dlq.cdc.enva.<reason>` /
`dlq.enva.<event_id>`), the `resourcePrefix` default (`enva-`), and the Prometheus
`env` label — so many sink envs share one stream without colliding on a single ack
floor. Notes the DNS-1123 grammar and the immutability warning (renaming envId
mints a fresh durable and strands the old DLQ lane).

- **Try it (bundled NATS, one release per env):**
  ```bash
  helm upgrade --install rrcs-enva ./chart -n rrcs-enva --create-namespace \
    -f chart/examples/values-sink-only.yaml
  ```
- **Render check (L1, seconds):**
  ```bash
  helm template chart/ -f chart/examples/values-sink-only.yaml >/dev/null
  ```
- **Pairs with:** `values-publisher.yaml` (the forward-leg half).

## Untested / unsupported combinations

- **Sharding + DLQ together is a hard error, by design.** Setting
  `connect.deadLetter.enabled=true` while `connect.sharding.families` is configured
  makes the chart FAIL to render, because the sharded sink pipeline has no DLQ
  routing yet and a mixed topology would be silently half-protected. Use
  `values-sharding.yaml` OR `values-dlq.yaml`, never both at once. Combined DLQ +
  sharding support is a documented follow-up.
- **External NATS with either example** is not exercised by the verify scripts
  above (they use bundled NATS). The examples include commented external-NATS
  blocks with placeholder Secret names; validate them in staging, and make sure
  external subscriber creds carry the grants each feature needs (the DLQ needs pub
  on `dlq.cdc.>`; multi-group sharding needs the per-group durable consumer
  wildcard).

## Adding another example

Keep new examples in this directory, follow the same friendly-comment style
(`.claude/skills/friendly-docs-comments/`), never commit real credentials, and add
a row here pointing at the render check and the test that proves it.
