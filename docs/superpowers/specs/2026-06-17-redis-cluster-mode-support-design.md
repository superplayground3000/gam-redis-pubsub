# Redis Cluster–mode support across the mono-binary

**Date:** 2026-06-17
**Status:** Approved (design)
**Component:** `redis-cdc-le-k8s`

## Problem

The workloads in the `redis-cdc-le-k8s` mono-binary connect to Redis with the
single-node client `redis.NewClient`. Against a clustered Redis, any command on a
key whose hash slot is not owned by the connected node returns a `MOVED`
redirection, which the single-node client does not follow — so the workload
errors out. The trigger was the `latency-calculator` (the "calculator"), which
issues `XRANGE`/`XREVRANGE` on the `cdc:latency` stream and hits `MOVED`, but the
same flaw affects every Redis-using component.

## Goal

Let every Redis-using component operate correctly against a Redis Cluster, with
full cluster correctness (not just `MOVED` redirection), selected by an explicit
toggle, while leaving existing single-node deployments behavior-identical.

## Scope

### In scope
- A shared client-construction helper used by all Redis-using components.
- Cluster support in the four Redis-using workloads: `latency`, `writer`,
  `verifier`, `dashboard`.
- Dashboard multi-node correctness (cluster-wide `SCAN`, keyspace subscription,
  and `CONFIG SET`).
- Helm chart wiring of the per-address cluster toggles.
- Unit tests for the new helper; existing tests stay green.

### Out of scope
- Standing up a clustered Redis inside the chart. The toggle targets an
  **externally provided** Redis Cluster; the chart's `redis-central` and
  `redis-region` deployments remain single-node. Documented, not implemented.
- The `elector` workload — it uses Kubernetes Lease-based leader election and has
  no Redis client.
- Integration/CI testing against a live cluster (documented as a manual step).

## Background / key findings

- All five workloads are dispatched from one binary by subcommand
  (`main.go`); only four touch Redis. The `elector` does not.
- Redis client construction today (single-node everywhere):
  - `internal/latency/main.go:44` — `XRANGE`/`XREVRANGE` on one stream key.
  - `internal/writer/main.go:45` — pipelined `XADD` + `SET`/`DEL`/`EVAL`.
  - `internal/verifier/redis.go:16` — `XADD`/`GET`/`SET`/`EVAL`/`XINFO`,
    constructed twice (central + region) from `internal/verifier/main.go:36,38`.
  - `internal/dashboard/main.go:84,85` — central + region clients used for
    `SCAN`, keyspace `PSUBSCRIBE`, `CONFIG SET`, and per-key `GET`.
- **The RENAME paths are already cluster-safe by data design.** Writer keys carry
  Redis Cluster hash tags so a value-preserving standby→active `RENAME` stays in
  one slot (`internal/writer/patterns.go:6-29`): e.g.
  `lb:company:active:{employees:%d}` and `lb:company:standby:{employees:%d}`
  share the `{employees:id}` tag. The verifier's `RenamePreserve` Lua
  (`internal/verifier/redis.go:64-74`) and the writer's `renamePreserveScript`
  operate on these same hash-tagged pairs, so they do **not** raise `CROSSSLOT`.
- The only genuinely node-local operations are in the dashboard:
  - `scanAll` (`internal/dashboard/main.go:181`) — `SCAN` covers only the
    connected node in cluster mode.
  - `subscribeChanges` (`internal/dashboard/main.go:148`) — keyspace
    notifications are published on the node owning each key; a single
    subscription misses events on other nodes.
  - `ConfigSet notify-keyspace-events KEA` (`internal/dashboard/main.go:95`) —
    applies to one node only.
  - The per-key `GET` after `SCAN` (`main.go:190`) routes by key and is correct
    under a cluster client without change.

## Design

### Component matrix

| Component | Redis ops | Cluster work required |
|---|---|---|
| `latency` (calculator) | `XRANGE`/`XREVRANGE` on one stream key | client swap only — fixes `MOVED` |
| `writer` | pipelined `XADD` + `SET`/`DEL`/`EVAL`(rename) | client swap only — `ClusterClient` pipeline auto-splits commands per node; rename keys already hash-tagged |
| `verifier` | `XADD`/`GET`/`SET`/`EVAL`/`XINFO` (central + region) | client swap only — rename keys hash-tagged |
| `dashboard` | `SCAN`, keyspace `PSUBSCRIBE`, `CONFIG SET`, per-key `GET` (central + region) | client swap **+ fan-out across masters** |

### 1. Shared helper: `internal/rediscfg`

A new package is the single place that knows how to build a client and how to
fan out across shards.

```go
package rediscfg

type Options struct {
    Addr     string // host:port. Comma-separated seed nodes are accepted in
                     // cluster mode, but the chart supplies a single seed (the
                     // ClusterClient discovers the rest via CLUSTER SLOTS).
    Cluster  bool
    PoolSize int    // optional; 0 = library default (writer sets workers*2)
}

// New returns a cluster-capable client.
//   Cluster=true  -> *redis.ClusterClient (Addrs = split(Addr, ","))
//   Cluster=false -> *redis.Client (Addr)
// Both concrete types satisfy redis.UniversalClient.
func New(opt Options) redis.UniversalClient

// ForEachMaster runs fn against every master shard (cluster) or against the one
// node (non-cluster). It is the primitive the dashboard uses for the node-local
// operations SCAN / keyspace subscribe / CONFIG SET.
//   *redis.ClusterClient -> delegates to (*redis.ClusterClient).ForEachMaster
//   *redis.Client        -> invokes fn once with that client
//   other                -> returns an error
func ForEachMaster(ctx context.Context, c redis.UniversalClient,
    fn func(context.Context, *redis.Client) error) error
```

Rationale for `redis.UniversalClient`: it is the interface both `*redis.Client`
and `*redis.ClusterClient` already implement, and it already exposes every method
the components call (`XAdd`, `Get`, `Set`, `Eval`, `XInfoGroups`, `Pipeline`,
`XRangeN`, `XRevRangeN`, `Ping`, `ConfigSet`, `PSubscribe`, `Scan`, `Close`). The
type change is therefore source-compatible — a widening, not a rewrite.

Considered and rejected:
- **Per-component custom interface** — more boilerplate, no benefit over the
  library's `UniversalClient`.
- **`redis.NewUniversalClient` auto-selecting on addr count** — selection would
  be implicit (driven by how many seeds are listed) rather than the explicit
  toggle the design calls for.
- **Build tags / always-ClusterClient** — changes behavior for existing
  single-node deployments; rejected.

### 2. Component changes (client swap)

Each component changes its client field/variable type from `*redis.Client` to
`redis.UniversalClient` and constructs via `rediscfg.New`:

- `latency/main.go` — `rdb := rediscfg.New(...)`; the `streamReader` interface in
  `consumer.go` is unchanged (both client types already satisfy it).
- `writer/main.go` — `rdb := rediscfg.New({..., PoolSize: workers*2})`;
  `Worker.RDB` becomes `redis.UniversalClient`. The pipeline in
  `worker.go` is unchanged: `ClusterClient.Pipeline()` groups queued commands by
  owning node and executes them per node, and the cross-key `EVAL` rename stays
  in one slot via hash tags.
- `verifier/redis.go` — `RedisClient.rdb` becomes `redis.UniversalClient`;
  `NewRedisClient(addr string, cluster bool)`.
- `dashboard/main.go` — `central`/`region` become `redis.UniversalClient`; see §4.

### 3. Selection — explicit per-address toggle

A boolean toggle per address; no startup probe. The address passed to each
component is the existing single seed `host:port` from the chart's external-Redis
URL; the client discovers the remaining nodes via `CLUSTER SLOTS`. (`rediscfg`
also accepts comma-separated seeds, but the chart supplies one — see §5.)

| Component | Cluster toggle | Address var |
|---|---|---|
| `writer` | `REDIS_CLUSTER` (env, default false) | `REDIS_ADDR` |
| `latency` | `REGION_CLUSTER` (env, default false) | `REGION_ADDR` |
| `dashboard` | `CENTRAL_CLUSTER`, `REGION_CLUSTER` (env, default false) | `CENTRAL_ADDR`, `REGION_ADDR` |
| `verifier` | `-redis-central-cluster`, `-redis-region-cluster` flags (default from the same env names) | `-redis-central`, `-redis-region` |

The verifier is flag-driven (`flag.NewFlagSet`), so it gets bool flags whose
defaults read the corresponding env var, keeping the toggle name consistent
across components.

### 4. Dashboard fan-out (the only multi-node change)

Three node-local operations become master fan-outs via `rediscfg.ForEachMaster`:

- **`CONFIG SET notify-keyspace-events KEA`** — applied on every master so each
  node emits keyspace events.
- **`subscribeChanges`** — one `PSubscribe` goroutine per master (each on the
  shard's `*redis.Client`), all feeding the existing `hub`. Keyspace events fire
  only on the node owning the changed key, so every master must be subscribed.
- **`scanAll`** — run the cursor `SCAN` loop on each master and merge the results
  under a mutex (`ForEachMaster` may run the closure concurrently across shards).
  The subsequent per-key `GET` routes by key and is correct on both topologies.

In single-node mode `ForEachMaster` runs the closure exactly once against the one
client, so non-cluster dashboards behave exactly as today.

### 5. Chart wiring

The chart already models an externally-provided Redis under
`redis.{central,region}.external` (`enabled` + `url`), and every component's
address is derived from that block via the `rrcs.redis.{central,region}.hostPort`
helpers (`chart/templates/_helpers.tpl:116-130`). Cluster mode is only meaningful
against such an external cluster — the bundled `redis-central`/`redis-region`
deployments are single-node and stay that way. The cluster flag is therefore
nested **inside the existing external block**, so it is structurally tied to the
`url` that points at the cluster:

```yaml
# chart/values.yaml
redis:
  central:
    external:
      enabled: false
      url: ""        # e.g. "redis://cluster-seed.central.svc:6379" (one seed node)
      cluster: false # NEW: route to this URL with a ClusterClient
  region:
    external:
      enabled: false
      url: ""
      cluster: false # NEW
```

Wiring:
- `chart/templates/latency-calculator.yaml` — add `REGION_CLUSTER` env =
  `.Values.redis.region.external.cluster`.
- `chart/templates/writer.yaml` — add `REDIS_CLUSTER` env =
  `.Values.redis.central.external.cluster` (the writer's `REDIS_ADDR` is central).
- `chart/templates/dashboard.yaml` — add `CENTRAL_CLUSTER` =
  `.Values.redis.central.external.cluster` and `REGION_CLUSTER` =
  `.Values.redis.region.external.cluster`.
- `chart/templates/verifier-job.yaml` — add `-redis-central-cluster=` /
  `-redis-region-cluster=` args from the same two values.
- The address envs/flags are **unchanged** — they keep using the existing
  `rrcs.redis.*.hostPort` helpers, which now resolve to the external cluster's
  seed `host:port` when `external.enabled=true`.

**Fail-closed guard:** setting `external.cluster=true` while `external.enabled=false`
points a `ClusterClient` at the bundled single-node Redis, which fails on
`CLUSTER SLOTS`. A new helper `rrcs.redis.{central,region}.cluster` resolves the
cluster bool and `fail`s with a clear message when `cluster=true` but
`enabled=false`. Templates source the toggle through this helper (mirroring the
existing `rediss://`-rejection guard in the `hostPort` helpers) rather than
reading the value directly, so the misconfiguration is caught at
`helm template`/install time instead of crash-looping the pod.

The chart does not deploy a clustered Redis; documented in the values comments.

## Error handling

- `rediscfg.New` returns a live client; connection failures surface on first use,
  preserving each component's existing retry/health behavior (e.g. latency's
  `Seek` retry loop, writer/dashboard `Ping` readiness loops).
- `ForEachMaster` propagates the first shard error to the caller; the dashboard
  loops already degrade gracefully (e.g. `scanAll` returns partial results on
  error), and that behavior is preserved.
- Cross-slot operations are avoided by construction (hash-tagged rename pairs);
  no new `CROSSSLOT` handling is required.

## Testing

- **`rediscfg` unit tests:** `New` returns `*redis.ClusterClient` when
  `Cluster=true` and `*redis.Client` otherwise; `ForEachMaster` invokes the
  closure once for a single-node client and errors on an unsupported type.
- **Existing tests stay green:** widening field types to `redis.UniversalClient`
  is source-compatible with the current fakes (e.g. the latency `streamReader`
  fake) and concrete clients.
- **Cluster integration:** exercising a real `ClusterClient` against a live
  multi-node cluster is documented as a manual/CI step, not a unit test.

## Affected files

New:
- `internal/rediscfg/rediscfg.go`
- `internal/rediscfg/rediscfg_test.go`

Modified (Go):
- `internal/latency/main.go`
- `internal/writer/main.go`, `internal/writer/worker.go`
- `internal/verifier/redis.go`, `internal/verifier/main.go`
- `internal/dashboard/main.go`

Modified (chart):
- `chart/templates/_helpers.tpl` — new `rrcs.redis.{central,region}.cluster`
  helpers (resolve the cluster bool; fail-closed when `cluster=true` &
  `enabled=false`)
- `chart/templates/latency-calculator.yaml`
- `chart/templates/writer.yaml`
- `chart/templates/dashboard.yaml`
- `chart/templates/verifier-job.yaml`
- `chart/values.yaml` — add `redis.{central,region}.external.cluster: false`
