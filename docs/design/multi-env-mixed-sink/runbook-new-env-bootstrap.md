# Runbook — new-env bootstrap (start policy + snapshot seed)

Onboard a brand-new downstream sink environment onto the shared external PROD stream
with the correct delivery start position, so the env's region Redis ends up *complete*
(no missing history) and *consistent* (no stale replay overwriting fresher values).

Companion to `design.md` §8.4 (R3) and `implementation-plan.md` P4. The knob is
`connect.sink.bootstrap` (`chart/values.yaml`); it is acted on by the **external**
`nats-init` job only (`chart/templates/nats-init-external-job.yaml`). The bundled
nats-init always creates `--deliver all` and ignores this switch — it is for disposable
labs, not PROD onboarding.

## Pick the mode first

An env is a durable set + its own region Redis (design §0). The durable's
`deliver_policy` is **fixed at creation** and the chart never mutates a user-owned
consumer, so choosing wrong means deleting and recreating the durable — pick before you
deploy.

| You want… | `bootstrap.deliver` | Region Redis is… | Notes |
|---|---|---|---|
| A go-forward-only env (history doesn't matter, or seeded another way) | `new` | empty at start; fills from the next event on | Safe default. Replays **nothing**. |
| A fully-correct region as of an instant T0 | `by-time` (+ `byStartTime: T0`) | seeded from a T0 snapshot | **Strict path — this runbook.** No gap, no stale overwrite. |
| A change-tolerant env that can rebuild from 72h of changes | `all` | empty at start; replays the retained backlog | `all` is a **partial** 72h replay of CHANGES, **not** a snapshot (VF-16): any key whose last change predates the 72h window is never written. Only correct when every live key changes within 72h, or the region is snapshot-seeded anyway. |

The rest of this runbook is the **strict `by-time` snapshot-seed path**. It is the only
mode that guarantees a complete *and* consistent region for a key space where some keys
are older than the stream's 72h retention.

## Why a snapshot alone, or a replay alone, is not enough

- **Replay-only (`all`)** misses any key not touched in the last 72h — silent gap.
- **Snapshot-only** (copy the source Redis, then start the durable at `new`) misses every
  change that lands *between* taking the snapshot and the durable's first delivery —
  silent gap in the other direction.

The seam that closes both gaps is a single instant **T0**: snapshot the source *as of* T0,
and start the durable *at* T0. Every key's value at T0 is in the snapshot; every change
after T0 is replayed from the stream; the boundary is idempotent (a change at exactly T0
may be both in the snapshot and replayed — applying it twice is a no-op, INV-1 allows
duplicates). Nothing falls between them.

## Steps (each step names its observable GATE — do not proceed until it holds)

### 1. Choose T0

Pick a wall-clock instant **T0** (UTC, RFC3339, e.g. `2026-07-21T00:00:00Z`) that is
**comfortably inside the stream's 72h retention** — i.e. `now - T0 < maxAge` with margin,
so JetStream still holds every message published at or after T0. The snapshot in step 2
and the durable in step 4 both anchor on this exact value.

- **GATE:** `nats stream info KV_CDC --json | jq -r '.state.first_ts'` is *older* than T0.
  If `first_ts > T0`, the stream has already discarded messages you need — pick a later T0
  or accept that pre-`first_ts` keys come only from the snapshot (which is fine as long as
  the snapshot itself is taken at/after `first_ts`; the point is the two overlap).

### 2. Snapshot the central (source) Redis at T0

The forward leg reads the **central** Redis stream and publishes each change; a snapshot of
the *keyspace* the source represents at T0 is what seeds the region. There is no bespoke
snapshot tool in this repo — use the generic, engine-agnostic path:

- **Preferred (managed Redis):** trigger a point-in-time backup (`BGSAVE`, or the provider's
  snapshot API) and record the wall-clock instant it was taken as T0. Restore that RDB into
  the env's region Redis (or `redis-cli --rdb` dump then load).
- **Portable (no RDB access):** iterate the keyspace with `SCAN` (never `KEYS`) and, for each
  key, `DUMP` on the source and `RESTORE key 0 <payload>` on the region:

  ```sh
  # against SRC (central) and DST (region) redis-cli endpoints; T0 = the moment you START this
  redis-cli -u "$SRC" --scan | while read -r k; do
    payload=$(redis-cli -u "$SRC" --no-raw DUMP "$k")   # binary-safe in practice: prefer RESTORE via a pipe/RDB in real runs
    redis-cli -u "$DST" RESTORE "$k" 0 "$payload" REPLACE
  done
  ```

  `SCAN` is not a consistent point-in-time view, so keys changing *during* the copy may be
  captured at slightly different instants — that is exactly why T0 is the **start** of the
  copy and the durable replays `[T0, ∞)`: any change during the copy window is re-applied
  from the stream, correcting a torn read. (For a strong point-in-time seed, prefer the RDB
  path over live `SCAN`.)

- **GATE:** the region Redis key count is within the expected range of the source
  (`redis-cli -u "$DST" DBSIZE` vs source `DBSIZE`), and a spot-check of a few known keys
  returns the source's T0 values.

### 3. Deploy the sink release with `bootstrap.deliver: by-time`

Set on this env's values (external NATS):

```yaml
connect:
  envId: <env>
  sink:
    bootstrap:
      deliver: by-time
      byStartTime: "2026-07-21T00:00:00Z"   # == T0, exactly
```

`helm upgrade --install`. The external `nats-init` runs as a pre-install hook and either
**creates** the durable `cdc_sink_<env>` at `deliver_policy=by_start_time`
`opt_start_time=T0`, or — if the durable already exists — **validates** its start
semantics and **fails the release closed** if they do not match (e.g. a leftover
`--deliver all` durable is squatting on the name). To adopt a pre-created durable whose
position you deliberately set, use `bootstrap.allowStartMismatch: true` (it downgrades the
mismatch to a WARN).

- **GATE (render, L1):** `helm template chart -f <values> -s templates/nats-init-external-job.yaml`
  shows `--deliver "2026-07-21T00:00:00Z"` on the create path and the `deliver_policy` /
  `opt_start_time` comparison on the existing-consumer path.
- **GATE (deploy):** the `nats-init-ext` hook Job completes (`kubectl get job`), and
  `nats consumer info KV_CDC cdc_sink_<env> --json | jq '{p:.config.deliver_policy, t:.config.opt_start_time}'`
  reports `{"p":"by_start_time","t":"2026-07-21T00:00:00Z"}`.

### 4. Verify no gap at the boundary

The durable must deliver its **first** message at a stream timestamp `>= T0`, and there
must be no published message in `[first_ts_of_env_durable's_first_delivery ... T0)` that the
snapshot did not already cover. In practice:

- **GATE:** the first message the env applies has a stream timestamp `>= T0`
  (peek: `nats consumer next KV_CDC cdc_sink_<env> --count 1 --raw` and inspect its
  `Nats-Time`/stream ts, or watch `jetstream_consumer_delivered_stream_seq` advance from a
  sequence whose `ts >= T0`). A first delivery with `ts < T0` means the durable started too
  early (wrong `opt_start_time`) — delete and recreate.
- **GATE:** `cdc_apply` on the env's sink increments and `num_pending` on the durable drains
  toward 0 as the post-T0 backlog applies; a spot-check of keys changed just after T0 shows
  the region reflecting the post-T0 value (snapshot value was overwritten by replay — the
  boundary is being applied).

## Fallback — `deliver: all` (change-tolerant envs only)

If the env can rebuild purely from the retained change history (every live key is guaranteed
to have changed within the last 72h), skip the snapshot and set `bootstrap.deliver: all`.
This replays the whole retained backlog on creation (a creation burst — see the capacity
worksheet, design §10). **Caveat (VF-16, design §8.4):** `all` is a *partial* replay of
CHANGES bounded by the 72h max-age, **not** a snapshot; any key whose last change is older
than 72h will be **missing** from the region and no error is raised. Do not use `all` for a
key space with long-lived, rarely-changed keys unless you also snapshot-seed.

## Rollback

The region Redis is **disposable** (design §8.4). To abort an onboarding at any step:

1. `helm uninstall <release>` (or set `connect.sink.enabled: false`) to stop applies.
2. Delete the env's durable(s) so they stop accruing `num_pending` on the shared stream:
   `nats consumer rm KV_CDC cdc_sink_<env> --force` (and any `cdc_sink_<env>_*` shard
   durables). This is the only way to change a durable's start policy — recreation resets
   delivery state, which is exactly what you want when re-seeding.
3. Flush the region Redis (`redis-cli -u "$DST" FLUSHALL`) before re-seeding, so a retry
   starts from a clean keyspace rather than a half-applied one.

Because the durable was disjoint (env-scoped by `connect.envId`, design §4) and the region
Redis is this env's alone (D-region), none of this touches the publisher, the shared stream's
other consumers, or any other env.

## See also

- `design.md` §8.4 (bootstrap), R3 (decision), §8.3 (the AIO→sharded handoff, which reuses
  this start-semantics validation via the P6 assert-only mode).
- `chart/examples/values-sink-only.yaml` (carries `bootstrap.deliver: new`).
- `rules/05-invariants.md` INV-1 (at-least-once — the boundary idempotence argument above
  relies on duplicates being absorbed).
