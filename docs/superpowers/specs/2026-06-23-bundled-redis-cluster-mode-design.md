# Bundled minimal Redis Cluster mode — design

**Date:** 2026-06-23
**Chart:** `redis-cdc-le-k8s/chart/`
**Goal:** Let the bundled `redis-central` / `redis-region` deploy as a minimal
(3-master, 0-replica) Redis Cluster, so the chart's already-cluster-aware client
path can be exercised in-cluster without an external Redis.

## Background

Today both bundled Redises are single-node `Deployment`s. The chart's client side
is *already* cluster-aware through one source of truth, `rrcs.redis.<side>.cluster`,
which feeds:

- writer `REDIS_CLUSTER` env
- verifier `--redis-<side>-cluster` flags
- Redpanda Connect `connectKind` (`cluster` / `simple`) on both CDC legs

That helper is fail-closed: `cluster=true` requires `external.enabled=true`, with
the message "the bundled redis-central is single-node." This task lifts that
restriction by adding a bundled cluster topology, so `cluster` mode works against
in-cluster Redis.

## Non-goals

- HA / replicas (0 replicas — the Redis Cluster minimum is 3 masters).
- Keyspace persistence (`appendonly`/`save` stay off — throwaway lab data).
- **Surviving a pod delete.** Cluster state (`nodes.conf`) lives in an `emptyDir`,
  so deleting/rescheduling a node breaks the 0-replica cluster. This is an
  explicit scope decision: the lab is fresh-install oriented and runs with
  ephemeral storage (no `StorageClass` dependency). A `helm upgrade` that rolls
  the pods is handled — the cluster-init hook reforms the cluster — but a bare
  pod eviction without re-running init is out of scope.
- External Redis auth / TLS (already deferred per existing spec §2).

## 1. Values API (`mode` enum)

Per side, add a `mode` selector; the `external` block is unchanged:

```yaml
redis:
  image: redis:7.4-alpine
  protectedMode: "no"
  central:
    mode: standalone          # standalone | cluster (bundled topology; ignored when external.enabled=true)
    external: { enabled: false, url: "", cluster: false, authSecret: "" }
  region:
    mode: standalone
    external: { enabled: false, url: "", cluster: false, authSecret: "" }
```

- `mode: standalone` (default) → today's single-node Deployment. Render is
  byte-identical to current output (regression guard).
- `mode: cluster` → 3-master, 0-replica bundled cluster.
- `mode` is ignored when `external.enabled=true` (external routing wins).

## 2. Helper changes (`templates/_helpers.tpl`)

- **`rrcs.redis.<side>.cluster`** new logic:
  - `external.enabled=true`  → return `external.cluster` ("true"/"false").
  - `external.enabled=false` → return `eq mode "cluster"`.
  This single change lights up the entire client side already wired through it.
  No other client template changes.
- **Mode-enum validation:** `fail` if `mode` ∉ {`standalone`, `cluster`}, mirroring
  the existing fail-closed guards. Keep the existing
  `external.cluster=true` ⇒ `external.enabled=true` guard.
- **`url` / `hostPort` helpers unchanged.** Clients still seed at the `redis-<side>`
  ClusterIP Service; go-redis `ClusterClient` and Redpanda `kind: cluster` discover
  the remaining nodes via `CLUSTER SLOTS` (pod IPs are routable in-cluster).
- **New `rrcs.redis.<side>.waitCmd`** helper: emits
  `redis-cli -h H -p P cluster info | grep cluster_state:ok` in cluster mode and
  `redis-cli -h H -p P ping | grep PONG` in standalone. Consumed by the writer's
  `wait-redis-central` init container so it blocks until the cluster is *formed*,
  not merely reachable.

## 3. Bundled resources — DRY'd into one shared template

`templates/redis-central.yaml` and `templates/redis-region.yaml` are currently
byte-identical except for `central`/`region`. Collapse them into a shared
`rrcs.redis.bundled` named template (in `_helpers.tpl` or a `_redis.tpl` partial)
that takes `side`; each file becomes a one-line `include`. The template branches:

- **standalone** → current Deployment + ClusterIP Service (unchanged output).
- **cluster** (gated `{{- if and (not external.enabled) (eq mode "cluster") }}`):
  - **Headless Service** `redis-<side>-hl` — `clusterIP: None`,
    `publishNotReadyAddresses: true`; stable per-pod DNS for the cluster bus and
    the init Job.
  - **ClusterIP Service** `redis-<side>` (existing name/port 6379) — client seed;
    keeps `url`/`hostPort` stable.
  - **StatefulSet** `redis-<side>`, `replicas: 3`, `serviceName: redis-<side>-hl`.
    redis args add `--cluster-enabled yes --cluster-config-file /data/nodes.conf
    --cluster-node-timeout 5000`, keeping `--protected-mode no --appendonly no
    --save ""`. `/data` is an **`emptyDir`** (ephemeral — see Non-goals). Reuses
    `rrcs.image`, `rrcs.scheduling`, `rrcs.imagePullSecrets`, `rrcs.podLabels`.
  - **cluster-init Job** `redis-<side>-init`, run as a Helm hook
    (`post-install,post-upgrade`; `hook-delete-policy: before-hook-creation`) so
    it re-executes safely on upgrade instead of hitting the immutable-Job error.
    Script: wait for all 3 pods to `ping`; exit 0 if `cluster_state:ok` already;
    otherwise — first install OR an upgrade that left the ephemeral nodes
    stale/partial — `flushall` + `cluster reset hard` every node (data is
    ephemeral; this avoids the "node is not empty" abort that would fail the
    upgrade), then `redis-cli --cluster create … --cluster-replicas 0
    --cluster-yes`. Converges from any degraded state rather than erroring.

## 4. Testing / verification

- **Regression:** `helm template` at defaults → assert zero diff vs current render.
- **Cluster render:** `helm template --set redis.central.mode=cluster
  --set redis.region.mode=cluster` → assert per side: StatefulSet(replicas=3,
  `emptyDir`) + headless Service + ClusterIP Service + init Job (Helm hook);
  writer `REDIS_CLUSTER=true`; both connect legs `kind: cluster`; all wait sites
  use `cluster_state:ok`.
- **Invalid mode / contradiction:** `--set redis.central.mode=bogus` and
  `--set redis.central.external.cluster=true` (without external.enabled) both
  fail at template time with clear messages.
- `helm lint` clean in both modes; full cluster render parses as valid YAML.
- **Manual (noted, not automated):** kind/k3d deploy to confirm the cluster forms
  and the writer + CDC path connect through `ClusterClient`.
