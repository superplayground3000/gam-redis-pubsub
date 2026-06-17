# Redis Cluster-mode Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let every Redis-using component (the four Go workloads + the Redis Connect source/sink) operate correctly against a Redis Cluster, selected by an explicit per-address toggle, with single-node deployments behavior-identical.

**Architecture:** A new `internal/rediscfg` package builds a cluster-capable `redis.UniversalClient` from an explicit toggle and provides a `ForEachMaster` fan-out primitive. Each Go component widens its client field to `redis.UniversalClient` and constructs via `rediscfg.New`; the dashboard additionally fans `SCAN`/keyspace-subscribe/`CONFIG SET` across masters. The Helm chart nests a `cluster` flag under the existing `redis.{central,region}.external` block (fail-closed when `cluster=true` without `enabled=true`) and templates the Go env/flags plus the connect `kind` field from it.

**Tech Stack:** Go 1.x, `github.com/redis/go-redis/v9` v9.19.0, Helm, redpanda-connect (Benthos) streams configs.

**Spec:** `docs/superpowers/specs/2026-06-17-redis-cluster-mode-support-design.md`

---

## File Structure

New files:
- `redis-cdc-le-k8s/internal/rediscfg/rediscfg.go` — `Options`, `New`, `ForEachMaster`, `EnvBool`.
- `redis-cdc-le-k8s/internal/rediscfg/rediscfg_test.go` — unit tests.

Modified (Go):
- `redis-cdc-le-k8s/internal/latency/main.go` — construct via `rediscfg.New`, read `REGION_CLUSTER`.
- `redis-cdc-le-k8s/internal/writer/main.go` — construct via `rediscfg.New`, read `REDIS_CLUSTER`.
- `redis-cdc-le-k8s/internal/writer/worker.go` — `Worker.RDB` → `redis.UniversalClient`.
- `redis-cdc-le-k8s/internal/verifier/redis.go` — `RedisClient.rdb` → `redis.UniversalClient`; `NewRedisClient(addr, cluster)`.
- `redis-cdc-le-k8s/internal/verifier/main.go` — add `-redis-central-cluster`/`-redis-region-cluster` flags.
- `redis-cdc-le-k8s/internal/verifier/redis_test.go` — update `NewRedisClient` call site.
- `redis-cdc-le-k8s/internal/dashboard/main.go` — clients → `UniversalClient`; fan out `CONFIG SET`/`SCAN`/keyspace-subscribe across masters.

Modified (chart):
- `redis-cdc-le-k8s/chart/templates/_helpers.tpl` — `rrcs.redis.{central,region}.cluster` + `.connectKind` helpers.
- `redis-cdc-le-k8s/chart/values.yaml` — `redis.{central,region}.external.cluster: false`.
- `redis-cdc-le-k8s/chart/templates/latency-calculator.yaml` — `REGION_CLUSTER` env.
- `redis-cdc-le-k8s/chart/templates/writer.yaml` — `REDIS_CLUSTER` env.
- `redis-cdc-le-k8s/chart/templates/dashboard.yaml` — `CENTRAL_CLUSTER`/`REGION_CLUSTER` env.
- `redis-cdc-le-k8s/chart/templates/verifier-job.yaml` — cluster flags.
- `redis-cdc-le-k8s/chart/files/connect/cdc-forward.yaml` — source `kind`.
- `redis-cdc-le-k8s/chart/files/connect/cdc-reverse.yaml` — sink `kind` (×4).

**All commands below assume the working directory is `redis-cdc-le-k8s/` unless a path says otherwise.**

---

### Task 1: `rediscfg` — `New` constructor + `EnvBool`

**Files:**
- Create: `redis-cdc-le-k8s/internal/rediscfg/rediscfg.go`
- Test: `redis-cdc-le-k8s/internal/rediscfg/rediscfg_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/rediscfg/rediscfg_test.go`:

```go
package rediscfg

import (
	"testing"

	"github.com/redis/go-redis/v9"
)

func TestNewSingleNode(t *testing.T) {
	c := New(Options{Addr: "127.0.0.1:6379"})
	defer c.Close()
	if _, ok := c.(*redis.Client); !ok {
		t.Fatalf("Cluster=false: want *redis.Client, got %T", c)
	}
}

func TestNewCluster(t *testing.T) {
	c := New(Options{Addr: "a:6379, b:6379", Cluster: true})
	defer c.Close()
	cc, ok := c.(*redis.ClusterClient)
	if !ok {
		t.Fatalf("Cluster=true: want *redis.ClusterClient, got %T", c)
	}
	// Seeds are comma-split and trimmed.
	opt := cc.Options()
	if len(opt.Addrs) != 2 || opt.Addrs[0] != "a:6379" || opt.Addrs[1] != "b:6379" {
		t.Fatalf("seeds not split/trimmed: %#v", opt.Addrs)
	}
}

func TestEnvBool(t *testing.T) {
	if EnvBool("RDSCFG_UNSET_VAR") != false {
		t.Fatal("unset var should be false")
	}
	t.Setenv("RDSCFG_TEST_BOOL", "true")
	if EnvBool("RDSCFG_TEST_BOOL") != true {
		t.Fatal(`"true" should parse to true`)
	}
	t.Setenv("RDSCFG_TEST_BOOL", "garbage")
	if EnvBool("RDSCFG_TEST_BOOL") != false {
		t.Fatal("unparseable value should fall back to false")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/rediscfg/ -run 'TestNew|TestEnvBool' -v`
Expected: FAIL — build error, `New`/`Options`/`EnvBool` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `internal/rediscfg/rediscfg.go`:

```go
// Package rediscfg is the single place that builds a cluster-capable Redis
// client from an explicit toggle, plus a fan-out primitive for the node-local
// operations (SCAN / keyspace subscribe / CONFIG SET) that a cluster client does
// not transparently spread across shards.
package rediscfg

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	"github.com/redis/go-redis/v9"
)

// Options configures New.
type Options struct {
	// Addr is host:port. Comma-separated seed nodes are accepted in cluster mode,
	// but the chart supplies a single seed (the ClusterClient discovers the rest
	// via CLUSTER SLOTS).
	Addr string
	// Cluster selects *redis.ClusterClient over *redis.Client.
	Cluster bool
	// PoolSize is optional; 0 uses the library default.
	PoolSize int
}

// New returns a cluster-capable client. Both concrete return types satisfy
// redis.UniversalClient.
func New(opt Options) redis.UniversalClient {
	if opt.Cluster {
		seeds := strings.Split(opt.Addr, ",")
		for i := range seeds {
			seeds[i] = strings.TrimSpace(seeds[i])
		}
		return redis.NewClusterClient(&redis.ClusterOptions{Addrs: seeds, PoolSize: opt.PoolSize})
	}
	return redis.NewClient(&redis.Options{Addr: opt.Addr, PoolSize: opt.PoolSize})
}

// EnvBool reads a boolean toggle from the environment. An empty or unparseable
// value is false (fail-safe to single-node behavior).
func EnvBool(key string) bool {
	v := os.Getenv(key)
	if v == "" {
		return false
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		log.Printf("WARN: %s=%q not a bool, using false", key, v)
		return false
	}
	return b
}

// ForEachMaster runs fn against every master shard (cluster) or against the one
// node (non-cluster). It is the primitive the dashboard uses for the node-local
// operations SCAN / keyspace subscribe / CONFIG SET.
func ForEachMaster(ctx context.Context, c redis.UniversalClient, fn func(context.Context, *redis.Client) error) error {
	switch cc := c.(type) {
	case *redis.ClusterClient:
		return cc.ForEachMaster(ctx, fn)
	case *redis.Client:
		return fn(ctx, cc)
	default:
		return fmt.Errorf("rediscfg: ForEachMaster unsupported client type %T", c)
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/rediscfg/ -run 'TestNew|TestEnvBool' -v`
Expected: PASS (3 tests). `New`/`NewClusterClient` are lazy — no Redis server is contacted.

- [ ] **Step 5: Commit**

```bash
git add internal/rediscfg/rediscfg.go internal/rediscfg/rediscfg_test.go
git commit -m "feat(rediscfg): cluster-capable client constructor + EnvBool"
```

---

### Task 2: `rediscfg.ForEachMaster` single-node dispatch test

**Files:**
- Test: `redis-cdc-le-k8s/internal/rediscfg/rediscfg_test.go` (add to existing file)

- [ ] **Step 1: Write the failing test**

Append to `internal/rediscfg/rediscfg_test.go`:

```go
func TestForEachMasterSingleNode(t *testing.T) {
	c := New(Options{Addr: "127.0.0.1:6379"})
	defer c.Close()

	calls := 0
	var got *redis.Client
	err := ForEachMaster(context.Background(), c, func(_ context.Context, shard *redis.Client) error {
		calls++
		got = shard
		return nil
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if calls != 1 {
		t.Fatalf("single-node: want closure called once, got %d", calls)
	}
	// The closure receives the single client itself.
	if got != c.(*redis.Client) {
		t.Fatalf("single-node: closure received a different client")
	}
}
```

Add `"context"` to the test file's imports.

- [ ] **Step 2: Run test to verify it fails (then passes)**

Run: `go test ./internal/rediscfg/ -run TestForEachMasterSingleNode -v`
Expected: PASS immediately — `ForEachMaster` was implemented in Task 1, this test pins its single-node contract. (If the import line is missing, fix the `context` import and re-run.)

> Note: the cluster branch of `ForEachMaster` requires a live multi-node cluster and is exercised by manual/CI integration, not this unit test (per spec §Testing).

- [ ] **Step 3: Commit**

```bash
git add internal/rediscfg/rediscfg_test.go
git commit -m "test(rediscfg): pin ForEachMaster single-node dispatch"
```

---

### Task 3: latency-calculator uses `rediscfg` + `REGION_CLUSTER`

**Files:**
- Modify: `redis-cdc-le-k8s/internal/latency/main.go:5-18` (imports), `:35` (addr), `:44` (client)

- [ ] **Step 1: Verify existing latency tests pass (baseline)**

Run: `go test ./internal/latency/ -v`
Expected: PASS — establishes the consumer/window/report tests are green before the change.

- [ ] **Step 2: Replace the import block**

In `internal/latency/main.go`, replace the import block (lines 5-18):

```go
import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"redis-cdc-le-k8s/internal/rediscfg"
)
```

(The direct `github.com/redis/go-redis/v9` import is removed — `main.go` no longer names the `redis` package; `consumer.go` keeps its own import.)

- [ ] **Step 3: Read the toggle and construct via rediscfg**

In `internal/latency/main.go`, change the addr line and the client construction.

Replace:

```go
	addr := env("REGION_ADDR", "redis-region:6379")
```

with:

```go
	addr := env("REGION_ADDR", "redis-region:6379")
	cluster := rediscfg.EnvBool("REGION_CLUSTER")
```

Replace:

```go
	rdb := redis.NewClient(&redis.Options{Addr: addr})
	defer rdb.Close()
```

with:

```go
	rdb := rediscfg.New(rediscfg.Options{Addr: addr, Cluster: cluster})
	defer rdb.Close()
```

- [ ] **Step 4: Build and test**

Run: `go build ./internal/latency/ && go test ./internal/latency/ -v`
Expected: PASS — `rediscfg.New` returns a `redis.UniversalClient`, which satisfies the `streamReader` interface `NewConsumer` expects (both `*redis.Client` and `*redis.ClusterClient` implement `XRangeN`/`XRevRangeN`).

- [ ] **Step 5: Commit**

```bash
git add internal/latency/main.go
git commit -m "feat(latency): cluster-capable Redis client via REGION_CLUSTER"
```

---

### Task 4: writer uses `rediscfg` + `REDIS_CLUSTER`

**Files:**
- Modify: `redis-cdc-le-k8s/internal/writer/worker.go:50` (RDB type)
- Modify: `redis-cdc-le-k8s/internal/writer/main.go:14-16` (imports), `:19` (addr), `:45` (client)

- [ ] **Step 1: Verify existing writer tests pass (baseline)**

Run: `go test ./internal/writer/ -v`
Expected: PASS.

- [ ] **Step 2: Widen `Worker.RDB` to UniversalClient**

In `internal/writer/worker.go`, change the `Worker` struct field (line 50):

Replace:

```go
	RDB           *redis.Client // central Redis (KV + app.events stream)
```

with:

```go
	RDB           redis.UniversalClient // central Redis (KV + app.events stream)
```

(`worker.go` keeps its `github.com/redis/go-redis/v9` import — still used for `redis.Pipeliner`, `redis.XAddArgs`. `ClusterClient.Pipeline()` groups queued commands per owning node and executes them, and the hash-tagged `EVAL` rename stays in one slot, so the batching loop is unchanged.)

- [ ] **Step 3: Construct via rediscfg in main.go**

In `internal/writer/main.go`, replace the import block (lines 4-16):

```go
import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"redis-cdc-le-k8s/internal/rediscfg"
)
```

(The direct `redis` import is removed — `main.go` only used it for the client constructor.)

Replace:

```go
	addr := envStr("REDIS_ADDR", "redis-central:6379")
```

with:

```go
	addr := envStr("REDIS_ADDR", "redis-central:6379")
	cluster := rediscfg.EnvBool("REDIS_CLUSTER")
```

Replace:

```go
	rdb := redis.NewClient(&redis.Options{Addr: addr, PoolSize: workers * 2})
	defer rdb.Close()
```

with:

```go
	rdb := rediscfg.New(rediscfg.Options{Addr: addr, Cluster: cluster, PoolSize: workers * 2})
	defer rdb.Close()
```

- [ ] **Step 4: Build and test**

Run: `go build ./internal/writer/ && go test ./internal/writer/ -v`
Expected: PASS — `worker_test.go` constructs `Worker{}` without setting `RDB`, so widening the field type does not affect it; the `rdb` value (`UniversalClient`) assigns directly to `Worker.RDB`.

- [ ] **Step 5: Commit**

```bash
git add internal/writer/main.go internal/writer/worker.go
git commit -m "feat(writer): cluster-capable Redis client via REDIS_CLUSTER"
```

---

### Task 5: verifier — UniversalClient + cluster flags

**Files:**
- Modify: `redis-cdc-le-k8s/internal/verifier/redis.go:1-17` (imports, type, constructor)
- Modify: `redis-cdc-le-k8s/internal/verifier/main.go:16-17` (flags), `:36,38` (construction)
- Modify: `redis-cdc-le-k8s/internal/verifier/redis_test.go:34` (call site)

- [ ] **Step 1: Update the broken-by-signature test first (write the failing expectation)**

In `internal/verifier/redis_test.go`, change line 34:

Replace:

```go
	c := NewRedisClient("127.0.0.1:1") // reserved, refuses connections
```

with:

```go
	c := NewRedisClient("127.0.0.1:1", false) // reserved, refuses connections
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/verifier/ -run TestGroupLagFailsClosed -v`
Expected: FAIL — build error: `NewRedisClient` still takes one argument (the test now passes two).

- [ ] **Step 3: Update the constructor and client type**

In `internal/verifier/redis.go`, replace the import block + type + constructor (lines 4-17):

```go
import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"

	"redis-cdc-le-k8s/internal/rediscfg"
)

type RedisClient struct{ rdb redis.UniversalClient }

func NewRedisClient(addr string, cluster bool) *RedisClient {
	return &RedisClient{rdb: rediscfg.New(rediscfg.Options{Addr: addr, Cluster: cluster})}
}
```

(The remaining methods — `XAddEvent`, `GetString`, `Set`, `RenamePreserve`, `GroupLag`, `GroupBacklog` — are unchanged; every call they make is on `redis.UniversalClient`. The `RenamePreserve` `Eval` over `KEYS[1]`/`KEYS[2]` operates on the writer's hash-tagged standby/active pair, which share a slot, so no `CROSSSLOT`.)

- [ ] **Step 4: Add the cluster flags and pass them**

In `internal/verifier/main.go`, add two flags after the `region` flag (after line 17):

```go
	centralCluster := fs.Bool("redis-central-cluster", false, "treat --redis-central as a Redis Cluster seed")
	regionCluster := fs.Bool("redis-region-cluster", false, "treat --redis-region as a Redis Cluster seed")
```

Replace the construction (lines 36-39):

```go
	centralC := NewRedisClient(*central)
	defer centralC.Close()
	regionC := NewRedisClient(*region)
	defer regionC.Close()
```

with:

```go
	centralC := NewRedisClient(*central, *centralCluster)
	defer centralC.Close()
	regionC := NewRedisClient(*region, *regionCluster)
	defer regionC.Close()
```

> Note: the verifier toggles are plain bool flags defaulting to `false`; the chart always renders them explicitly from the same values that drive the other components (Task 8). This is simpler than env-defaulting and fully deterministic.

- [ ] **Step 5: Build and test**

Run: `go build ./internal/verifier/ && go test ./internal/verifier/ -v`
Expected: PASS — `TestGroupLagFailsClosed` now compiles and still observes a propagated dial error against the dead address.

- [ ] **Step 6: Commit**

```bash
git add internal/verifier/redis.go internal/verifier/main.go internal/verifier/redis_test.go
git commit -m "feat(verifier): cluster-capable Redis clients via -redis-*-cluster flags"
```

---

### Task 6: dashboard — UniversalClient + master fan-out

**Files:**
- Modify: `redis-cdc-le-k8s/internal/dashboard/main.go` — imports, `Run` (`:77-101`), `subscribeChanges` (`:148-178`), `scanAll` (`:181-200`), `pollLoop` (`:202-222`)

- [ ] **Step 1: Verify existing dashboard tests pass (baseline)**

Run: `go test ./internal/dashboard/ -v`
Expected: PASS — `divergence_test.go` covers `computeDivergence` (a pure function), unaffected by client changes.

- [ ] **Step 2: Add the rediscfg import**

`internal/dashboard/main.go` already imports `sync` (line 17) and
`github.com/redis/go-redis/v9` (line 22). Add only the rediscfg import — insert it
as a new import group after the third-party block (after the
`github.com/redis/go-redis/v9` line):

```go
	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"

	"redis-cdc-le-k8s/internal/rediscfg"
```

- [ ] **Step 3: Construct clients via rediscfg and fan out CONFIG SET**

In `Run`, replace the client construction (lines 84-85):

```go
	central := redis.NewClient(&redis.Options{Addr: centralAddr})
	region := redis.NewClient(&redis.Options{Addr: regionAddr})
```

with:

```go
	central := rediscfg.New(rediscfg.Options{Addr: centralAddr, Cluster: rediscfg.EnvBool("CENTRAL_CLUSTER")})
	region := rediscfg.New(rediscfg.Options{Addr: regionAddr, Cluster: rediscfg.EnvBool("REGION_CLUSTER")})
```

Replace the single-node keyspace-config line (line 95):

```go
	_ = region.ConfigSet(ctx, "notify-keyspace-events", "KEA").Err()
```

with a per-master fan-out:

```go
	// Enable keyspace notifications on every region master — in cluster mode each
	// node must be configured (and later subscribed) independently.
	_ = rediscfg.ForEachMaster(ctx, region, func(ctx context.Context, shard *redis.Client) error {
		return shard.ConfigSet(ctx, "notify-keyspace-events", "KEA").Err()
	})
```

- [ ] **Step 4: Rewrite `subscribeChanges` to fan out per master**

Replace the whole `subscribeChanges` function (lines 147-178) with:

```go
// subscribeChanges streams region key changes (set/del) to the browser. In
// cluster mode keyspace events fire only on the node owning each key, so it
// subscribes on every master; in single-node mode ForEachMaster runs the pump
// once against the one client (identical to the previous behavior).
func subscribeChanges(ctx context.Context, c redis.UniversalClient, h *hub) {
	_ = rediscfg.ForEachMaster(ctx, c, func(ctx context.Context, shard *redis.Client) error {
		// Start the pump and return immediately: a blocking read here would
		// prevent ForEachMaster from returning across the other masters.
		go pumpKeyevents(ctx, shard, h)
		return nil
	})
	// Preserve the prior contract that this call blocks until shutdown so the
	// caller's WaitGroup tracks the subscription's lifetime.
	<-ctx.Done()
}

// pumpKeyevents forwards one master's set/del keyspace events to the hub.
func pumpKeyevents(ctx context.Context, c *redis.Client, h *hub) {
	sub := c.PSubscribe(ctx, "__keyevent@0__:set", "__keyevent@0__:del")
	defer func() { _ = sub.Close() }()
	ch := sub.Channel()
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			key := msg.Payload
			if !strings.HasPrefix(key, "lb:") {
				continue
			}
			op := "set"
			if strings.HasSuffix(msg.Channel, ":del") {
				op = "del"
			}
			val := ""
			if op == "set" {
				// The key lives on this master, so Get on the shard client resolves
				// without a redirect.
				val, _ = c.Get(ctx, key).Result()
			}
			b, _ := json.Marshal(map[string]any{
				"type": "event", "op": op, "key": key, "value": val, "ts_ms": time.Now().UnixMilli(),
			})
			h.broadcast(b)
		}
	}
}
```

- [ ] **Step 5: Rewrite `scanAll` to fan out per master**

Replace the whole `scanAll` function (lines 180-200) with:

```go
// scanAll loads every key matching pattern and its string value into a map. In
// cluster mode SCAN only covers the connected node, so it scans every master and
// merges the results; in single-node mode ForEachMaster runs once. Per-key GET on
// the owning shard resolves without a redirect. Partial results are returned on
// error (graceful degradation, matching the previous behavior).
func scanAll(ctx context.Context, c redis.UniversalClient, match string) map[string]string {
	out := map[string]string{}
	var mu sync.Mutex
	_ = rediscfg.ForEachMaster(ctx, c, func(ctx context.Context, shard *redis.Client) error {
		var cursor uint64
		for {
			keys, cur, err := shard.Scan(ctx, cursor, match, 500).Result()
			if err != nil {
				return err
			}
			for _, k := range keys {
				if v, err := shard.Get(ctx, k).Result(); err == nil {
					mu.Lock()
					out[k] = v
					mu.Unlock()
				}
			}
			cursor = cur
			if cursor == 0 {
				break
			}
		}
		return nil
	})
	return out
}
```

- [ ] **Step 6: Widen `pollLoop` client parameter types**

In `pollLoop` (line 202), change the signature:

Replace:

```go
func pollLoop(ctx context.Context, central, region *redis.Client, writerURL, sinkURL, match string, h *hub) {
```

with:

```go
func pollLoop(ctx context.Context, central, region redis.UniversalClient, writerURL, sinkURL, match string, h *hub) {
```

(The body calls only `scanAll`, which now takes `redis.UniversalClient` — no other change needed.)

- [ ] **Step 7: Build and test**

Run: `go build ./internal/dashboard/ && go test ./internal/dashboard/ -v`
Expected: PASS — `central`/`region` are now `redis.UniversalClient`; `subscribeChanges` and `pollLoop` accept that type; `divergence_test.go` is unaffected.

- [ ] **Step 8: Full-module build + vet to catch dropped imports**

Run: `go build ./... && go vet ./...`
Expected: no output (success) — confirms no unused/missing imports across all five components after the type changes.

- [ ] **Step 9: Commit**

```bash
git add internal/dashboard/main.go
git commit -m "feat(dashboard): cluster master fan-out for SCAN/keyspace/CONFIG SET"
```

---

### Task 7: chart helpers — `cluster` + `connectKind` with fail-closed guard

**Files:**
- Modify: `redis-cdc-le-k8s/chart/templates/_helpers.tpl` (append after line 130)
- Modify: `redis-cdc-le-k8s/chart/values.yaml:44-53`

- [ ] **Step 1: Add the `cluster` value to both external blocks**

In `chart/values.yaml`, the `redis.central.external` and `redis.region.external` blocks currently read:

```yaml
  central:
    external:
      enabled: false
      url: ""                      # required when enabled, e.g. "redis://redis.prod:6379"
      authSecret: ""               # RESERVED — v1 does NOT consume it (see spec §2 non-goals)
  region:
    external:
      enabled: false
      url: ""
      authSecret: ""               # RESERVED — v1 does NOT consume it
```

Add a `cluster:` line to each external block:

```yaml
  central:
    external:
      enabled: false
      url: ""                      # required when enabled, e.g. "redis://redis.prod:6379"
      cluster: false               # route to url with a ClusterClient; requires enabled: true
      authSecret: ""               # RESERVED — v1 does NOT consume it (see spec §2 non-goals)
  region:
    external:
      enabled: false
      url: ""
      cluster: false               # route to url with a ClusterClient; requires enabled: true
      authSecret: ""               # RESERVED — v1 does NOT consume it
```

- [ ] **Step 2: Add the helpers**

In `chart/templates/_helpers.tpl`, append after the `rrcs.redis.region.hostPort` definition (after line 130):

```
{{/*
rrcs.redis.{central,region}.cluster — "true"/"false" for the Go components'
*_CLUSTER env and the verifier's -redis-*-cluster flags. Fail-closed:
cluster=true requires external.enabled=true, because a ClusterClient pointed at
the bundled single-node Redis errors on CLUSTER SLOTS. Caught at template time
rather than crash-looping the pod (mirrors the rediss:// guard above).
*/}}
{{- define "rrcs.redis.central.cluster" -}}
{{- if .Values.redis.central.external.cluster -}}
{{- if not .Values.redis.central.external.enabled -}}
{{- fail "redis.central.external.cluster=true requires redis.central.external.enabled=true (cluster mode applies only to an external Redis Cluster; the bundled redis-central is single-node)." -}}
{{- end -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.cluster" -}}
{{- if .Values.redis.region.external.cluster -}}
{{- if not .Values.redis.region.external.enabled -}}
{{- fail "redis.region.external.cluster=true requires redis.region.external.enabled=true (cluster mode applies only to an external Redis Cluster; the bundled redis-region is single-node)." -}}
{{- end -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
rrcs.redis.{central,region}.connectKind — "cluster"/"simple" for the redpanda-
connect redis components. Wraps the guarded .cluster helper so the toggle has one
source of truth.
*/}}
{{- define "rrcs.redis.central.connectKind" -}}
{{- if eq (include "rrcs.redis.central.cluster" .) "true" -}}cluster{{- else -}}simple{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.connectKind" -}}
{{- if eq (include "rrcs.redis.region.cluster" .) "true" -}}cluster{{- else -}}simple{{- end -}}
{{- end -}}
```

- [ ] **Step 3: Render-test the helpers (default + guard)**

Run (default render must succeed and show single-node defaults later; here just confirm it renders):

```bash
helm template t chart/ >/dev/null && echo "DEFAULT_RENDER_OK"
```
Expected: `DEFAULT_RENDER_OK`.

Run the fail-closed guard:

```bash
helm template t chart/ --set redis.region.external.cluster=true 2>&1 | grep -c "requires redis.region.external.enabled=true"
```
Expected: `1` (the render fails with the guard message because `enabled` is still false).

- [ ] **Step 4: Commit**

```bash
git add chart/templates/_helpers.tpl chart/values.yaml
git commit -m "feat(chart): cluster/connectKind helpers + external.cluster value (fail-closed)"
```

---

### Task 8: chart wiring — Go env/flags + connect `kind`

**Files:**
- Modify: `redis-cdc-le-k8s/chart/templates/latency-calculator.yaml:25-26`
- Modify: `redis-cdc-le-k8s/chart/templates/writer.yaml:42-43`
- Modify: `redis-cdc-le-k8s/chart/templates/dashboard.yaml:25-28`
- Modify: `redis-cdc-le-k8s/chart/templates/verifier-job.yaml:31-32`
- Modify: `redis-cdc-le-k8s/chart/files/connect/cdc-forward.yaml:18`
- Modify: `redis-cdc-le-k8s/chart/files/connect/cdc-reverse.yaml:58,76,88,100`

- [ ] **Step 1: latency-calculator env**

In `chart/templates/latency-calculator.yaml`, the env block has:

```yaml
            - name: REGION_ADDR
              value: {{ include "rrcs.redis.region.hostPort" . | quote }}
```

Add immediately after it:

```yaml
            - name: REGION_CLUSTER
              value: {{ include "rrcs.redis.region.cluster" . | quote }}
```

- [ ] **Step 2: writer env**

In `chart/templates/writer.yaml`, after:

```yaml
            - name: REDIS_ADDR
              value: {{ include "rrcs.redis.central.hostPort" . | quote }}
```

add:

```yaml
            - name: REDIS_CLUSTER
              value: {{ include "rrcs.redis.central.cluster" . | quote }}
```

- [ ] **Step 3: dashboard env**

In `chart/templates/dashboard.yaml`, after the `CENTRAL_ADDR` and `REGION_ADDR` env entries (lines 25-28), add the two toggles. The block becomes:

```yaml
            - name: CENTRAL_ADDR
              value: {{ include "rrcs.redis.central.hostPort" . | quote }}
            - name: CENTRAL_CLUSTER
              value: {{ include "rrcs.redis.central.cluster" . | quote }}
            - name: REGION_ADDR
              value: {{ include "rrcs.redis.region.hostPort" . | quote }}
            - name: REGION_CLUSTER
              value: {{ include "rrcs.redis.region.cluster" . | quote }}
```

(Match the exact existing indentation/values of the `CENTRAL_ADDR`/`REGION_ADDR` lines; only the two `*_CLUSTER` entries are new.)

- [ ] **Step 4: verifier flags**

In `chart/templates/verifier-job.yaml`, after:

```yaml
            - --redis-central={{ include "rrcs.redis.central.hostPort" . }}
            - --redis-region={{ include "rrcs.redis.region.hostPort" . }}
```

add:

```yaml
            - --redis-central-cluster={{ include "rrcs.redis.central.cluster" . }}
            - --redis-region-cluster={{ include "rrcs.redis.region.cluster" . }}
```

- [ ] **Step 5: connect source kind**

In `chart/files/connect/cdc-forward.yaml`, replace line 18:

```yaml
    kind: simple
```

with:

```yaml
    kind: {{ include "rrcs.redis.central.connectKind" . }}
```

- [ ] **Step 6: connect sink kind (×4)**

In `chart/files/connect/cdc-reverse.yaml`, replace each of the four `kind: simple` lines (58, 76, 88, 100) with (preserving each line's existing indentation):

```yaml
kind: {{ include "rrcs.redis.region.connectKind" . }}
```

There are exactly four `redis` components (xadd, set, del, eval) — all on the region Redis, so all use `region.connectKind`.

- [ ] **Step 7: Render-test defaults (single-node)**

Run:

```bash
helm template t chart/ | grep -E "REGION_CLUSTER|REDIS_CLUSTER|CENTRAL_CLUSTER|redis-central-cluster|redis-region-cluster" | sort -u
```
Expected: every toggle renders `"false"` (env) / `=false` (flags).

Run:

```bash
helm template t chart/ | grep -E "kind:" 
```
Expected: the connect `kind:` lines render `simple`.

- [ ] **Step 8: Render-test cluster-on (external enabled)**

Run:

```bash
helm template t chart/ \
  --set redis.region.external.enabled=true --set redis.region.external.url=redis://region-seed:6379 --set redis.region.external.cluster=true \
  --set redis.central.external.enabled=true --set redis.central.external.url=redis://central-seed:6379 --set redis.central.external.cluster=true \
  | grep -E "REGION_CLUSTER|REDIS_CLUSTER|CENTRAL_CLUSTER|redis-(central|region)-cluster|kind:"
```
Expected: `*_CLUSTER` env render `"true"`, the verifier flags render `=true`, and the connect `kind:` lines render `cluster`.

- [ ] **Step 9: Commit**

```bash
git add chart/templates/latency-calculator.yaml chart/templates/writer.yaml \
        chart/templates/dashboard.yaml chart/templates/verifier-job.yaml \
        chart/files/connect/cdc-forward.yaml chart/files/connect/cdc-reverse.yaml
git commit -m "feat(chart): wire cluster toggle into Go env/flags and connect kind"
```

---

### Task 9: Full verification sweep

**Files:** none (verification only)

- [ ] **Step 1: Go build + vet + test, whole module**

Run: `go build ./... && go vet ./... && go test ./...`
Expected: all packages build, vet clean, all tests PASS.

- [ ] **Step 2: Helm lint**

Run: `helm lint chart/`
Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 3: Default render is unchanged in spirit (single-node)**

Run:

```bash
helm template t chart/ | grep -E "kind:|_CLUSTER|cluster=" | sort -u
```
Expected: only `simple` / `false` values — the chart's bundled single-node behavior is preserved when no external cluster is configured.

- [ ] **Step 4: Commit any final touch-ups (if needed)**

If steps 1-3 surfaced nothing to change, there is nothing to commit. Otherwise fix and:

```bash
git add -A && git commit -m "fix: address verification-sweep findings"
```

---

## Self-Review notes (author)

- **Spec coverage:** helper (§1) → Task 1-2; component swaps (§2) → Task 3-6; selection toggle (§3) → Tasks 3-6 + 8; dashboard fan-out (§4) → Task 6; connect data plane (§5) → Task 8 steps 5-6; chart wiring + guard (§6) → Task 7-8; testing (§Testing) → Tasks 1-2, 9 + documented cluster-integration gap.
- **Type consistency:** `redis.UniversalClient` used uniformly for `Worker.RDB`, `RedisClient.rdb`, dashboard `central`/`region`/`pollLoop`; `rediscfg.New`/`Options`/`ForEachMaster`/`EnvBool` signatures identical across all call sites.
- **Known non-unit-tested path:** `ForEachMaster`'s cluster branch and all live cluster routing require a real multi-node cluster — verified manually/CI per spec, not in unit tests. Flagged in Task 2.
