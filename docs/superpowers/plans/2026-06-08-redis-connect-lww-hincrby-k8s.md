# redis-connect-lww-hincrby-k8s Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Kubernetes/Helm lab proving that with versions minted by a shared `HINCRBY` counter (no local counter), multiple uncoordinated writers writing to the *same* keys across 3 connect-sources + 3 connect-sinks preserve the per-key last-write-wins fence exactly — across `set`, `delete` (tombstone+GC), and atomic `standby→active` rename — and that finds the max sustained throughput at which this holds.

**Architecture:** Fork of `labs/redis-connect-lww-multi-k8s/`. The data path is unchanged (Redis Streams → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis) except: (1) the writer mints every version via `HINCRBY` on source Redis and draws keys from a *shared* space; (2) the sink Lua gains a delete-tombstone branch and a new atomic dual-key rename script; (3) a GC sweeper reaps tombstones; (4) the verifier compares region state against a per-epoch `srcmax` authoritative hash and runs a rate sweep; (5) a Go report generator emits a static HTML report.

**Tech Stack:** Go 1.23 (writer, verifier, gc-sweeper, report-gen), Redis 7.4, NATS JetStream 2.10, Redpanda Connect 4.92, Helm 3, kind, bash harness.

**Spec:** `docs/superpowers/specs/2026-06-08-redis-connect-lww-hincrby-k8s-design.md`

---

## Conventions & key decisions (read before starting)

- **Lab dir:** `labs/redis-connect-lww-hincrby-k8s/`. All paths below are relative to it unless they start with `labs/` or `docs/`.
- **Parent dir (read-only reference):** `labs/redis-connect-lww-multi-k8s/`.
- **Host ports:** parent uses none persistently (k8s). The dashboard forward script binds 8080; keep.
- **Version minting:** `HINCRBY kv:ver <kv_key> 1` for set/delete; `HINCRBY kv:gver global 1` for rename. No in-process counter anywhere.
- **Authoritative source-of-truth max (per key, per run):** writer records every minted version into a per-epoch hash `srcmax:<epoch>` on **central** Redis via `hmax.lua` (HSET field→max). The verifier reads `HGETALL srcmax:<epoch>` and compares each field to region `HGET <key> ver`. Tombstoned keys retain `ver==max` so they still match.
- **Run isolation:** keys embed the epoch in the hash tag: `lb:<domain>:<status>:{<entity>:<epoch>-<id>}`. A new epoch ⇒ new key namespace ⇒ region/srcmax naturally empty (no FLUSHDB, mirrors parent). `kv:gver` stays globally monotonic across epochs (harmless — active keys are epoch-fresh).
- **Op contract on the wire (XADD fields):** `event_id`, `key`, `op` (`set|delete|rename`), `version`, `value`, `t_send_ms`, `pattern`; rename adds `old_key`, `new_key`.
- **Lua eval result contract (unchanged):** `1` applied, `0` stale, `-1` duplicate — so the parent's `lww_apply` metric + verifier scrapers keep working.
- **TDD:** Go via `go test`; Lua via an ephemeral-redis bash harness (`scripts/test-lua.sh`). Commit after every green step.
- **Go module names:** keep parent's (`writer`, `verifier`); new binaries get their own modules (`gc-sweeper`, `report-gen`).

## File structure (created/modified)

```
labs/redis-connect-lww-hincrby-k8s/
├── chart/
│   ├── Chart.yaml                       MODIFY (name)
│   ├── values.yaml                      MODIFY (+writer opWeights/keyspace, +gc, +sweep, +report; rm dashboard if unused)
│   ├── values-dev.yaml                  MODIFY (image tags)
│   ├── files/connect/
│   │   ├── lww_set.lua                  MODIFY (+delete branch, +op/now/event_id args)
│   │   ├── lww_rename.lua               CREATE (atomic dual-key)
│   │   ├── hmax.lua                     CREATE (HSET→max, used by writer)
│   │   ├── lww-forward.yaml             MODIFY (carry op/old_key/new_key metadata)
│   │   └── lww-reverse.yaml             MODIFY (route set/delete vs rename to the right EVAL)
│   └── templates/
│       ├── connect-configmaps.yaml      MODIFY (mount new lua + reverse routing)
│       ├── gc-sweeper.yaml              CREATE (Deployment + metrics Service)
│       ├── report-job.yaml              CREATE (report-gen Job, harness-rendered)
│       ├── writer.yaml                  MODIFY (new env)
│       ├── verifier-job.yaml            MODIFY (new flags: central srcmax, sweep tier)
│       └── dashboard.yaml               KEEP (optional live view)
├── writer/
│   ├── version.go                       REPLACE (HINCRBY Minter; delete local counter)
│   ├── keys.go                          CREATE (3 patterns, hash-tag, epoch)
│   ├── ops.go                           CREATE (weighted op picker)
│   ├── worker.go                        MODIFY (shared keyspace, op-mix, mint+record+XADD)
│   ├── http.go                          MODIFY (/state from epoch+counts only; keep /reset,/rate,/metrics)
│   ├── main.go                          MODIFY (wire Minter, OpPicker, keyspace)
│   └── *_test.go                        CREATE/MODIFY (keys, ops, minter, worker)
├── gc-sweeper/                          CREATE (Go: scan tombstones, DEL, metrics)
│   ├── go.mod, main.go, sweep.go, sweep_test.go, Dockerfile
├── report-gen/                          CREATE (Go: sweep.json → report.html)
│   ├── go.mod, main.go, render.go, render_test.go, templates/report.html.tmpl, Dockerfile
├── verifier/
│   ├── redis.go                         MODIFY (+HGetAll srcmax, +HGetField)
│   ├── lww.go                           MODIFY (CompareSrcMax against central srcmax:<epoch>)
│   ├── main.go                          MODIFY (read srcmax for compare; emit op/tombstone stats)
│   └── *_test.go                        MODIFY
├── scripts/
│   ├── build-images.sh                  MODIFY (+gc-sweeper, +report-gen images)
│   ├── build-binaries.sh                CREATE (local Go builds → ./bin, no Docker)
│   ├── test-lua.sh                      CREATE (ephemeral-redis Lua tests)
│   ├── proof-mwplus.sh                  CREATE (positive: HINCRBY multi-writer safe)
│   ├── proof-delete.sh                  CREATE (tombstone + no-resurrect)
│   ├── proof-rename.sh                  CREATE (atomic standby→active pairing)
│   ├── proof-c.sh                       KEEP (negative control; relabel in README)
│   ├── verify-lww.sh                    MODIFY (run all proofs + rate sweep + report)
│   └── lib/run-defaults.sh              MODIFY (+SWEEP_TIERS)
├── README.md                            MODIFY (new property, ops, proofs, report)
├── RESEARCH.md                          MODIFY (HINCRBY/delete/rename/GC design)
└── docs/derisk-notes.md                 KEEP
```

---

## Phase 0 — Scaffold the fork

### Task 0.1: Copy the parent lab to the new directory

**Files:**
- Create: `labs/redis-connect-lww-hincrby-k8s/` (copy of parent)

- [ ] **Step 1: Copy the tree (excluding build artifacts)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
rsync -a --exclude 'reports/' --exclude 'bin/' \
  --exclude 'verifier/verifier' \
  labs/redis-connect-lww-multi-k8s/ labs/redis-connect-lww-hincrby-k8s/
```

- [ ] **Step 2: Remove the prebuilt verifier binary if copied**

```bash
cd labs/redis-connect-lww-hincrby-k8s
rm -f verifier/verifier
```

- [ ] **Step 3: Verify the tree exists and compiles as-is (Go)**

Run: `cd labs/redis-connect-lww-hincrby-k8s/writer && go build ./... && cd ../verifier && go build ./...`
Expected: both build with no error (it's an exact copy of working code).

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-hincrby-k8s
git commit -m "lww-hincrby-k8s: scaffold fork of redis-connect-lww-multi-k8s"
```

### Task 0.2: Rename the chart

**Files:**
- Modify: `chart/Chart.yaml`

- [ ] **Step 1: Set the chart name**

In `chart/Chart.yaml` change:
```yaml
name: redis-connect-lww-k8s
```
to:
```yaml
name: redis-connect-lww-hincrby-k8s
```

- [ ] **Step 2: Render to confirm the chart still templates**

Run: `helm template t ./chart --set profile=lww >/dev/null && echo OK`
Expected: `OK` (no template errors).

- [ ] **Step 3: Commit**

```bash
git add chart/Chart.yaml
git commit -m "lww-hincrby-k8s: rename chart"
```

---

## Phase 1 — Lua fences (TDD via ephemeral redis)

### Task 1.1: Lua test harness

**Files:**
- Create: `scripts/test-lua.sh`

- [ ] **Step 1: Write the harness (it will fail until scripts behave)**

Create `scripts/test-lua.sh`:
```bash
#!/usr/bin/env bash
# Unit-tests the sink Lua scripts against an ephemeral Redis container.
# No host changes: spins `redis:7.4-alpine`, evals scripts, asserts, tears down.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA="${LAB_DIR}/chart/files/connect"
CID="$(docker run -d --rm redis:7.4-alpine)"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# wait for ready
for _ in $(seq 1 30); do docker exec "$CID" redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 0.3; done

cp "${LUA}/lww_set.lua" /tmp/lww_set.lua 2>/dev/null || true
docker cp "${LUA}/lww_set.lua" "$CID":/tmp/lww_set.lua
docker cp "${LUA}/lww_rename.lua" "$CID":/tmp/lww_rename.lua
EV() { docker exec "$CID" redis-cli --eval "$@"; }
HGET() { docker exec "$CID" redis-cli HGET "$@"; }
fail=0
assert() { # $1=desc $2=got $3=want
  if [ "$2" != "$3" ]; then echo "FAIL: $1: got '$2' want '$3'"; fail=1; else echo "ok: $1"; fi
}

# ---- lww_set: set newer wins, older stale, equal duplicate ----
docker exec "$CID" redis-cli DEL k1 >/dev/null
assert "set v3 applied"   "$(EV /tmp/lww_set.lua k1 , v3 3 set 1000 e1)" "1"
assert "set v1 stale"     "$(EV /tmp/lww_set.lua k1 , v1 1 set 1001 e2)" "0"
assert "set v3 duplicate" "$(EV /tmp/lww_set.lua k1 , v3 3 set 1002 e3)" "-1"
assert "k1 ver==3"        "$(HGET k1 ver)" "3"
assert "k1 val==v3"       "$(HGET k1 val)" "v3"
assert "k1 deleted==0"    "$(HGET k1 deleted)" "0"

# ---- lww_set: delete tombstone retains ver, blocks resurrection ----
docker exec "$CID" redis-cli DEL k2 >/dev/null
EV /tmp/lww_set.lua k2 , a 5 set 2000 e4 >/dev/null
assert "delete v6 applied"   "$(EV /tmp/lww_set.lua k2 , '' 6 delete 2001 e5)" "1"
assert "k2 deleted==1"       "$(HGET k2 deleted)" "1"
assert "k2 tombstone ver==6" "$(HGET k2 ver)" "6"
assert "stale set v4 after delete -> stale" "$(EV /tmp/lww_set.lua k2 , resurrect 4 set 2002 e6)" "0"
assert "k2 still deleted==1 (no resurrect)" "$(HGET k2 deleted)" "1"
assert "newer set v7 after delete revives"  "$(EV /tmp/lww_set.lua k2 , back 7 set 2003 e7)" "1"
assert "k2 deleted==0 after revive"         "$(HGET k2 deleted)" "0"

# ---- lww_rename: atomic standby->active ----
OLD='lb:company:standby:{employees:run-9}'
NEW='lb:company:active:{employees:run-9}'
docker exec "$CID" redis-cli DEL "$OLD" "$NEW" >/dev/null
EV /tmp/lww_set.lua "$OLD" , standbyval 2 set 3000 e8 >/dev/null
assert "rename v10 applied" "$(docker exec "$CID" redis-cli --eval /tmp/lww_rename.lua "$OLD" "$NEW" , activeval 10 3001 e9)" "1"
assert "new active ver==10"  "$(HGET "$NEW" ver)" "10"
assert "new active val"      "$(HGET "$NEW" val)" "activeval"
assert "new active live"     "$(HGET "$NEW" deleted)" "0"
assert "old standby tombstoned" "$(HGET "$OLD" deleted)" "1"
assert "rename v10 duplicate" "$(docker exec "$CID" redis-cli --eval /tmp/lww_rename.lua "$OLD" "$NEW" , again 10 3002 e10)" "-1"
assert "stale rename v8 -> stale" "$(docker exec "$CID" redis-cli --eval /tmp/lww_rename.lua "$OLD" "$NEW" , older 8 3003 e11)" "0"

[ "$fail" = 0 ] && echo "ALL LUA TESTS PASS" || { echo "LUA TESTS FAILED"; exit 1; }
```

```bash
chmod +x scripts/test-lua.sh
```

- [ ] **Step 2: Run it — expect failure (lww_rename.lua missing, lww_set arg mismatch)**

Run: `bash scripts/test-lua.sh`
Expected: FAIL — `lww_rename.lua` does not exist / `lww_set` ignores new args. (Docker required.)

- [ ] **Step 3: Commit the test**

```bash
git add scripts/test-lua.sh
git commit -m "lww-hincrby-k8s: add ephemeral-redis Lua test harness (red)"
```

### Task 1.2: Extend `lww_set.lua` with delete + tombstone

**Files:**
- Modify: `chart/files/connect/lww_set.lua`

- [ ] **Step 1: Replace the script body**

Replace `chart/files/connect/lww_set.lua` with:
```lua
-- lww_set.lua — last-write-wins compare-and-set fence (set + delete tombstone).
-- KEYS[1]=kv_key
-- ARGV[1]=value  ARGV[2]=version  ARGV[3]=op (set|delete)  ARGV[4]=now_ms  ARGV[5]=event_id
-- returns: 1 = applied (strictly newer or first write)
--          0 = stale     (strictly older — only under reordering)
--         -1 = duplicate (equal version — routine at-least-once redelivery)
local v = tonumber(ARGV[2])
if v == nil then
  return redis.error_reply('lww_set: non-numeric version: ' .. tostring(ARGV[2]))
end
local op  = ARGV[3]
local now = ARGV[4]
local eid = ARGV[5]
local cur = redis.call('HGET', KEYS[1], 'ver')
if cur ~= false then
  local c = tonumber(cur)
  if c ~= nil then
    if v < c then return 0 end
    if v == c then return -1 end
  end
end
if op == 'delete' then
  redis.call('HSET', KEYS[1], 'ver', v, 'deleted', '1', 'deleted_at', now, 'val', '', 'src_event_id', eid)
else
  redis.call('HSET', KEYS[1], 'ver', v, 'deleted', '0', 'updated_at', now, 'val', ARGV[1], 'src_event_id', eid)
end
return 1
```

- [ ] **Step 2: Re-run the Lua harness — set + delete sections should pass, rename still fails**

Run: `bash scripts/test-lua.sh`
Expected: all `lww_set` assertions `ok:`; still FAILs at the rename section (script missing).

- [ ] **Step 3: Commit**

```bash
git add chart/files/connect/lww_set.lua
git commit -m "lww-hincrby-k8s: lww_set.lua handles delete tombstone + resurrection guard"
```

### Task 1.3: Add `lww_rename.lua` (atomic dual-key)

**Files:**
- Create: `chart/files/connect/lww_rename.lua`

- [ ] **Step 1: Write the script**

Create `chart/files/connect/lww_rename.lua`:
```lua
-- lww_rename.lua — atomic standby->active promotion under one global version.
-- KEYS[1]=old_key (…standby…)  KEYS[2]=new_key (…active…)  -- same hash tag => same slot
-- ARGV[1]=value (new active snapshot)  ARGV[2]=version (global)  ARGV[3]=now_ms  ARGV[4]=event_id
-- returns: 1 applied, 0 stale (lost the active CAS), -1 duplicate
local v = tonumber(ARGV[2])
if v == nil then
  return redis.error_reply('lww_rename: non-numeric version: ' .. tostring(ARGV[2]))
end
local now = ARGV[3]
local eid = ARGV[4]
-- Gate the whole promotion on the NEW (active) key: apply only if strictly newest.
local curNew = redis.call('HGET', KEYS[2], 'ver')
if curNew ~= false then
  local cn = tonumber(curNew)
  if cn ~= nil then
    if v < cn then return 0 end
    if v == cn then return -1 end
  end
end
redis.call('HSET', KEYS[2], 'ver', v, 'deleted', '0', 'updated_at', now, 'val', ARGV[1], 'src_event_id', eid)
-- Tombstone the old (standby) key, but never roll its ver backwards.
local curOld = redis.call('HGET', KEYS[1], 'ver')
local applyOld = true
if curOld ~= false then
  local co = tonumber(curOld)
  if co ~= nil and v <= co then applyOld = false end
end
if applyOld then
  redis.call('HSET', KEYS[1], 'ver', v, 'deleted', '1', 'deleted_at', now, 'val', '', 'src_event_id', eid)
end
return 1
```

- [ ] **Step 2: Run the full Lua harness — all green**

Run: `bash scripts/test-lua.sh`
Expected: `ALL LUA TESTS PASS`.

- [ ] **Step 3: Commit**

```bash
git add chart/files/connect/lww_rename.lua
git commit -m "lww-hincrby-k8s: add atomic dual-key lww_rename.lua"
```

### Task 1.4: Add `hmax.lua` (writer's srcmax recorder)

**Files:**
- Create: `chart/files/connect/hmax.lua`

- [ ] **Step 1: Write the script**

Create `chart/files/connect/hmax.lua`:
```lua
-- hmax.lua — set hash field to max(current, incoming). Used by the writer to
-- record the authoritative per-key source max version into srcmax:<epoch>.
-- KEYS[1]=hash  ARGV[1]=field  ARGV[2]=value(int)
local cur = redis.call('HGET', KEYS[1], ARGV[1])
local v = tonumber(ARGV[2])
if cur == false or v > tonumber(cur) then
  redis.call('HSET', KEYS[1], ARGV[1], v)
  return v
end
return tonumber(cur)
```

- [ ] **Step 2: Smoke it inline**

Run:
```bash
CID=$(docker run -d --rm redis:7.4-alpine); sleep 1
docker cp chart/files/connect/hmax.lua $CID:/tmp/hmax.lua
echo "want 5:"; docker exec $CID redis-cli --eval /tmp/hmax.lua h , f 5
echo "want 5:"; docker exec $CID redis-cli --eval /tmp/hmax.lua h , f 3
echo "want 9:"; docker exec $CID redis-cli --eval /tmp/hmax.lua h , f 9
docker rm -f $CID >/dev/null
```
Expected: `5`, `5`, `9`.

- [ ] **Step 3: Commit**

```bash
git add chart/files/connect/hmax.lua
git commit -m "lww-hincrby-k8s: add hmax.lua (writer srcmax recorder)"
```

---

## Phase 2 — Writer: HINCRBY minting, shared keyspace, op-mix

### Task 2.1: Key construction (`keys.go`)

**Files:**
- Create: `writer/keys.go`
- Test: `writer/keys_test.go`

- [ ] **Step 1: Write the failing test**

Create `writer/keys_test.go`:
```go
package main

import "testing"

func TestPatternKeyShape(t *testing.T) {
	p := Pattern{Domain: "company", Entity: "employees"}
	got := p.Key("active", "run-1", 55688)
	want := "lb:company:active:{employees:run-1-55688}"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestActiveStandbyShareHashTag(t *testing.T) {
	p := Pattern{Domain: "company", Entity: "employees"}
	a := p.Key("active", "e", 7)
	s := p.Key("standby", "e", 7)
	tag := func(k string) string { return k[len(k)-len("{employees:e-7}"):] }
	if tag(a) != tag(s) {
		t.Fatalf("hash tags differ: %q vs %q", a, s)
	}
}

func TestThreePatterns(t *testing.T) {
	if len(Patterns) != 3 {
		t.Fatalf("want 3 patterns, got %d", len(Patterns))
	}
}
```

- [ ] **Step 2: Run — expect compile failure**

Run: `cd writer && go test ./... -run TestPattern -v`
Expected: FAIL (undefined `Pattern`, `Patterns`).

- [ ] **Step 3: Implement `keys.go`**

Create `writer/keys.go`:
```go
package main

import "fmt"

// Pattern is one of the three required key families.
type Pattern struct {
	Domain string // company | functions | general
	Entity string // employees | groups | items
}

// Patterns are the three required key families (lab-requirements.md §1).
var Patterns = []Pattern{
	{"company", "employees"},
	{"functions", "groups"},
	{"general", "items"},
}

// Key renders lb:<domain>:<status>:{<entity>:<epoch>-<id>}. The hash tag
// {<entity>:<epoch>-<id>} is shared by the active and standby variants of one id,
// so an atomic dual-key rename lands on a single slot. The epoch isolates re-runs
// without flushing (region/srcmax start empty for a fresh epoch).
func (p Pattern) Key(status, epoch string, id int64) string {
	return fmt.Sprintf("lb:%s:%s:{%s:%s-%d}", p.Domain, status, p.Entity, epoch, id)
}
```

- [ ] **Step 4: Run — green**

Run: `cd writer && go test ./... -run 'TestPattern|TestActive|TestThree' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add writer/keys.go writer/keys_test.go
git commit -m "lww-hincrby-k8s: writer key patterns with epoch + shared hash tag"
```

### Task 2.2: Weighted op picker (`ops.go`)

**Files:**
- Create: `writer/ops.go`
- Test: `writer/ops_test.go`

- [ ] **Step 1: Write the failing test**

Create `writer/ops_test.go`:
```go
package main

import (
	"math/rand"
	"testing"
)

func TestOpPickerRespectsWeights(t *testing.T) {
	p := NewOpPicker(OpWeights{Set: 8, Delete: 1, Rename: 1}, rand.New(rand.NewSource(1)))
	counts := map[Op]int{}
	for i := 0; i < 100000; i++ {
		counts[p.Pick()]++
	}
	if counts[OpSet] < counts[OpDelete] || counts[OpSet] < counts[OpRename] {
		t.Fatalf("set should dominate: %+v", counts)
	}
	if counts[OpDelete] == 0 || counts[OpRename] == 0 {
		t.Fatalf("delete/rename never picked: %+v", counts)
	}
}

func TestOpPickerZeroWeightsDefaultsToSet(t *testing.T) {
	p := NewOpPicker(OpWeights{}, rand.New(rand.NewSource(1)))
	if p.Pick() != OpSet {
		t.Fatal("empty weights should default to set")
	}
}
```

- [ ] **Step 2: Run — expect compile failure**

Run: `cd writer && go test ./... -run TestOpPicker -v`
Expected: FAIL (undefined symbols).

- [ ] **Step 3: Implement `ops.go`**

Create `writer/ops.go`:
```go
package main

import "math/rand"

type Op string

const (
	OpSet    Op = "set"
	OpDelete Op = "delete"
	OpRename Op = "rename" // standby -> active
)

type OpWeights struct{ Set, Delete, Rename int }

// OpPicker is a weighted random selector over the three op types.
type OpPicker struct {
	cum   []int
	ops   []Op
	total int
	rnd   *rand.Rand
}

func NewOpPicker(w OpWeights, rnd *rand.Rand) *OpPicker {
	p := &OpPicker{rnd: rnd}
	add := func(op Op, wt int) {
		if wt <= 0 {
			return
		}
		p.total += wt
		p.cum = append(p.cum, p.total)
		p.ops = append(p.ops, op)
	}
	add(OpSet, w.Set)
	add(OpDelete, w.Delete)
	add(OpRename, w.Rename)
	return p
}

func (p *OpPicker) Pick() Op {
	if p.total == 0 {
		return OpSet
	}
	r := p.rnd.Intn(p.total)
	for i, c := range p.cum {
		if r < c {
			return p.ops[i]
		}
	}
	return p.ops[len(p.ops)-1]
}
```

- [ ] **Step 4: Run — green**

Run: `cd writer && go test ./... -run TestOpPicker -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add writer/ops.go writer/ops_test.go
git commit -m "lww-hincrby-k8s: writer weighted op picker"
```

### Task 2.3: HINCRBY minter (`version.go` replacement)

**Files:**
- Replace: `writer/version.go`
- Delete: `writer/version_test.go` (parent tests the local counter that no longer exists)
- Test: `writer/minter_test.go` (uses `miniredis`)

- [ ] **Step 1: Add miniredis dep**

Run: `cd writer && go get github.com/alicebob/miniredis/v2@v2.33.0`
Expected: `go.mod`/`go.sum` updated.

- [ ] **Step 2: Write the failing test**

Create `writer/minter_test.go`:
```go
package main

import (
	"context"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func newMini(t *testing.T) (*redis.Client, func()) {
	t.Helper()
	mr, err := miniredis.Run()
	if err != nil {
		t.Fatal(err)
	}
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	return rdb, func() { rdb.Close(); mr.Close() }
}

func TestMinterPerKeyMonotonicAcrossCallers(t *testing.T) {
	rdb, done := newMini(t)
	defer done()
	m := NewMinter(rdb)
	ctx := context.Background()
	// Two "writers" minting the SAME key: versions must be strictly increasing,
	// no collision — the HINCRBY property that makes multi-writer-same-key safe.
	seen := map[int64]bool{}
	last := int64(0)
	for i := 0; i < 10; i++ {
		for _, w := range []int{0, 1} {
			_ = w
			v, err := m.NextPerKey(ctx, "lb:company:active:{employees:e-1}")
			if err != nil {
				t.Fatal(err)
			}
			if seen[v] {
				t.Fatalf("version collision at %d", v)
			}
			if v <= last {
				t.Fatalf("non-monotonic: %d after %d", v, last)
			}
			seen[v], last = true, v
		}
	}
}

func TestMinterGlobalMonotonic(t *testing.T) {
	rdb, done := newMini(t)
	defer done()
	m := NewMinter(rdb)
	ctx := context.Background()
	a, _ := m.NextGlobal(ctx)
	b, _ := m.NextGlobal(ctx)
	if b <= a {
		t.Fatalf("global not monotonic: %d then %d", a, b)
	}
}
```

- [ ] **Step 3: Run — expect failure**

Run: `cd writer && go test ./... -run TestMinter -v`
Expected: FAIL (undefined `Minter`).

- [ ] **Step 4: Replace `version.go`**

Replace `writer/version.go` entirely with:
```go
package main

import (
	"context"

	"github.com/redis/go-redis/v9"
)

// Minter mints monotonic versions on the SOURCE Redis via HINCRBY — the shared
// atomic counter that makes multi-writer-same-key safe (design-doc §6). There is
// NO in-process counter: every version is minted by Redis, so concurrent writers
// on one key always get strictly-increasing, collision-free versions.
type Minter struct{ RDB *redis.Client }

func NewMinter(rdb *redis.Client) *Minter { return &Minter{RDB: rdb} }

// NextPerKey mints the next version for kv_key: HINCRBY kv:ver <kv_key> 1.
func (m *Minter) NextPerKey(ctx context.Context, kvKey string) (int64, error) {
	return m.RDB.HIncrBy(ctx, "kv:ver", kvKey, 1).Result()
}

// NextGlobal mints the next global version (rename must dominate two key
// sequences): HINCRBY kv:gver global 1.
func (m *Minter) NextGlobal(ctx context.Context) (int64, error) {
	return m.RDB.HIncrBy(ctx, "kv:gver", "global", 1).Result()
}
```

- [ ] **Step 5: Delete the obsolete local-counter test**

```bash
rm writer/version_test.go
```

- [ ] **Step 6: Run — green (minter tests pass; package may not yet build because worker.go still references old Versions — that's fixed in Task 2.4)**

Run: `cd writer && go test ./... -run TestMinter -v`
Expected: the package will FAIL TO COMPILE if `worker.go`/`main.go`/`http.go` still reference the removed `Versions` type. That is expected; proceed to Task 2.4 which updates them, then this test goes green. (If you prefer a green checkpoint here, do Task 2.4 before re-running.)

- [ ] **Step 7: Commit (WIP — compiles after 2.4)**

```bash
git add writer/version.go writer/minter_test.go writer/go.mod writer/go.sum
git rm writer/version_test.go
git commit -m "lww-hincrby-k8s: replace local counter with HINCRBY Minter"
```

### Task 2.4: Rewire the worker — shared keyspace, op-mix, mint+record+XADD

**Files:**
- Modify: `writer/worker.go`
- Modify: `writer/main.go`
- Modify: `writer/http.go`
- Test: `writer/worker_test.go` (replace parent's)

**Context:** The worker no longer owns a strided key subset; all workers draw ids from `[0, KeySpaceSize)` (shared → contention is the point). For each emission it: picks an op, builds the key(s), mints a version (`NextPerKey` for set/delete, `NextGlobal` for rename), records it into `srcmax:<epoch>` via `hmax.lua`, and XADDs the event with the `op` field. `/state` now reports only `boot_id`, `epoch`, and counts (the authoritative per-key max lives in `srcmax:<epoch>` on central, which the verifier reads directly).

- [ ] **Step 1: Write the failing test**

Replace `writer/worker_test.go` with:
```go
package main

import (
	"context"
	"math/rand"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func TestEmitOnceWritesStreamAndSrcmax(t *testing.T) {
	mr, err := miniredis.Run()
	if err != nil {
		t.Fatal(err)
	}
	defer mr.Close()
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	defer rdb.Close()
	ctx := context.Background()

	w := &Worker{
		ID: 0, Workers: 2, RDB: rdb, StreamKey: "app.events",
		StreamMaxLen: 1000, PayloadBytes: 8, KeySpaceSize: 4,
		Minter:   NewMinter(rdb),
		Counters: &Counters{},
		Ops:      NewOpPicker(OpWeights{Set: 1}, rand.New(rand.NewSource(1))),
		Epoch:    "run-test",
	}
	// emitOne performs: pick op, mint, record srcmax, build XADD args, and returns
	// the kv_key + version it used.
	key, ver, err := w.emitOne(ctx, rdb.Pipeline())
	if err != nil {
		t.Fatal(err)
	}
	if ver < 1 {
		t.Fatalf("version not minted: %d", ver)
	}
	// srcmax must hold the minted version for this key.
	got, err := rdb.HGet(ctx, "srcmax:run-test", key).Int64()
	if err != nil {
		t.Fatalf("srcmax missing for %s: %v", key, err)
	}
	if got != ver {
		t.Fatalf("srcmax=%d want %d", got, ver)
	}
}
```

> Note: `emitOne` is a new helper extracted from the emit loop so it is unit-testable. It takes a pipeline for the XADD but performs mint+record eagerly (they must precede XADD on the wire anyway). For the test we pass a throwaway pipeline and assert the side effects (mint + srcmax) that happen before `pipe.Exec`.

- [ ] **Step 2: Run — expect compile failure**

Run: `cd writer && go test ./... -run TestEmitOnce -v`
Expected: FAIL (undefined fields `Minter`, `Ops`, `Epoch`, method `emitOne`).

- [ ] **Step 3: Rewrite `worker.go`**

Replace `writer/worker.go` with:
```go
package main

import (
	"context"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID           int
	Workers      int
	RDB          *redis.Client
	StreamKey    string
	StreamMaxLen int64
	PipelineDepth int
	PayloadBytes int
	KeySpaceSize int64
	Lim          *Limiter
	Counters     *Counters
	Minter       *Minter
	Ops          *OpPicker
	// Epoch is read per batch from the shared EpochHolder so a concurrent /reset
	// is observed; set directly only in tests.
	Epoch       string
	EpochHolder *EpochHolder
}

func (w *Worker) epoch() string {
	if w.EpochHolder != nil {
		return w.EpochHolder.Get()
	}
	return w.Epoch
}

// emitOne picks an op, builds the key(s), mints a version (HINCRBY), records it
// into srcmax:<epoch> (hmax via HSET-max), and queues the XADD onto pipe. Returns
// the primary kv_key and version used. Mint + srcmax happen eagerly (they must
// precede the XADD on the wire); only the XADD is pipelined.
func (w *Worker) emitOne(ctx context.Context, pipe redis.Pipeliner) (string, int64, error) {
	epoch := w.epoch()
	pat := Patterns[w.Counters.Sent.Load()%int64(len(Patterns))]
	id := w.pickID()
	op := w.Ops.Pick()
	now := time.Now()
	nowMs := now.UnixMilli()
	eid := newEventID()
	pad := makePad(w.PayloadBytes)

	switch op {
	case OpRename:
		oldKey := pat.Key("standby", epoch, id)
		newKey := pat.Key("active", epoch, id)
		ver, err := w.Minter.NextGlobal(ctx)
		if err != nil {
			return "", 0, err
		}
		if err := w.recordSrcmax(ctx, epoch, newKey, ver); err != nil {
			return "", 0, err
		}
		if err := w.recordSrcmax(ctx, epoch, oldKey, ver); err != nil {
			return "", 0, err
		}
		val := payloadJSON(eid, nowMs, ver, pad)
		pipe.XAdd(ctx, &redis.XAddArgs{
			Stream: w.StreamKey, MaxLen: w.StreamMaxLen, Approx: true,
			Values: map[string]any{
				"value": val, "event_id": eid, "key": newKey, "old_key": oldKey,
				"new_key": newKey, "op": string(op), "pattern": pat.Domain,
				"t_send_ms": nowMs, "version": ver,
			},
		})
		return newKey, ver, nil
	default: // set | delete
		key := pat.Key("active", epoch, id)
		ver, err := w.Minter.NextPerKey(ctx, key)
		if err != nil {
			return "", 0, err
		}
		if err := w.recordSrcmax(ctx, epoch, key, ver); err != nil {
			return "", 0, err
		}
		val := ""
		if op == OpSet {
			val = payloadJSON(eid, nowMs, ver, pad)
		}
		pipe.XAdd(ctx, &redis.XAddArgs{
			Stream: w.StreamKey, MaxLen: w.StreamMaxLen, Approx: true,
			Values: map[string]any{
				"value": val, "event_id": eid, "key": key, "op": string(op),
				"pattern": pat.Domain, "t_send_ms": nowMs, "version": ver,
			},
		})
		return key, ver, nil
	}
}

func (w *Worker) pickID() int64 {
	// Shared keyspace: every worker draws from [0, KeySpaceSize) so writers
	// contend on the same keys (the multi-writer-same-key scenario).
	return int64(w.Counters.Sent.Load()) % w.KeySpaceSize
}

func (w *Worker) recordSrcmax(ctx context.Context, epoch, key string, ver int64) error {
	return w.RDB.Eval(ctx, hmaxScript, []string{"srcmax:" + epoch}, key, ver).Err()
}

func (w *Worker) Run(ctx context.Context) {
	for {
		rate := int(w.Lim.Current())
		depth := w.PipelineDepth
		if rate > 0 {
			if perTenth := rate / 10; perTenth >= 1 && perTenth < depth {
				depth = perTenth
			}
		}
		waitCtx, waitCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		err := w.Lim.WaitN(waitCtx, depth)
		waitCancel()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		if w.epoch() == "" {
			select {
			case <-ctx.Done():
				return
			case <-time.After(100 * time.Millisecond):
			}
			continue
		}
		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		var n int
		for i := 0; i < depth; i++ {
			if _, _, err := w.emitOne(ctx, pipe); err != nil {
				if ctx.Err() == nil {
					log.Printf("worker %d: emit error: %v", w.ID, err)
				}
				w.Counters.Errors.Add(1)
				continue
			}
			w.Counters.Sent.Add(1) // advance so pattern/id rotate; corrected below on exec error
			n++
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(n))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		}
	}
}
```

> Note: `hmaxScript` is the embedded text of `hmax.lua` (see Step 4). `newEventID`, `makePad`, `payloadJSON` come from `payload.go` (Step 5). `EpochHolder` comes from `http.go` (Step 6).

- [ ] **Step 4: Embed `hmax.lua` for the writer**

Create `writer/lua.go`:
```go
package main

import _ "embed"

// hmaxScript is the source of hmax.lua (kept identical to
// chart/files/connect/hmax.lua). go:embed needs the file inside the module dir,
// so a copy is vendored here and kept in sync by scripts/build-binaries.sh check.
//
//go:embed hmax.lua
var hmaxScript string
```

```bash
cp chart/files/connect/hmax.lua writer/hmax.lua
```

- [ ] **Step 5: Adjust `payload.go` to the helpers used above**

Modify `writer/payload.go` to add free functions (keep the existing `Payload` type if other code needs it):
```go
package main

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

func newEventID() string { return uuid.NewString() }

func makePad(n int) string { return strings.Repeat("x", n) }

// payloadJSON is the snapshot body carried in the stream value field.
func payloadJSON(eventID string, tsMs, version int64, pad string) string {
	b, _ := json.Marshal(map[string]any{
		"event_id": eventID,
		"ts_ns":    time.Now().UnixNano(),
		"version":  version,
		"pad":      pad,
	})
	return string(b)
}
```

- [ ] **Step 6: Simplify epoch state in `http.go`**

Replace the `Versions`-based state in `writer/http.go` with a minimal `EpochHolder` + counts. Locate the parent `Server` struct (field `Versions *Versions`) and replace with:
```go
// EpochHolder holds the active run epoch; swapped atomically by /reset.
type EpochHolder struct{ v atomic.Pointer[string] }

func (e *EpochHolder) Set(s string) { e.v.Store(&s) }
func (e *EpochHolder) Get() string {
	if p := e.v.Load(); p != nil {
		return *p
	}
	return ""
}
```
Update `Server` to hold `Epoch *EpochHolder`, `BootID string`, `Counters *Counters`. The `/reset` handler sets the epoch (`s.Epoch.Set(rq.Epoch)`); `/state` returns:
```go
_ = json.NewEncoder(w).Encode(map[string]any{
	"boot_id":  s.BootID,
	"epoch":    s.Epoch.Get(),
	"sent":     s.Counters.Sent.Load(),
})
```
Keep `/rate`, `/healthz`, `/metrics`, `/reset` handlers. Remove all references to `Versions`, `NewVersions`, `State`. Generate a random `BootID` once at startup (reuse parent's hex-random approach from old `version.go`).

- [ ] **Step 7: Update `main.go` wiring**

In `writer/main.go`: remove `versions := NewVersions(workers)`. Construct `minter := NewMinter(rdb)`, `epoch := &EpochHolder{}`, one shared `*OpPicker` per worker built from env weights (use a per-worker `rand.New(rand.NewSource(seed+ID))` to avoid lock contention), pass `Minter`, `Ops`, `EpochHolder`, `KeySpaceSize` into each `Worker`. Read new env vars: `OP_W_SET` (default 8), `OP_W_DELETE` (default 1), `OP_W_RENAME` (default 1), `KEY_SPACE_SIZE` (default 32). Wire `Server{Epoch: epoch, BootID: bootID, Counters: counters}`.

- [ ] **Step 8: Fix `http_test.go`**

Update `writer/http_test.go` to construct the new `Server` shape (`Epoch: &EpochHolder{}`, `Counters: &Counters{}`) and assert `/reset` sets epoch and `/state` returns it. Remove assertions on `Versions`.

- [ ] **Step 9: Run the whole writer test suite — green**

Run: `cd writer && go test ./... -v`
Expected: PASS (minter, keys, ops, worker emitOne, http).

- [ ] **Step 10: Build**

Run: `cd writer && go build ./...`
Expected: builds clean.

- [ ] **Step 11: Commit**

```bash
git add writer/
git commit -m "lww-hincrby-k8s: writer mints via HINCRBY, shared keyspace, op-mix, srcmax record"
```

---

## Phase 3 — GC sweeper

### Task 3.1: Sweep logic (`gc-sweeper`)

**Files:**
- Create: `gc-sweeper/go.mod`, `gc-sweeper/sweep.go`, `gc-sweeper/sweep_test.go`, `gc-sweeper/main.go`, `gc-sweeper/Dockerfile`

- [ ] **Step 1: Init module + deps**

```bash
mkdir -p gc-sweeper && cd gc-sweeper
go mod init gc-sweeper
go get github.com/redis/go-redis/v9@v9.7.0
go get github.com/alicebob/miniredis/v2@v2.33.0
cd ..
```

- [ ] **Step 2: Write the failing test**

Create `gc-sweeper/sweep_test.go`:
```go
package main

import (
	"context"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func TestSweepDeletesOldTombstonesOnly(t *testing.T) {
	mr, _ := miniredis.Run()
	defer mr.Close()
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	defer rdb.Close()
	ctx := context.Background()

	now := int64(100000) // ms
	// old tombstone (eligible)
	rdb.HSet(ctx, "k:old", "ver", 5, "deleted", "1", "deleted_at", now-60000)
	// fresh tombstone (within horizon, keep)
	rdb.HSet(ctx, "k:fresh", "ver", 5, "deleted", "1", "deleted_at", now-1000)
	// live key (never touch)
	rdb.HSet(ctx, "k:live", "ver", 7, "deleted", "0")

	s := &Sweeper{RDB: rdb, HorizonMs: 30000, ScanCount: 100}
	n, err := s.SweepOnce(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 reaped, got %d", n)
	}
	if mr.Exists("k:old") {
		t.Fatal("old tombstone should be deleted")
	}
	if !mr.Exists("k:fresh") || !mr.Exists("k:live") {
		t.Fatal("fresh tombstone and live key must survive")
	}
}
```

- [ ] **Step 3: Run — expect failure**

Run: `cd gc-sweeper && go test ./... -v`
Expected: FAIL (undefined `Sweeper`).

- [ ] **Step 4: Implement `sweep.go`**

Create `gc-sweeper/sweep.go`:
```go
package main

import (
	"context"
	"strconv"

	"github.com/redis/go-redis/v9"
)

// Sweeper reaps tombstones (deleted=1) older than HorizonMs. Physical DEL only
// after the horizon so a very-late stale write cannot resurrect a key the fence
// already tombstoned (design-doc §7 GC).
type Sweeper struct {
	RDB       *redis.Client
	HorizonMs int64
	ScanCount int64
	// Metrics (read by the /metrics handler).
	Reaped     int64
	Tombstones int64
	OldestAgeMs int64
}

// SweepOnce scans the keyspace once and DELs eligible tombstones, using `now` (ms)
// as the clock. Returns the number reaped.
func (s *Sweeper) SweepOnce(ctx context.Context, now int64) (int64, error) {
	var cursor uint64
	var reaped, tombstones, oldest int64
	for {
		keys, next, err := s.RDB.Scan(ctx, cursor, "*", s.ScanCount).Result()
		if err != nil {
			return reaped, err
		}
		for _, k := range keys {
			vals, err := s.RDB.HMGet(ctx, k, "deleted", "deleted_at").Result()
			if err != nil || len(vals) != 2 || vals[0] != "1" {
				continue
			}
			tombstones++
			da, _ := strconv.ParseInt(toS(vals[1]), 10, 64)
			if age := now - da; age > oldest {
				oldest = age
			}
			if now-da > s.HorizonMs {
				if err := s.RDB.Del(ctx, k).Err(); err == nil {
					reaped++
				}
			}
		}
		cursor = next
		if cursor == 0 {
			break
		}
	}
	s.Reaped += reaped
	s.Tombstones = tombstones
	s.OldestAgeMs = oldest
	return reaped, nil
}

func toS(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return "0"
}
```

- [ ] **Step 5: Run — green**

Run: `cd gc-sweeper && go test ./... -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add gc-sweeper/go.mod gc-sweeper/go.sum gc-sweeper/sweep.go gc-sweeper/sweep_test.go
git commit -m "lww-hincrby-k8s: gc-sweeper tombstone reap logic"
```

### Task 3.2: GC main loop + metrics + Dockerfile

**Files:**
- Create: `gc-sweeper/main.go`, `gc-sweeper/Dockerfile`

- [ ] **Step 1: Implement `main.go`**

Create `gc-sweeper/main.go`:
```go
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func main() {
	addr := flag.String("region", envOr("REGION_ADDR", "redis-region:6379"), "region redis addr")
	horizon := flag.Duration("horizon", durEnv("GC_HORIZON", 5*time.Minute), "tombstone GC horizon")
	interval := flag.Duration("interval", durEnv("GC_INTERVAL", 30*time.Second), "sweep interval")
	metricsAddr := flag.String("metrics", ":9090", "metrics listen addr")
	flag.Parse()

	rdb := redis.NewClient(&redis.Options{Addr: *addr})
	s := &Sweeper{RDB: rdb, HorizonMs: horizon.Milliseconds(), ScanCount: 500}

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		<-c
		cancel()
	}()

	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	http.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "gc_reaped_total %d\n", s.Reaped)
		fmt.Fprintf(w, "gc_tombstones %d\n", s.Tombstones)
		fmt.Fprintf(w, "gc_oldest_tombstone_age_ms %d\n", s.OldestAgeMs)
	})
	go func() { log.Fatal(http.ListenAndServe(*metricsAddr, nil)) }()

	t := time.NewTicker(*interval)
	defer t.Stop()
	for {
		n, err := s.SweepOnce(ctx, time.Now().UnixMilli())
		if err != nil && ctx.Err() == nil {
			log.Printf("sweep error: %v", err)
		} else if n > 0 {
			log.Printf("reaped %d tombstones (total %d, oldest %dms)", n, s.Reaped, s.OldestAgeMs)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func durEnv(k string, d time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if p, err := time.ParseDuration(v); err == nil {
			return p
		}
	}
	return d
}
```

- [ ] **Step 2: Build**

Run: `cd gc-sweeper && go build ./... && echo OK`
Expected: `OK`.

- [ ] **Step 3: Write the Dockerfile (copy parent verifier Dockerfile pattern)**

Create `gc-sweeper/Dockerfile` mirroring `verifier/Dockerfile` (multi-stage, `ARG BASE_REGISTRY`, non-root, pinned `golang:1.23` + `gcr.io/distroless/static` or alpine — match what the parent verifier uses). Final binary `/gc-sweeper`, entrypoint `["/gc-sweeper"]`.

Run to confirm the parent pattern: `sed -n '1,60p' verifier/Dockerfile`

- [ ] **Step 4: Commit**

```bash
git add gc-sweeper/main.go gc-sweeper/Dockerfile
git commit -m "lww-hincrby-k8s: gc-sweeper main loop, metrics, Dockerfile"
```

---

## Phase 4 — Verifier: srcmax compare + op/tombstone stats

### Task 4.1: Read srcmax + region tombstone fields

**Files:**
- Modify: `verifier/redis.go`
- Test: `verifier/redis_test.go` (create)

- [ ] **Step 1: Write the failing test**

Create `verifier/redis_test.go`:
```go
package main

import (
	"context"
	"testing"

	"github.com/alicebob/miniredis/v2"
)

func TestHGetAllSrcmaxAndTombstone(t *testing.T) {
	mr, _ := miniredis.Run()
	defer mr.Close()
	c := NewStreamClient(mr.Addr())
	defer c.Close()
	ctx := context.Background()

	mr.HSet("srcmax:run-1", "lb:company:active:{employees:run-1-1}", "9")
	mr.HSet("lb:company:active:{employees:run-1-1}", "ver", "9")
	mr.HSet("lb:company:active:{employees:run-1-1}", "deleted", "0")

	m, err := c.HGetAllInt(ctx, "srcmax:run-1")
	if err != nil {
		t.Fatal(err)
	}
	if m["lb:company:active:{employees:run-1-1}"] != 9 {
		t.Fatalf("srcmax wrong: %+v", m)
	}
}
```

- [ ] **Step 2: Run — expect failure**

Run: `cd verifier && go get github.com/alicebob/miniredis/v2@v2.33.0 && go test ./... -run TestHGetAll -v`
Expected: FAIL (undefined `HGetAllInt`).

- [ ] **Step 3: Implement in `redis.go`**

Add to `verifier/redis.go`:
```go
// HGetAllInt reads a hash of string->int64 (used for srcmax:<epoch>).
func (c *StreamClient) HGetAllInt(ctx context.Context, hash string) (map[string]int64, error) {
	m, err := c.rdb.HGetAll(ctx, hash).Result()
	if err != nil {
		return nil, err
	}
	out := make(map[string]int64, len(m))
	for k, v := range m {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("srcmax field %q non-int %q", k, v)
		}
		out[k] = n
	}
	return out, nil
}

// HGetDeleted returns the tombstone flag for a key ("1" if tombstoned).
func (c *StreamClient) HGetDeleted(ctx context.Context, key string) (string, error) {
	return c.rdb.HGet(ctx, key, "deleted").Result()
}
```
(Ensure `strconv` and `fmt` are imported; confirm the client field is named `rdb` — match the parent file.)

- [ ] **Step 4: Run — green**

Run: `cd verifier && go test ./... -run TestHGetAll -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add verifier/redis.go verifier/redis_test.go verifier/go.mod verifier/go.sum
git commit -m "lww-hincrby-k8s: verifier reads srcmax + tombstone fields"
```

### Task 4.2: Compare region against central srcmax

**Files:**
- Modify: `verifier/lww.go`
- Test: `verifier/lww_test.go`

- [ ] **Step 1: Write the failing test**

Add to `verifier/lww_test.go`:
```go
func TestCompareSrcMax(t *testing.T) {
	mrC, _ := miniredis.Run(); defer mrC.Close()
	mrR, _ := miniredis.Run(); defer mrR.Close()
	central := NewStreamClient(mrC.Addr()); defer central.Close()
	region := NewStreamClient(mrR.Addr()); defer region.Close()
	ctx := context.Background()

	k := "lb:general:active:{items:run-2-3}"
	mrC.HSet("srcmax:run-2", k, "12")
	mrR.HSet(k, "ver", "12") // region caught up

	checked, mism, regr, err := CompareSrcMax(ctx, central, region, "run-2")
	if err != nil { t.Fatal(err) }
	if checked != 1 || mism != 0 || regr != 0 {
		t.Fatalf("checked=%d mism=%d regr=%d", checked, mism, regr)
	}

	// region behind -> mismatch
	mrR.HSet(k, "ver", "11")
	_, mism, _, _ = CompareSrcMax(ctx, central, region, "run-2")
	if mism != 1 { t.Fatalf("want 1 mismatch, got %d", mism) }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `cd verifier && go test ./... -run TestCompareSrcMax -v`
Expected: FAIL (undefined `CompareSrcMax`).

- [ ] **Step 3: Implement in `lww.go`**

Add:
```go
// CompareSrcMax compares every key in central's srcmax:<epoch> hash (the
// authoritative HINCRBY-minted max) against region HGET <key> ver. Tombstoned
// keys retain ver==max so they still match. mismatches = region != src;
// regressions = region > src (impossible ⇒ fence bug).
func CompareSrcMax(ctx context.Context, central, region *StreamClient, epoch string) (checked, mismatches, regressions int, err error) {
	src, err := central.HGetAllInt(ctx, "srcmax:"+epoch)
	if err != nil {
		return 0, 0, 0, err
	}
	for key, srcMax := range src {
		cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		regionVer, ok, e := region.HGetVer(cctx, key)
		cancel()
		if e != nil {
			return checked, mismatches, regressions, e
		}
		checked++
		if !ok || regionVer != srcMax {
			mismatches++
		}
		if ok && regionVer > srcMax {
			regressions++
		}
	}
	return checked, mismatches, regressions, nil
}
```

- [ ] **Step 4: Run — green**

Run: `cd verifier && go test ./... -run TestCompareSrcMax -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add verifier/lww.go verifier/lww_test.go
git commit -m "lww-hincrby-k8s: verifier compares region against central srcmax"
```

### Task 4.3: Wire srcmax compare into `main.go` + emit op/tombstone stats

**Files:**
- Modify: `verifier/main.go`

- [ ] **Step 1: Replace the source-of-truth step**

In `verifier/main.go`: add flags `--epoch` (already present) and ensure `centralC` is available (it is). Replace the `FetchState`/`CompareVersions` block (step 7–8) with:
- Drop the writer `/state` per-key map dependency for the comparison.
- After quiescence, call `checked, mismatches, regressions, err := CompareSrcMax(ctx, centralC, regionC, epoch)`.
- Keep the writer `/state` call only to read `boot_id` (boot recheck) and `epoch` adoption — `/state` no longer returns `Keys`, so compute `WritesPerKeyAvg` from `srcmax` (`TotalVersions = sum(src values)`, `DistinctKeys = len(src)`).
- Add `Tombstones` (count region keys with `deleted=1` among srcmax keys) to `LWWResult`.

- [ ] **Step 2: Extend `LWWResult` (in `lww.go`)**

Add field:
```go
Tombstones int `json:"tombstones"`
```
and populate it in `main.go` by checking `HGetDeleted` for each srcmax key (or a sampled subset for large keyspaces — if sampled, log the sample size, never silently cap).

- [ ] **Step 3: Build + run existing verifier tests**

Run: `cd verifier && go build ./... && go test ./... -v`
Expected: builds; tests pass.

- [ ] **Step 4: Commit**

```bash
git add verifier/main.go verifier/lww.go
git commit -m "lww-hincrby-k8s: verifier uses srcmax compare; emits tombstone stats"
```

---

## Phase 5 — Static HTML report generator

### Task 5.1: Render sweep JSON → HTML

**Files:**
- Create: `report-gen/go.mod`, `report-gen/render.go`, `report-gen/render_test.go`, `report-gen/templates/report.html.tmpl`, `report-gen/main.go`, `report-gen/Dockerfile`

- [ ] **Step 1: Init module**

```bash
mkdir -p report-gen/templates && cd report-gen
go mod init report-gen
cd ..
```

- [ ] **Step 2: Write the failing test**

Create `report-gen/render_test.go`:
```go
package main

import (
	"strings"
	"testing"
)

func TestRenderReportContainsVerdictAndTiers(t *testing.T) {
	sweep := Sweep{
		Lab:   "redis-connect-lww-hincrby-k8s",
		MaxPassingTier: 20000,
		Tiers: []Tier{
			{Rate: 5000, Pass: true, Mismatches: 0, Stale: 12, Applied: 100, Duplicate: 3},
			{Rate: 20000, Pass: true, Mismatches: 0, Stale: 40, Applied: 400, Duplicate: 9},
			{Rate: 40000, Pass: false, Mismatches: 0, Stale: 0, Applied: 800, Duplicate: 1},
		},
		Proofs: []Proof{{Name: "MW+", Pass: true}, {Name: "delete", Pass: true}, {Name: "rename", Pass: true}},
	}
	html, err := Render(sweep)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"redis-connect-lww-hincrby-k8s", "20000", "MW+", "delete", "rename"} {
		if !strings.Contains(html, want) {
			t.Fatalf("report missing %q", want)
		}
	}
}
```

- [ ] **Step 3: Run — expect failure**

Run: `cd report-gen && go test ./... -v`
Expected: FAIL (undefined types).

- [ ] **Step 4: Implement `render.go` + template**

Create `report-gen/render.go`:
```go
package main

import (
	"bytes"
	_ "embed"
	"html/template"
)

type Tier struct {
	Rate       int  `json:"rate"`
	Pass       bool `json:"pass"`
	Mismatches int  `json:"mismatches"`
	Stale      int64 `json:"stale"`
	Applied    int64 `json:"applied"`
	Duplicate  int64 `json:"duplicate"`
	Tombstones int  `json:"tombstones"`
}

type Proof struct {
	Name string `json:"name"`
	Pass bool   `json:"pass"`
}

type Sweep struct {
	Lab            string  `json:"lab"`
	MaxPassingTier int     `json:"max_passing_tier"`
	Tiers          []Tier  `json:"tiers"`
	Proofs         []Proof `json:"proofs"`
}

//go:embed templates/report.html.tmpl
var reportTmpl string

func Render(s Sweep) (string, error) {
	t, err := template.New("report").Parse(reportTmpl)
	if err != nil {
		return "", err
	}
	var b bytes.Buffer
	if err := t.Execute(&b, s); err != nil {
		return "", err
	}
	return b.String(), nil
}
```

Create `report-gen/templates/report.html.tmpl` — a self-contained HTML doc (inline CSS, no external assets) rendering: a header with `{{.Lab}}`, a verdict banner with `Max passing tier: {{.MaxPassingTier}} msg/s`, a proofs table (`{{range .Proofs}}`), and a tiers table with a simple inline bar (CSS width ∝ applied) (`{{range .Tiers}}`). Keep it minimal but valid HTML5. Include the strings the test asserts.

- [ ] **Step 5: Run — green**

Run: `cd report-gen && go test ./... -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add report-gen/go.mod report-gen/render.go report-gen/render_test.go report-gen/templates/report.html.tmpl
git commit -m "lww-hincrby-k8s: report-gen renders sweep JSON to static HTML"
```

### Task 5.2: report-gen CLI + Dockerfile

**Files:**
- Create: `report-gen/main.go`, `report-gen/Dockerfile`

- [ ] **Step 1: Implement `main.go`**

Create `report-gen/main.go`:
```go
package main

import (
	"encoding/json"
	"flag"
	"log"
	"os"
)

func main() {
	in := flag.String("in", "/dev/stdin", "sweep JSON input")
	out := flag.String("out", "report.html", "HTML output path")
	flag.Parse()

	raw, err := os.ReadFile(*in)
	if err != nil {
		log.Fatalf("read %s: %v", *in, err)
	}
	var s Sweep
	if err := json.Unmarshal(raw, &s); err != nil {
		log.Fatalf("parse sweep json: %v", err)
	}
	html, err := Render(s)
	if err != nil {
		log.Fatalf("render: %v", err)
	}
	if err := os.WriteFile(*out, []byte(html), 0o644); err != nil {
		log.Fatalf("write %s: %v", *out, err)
	}
	log.Printf("wrote %s (%d bytes)", *out, len(html))
}
```

- [ ] **Step 2: Build + smoke**

Run:
```bash
cd report-gen && go build -o /tmp/report-gen . && \
echo '{"lab":"x","max_passing_tier":20000,"tiers":[{"rate":5000,"pass":true}],"proofs":[{"name":"MW+","pass":true}]}' \
 | /tmp/report-gen -in /dev/stdin -out /tmp/r.html && grep -q 20000 /tmp/r.html && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Dockerfile (mirror verifier pattern)**

Create `report-gen/Dockerfile` like `verifier/Dockerfile` (multi-stage, `ARG BASE_REGISTRY`, embeds `templates/` via go:embed so no runtime asset needed), final binary `/report-gen`.

- [ ] **Step 4: Commit**

```bash
git add report-gen/main.go report-gen/Dockerfile
git commit -m "lww-hincrby-k8s: report-gen CLI + Dockerfile"
```

---

## Phase 6 — Chart wiring

### Task 6.1: Connect configs — carry op + route rename

**Files:**
- Modify: `chart/files/connect/lww-forward.yaml`
- Modify: `chart/files/connect/lww-reverse.yaml`
- Modify: `chart/templates/connect-configmaps.yaml`

- [ ] **Step 1: Forward — pass op/old_key/new_key through to NATS**

In `chart/files/connect/lww-forward.yaml`, extend the `mapping` root to include the new metadata fields (read from XADD via `meta(...)`):
```
        root = {
          "key":        meta("key").or("unknown"),
          "value":      $original_value,
          "event_id":   meta("event_id").or("unknown"),
          "pattern":    meta("pattern").or("unknown"),
          "op":         meta("op").or("set"),
          "old_key":    meta("old_key").or(""),
          "new_key":    meta("new_key").or(""),
          "t_send_ms":  meta("t_send_ms").or("0").number(),
          "version":    meta("version").or("0").number()
        }
```

- [ ] **Step 2: Reverse — branch on op for the EVAL**

In `chart/files/connect/lww-reverse.yaml`, replace the single `redis: eval` processor with a `switch` on `meta op`. Set metadata first (add `meta op`, `meta old_key`, `meta new_key`), then:
```yaml
    - mapping: |
        meta key       = this.key
        meta op        = this.op.or("set")
        meta old_key   = this.old_key.or("")
        meta new_key   = this.new_key.or("")
        meta version   = this.version.string()
        meta event_id  = this.event_id
        meta value     = this.value
        meta now_ms    = (timestamp_unix_nano() / 1000000).string()
        root = this.value
    - switch:
        - check: meta("op") == "rename"
          processors:
            - redis:
                url: {{ include "rrcs.redis.region.url" . }}
                kind: simple
                command: eval
                args_mapping: |
                  let script = {{ .Files.Get "files/connect/lww_rename.lua" | toJson }}
                  root = [ $script, 2, meta("old_key"), meta("new_key"), meta("value"), meta("version"), meta("now_ms"), meta("event_id") ]
        - processors:
            - redis:
                url: {{ include "rrcs.redis.region.url" . }}
                kind: simple
                command: eval
                args_mapping: |
                  let script = {{ .Files.Get "files/connect/lww_set.lua" | toJson }}
                  root = [ $script, 1, meta("key"), meta("value"), meta("version"), meta("op"), meta("now_ms"), meta("event_id") ]
    - mapping: 'meta lww_applied = this.string()'
    - mapping: |
        meta lww_result = if meta("lww_applied") == "1" { "applied" } else if meta("lww_applied") == "0" { "stale" } else { "duplicate" }
    - metric:
        type: counter
        name: lww_apply
        labels:
          result: ${! meta("lww_result") }
          op: ${! meta("op") }
    - mapping: 'root = meta("value")'
```

> De-risk note (carried from parent T1.1): this Connect build's `redis` processor has no `result_map`; the eval result REPLACES content, so the `meta lww_applied = this.string()` capture MUST be its own mapping. Verify with `helm template` that both branches render valid Bloblang.

- [ ] **Step 3: ConfigMap mounts the new Lua files**

In `chart/templates/connect-configmaps.yaml`, ensure `lww_rename.lua` (and `lww_set.lua`) are available to the reverse pipeline. Since the reverse YAML inlines them via `.Files.Get`, no extra mount is needed — but confirm `lww_rename.lua` exists under `chart/files/connect/` (it does, Task 1.3). If the parent mounts the connect YAML through a ConfigMap built from `.Files.Get`, no change beyond the YAML edits above.

- [ ] **Step 4: Render check (both branches)**

Run: `helm template t ./chart --set profile=lww -s templates/connect-configmaps.yaml | grep -c lww_rename.lua`
Expected: `>= 1` (rename script embedded).

- [ ] **Step 5: Commit**

```bash
git add chart/files/connect/lww-forward.yaml chart/files/connect/lww-reverse.yaml chart/templates/connect-configmaps.yaml
git commit -m "lww-hincrby-k8s: connect carries op; reverse routes set/delete vs rename"
```

### Task 6.2: GC sweeper Deployment

**Files:**
- Create: `chart/templates/gc-sweeper.yaml`

- [ ] **Step 1: Write the template (model on `chart/templates/dashboard.yaml`)**

Create `chart/templates/gc-sweeper.yaml` — a Deployment (replicas 1) + headless/ClusterIP Service exposing `:9090`. Image `{{ .Values.gc.image }}`, env `REGION_ADDR` (region url host:port via existing helper), `GC_HORIZON: {{ .Values.gc.horizon }}`, `GC_INTERVAL: {{ .Values.gc.interval }}`. Healthcheck: `httpGet /healthz :9090`. Resources from `.Values.resources.gc`. Use the `rrcs.name` prefix helper and standard labels exactly as `dashboard.yaml` does.

- [ ] **Step 2: Render check**

Run: `helm template t ./chart --set profile=lww -s templates/gc-sweeper.yaml | head -40`
Expected: a Deployment + Service render with the gc image and `/healthz` probe.

- [ ] **Step 3: Commit**

```bash
git add chart/templates/gc-sweeper.yaml
git commit -m "lww-hincrby-k8s: gc-sweeper Deployment + metrics Service"
```

### Task 6.3: Values + writer env + report Job

**Files:**
- Modify: `chart/values.yaml`, `chart/values-dev.yaml`
- Modify: `chart/templates/writer.yaml`
- Create: `chart/templates/report-job.yaml`

- [ ] **Step 1: Add values**

In `chart/values.yaml` add:
```yaml
writer:
  env:
    KEY_SPACE_SIZE: "64"
    OP_W_SET: "8"
    OP_W_DELETE: "1"
    OP_W_RENAME: "1"
gc:
  image: redis-rrcs/gc-sweeper:dev
  pullPolicy: ""
  horizon: "5m"
  interval: "30s"
report:
  image: redis-rrcs/report-gen:dev
  pullPolicy: ""
  run: false
  jobName: ""
sweep:
  tiers: "5000,10000,20000,40000"
  durationS: 30
resources:
  gc:
    requests: { cpu: 100m, memory: 64Mi }
    limits:   { cpu: 500m, memory: 128Mi }
```
(Merge into existing `writer.env` rather than duplicating the key.)

- [ ] **Step 2: Writer template passes new env**

In `chart/templates/writer.yaml`, add the four new env vars (`KEY_SPACE_SIZE`, `OP_W_SET`, `OP_W_DELETE`, `OP_W_RENAME`) from `.Values.writer.env`, alongside the existing ones.

- [ ] **Step 3: report-job template (model on `verifier-job.yaml`)**

Create `chart/templates/report-job.yaml` guarded by `{{ if .Values.report.run }}` — a Job that runs `report-gen -in /data/sweep.json -out /data/report.html`. The harness will instead invoke report-gen via the binary locally (simpler); this template is the in-cluster option. Keep it minimal and render-guarded so it is inert by default.

- [ ] **Step 4: Render the whole chart**

Run: `helm template t ./chart --set profile=lww >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add chart/values.yaml chart/values-dev.yaml chart/templates/writer.yaml chart/templates/report-job.yaml
git commit -m "lww-hincrby-k8s: chart values for op-mix, keyspace, gc, sweep, report"
```

---

## Phase 7 — Scripts: build, proofs, sweep harness

### Task 7.1: Local binary build script

**Files:**
- Create: `scripts/build-binaries.sh`

- [ ] **Step 1: Write it**

Create `scripts/build-binaries.sh`:
```bash
#!/usr/bin/env bash
# Builds all Go binaries locally to ./bin (no Docker). Satisfies the
# "binary builds must provide local build scripts" requirement.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${LAB_DIR}"
mkdir -p bin
# Keep the writer's embedded hmax.lua in sync with the chart source of truth.
cp chart/files/connect/hmax.lua writer/hmax.lua
for m in writer verifier gc-sweeper report-gen; do
  echo "[build] ${m}"
  ( cd "${m}" && go build -o "../bin/${m}" . )
done
echo "[ok] binaries in ./bin: $(ls bin)"
```

```bash
chmod +x scripts/build-binaries.sh
```

- [ ] **Step 2: Run it**

Run: `bash scripts/build-binaries.sh`
Expected: `bin/writer bin/verifier bin/gc-sweeper bin/report-gen` built.

- [ ] **Step 3: Commit (bin/ is gitignored)**

Confirm `.gitignore` includes `bin/` (parent has it); if not, add it.
```bash
git add scripts/build-binaries.sh .gitignore
git commit -m "lww-hincrby-k8s: local binary build script"
```

### Task 7.2: build-images.sh — add gc-sweeper + report-gen

**Files:**
- Modify: `scripts/build-images.sh`

- [ ] **Step 1: Add the two images**

In `scripts/build-images.sh`: add `GC_IMG="${prefix}redis-rrcs/gc-sweeper:${TAG}"` and `REPORT_IMG="${prefix}redis-rrcs/report-gen:${TAG}"`; `build_one gc-sweeper "${GC_IMG}"` and `build_one report-gen "${REPORT_IMG}"`; add both to the `kind load` and `--push` and summary blocks. (The dashboard build may stay or be removed; keep it to avoid touching the dashboard template.)

- [ ] **Step 2: Dry render of help**

Run: `bash scripts/build-images.sh --help | head -5`
Expected: prints usage (no build).

- [ ] **Step 3: Commit**

```bash
git add scripts/build-images.sh
git commit -m "lww-hincrby-k8s: build gc-sweeper + report-gen images"
```

### Task 7.3: Deterministic proofs (bash, mirror proof-c.sh)

**Files:**
- Create: `scripts/proof-mwplus.sh`, `scripts/proof-delete.sh`, `scripts/proof-rename.sh`

- [ ] **Step 1: `proof-mwplus.sh` — positive multi-writer (HINCRBY safe)**

Create `scripts/proof-mwplus.sh` mirroring `proof-c.sh` structure but POSITIVE: two writers minting the SAME key via `HINCRBY kv:ver KEY 1` (so versions never collide), each applying via `lww_set.lua`. Assert: final `ver == 2K` (all 2K writes minted distinct versions), final `val` is the last-applied (highest version) writer's value, and applied count == 2K, duplicate == 0. This is the inversion of Proof C: HINCRBY removes the same-version collision, so no write is silently lost.
```bash
#!/usr/bin/env bash
set -euo pipefail
NS="${1:?ns}"; POD="${2:?redis-region pod}"; K="${3:-5}"
KEY="lwwproofMW:1"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl -n "$NS" cp "${LAB_DIR}/chart/files/connect/lww_set.lua" "${POD}:/tmp/lww_set.lua"
OUT="$(kubectl -n "$NS" exec "$POD" -- sh -c '
  K='"$K"'; KEY="'"$KEY"'"
  redis-cli DEL "$KEY" "vKEY" >/dev/null
  applied=0; dup=0; last=""
  i=1
  while [ "$i" -le "$K" ]; do
    for wr in A B; do
      v=$(redis-cli HINCRBY vKEY "$KEY" 1)
      r=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , "$wr:v$v" "$v" set 0 e)
      [ "$r" = "1" ] && applied=$((applied+1)); [ "$r" = "-1" ] && dup=$((dup+1))
      last="$wr:v$v"
    done
    i=$((i+1))
  done
  echo "applied=$applied dup=$dup ver=$(redis-cli HGET "$KEY" ver) val=$(redis-cli HGET "$KEY" val) want_last=$last want_ver=$((K*2))"
')"
echo "[proofMW+] ${OUT}"
echo "$OUT" | grep -q "dup=0" || { echo "[proofMW+] FAIL: expected dup=0 (HINCRBY never collides)"; exit 1; }
A_VER=$(echo "$OUT"|sed -n 's/.*ver=\([0-9]*\).*/\1/p'); W_VER=$(echo "$OUT"|sed -n 's/.*want_ver=\([0-9]*\).*/\1/p')
[ "$A_VER" = "$W_VER" ] || { echo "[proofMW+] FAIL: ver=$A_VER want $W_VER"; exit 1; }
echo "[proofMW+] PASS — HINCRBY makes multi-writer-same-key safe (no lost update, dup=0)"
```

- [ ] **Step 2: `proof-delete.sh` — tombstone + no resurrect**

Create `scripts/proof-delete.sh`: set v1, delete v2 (assert deleted=1, ver=2), stale set v1 → 0 (assert still deleted=1), newer set v3 → 1 (assert deleted=0). Mirror proof-c.sh kubectl/exec scaffolding.

- [ ] **Step 3: `proof-rename.sh` — atomic standby→active**

Create `scripts/proof-rename.sh`: set standby key, run `lww_rename.lua` with global v=K, assert active live (deleted=0, ver=K, val set) AND standby tombstoned (deleted=1) — pairing complete. Then a stale rename (v<K) → 0, state unchanged. Use the shared hash tag so both keys are on one node.

- [ ] **Step 4: Make executable + commit**

```bash
chmod +x scripts/proof-mwplus.sh scripts/proof-delete.sh scripts/proof-rename.sh
git add scripts/proof-mwplus.sh scripts/proof-delete.sh scripts/proof-rename.sh
git commit -m "lww-hincrby-k8s: deterministic proofs — MW+, delete, rename"
```

### Task 7.4: verify-lww.sh — proofs + rate sweep + report

**Files:**
- Modify: `scripts/verify-lww.sh`
- Modify: `scripts/lib/run-defaults.sh`

- [ ] **Step 1: Add SWEEP_TIERS default**

In `scripts/lib/run-defaults.sh` add: `: "${SWEEP_TIERS:=5000,10000,20000,40000}"`.

- [ ] **Step 2: Rework verify-lww.sh**

Modify `scripts/verify-lww.sh`:
1. Boot the chart (keep).
2. Run Proof A (keep), then `proof-mwplus.sh`, `proof-c.sh` (negative control — keep but it now reads as the contrast), `proof-delete.sh`, `proof-rename.sh`. Collect each proof's pass/fail.
3. **Sweep:** for each tier in `SWEEP_TIERS`, render+apply the verifier Job (as today) with `--set verifier.rate=$tier --set verifier.epoch=run-$tier-$$`, wait, extract `RESULT_JSON`, parse `verdict.pass`, `mismatches`, `stale`, `applied`, `duplicate`. Append a tier object to a JSON array. Track the highest tier with `verdict.pass==true` as `max_passing_tier`.
4. Build `sweep.json` = `{lab, max_passing_tier, tiers:[...], proofs:[...]}`.
5. Run report-gen locally: `bash scripts/build-binaries.sh` then `./bin/report-gen -in reports/sweep.json -out reports/report.html` (mkdir -p reports).
6. Exit 0 iff all proofs pass AND `max_passing_tier` is non-empty (≥ lowest tier). Print the report path.

Use `jq` for JSON assembly (parent already depends on `jq`).

- [ ] **Step 3: Shellcheck**

Run: `bash -n scripts/verify-lww.sh && echo OK`
Expected: `OK` (syntax).

- [ ] **Step 4: Commit**

```bash
git add scripts/verify-lww.sh scripts/lib/run-defaults.sh
git commit -m "lww-hincrby-k8s: verify-lww runs all proofs + rate sweep + HTML report"
```

---

## Phase 8 — Docs

### Task 8.1: RESEARCH.md + README.md

**Files:**
- Modify: `RESEARCH.md`, `README.md`

- [ ] **Step 1: RESEARCH.md**

Rewrite the "What this demonstrates" and "Design decisions" to match the spec: HINCRBY shared counter makes multi-writer-same-key safe (vs parent's negative Proof C); delete tombstone + GC horizon; atomic dual-key rename; srcmax authoritative compare; rate sweep; static HTML report. Keep a "Deliberately excluded" list (wall-clock/HLC sources, Cluster multi-node hot-slot, delta/CRDT). Reference `lww-update-delete-gc-hinc/design-decision-tree.md` and `docs/design/lab-coverage-analysis.md`.

- [ ] **Step 2: README.md**

Update: property sentence, run instructions (kind: `build-images.sh --kind`, `verify-lww.sh`), the proof list (A, MW+, MW− contrast, delete, rename, B′ sweep), where the report lands (`reports/report.html`), and the values knobs (op weights, keyspace, gc horizon, sweep tiers).

- [ ] **Step 3: Commit**

```bash
git add README.md RESEARCH.md
git commit -m "lww-hincrby-k8s: docs — property, proofs, report, knobs"
```

---

## Phase 9 — End-to-end validation on kind

### Task 9.1: Full validation run

- [ ] **Step 1: Unit + Lua tests all green**

Run:
```bash
cd labs/redis-connect-lww-hincrby-k8s
for m in writer verifier gc-sweeper report-gen; do (cd $m && go test ./... ) || exit 1; done
bash scripts/test-lua.sh
```
Expected: all PASS; `ALL LUA TESTS PASS`.

- [ ] **Step 2: Create kind cluster + build/load images**

Run:
```bash
kind create cluster --name lwwh
bash scripts/gen-nats-auth.sh
bash scripts/build-images.sh --kind --kind-name=lwwh
```
Expected: images loaded.

- [ ] **Step 3: Run the full harness (small sweep first)**

Run: `SWEEP_TIERS=5000,10000 RRCS_NS=lwwh-k8s RRCS_RELEASE=lwwh bash scripts/verify-lww.sh`
Expected: Proof A / MW+ / MW− / delete / rename all PASS; sweep produces `reports/sweep.json` and `reports/report.html`; harness exits 0 with a `max_passing_tier`.

- [ ] **Step 4: Eyeball the report**

Run: `grep -o 'Max passing tier:[^<]*' reports/report.html`
Expected: a non-empty tier value; open `reports/report.html` to confirm tiers + proofs render.

- [ ] **Step 5: Verify tombstones + GC actually happened**

Run:
```bash
kubectl -n lwwh-k8s exec deploy/lab-redis-region -- redis-cli --scan --pattern 'lb:*' | head
kubectl -n lwwh-k8s logs deploy/lab-gc-sweeper | grep reaped | tail
```
Expected: tombstoned keys present during run; gc-sweeper logs reaping after the horizon.

- [ ] **Step 6: Tear down**

Run: `kind delete cluster --name lwwh`
Expected: cluster removed. Confirm no leftover containers/volumes: `docker ps -a | grep -c lwwh` → `0`.

- [ ] **Step 7: Final commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-hincrby-k8s
git commit -m "lww-hincrby-k8s: validated end-to-end on kind (proofs green, sweep + report)"
```

---

## Self-review notes (author)

- **Spec coverage:** §4 set/delete → Task 1.2; §4 rename → 1.3; §5 HINCRBY+keyspace+op-mix → Phase 2; §6 GC → Phase 3; §7 proofs → 7.3 + verifier sweep 7.4; §8 report → Phase 5; §9 chart values → 6.3; §10 build-binaries → 7.1; §11 validation → Phase 9. All spec sections map to a task.
- **No local counter:** parent `version.go` + its test are deleted (Task 2.3); minting is HINCRBY-only. Requirement "no local counter" satisfied.
- **Multi-writer same key:** shared keyspace `pickID` (Task 2.4) + Proof MW+ (7.3). Requirement satisfied.
- **Type consistency:** `Minter.NextPerKey/NextGlobal`, `OpPicker.Pick`, `Pattern.Key`, `Sweeper.SweepOnce`, `CompareSrcMax`, `Render(Sweep)` are used with identical signatures across tasks.
- **Known follow-up risks to watch during execution:** (a) ~~parent `StreamClient` field name~~ — CONFIRMED `rdb` (verifier/redis.go); plan's `c.rdb` is correct. (b) Connect 4.92 `switch` processor Bloblang shape — render-verify in 6.1 (the one genuine unknown; if `switch` is unsupported in this build, fall back to two `redis` processors each guarded by a `mapping` that no-ops when `meta("op")` doesn't match). (c) ~~writer `Counters` field names~~ — CONFIRMED `Sent`,`Errors`,`Inflight` (writer/counters.go); plan uses exactly these. Note `Counters` is shared across workers, so `Sent.Load()`-based pattern/id selection intentionally lets workers collide on keys (the multi-writer-same-key contention we want).
```
