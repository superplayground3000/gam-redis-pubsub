# Subject-sharding v2 — pause-drain cutover & resharding runbook

Operational procedure for turning `connect.sharding` on for an existing family
(design.md §10), for rolling back, and for changing N later. Executable drill:
`scripts/sharding-cutover-drill.sh` (T-10) walks every step against kind and
asserts the two acceptance criteria (no loss, no reorder).

## Why dual consumption is a CORRECTNESS error here (read first)

The old (un-sharded) group's consumer filter `kv.cdc.lp.m2g.>` is a **superset**
of every new shard subject `kv.cdc.lp.m2g.s<K>.<op>`. If both the old durable
and the new shard durables exist while the sharded forward is publishing, the
same message is delivered to BOTH consumers and applied TWICE by two
independent, unsynchronized appliers.

v1 tolerated this: its LWW fence rejected the second (stale) apply, so dual
consumption was only waste. **v2 has no fence** — two appliers racing on the
same key can interleave (old-consumer apply of event 2 landing after
new-consumer apply of event 3) and leave a stale terminal value, with **no
metric able to detect it**. That is why v2 replaces v1's rolling cutover with
pause-drain: there must never be a moment where a subject has two live
consumers while traffic flows.

The same reasoning gates pruning: `nats-init` only **reports** orphaned
durables while sharding is configured (`connect.sharding.pruneOrphans: false`,
the default). Deleting the old durable is step 4 below — a deliberate act after
the drain criterion holds — via a one-shot `pruneOrphans: true` upgrade.

## Preconditions (design.md §12)

- **P-1**: `app.events` retention (`STREAM_MAXLEN` / MAXLEN policy) holds the
  whole pause window plus the forward's blocking-retry window. Producers keep
  XADDing while the forward is paused; if the stream trims un-forwarded
  entries, they are lost silently.
- **P-2**: `nats.stream.dupeWindow` ≥ the longest realistic forward
  stop/restart time (O-5 coupling — a replay outside the window re-lands
  messages; the contiguous-tail property keeps that safe, but keep the window
  honest anyway).
- The subscriber creds must carry the wildcard consumer grant
  (`scripts/gen-nats-auth.sh --force`, already committed for this repo).

## Procedure

1. **Deploy the shard consumers and groups** (no traffic yet). Because the
   chart validates that a family must not simultaneously appear in a group's
   `prefixes`, the flip from prefix-group to shard-groups happens in one values
   change — so steps 1–2 are ONE upgrade with the forward paused:

   ```yaml
   connect:
     source:
       enabled: false          # STEP 2 — pause first, in the same upgrade
     sharding:
       keyPattern: '\{employee:(?P<id>[0-9]+)\}'
       families:
         "lp:m2g": { shards: 32 }
     sinkGroups:
       # old   - { name: m2g, prefixes: ["lp:m2g"] }   <- REMOVED
       - { name: m2g-a, shardsOf: "lp:m2g", shards: [0,1,2,3,4,5,6,7] }
       - { name: m2g-b, shardsOf: "lp:m2g", shards: [8,9,10,11,12,13,14,15] }
       - { name: m2g-c, shardsOf: "lp:m2g", shards: [16,17,18,19,20,21,22,23] }
       - { name: m2g-d, shardsOf: "lp:m2g", shards: [24,25,26,27,28,29,30,31,"x"] }
       - { name: others, catchAll: true }
   ```

   `connect.source.enabled=false` makes the source elector DELETE its stream on
   leadership loss — publishing stops; producers keep XADDing (backlog parks in
   `app.events`, see P-1). nats-init creates `s0..s31` + `sx` durables
   (max_ack_pending=1 hard-coded); the new groups' `wait-consumer` gates all of
   them; the old durable becomes an orphan that the gated prune only reports.

2. *(folded into step 1 — pause before flip, same upgrade.)*

3. **Drain criterion** on the OLD durable — both must be zero before touching it:

   ```
   nats consumer info KV_CDC cdc_sink_m2g --json | jq '.num_pending, .num_ack_pending'
   ```

   `num_pending==0 && num_ack_pending==0` means every message published before
   the pause has been applied (JetStream FIFO: pending zero implies all lower
   stream sequences acked).

4. **Delete the old durable** (the superset filter disappears with it):
   one-shot upgrade with `connect.sharding.pruneOrphans: true`, then revert the
   flag. (Equivalent manual form: `nats consumer rm KV_CDC cdc_sink_m2g`.)

5. **Resume the forward**: `connect.source.enabled: true`. The paused backlog
   drains through the serialized sharded forward (threads:1, max_in_flight:1)
   to the shard subjects; only the new groups consume. Expect elevated e2e
   latency until the backlog clears — the forward ceiling is ~1/RTT for the
   whole family (design.md §14).

6. **Acceptance**: `cdc_apply{shard=~"s.*"}` rate recovers to the pre-cutover
   family rate; `cdc_apply{shard="sx"}` is 0;
   `cdc_forward_cross_shard_rename` is 0; e2e p99 falls back after the backlog
   (dashboard panels 15–17, alerts A1–A6).

## Rollback (any point before step 5)

Restore the previous values (old prefix group back, `sharding.families`
removed, source re-enabled). If the old durable was already deleted in step 4,
nats-init recreates it with `--deliver all` — it starts from the messages still
present in the stream; the applied prefix-subject messages were already acked
under the old consumer name, and re-applied creates/updates are idempotent.
Shard durables left behind are harmless (no traffic) and can be pruned later.

## Resharding (changing N) and re-grouping

- **Changing N** (e.g. 32 → 64) re-maps `id mod N` for almost every key: the
  same pause-drain procedure applies, with step 3's drain criterion evaluated
  over ALL old shard durables (`cdc_sink_lp_m2g_s0..s31`), and step 4 pruning
  all of them. This is why N is over-provisioned once (D-10: virtual shards).
- **Changing the shard→group assignment** (moving shards between groups) does
  NOT need pause-drain: each durable still has exactly one active puller at a
  time (Lease per group + `copies: 1`), and the Lease handover is atomic per
  group. A rolling `helm upgrade` suffices.

## Known trade-offs carried by this design (design.md §14)

- Forward throughput ceiling ≈ 1/RTT(central Connect ↔ NATS), all families
  combined (~1000 msg/s at 1ms RTT). Exceeding it requires returning to the
  v1 fence design (kept in design-v1.md as the upgrade path).
- No direct out-of-order detection signal exists. The A1–A6 alerts and the
  T-4/T-6/T-7 tests are proxies guarding the chain links, not detectors of the
  failure itself.
