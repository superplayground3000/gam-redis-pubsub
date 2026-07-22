# Runbook — first-sharded-env onboarding (forward-side, GLOBAL capacity event)

Bring the **first** sharded sink environment onto the shared external PROD stream.
Unlike the sink-side AIO→sharded handoff (`runbook-aio-to-sharded-handoff.md`), declaring
the first sharding family is a **forward-side, GLOBAL** change: it flips the publish
subject grammar for EVERY env and imposes the serialized-forward ceiling (~1/RTT) on all
of them, including AIO envs that never asked for sharding (design §8.2, R1/E5). Do it in a
maintenance window, in the exact order below — the sequencing is load-bearing. Companion
to `design.md` §8.2 (normative) and `implementation-plan.md` P8.

## Preconditions

- **Publisher-taxonomy decoupling (P3) has landed** — the publisher emits shard/prefix
  tokens from its own declaration, not a locally-enabled sink group (else a sink-less
  publisher declaring a family fails render, VF-6, or black-holes family traffic, VF-5).
- **The topology manifest (P2) is live and EVERY sink release is registered on it** (each
  has done ≥1 verified deploy with `connect.topologyManifest.enabled: true`). This is the
  F2 rule: the manifest gate must precede any taxonomy change so no rollout window can
  move traffic onto subjects no running sink matches.

## Steps (each names its observable GATE — do not proceed until it holds)

### 1. Sequence a catch-all group FIRST (E5 — the trap)

Enabling the first family flips `prefixRouting` **globally**: every non-family subject
shifts `kv.cdc.<seg>.<op>` → `kv.cdc.<seg>.<prefix|others>.<op>`. A sharded env with no
enabled catch-all group then misses ALL non-family traffic, which black-holes and fires
`CDCForwardUnrouted`. So the catch-all (`sinkGroups[*].catchAll: true`, filter
`kv.cdc.<seg>.others.>`) must be deployed and consuming BEFORE the family is declared.

- **GATE:** the sharded release renders a catch-all durable
  (`helm template … | grep others`) and, once deployed, `nats consumer info` shows it
  bound and draining. `CDCForwardUnrouted` is silent.

### 2. Declare the family in the publisher taxonomy + re-baseline capacity

Add the family (e.g. `"lp:m2g": {shards: N}`) to the PUBLISHER's taxonomy and upgrade.
This forces the serialized forward (`threads:1` + `max_in_flight:1`, INV-1 row 13) on
ALL envs — the ceiling regime trigger is "ANY sharded env exists", not "this env is
sharded". Re-baseline every env's headroom against the new ceiling:

```sh
RTT_MS=<measured> NMSG=400 RRCS_NS=<ns> scripts/measure-shard-throughput.sh
```

- **GATE:** the script exits 0 (spread ≥ 2× pinned) and the single-lane rate clears your
  total source XADD rate with margin (design §10 — the forward is now ~1/RTT TOTAL across
  all families and envs). If not, resolve N / RTT before rolling the sink.
- **GATE (F2):** the publisher's `nats-init` overwrote `cdc_topology/current` with the
  new taxonomy. A publisher re-running with a CHANGED taxonomy blocks the overwrite
  (fail-closed) unless `connect.topologyManifest.allowTaxonomyChange: true` — set it ONLY
  after every sink is on the new taxonomy, then set it back to false.

### 3. Deploy the sharded sink release covering {0..N-1, x}

Deploy the sharded env (`connect.envId=<env>`, `sharding.families` matching the
publisher's N, sinkGroups covering every shard `s0..sN-1` + `sx` + the catch-all from
step 1). AIO / prefix envs keep absorbing the deeper subjects under their `.>` filters
(subject-monotonic) — zero pause for them.

- **GATE:** each shard durable `cdc_sink_<env>_<fam>_s<K>` is bound MAP=1 and `cdc_apply`
  moves per shard; `CDCShardStuck` / `CDCShardIsolationLane` are silent.
- **GATE (manifest verified):** no fail-open marker was left behind —
  `nats kv ls cdc_topology | grep '^_unverified_'` returns nothing (a hit means a release
  came up unverified; re-run its nats-init once the bucket is readable, then
  `nats kv del cdc_topology _unverified_<env>`). This lab ships no Prometheus alert for it
  (the E10 shared NATS exporter is out of scope), so run the check by hand after each deploy.

## Rollback

Reverting the family declaration on the publisher (step 2) un-serializes the forward and
shifts subjects back — do it only if no sharded sink is yet consuming, and expect a brief
re-route. The sharded sink release (step 3) is sink-side: `helm uninstall` it and delete
its `cdc_sink_<env>_*` durables; other envs are untouched.

## See also

- `design.md` §8.2 (normative), §3.2 (taxonomy decoupling), R1 (ceiling), E5 (catch-all
  first), §7/E6 (manifest / F2 rule); `rules/05-invariants.md` INV-1 row 13 + the "exactly
  ONE publisher release per stream" operational invariant.
- `runbook-aio-to-sharded-handoff.md` (migrate an existing AIO env once sharding exists);
  `runbook-new-env-bootstrap.md` (start-policy / snapshot-seed for a brand-new env).
