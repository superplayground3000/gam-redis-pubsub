# Redis → Connect Last-Write-Wins (Kubernetes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork `labs/redis-redpanda-connect-stress-k8s` into `labs/redis-connect-lww-k8s`, a Kubernetes/Helm lab that proves a sink-side last-write-wins compare-and-set fence holds under same-key reordering and reports single-instance throughput, with a live key/value/version dashboard.

**Architecture:** Same pipeline as the parent (writer → redis-central stream → connect-source → NATS JetStream → connect-sink → redis-region), but the sink's blind `SET` becomes a Lua `EVAL` CAS gated on a per-key monotonic `version`. A versioned writer (single owner per key, fresh per-run key namespace, boot-id) feeds it; an LWW verifier Job asserts correctness under the §3.4.1 precondition plus measures throughput; a dashboard streams key/value/version live.

**Tech Stack:** Helm 3, kind, Redpanda Connect (`hpdevelop/connect:4.92.0-claudefix`), Redis 7.4, NATS 2.10 JetStream, Go 1.25 (writer/dashboard), Go 1.24 (verifier), Redis Lua, gorilla/websocket.

**Spec:** `docs/superpowers/specs/2026-06-04-redis-connect-lww-k8s-design.md` (sections referenced as §N below).

---

## File Structure

```
labs/redis-connect-lww-k8s/
├── README.md                         # T7.2  (new)
├── RESEARCH.md                       # T7.1  (new, skill format)
├── chart/
│   ├── Chart.yaml                    # T0.1  (copied, name bumped)
│   ├── values.yaml                   # T6.1  (edited: profile lww, dashboard, keyspace)
│   ├── values-dev.yaml               # T6.1  (edited)
│   ├── files/connect/lww_set.lua     # T2.1  (new)
│   ├── files/connect/lww-forward.yaml# T2.2  (new)
│   ├── files/connect/lww-reverse.yaml# T2.3  (new)
│   ├── files/nats-auth/…             # T0.1  (copied fixtures)
│   └── templates/
│       ├── _helpers.tpl              # T6.1  (edited: rrcs.dashboard.* if needed)
│       ├── connect-lua-cm.yaml       # T2.4  (new)
│       ├── connect-sink.yaml         # T2.4  (edited: mount Lua)
│       ├── dashboard.yaml            # T5.3  (new)
│       ├── verifier-job.yaml         # T4.2  (new, replaces collector-job.yaml)
│       └── (redis-*, nats*, connect-source, writer, NOTES.txt)  # T0.1 copied
├── writer/        # T3.x  forked: epoch namespace + per-key version + boot_id + /state
│   ├── version.go        (new)        version_test.go (new)
│   ├── worker.go  http.go payload.go counters.go main.go  (edited)
├── verifier/      # T4.x  forked from collector/: LWW verdict, no matrix
│   ├── lww.go (new)  lww_test.go (new)  main.go verdict.go report.go (rewritten)
│   └── redis.go scrapers.go quiescence.go snapshot.go nats.go (copied, +HGet/Sample)
├── dashboard/     # T5.x  new
│   ├── main.go go.mod go.sum Dockerfile  static/index.html
└── scripts/
    ├── build-images.sh   # T6.2 (edited: + dashboard image)
    ├── render.sh         # T6.2 (edited: default profile=lww)
    ├── gen-nats-auth.sh  # T0.1 copied
    ├── verify-lww.sh     # T6.3 (new, replaces stress-run.sh)
    ├── dashboard-forward.sh # T6.4 (new)
    └── lib/run-defaults.sh  # T6.3 (new, minimal; replaces tier-defs.sh)
```

**Conventions for this plan:** all paths are relative to the repo root `/media/hp/secondary/projects/gam-redis-pubsub`. "the parent" = `labs/redis-redpanda-connect-stress-k8s`. "the lab" = `labs/redis-connect-lww-k8s`. Run all `go` commands inside the relevant module dir. Commit after each task.

---

## Phase 0 — Scaffold the fork

### Task 0.1: Copy the parent lab and prune

**Files:**
- Create: `labs/redis-connect-lww-k8s/` (whole tree, copied)
- Modify: `labs/redis-connect-lww-k8s/chart/Chart.yaml`

- [ ] **Step 1: Copy the parent tree**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
cp -a labs/redis-redpanda-connect-stress-k8s labs/redis-connect-lww-k8s
cd labs/redis-connect-lww-k8s
rm -rf out reports/*.json
# Drop the parent's QoS config pairs we don't fork (lww configs come in Phase 2):
rm -f chart/files/connect/alo-*.yaml chart/files/connect/amo-*.yaml chart/files/connect/eoe-*.yaml
# Drop chaos + tier matrix harness (lab is single-concern; replaced in Phase 6):
rm -rf scripts/chaos scripts/stress-run.sh scripts/lib/tier-defs.sh
# Rename collector → verifier (history not needed for a lab fork):
git mv collector verifier 2>/dev/null || mv collector verifier
mv verifier/go.mod verifier/go.mod.bak && sed 's/^module collector/module verifier/' verifier/go.mod.bak > verifier/go.mod && rm verifier/go.mod.bak
# Remove the parent collector binary if checked in:
rm -f verifier/collector writer/writer
```

- [ ] **Step 2: Bump the chart name**

Edit `chart/Chart.yaml`: set `name: redis-connect-lww-k8s` (leave `version`/`appVersion` as copied). Confirm the file:

```bash
cat chart/Chart.yaml
```

- [ ] **Step 3: Sanity render (parent profile still present? expect failure is OK)**

The chart still references `profile: alo` files we deleted; do NOT render yet. Just confirm the tree exists:

```bash
ls chart/files/connect/   # expect empty
ls scripts/               # expect build-images.sh gen-nats-auth.sh render.sh lib/
```

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s
git commit -m "lww-k8s: scaffold fork from redis-redpanda-connect-stress-k8s"
```

---

## Phase 1 — De-risk empirically (spec §7 risks 1 & 2)

> This phase front-loads the two unknowns on a real kind cluster BEFORE building config around them. If either assumption is wrong, the fallback is recorded here and Phase 2 adapts.

### Task 1.1: Stand up kind + confirm Connect `redis` EVAL and HSET keyspace events

**Files:**
- Create: `labs/redis-connect-lww-k8s/docs/derisk-notes.md` (findings, deleted before final commit or kept as appendix)

- [ ] **Step 1: Create a kind cluster**

```bash
kind create cluster --name lww
kubectl config current-context   # expect kind-lww
```

- [ ] **Step 2: Confirm HSET fires a keyspace event (dashboard depends on this)**

```bash
kubectl run redis-probe --image=redis:7.4-alpine --restart=Never -i --rm --command -- sh -c '
  redis-server --daemonize yes --notify-keyspace-events KEA &&
  sleep 1 &&
  ( redis-cli psubscribe "__keyevent@0__:hset" & ) &&
  sleep 1 &&
  redis-cli HSET k ver 1 val hello &&
  sleep 1'
```
Expected: the psubscribe stream prints a message on channel `__keyevent@0__:hset` with payload `k`. Record PASS/FAIL in `docs/derisk-notes.md`.
If FAIL (event class differs), record the actual channel observed; the dashboard (§T5.1) subscribes to that channel instead.

- [ ] **Step 3: Confirm the Redpanda Connect `redis` processor runs `eval`**

Create a throwaway config and run the connect image directly:

```bash
cat > /tmp/eval-probe.yaml <<'YAML'
input:
  generate:
    count: 1
    interval: 0s
    mapping: 'root = {"k":"probe","v":"hello","ver":"5"}'
pipeline:
  processors:
    - mapping: |
        meta k = this.k
        meta ver = this.ver
        root = this.v
    - redis:
        url: redis://127.0.0.1:6379
        command: eval
        args_mapping: |
          root = [
            "local cur = redis.call('HGET', KEYS[1], 'ver'); if cur==false or tonumber(ARGV[2])>tonumber(cur) then redis.call('HSET', KEYS[1],'val',ARGV[1],'ver',ARGV[2]); return 1 end; return 0",
            1,
            meta("k"),
            content().string(),
            meta("ver")
          ]
        result_map: 'meta lww_applied = this'
    - mapping: 'root = {"lww_applied": meta("lww_applied")}'
output:
  stdout: {}
YAML
kubectl run connect-probe --image=hpdevelop/connect:4.92.0-claudefix --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"hpdevelop/connect:4.92.0-claudefix","command":["sh","-c","redis-server --daemonize yes && sleep 1 && /connect.yaml.sh"],"stdin":true,"tty":false}]}}' \
  -i --rm --command -- sh -c 'redis-server --daemonize yes >/dev/null 2>&1 & sleep 1; cat > /c.yaml <<<"$(cat)"; rpk-connect run /c.yaml 2>&1 | head -40' < /tmp/eval-probe.yaml || true
```

> NOTE: the connect entrypoint binary may be `redpanda-connect` / `connect` / `rpk connect`. If the command above errors on the binary name, exec into the image to discover it:
> ```bash
> kubectl run connect-shell --image=hpdevelop/connect:4.92.0-claudefix --restart=Never -i --rm --command -- sh -c 'ls /usr/local/bin /usr/bin 2>/dev/null | grep -i connect; which redpanda-connect connect rpk 2>/dev/null'
> ```
> Record the actual run command (the parent uses `args: ["run","/connect.yaml"]`, so the entrypoint already accepts `run <file>` — mirror that: `<entrypoint> run /c.yaml`).

Expected: output line shows `{"lww_applied":"1"}` (applied). Record in `docs/derisk-notes.md`:
- the working entrypoint command,
- that `command: eval` + `args_mapping` returning `[script, numkeys, key, value, version]` works,
- that `result_map: 'meta lww_applied = this'` populates the integer result.

**Fallback if `command: eval` is unsupported:** record it and use `command: evalsha` with a preceding `command: script_load` bootstrap processor, OR a `redis_script` cache resource. Phase 2 Task 2.3 adapts to whatever this task proves.

- [ ] **Step 4: Record findings + keep cluster**

Write the three findings (HSET event channel, connect entrypoint, eval support + fallback decision) into `docs/derisk-notes.md`. Keep the kind cluster for later phases (`kind get clusters` shows `lww`).

- [ ] **Step 5: Commit the findings**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/docs/derisk-notes.md
git commit -m "lww-k8s: de-risk notes — Connect eval + HSET keyspace verified on kind"
```

---

## Phase 2 — Lua CAS + Connect configs

### Task 2.1: The CAS Lua script (3-way return)

**Files:**
- Create: `labs/redis-connect-lww-k8s/chart/files/connect/lww_set.lua`

- [ ] **Step 1: Write the script**

```lua
-- lww_set.lua — last-write-wins compare-and-set fence.
-- KEYS[1]=key  ARGV[1]=value  ARGV[2]=version (monotonic integer per key)
-- returns: 1 = applied (strictly newer; or first write for the key)
--          0 = stale     (ARGV[2] strictly OLDER than stored — only under reordering)
--         -1 = duplicate (ARGV[2] == stored — routine at-least-once redelivery)
local cur = redis.call('HGET', KEYS[1], 'ver')
if cur == false then
  redis.call('HSET', KEYS[1], 'val', ARGV[1], 'ver', ARGV[2])
  return 1
end
local v = tonumber(ARGV[2])
local c = tonumber(cur)
if v > c then
  redis.call('HSET', KEYS[1], 'val', ARGV[1], 'ver', ARGV[2])
  return 1
elseif v < c then
  return 0
else
  return -1
end
```

- [ ] **Step 2: Unit-test the script logic directly against Redis (uses the kind cluster's probe pattern)**

```bash
cd labs/redis-connect-lww-k8s
kubectl run lua-test --image=redis:7.4-alpine --restart=Never -i --rm --command -- sh -c '
  redis-server --daemonize yes >/dev/null 2>&1; sleep 1
  S=$(cat <<"LUA"
'"$(cat chart/files/connect/lww_set.lua)"'
LUA
)
  echo "v3 -> $(redis-cli EVAL "$S" 1 k v3 3)"   # expect 1
  echo "v1 -> $(redis-cli EVAL "$S" 1 k v1 1)"   # expect 0
  echo "v2 -> $(redis-cli EVAL "$S" 1 k v2 2)"   # expect 0
  echo "v3dup -> $(redis-cli EVAL "$S" 1 k v3 3)" # expect -1
  echo "final ver=$(redis-cli HGET k ver) val=$(redis-cli HGET k val)" # expect ver=3 val=v3'
```
Expected: `v3 -> 1`, `v1 -> 0`, `v2 -> 0`, `v3dup -> -1`, `final ver=3 val=v3`. This is Proof A's logic in miniature.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/chart/files/connect/lww_set.lua
git commit -m "lww-k8s: add 3-way last-write-wins CAS Lua script"
```

### Task 2.2: Forward connect config (carry `version`)

**Files:**
- Create: `labs/redis-connect-lww-k8s/chart/files/connect/lww-forward.yaml`

- [ ] **Step 1: Write the config** (parent `alo-forward.yaml` + a `version` field in the envelope and metadata)

```yaml
# Reads central Redis stream and publishes each entry to NATS JetStream.
# XADD entry fields: event_id, key, value, pattern, t_send_ms, version.
# body_key=value -> body is the JSON value; the rest land as metadata.
http:
  address: 0.0.0.0:4195
  enabled: true

input:
  label: redis_source
  redis_streams:
    url: {{ include "rrcs.redis.central.url" . }}
    kind: simple
    streams: [app.events]
    consumer_group: propagator
    client_id: ${HOSTNAME:rpconnect-forward}
    body_key: value
    create_streams: true
    start_from_oldest: false
    commit_period: 200ms
    timeout: 500ms
    limit: 50
    auto_replay_nacks: true

pipeline:
  threads: 2
  processors:
    - mapping: |
        let original_value = content().string()
        root = {
          "key":        meta("key").or("unknown"),
          "value":      $original_value,
          "event_id":   meta("event_id").or("unknown"),
          "pattern":    meta("pattern").or("unknown"),
          "t_send_ms":  meta("t_send_ms").or("0").number(),
          "version":    meta("version").or("0").number()
        }
        meta event_id = meta("event_id").or($original_value.hash("sha256").encode("hex"))
        meta pattern  = meta("pattern").or("unknown")

output:
  label: jetstream_sink
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth: { user_credentials_file: {{ .Values.nats.auth.creds.publisher | quote }} }
    subject: {{ include "rrcs.nats.stream.publishSubject" . | quote }}
    headers:
      Nats-Msg-Id: ${! meta("event_id") }
      Content-Type: application/json
    max_in_flight: 256

logger:
  level: INFO
  format: json
  add_timestamp: true
```

- [ ] **Step 2: Commit**

```bash
git add labs/redis-connect-lww-k8s/chart/files/connect/lww-forward.yaml
git commit -m "lww-k8s: forward connect config carries per-key version"
```

### Task 2.3: Reverse connect config (the CAS fence)

**Files:**
- Create: `labs/redis-connect-lww-k8s/chart/files/connect/lww-reverse.yaml`

> Use the `eval` shape proven in Task 1.1. If the fallback (`evalsha`/`script_load`) was recorded, adapt the `redis` processor accordingly and note it inline.

- [ ] **Step 1: Write the config**

```yaml
# QoS: last-write-wins. Consumes JetStream APP_EVENTS; for each delivery applies a
# version-gated compare-and-set to region Redis (HSET only if incoming version is
# strictly greater), then appends to the region-events ledger for observability.
# Sink runs threads:4 + high max_in_flight ON PURPOSE — the CAS makes ordering
# unnecessary, so reordering of same-key messages is expected and fenced.
http:
  address: 0.0.0.0:4195
  enabled: true

input:
  label: jetstream_source
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth: { user_credentials_file: {{ .Values.nats.auth.creds.subscriber | quote }} }
    subject: {{ include "rrcs.nats.stream.subjects" . | quote }}
    stream: {{ .Values.nats.stream.name | quote }}
    durable: {{ .Values.nats.stream.consumer.durable | quote }}
    deliver: all
    ack_wait: 30s

pipeline:
  threads: 4
  processors:
    - mapping: |
        meta key       = this.key
        meta version   = this.version.string()
        meta event_id  = this.event_id
        meta applied_ms = (timestamp_unix_nano() / 1000000).string()
        root = this.value
    # The last-write-wins compare-and-set. result: 1 applied, 0 stale, -1 duplicate.
    - redis:
        url: {{ include "rrcs.redis.region.url" . }}
        kind: simple
        command: eval
        args_mapping: |
          root = [
            file("/etc/rpconnect/lww_set.lua"),
            1,
            meta("key"),
            content().string(),
            meta("version")
          ]
        result_map: 'meta lww_applied = this.string()'
    # Export applied/stale/duplicate as a labelled counter for the verifier + dashboard.
    - mapping: |
        meta lww_result = if meta("lww_applied") == "1" { "applied" } else if meta("lww_applied") == "0" { "stale" } else { "duplicate" }
    - metric:
        type: counter
        name: lww_apply
        labels:
          result: ${! meta("lww_result") }

output:
  label: region_ledger
  redis_streams:
    url: {{ include "rrcs.redis.region.url" . }}
    stream: region-events
    body_key: value
    max_length: 100000
    max_in_flight: 64
    metadata:
      exclude_prefixes: ["nats_"]

metrics:
  prometheus: {}

logger:
  level: INFO
  format: json
  add_timestamp: true
```

> If `metrics.prometheus` is already implied by the connect image defaults (the parent scrapes `/metrics` without declaring it), drop the `metrics:` block — Task 4 verifies the counter shows at `:4195/metrics`.

- [ ] **Step 2: Commit**

```bash
git add labs/redis-connect-lww-k8s/chart/files/connect/lww-reverse.yaml
git commit -m "lww-k8s: reverse connect config applies version-gated CAS + lww_apply metric"
```

### Task 2.4: Mount the Lua script into connect-sink

**Files:**
- Create: `labs/redis-connect-lww-k8s/chart/templates/connect-lua-cm.yaml`
- Modify: `labs/redis-connect-lww-k8s/chart/templates/connect-sink.yaml`

- [ ] **Step 1: Create the ConfigMap template**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-lua") }}
  labels: { app: connect-sink }
data:
  lww_set.lua: |-
{{ .Files.Get "files/connect/lww_set.lua" | indent 4 }}
```

- [ ] **Step 2: Mount it in `connect-sink.yaml`** — add to the `connect` container `volumeMounts` (after the existing `nats-creds` mount, before `resources:`):

```yaml
            - name: lua
              mountPath: /etc/rpconnect/lww_set.lua
              subPath: lww_set.lua
              readOnly: true
```

and add to the pod `volumes:` list (after the `nats-creds` secret volume):

```yaml
        - name: lua
          configMap:
            name: {{ include "rrcs.name" (dict "root" $ "base" "connect-lua") }}
```

- [ ] **Step 3: Render to verify templating (set profile=lww; chart still has parent values — override profile)**

```bash
cd labs/redis-connect-lww-k8s
helm template lww ./chart --set profile=lww -s templates/connect-lua-cm.yaml
helm template lww ./chart --set profile=lww -s templates/connect-sink.yaml | grep -A2 'lww_set.lua'
helm template lww ./chart --set profile=lww -s templates/connect-configmaps.yaml | head -20
```
Expected: the ConfigMap renders the Lua body; the sink Deployment shows the `lua` mount; connect-configmaps renders `lww-forward.yaml`/`lww-reverse.yaml` (because `connect-configmaps.yaml` reads `files/connect/%s-forward.yaml` with `%s=lww`).

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/chart/templates/connect-lua-cm.yaml labs/redis-connect-lww-k8s/chart/templates/connect-sink.yaml
git commit -m "lww-k8s: mount lww_set.lua into connect-sink via ConfigMap"
```

---

## Phase 3 — Versioned writer

> Module dir: `labs/redis-connect-lww-k8s/writer` (module `writer`, go 1.25). Run `go test ./...` there.

### Task 3.1: Version registry (epoch namespace + per-key counter + boot-id)

**Files:**
- Create: `labs/redis-connect-lww-k8s/writer/version.go`
- Test: `labs/redis-connect-lww-k8s/writer/version_test.go`

- [ ] **Step 1: Write the failing test**

```go
package main

import (
	"strconv"
	"sync"
	"testing"
)

func TestVersionsMonotonicPerKeyWithinEpoch(t *testing.T) {
	v := NewVersions(2) // 2 shards (workers)
	v.SetEpoch("e1")
	// worker 0 owns shard 0; bump key "k" five times
	var last int64
	for i := 0; i < 5; i++ {
		got := v.Next(0, "lww:e1:0")
		if got != last+1 {
			t.Fatalf("Next #%d = %d, want %d", i, got, last+1)
		}
		last = got
	}
}

func TestVersionsResetOnNewEpoch(t *testing.T) {
	v := NewVersions(1)
	v.SetEpoch("e1")
	v.Next(0, "lww:e1:0")
	v.Next(0, "lww:e1:0") // ver=2
	v.SetEpoch("e2")      // new namespace
	if got := v.Next(0, "lww:e2:0"); got != 1 {
		t.Fatalf("after new epoch Next = %d, want 1", got)
	}
}

func TestVersionsBootIDStableNonEmpty(t *testing.T) {
	v := NewVersions(1)
	if v.BootID() == "" {
		t.Fatal("BootID empty")
	}
	if v.BootID() != v.BootID() {
		t.Fatal("BootID changed between calls")
	}
}

func TestVersionsStateMergesAcrossShards(t *testing.T) {
	v := NewVersions(2)
	v.SetEpoch("e1")
	v.Next(0, "lww:e1:0")
	v.Next(1, "lww:e1:1")
	v.Next(1, "lww:e1:1") // ver=2
	st := v.State()
	if st.Epoch != "e1" {
		t.Fatalf("epoch=%s", st.Epoch)
	}
	if st.Keys["lww:e1:0"] != 1 || st.Keys["lww:e1:1"] != 2 {
		t.Fatalf("keys=%v", st.Keys)
	}
	if st.DistinctKeys != 2 || st.TotalVersions != 3 {
		t.Fatalf("distinct=%d total=%d", st.DistinctKeys, st.TotalVersions)
	}
}

func TestVersionsConcurrentNextNoRace(t *testing.T) {
	v := NewVersions(4)
	v.SetEpoch("e1")
	var wg sync.WaitGroup
	for w := 0; w < 4; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				v.Next(w, "lww:e1:"+strconv.Itoa(w))
			}
		}(w)
	}
	wg.Wait()
	st := v.State()
	if st.TotalVersions != 4000 {
		t.Fatalf("total=%d, want 4000", st.TotalVersions)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd labs/redis-connect-lww-k8s/writer && go test -run TestVersions ./...`
Expected: FAIL (undefined: NewVersions).

- [ ] **Step 3: Implement `version.go`**

```go
package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"sync/atomic"
)

// State is the JSON shape returned by GET /state.
type State struct {
	BootID        string           `json:"boot_id"`
	Epoch         string           `json:"epoch"`
	Keys          map[string]int64 `json:"keys"`
	DistinctKeys  int              `json:"distinct_keys"`
	TotalVersions int64            `json:"total_versions"`
}

// shard holds the per-key max version for the keys owned by one worker.
type shard struct {
	mu sync.Mutex
	m  map[string]int64
}

// epochState is the immutable-per-epoch set of shards. Swapping epoch swaps the
// whole pointer, so a new epoch starts every shard empty (versions restart at 1)
// — which is SAFE because the key namespace also changes (keys embed the epoch),
// so no strictly-older-vs-stored arrivals are manufactured (spec §3.4.1).
type epochState struct {
	name   string
	shards []*shard
}

type Versions struct {
	bootID  string
	nshards int
	cur     atomic.Pointer[epochState]
}

func NewVersions(workers int) *Versions {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return &Versions{bootID: hex.EncodeToString(b), nshards: workers}
}

func (v *Versions) BootID() string { return v.bootID }

func (v *Versions) SetEpoch(name string) {
	shards := make([]*shard, v.nshards)
	for i := range shards {
		shards[i] = &shard{m: map[string]int64{}}
	}
	v.cur.Store(&epochState{name: name, shards: shards})
}

// Next increments and returns the version for key, owned by worker `w`.
func (v *Versions) Next(w int, key string) int64 {
	es := v.cur.Load()
	s := es.shards[w%v.nshards]
	s.mu.Lock()
	s.m[key]++
	n := s.m[key]
	s.mu.Unlock()
	return n
}

// Epoch returns the active epoch name ("" before SetEpoch).
func (v *Versions) Epoch() string {
	if es := v.cur.Load(); es != nil {
		return es.name
	}
	return ""
}

func (v *Versions) State() State {
	st := State{BootID: v.bootID, Keys: map[string]int64{}}
	es := v.cur.Load()
	if es == nil {
		return st
	}
	st.Epoch = es.name
	for _, s := range es.shards {
		s.mu.Lock()
		for k, n := range s.m {
			st.Keys[k] = n
			st.TotalVersions += n
		}
		s.mu.Unlock()
	}
	st.DistinctKeys = len(st.Keys)
	return st
}
```

- [ ] **Step 4: Run tests (with race detector for the concurrency test)**

Run: `cd labs/redis-connect-lww-k8s/writer && go test -race -run TestVersions ./...`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/writer/version.go labs/redis-connect-lww-k8s/writer/version_test.go
git commit -m "lww-k8s: writer version registry (epoch namespace, per-key counter, boot-id)"
```

### Task 3.2: Wire versioning into the worker

**Files:**
- Modify: `labs/redis-connect-lww-k8s/writer/worker.go`
- Modify: `labs/redis-connect-lww-k8s/writer/main.go`

- [ ] **Step 1: Rewrite `worker.go`** so each worker writes only its owned keys under the active epoch and emits `version`:

```go
package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID            int
	Workers       int
	RDB           *redis.Client
	StreamKey     string
	StreamMaxLen  int64
	PipelineDepth int
	PayloadBytes  int
	KeySpaceSize  int64
	Lim           *Limiter
	Counters      *Counters
	Versions      *Versions
}

// ownedKeyID returns the n-th key id (0-based) this worker owns, round-robining
// over the strided subset { id : id % Workers == ID } of [0, KeySpaceSize).
func (w *Worker) ownedKeyID(n int64) int64 {
	stride := int64(w.Workers)
	count := (w.KeySpaceSize - int64(w.ID) + stride - 1) / stride // # owned ids
	if count <= 0 {
		return int64(w.ID) % w.KeySpaceSize
	}
	return int64(w.ID) + (n%count)*stride
}

func (w *Worker) Run(ctx context.Context) {
	var emitted int64
	for {
		rate := int(w.Lim.Current())
		depth := w.PipelineDepth
		if rate > 0 {
			perTenth := rate / 10
			if perTenth < 1 {
				perTenth = 1
			}
			if perTenth < depth {
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

		epoch := w.Versions.Epoch()
		if epoch == "" {
			// No run started yet; nothing to number against. Idle briefly.
			continue
		}

		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		for i := 0; i < depth; i++ {
			id := w.ownedKeyID(emitted)
			emitted++
			key := fmt.Sprintf("lww:%s:%d", epoch, id)
			ver := w.Versions.Next(w.ID, key)
			p := NewPayload(ver, w.PayloadBytes)
			body, _ := p.JSON()
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: map[string]any{
					"value":     string(body),
					"event_id":  p.EventID,
					"key":       key,
					"pattern":   "stress",
					"t_send_ms": p.TsNs / 1_000_000,
					"version":   ver,
				},
			})
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(depth))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		} else {
			w.Counters.Sent.Add(int64(depth))
		}
	}
}
```

- [ ] **Step 2: Update `main.go`** to construct `Versions`, pass `Workers` + `Versions` to each worker, and expose both to the HTTP server. Apply this diff:

In the var block (after `healthAddr := ...`), add nothing new. After `counters := &Counters{}` add:

```go
	versions := NewVersions(workers)
```

In the worker construction loop, replace the `w := &Worker{...}` literal with:

```go
		w := &Worker{
			ID: i, Workers: workers, RDB: rdb,
			StreamKey:     streamKey,
			StreamMaxLen:  int64(streamMaxLen),
			PipelineDepth: pipelineDepth,
			PayloadBytes:  payloadBytes,
			KeySpaceSize:  int64(keySpaceSize),
			Lim:           lim,
			Counters:      counters,
			Versions:      versions,
		}
```

In the `srv := &Server{...}` literal, add the `Versions: versions,` field (Server gets the field in Task 3.3).

- [ ] **Step 3: Build (compile check; HTTP wiring lands in 3.3)**

Run: `cd labs/redis-connect-lww-k8s/writer && go build ./...`
Expected: FAIL only on `Server` missing `Versions` field — that is added in Task 3.3. If any other error, fix here.

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/writer/worker.go labs/redis-connect-lww-k8s/writer/main.go
git commit -m "lww-k8s: writer emits per-key version under per-run epoch namespace"
```

### Task 3.3: `/state` and `/reset {epoch}` HTTP handlers

**Files:**
- Modify: `labs/redis-connect-lww-k8s/writer/http.go`
- Test: `labs/redis-connect-lww-k8s/writer/http_test.go` (new)

- [ ] **Step 1: Write the failing test**

```go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer() *Server {
	return &Server{
		Lim: NewLimiter(), Counters: &Counters{}, MaxRate: 100000,
		Versions:    NewVersions(2),
		HealthCheck: func() bool { return true },
	}
}

func TestResetSetsEpochAndStateReportsIt(t *testing.T) {
	s := newTestServer()
	mux := http.NewServeMux()
	s.Register(mux)

	body := strings.NewReader(`{"epoch":"run-123"}`)
	req := httptest.NewRequest(http.MethodPost, "/reset", body)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("reset code=%d body=%s", rr.Code, rr.Body.String())
	}

	// Simulate a write so /state has content.
	s.Versions.Next(0, "lww:run-123:0")

	req = httptest.NewRequest(http.MethodGet, "/state", nil)
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("state code=%d", rr.Code)
	}
	var st State
	if err := json.Unmarshal(rr.Body.Bytes(), &st); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, rr.Body.String())
	}
	if st.Epoch != "run-123" {
		t.Errorf("epoch=%q", st.Epoch)
	}
	if st.BootID == "" {
		t.Error("boot_id empty")
	}
	if st.Keys["lww:run-123:0"] != 1 {
		t.Errorf("keys=%v", st.Keys)
	}
}

func TestResetRequiresEpoch(t *testing.T) {
	s := newTestServer()
	mux := http.NewServeMux()
	s.Register(mux)
	req := httptest.NewRequest(http.MethodPost, "/reset", strings.NewReader(`{}`))
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("want 400 for missing epoch, got %d", rr.Code)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd labs/redis-connect-lww-k8s/writer && go test -run TestReset ./...`
Expected: FAIL (Server has no Versions field / no /state route).

- [ ] **Step 3: Edit `http.go`** — add the field, routes, and handlers. Apply:

Add to the `Server` struct (after `HealthCheck func() bool`):

```go
	Versions *Versions
```

In `Register`, add:

```go
	mux.HandleFunc("/state", s.state)
```

and change the existing `/reset` registration to keep the same line (handler rewritten below).

Replace the `reset` handler with one that takes an epoch, and add a `state` handler:

```go
type resetReq struct {
	Epoch string `json:"epoch"`
}

func (s *Server) reset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var rq resetReq
	if err := json.NewDecoder(r.Body).Decode(&rq); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if rq.Epoch == "" {
		http.Error(w, "epoch required", http.StatusBadRequest)
		return
	}
	s.Counters.Reset()
	s.Versions.SetEpoch(rq.Epoch)
	fmt.Fprintf(w, "reset; epoch=%s\n", rq.Epoch)
}

func (s *Server) state(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(s.Versions.State())
}
```

- [ ] **Step 4: Run tests**

Run: `cd labs/redis-connect-lww-k8s/writer && go test -race ./...`
Expected: PASS (version + http + existing payload/limiter tests).

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/writer/http.go labs/redis-connect-lww-k8s/writer/http_test.go
git commit -m "lww-k8s: writer /state + /reset{epoch} endpoints"
```

### Task 3.4: Update writer Deployment env (epoch is runtime, keyspace default)

**Files:**
- Modify: `labs/redis-connect-lww-k8s/chart/templates/writer.yaml`

- [ ] **Step 1:** The writer no longer needs build-time epoch (verifier POSTs it). No template change is required for epoch. Confirm the writer template still passes `KEY_SPACE_SIZE`, `WORKERS` from values (it does). No edit needed unless the parent hardcoded `STREAM_KEY` — it sets `app.events`, which is correct. **Skip if unchanged.**

- [ ] **Step 2:** No commit if no change.

---

## Phase 4 — LWW verifier (fork of collector)

> Module dir: `labs/redis-connect-lww-k8s/verifier` (module `verifier`, go 1.24).
> Strategy: keep `redis.go`, `scrapers.go`, `quiescence.go`, `nats.go`, `snapshot.go` (the measurement spine). Delete `latency.go`, `receiver.go`, `*_test.go` for removed pieces. Rewrite `verdict.go`, `report.go`, `main.go`. Add `lww.go`.

### Task 4.1: Prune the collector down to the spine

**Files:**
- Delete: `verifier/latency.go`, `verifier/latency_test.go`, `verifier/receiver.go`, `verifier/receiver_test.go`, `verifier/result_out_test.go`, `verifier/final_xlen_test.go`, `verifier/quiescence_test.go` (keep `quiescence.go`), `verifier/scrapers_nats_empty_test.go`, `verifier/verdict_test.go`, `verifier/report_test.go`

- [ ] **Step 1: Delete removed pieces**

```bash
cd labs/redis-connect-lww-k8s/verifier
rm -f latency.go latency_test.go receiver.go receiver_test.go \
      result_out_test.go final_xlen_test.go quiescence_test.go \
      scrapers_nats_empty_test.go verdict_test.go report_test.go
```

- [ ] **Step 2: See what still references the deleted symbols**

Run: `cd labs/redis-connect-lww-k8s/verifier && go build ./... 2>&1 | head -40`
Expected: errors in `main.go`/`report.go` referencing `Receiver`, `Latency`, `Sampler` latency fields. These are rewritten in 4.2–4.3. Record the list; do not fix yet.

- [ ] **Step 3: Commit the prune** (compile-broken intermediate is fine on a feature branch task)

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add -A labs/redis-connect-lww-k8s/verifier
git commit -m "lww-k8s: prune collector to measurement spine (remove latency/chaos/matrix)"
```

### Task 4.2: LWW domain logic (`lww.go`) + tests

**Files:**
- Create: `labs/redis-connect-lww-k8s/verifier/lww.go`
- Test: `labs/redis-connect-lww-k8s/verifier/lww_test.go`
- Modify: `labs/redis-connect-lww-k8s/verifier/redis.go` (add `HGet`, `SampleHasVer`)

- [ ] **Step 1: Add Redis helpers to `redis.go`** (append methods):

```go
// HGetVer returns the stored version for a KV hash key, ok=false if the key/field is absent.
func (s *StreamClient) HGetVer(ctx context.Context, key string) (int64, bool, error) {
	v, err := s.rdb.HGet(ctx, key, "ver").Result()
	if err == redis.Nil {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	n, perr := strconv.ParseInt(v, 10, 64)
	if perr != nil {
		return 0, false, perr
	}
	return n, true, nil
}
```

Add `"strconv"` to `redis.go` imports.

- [ ] **Step 2: Write the failing test for the verdict logic**

```go
package main

import "testing"

func TestLWWVerdictPassRequiresAllConditions(t *testing.T) {
	base := LWWResult{
		KeysChecked: 1000, Mismatches: 0, Regressions: 0,
		Applied: 50000, Stale: 1200, Duplicate: 30,
		RateAchievedAvg: 4800, RateTarget: 5000,
		BootOK: true, StoreEmptyAtStart: true,
	}
	if v := ComputeLWWVerdict(base); !v.Pass {
		t.Fatalf("expected pass, got %+v", v)
	}

	// stale==0 → inconclusive (no reordering exercised)
	noReorder := base
	noReorder.Stale = 0
	if v := ComputeLWWVerdict(noReorder); v.Pass {
		t.Fatal("stale==0 must NOT pass (inconclusive)")
	}

	// mismatch → fail
	mm := base
	mm.Mismatches = 3
	if v := ComputeLWWVerdict(mm); v.Pass {
		t.Fatal("mismatches>0 must fail")
	}

	// precondition violated (boot changed) → fail even if everything else is green
	boot := base
	boot.BootOK = false
	if v := ComputeLWWVerdict(boot); v.Pass {
		t.Fatal("boot_ok=false must fail (precondition violated)")
	}

	// store not empty at start → fail
	store := base
	store.StoreEmptyAtStart = false
	if v := ComputeLWWVerdict(store); v.Pass {
		t.Fatal("store_empty_at_start=false must fail")
	}

	// no throughput → fail
	rate := base
	rate.RateAchievedAvg = 0
	if v := ComputeLWWVerdict(rate); v.Pass {
		t.Fatal("rate_achieved_avg==0 must fail")
	}
}

func TestLWWVerdictReasonIsSpecific(t *testing.T) {
	r := LWWResult{KeysChecked: 10, Mismatches: 0, Regressions: 0,
		Applied: 10, Stale: 0, Duplicate: 0, RateAchievedAvg: 100,
		BootOK: true, StoreEmptyAtStart: true}
	v := ComputeLWWVerdict(r)
	if v.Pass || v.Reason == "" {
		t.Fatalf("want fail with reason, got %+v", v)
	}
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd labs/redis-connect-lww-k8s/verifier && go test -run TestLWW ./...`
Expected: FAIL (undefined: LWWResult, ComputeLWWVerdict).

- [ ] **Step 4: Implement `lww.go`**

```go
package main

import (
	"context"
	"fmt"
	"net/http"
)

// State mirrors the writer's GET /state response.
type State struct {
	BootID        string           `json:"boot_id"`
	Epoch         string           `json:"epoch"`
	Keys          map[string]int64 `json:"keys"`
	DistinctKeys  int              `json:"distinct_keys"`
	TotalVersions int64            `json:"total_versions"`
}

// LWWResult is the per-run measurement + verdict input.
type LWWResult struct {
	Epoch             string  `json:"epoch"`
	KeysChecked       int     `json:"keys_checked"`
	Mismatches        int     `json:"mismatches"`
	Regressions       int     `json:"regressions"`
	Applied           int64   `json:"applied"`
	Stale             int64   `json:"stale"`
	Duplicate         int64   `json:"duplicate"`
	WritesPerKeyAvg   float64 `json:"writes_per_key_avg"`
	RateTarget        int     `json:"rate_target"`
	RateAchievedAvg   float64 `json:"rate_achieved_avg"`
	BootOK            bool    `json:"boot_ok"`
	StoreEmptyAtStart bool    `json:"store_empty_at_start"`
}

type LWWVerdict struct {
	Pass   bool   `json:"pass"`
	Reason string `json:"reason,omitempty"`
}

// ComputeLWWVerdict encodes spec §3.4: pass requires the precondition to hold,
// final state correct, throughput measured, AND a windowed strictly-older (stale)
// arrival observed (proof reordering was exercised and fenced).
func ComputeLWWVerdict(r LWWResult) LWWVerdict {
	switch {
	case !r.StoreEmptyAtStart:
		return LWWVerdict{false, "precondition violated: region not empty for run epoch at start"}
	case !r.BootOK:
		return LWWVerdict{false, "precondition violated: writer restarted mid-run (boot_id changed)"}
	case r.Regressions > 0:
		return LWWVerdict{false, fmt.Sprintf("IMPOSSIBLE: %d keys have region_ver > source_ver (fence bug)", r.Regressions)}
	case r.Mismatches > 0:
		return LWWVerdict{false, fmt.Sprintf("%d keys: region_ver != source_max (stale write won or message lost)", r.Mismatches)}
	case r.RateAchievedAvg <= 0:
		return LWWVerdict{false, "no throughput measured"}
	case r.Stale == 0:
		return LWWVerdict{false, "inconclusive — no strictly-older arrival observed in the measured window; reorder-fencing unproven end-to-end"}
	default:
		return LWWVerdict{true, ""}
	}
}

// FetchState GETs the writer /state.
func FetchState(ctx context.Context, writerURL string) (State, error) {
	var st State
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, writerURL+"/state", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return st, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return st, fmt.Errorf("/state status %d", resp.StatusCode)
	}
	return st, decodeJSON(resp, &st)
}

// PostResetEpoch POSTs /reset {"epoch":...}.
func PostResetEpoch(ctx context.Context, writerURL, epoch string) error {
	body := fmt.Sprintf(`{"epoch":%q}`, epoch)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, writerURL+"/reset", stringsReader(body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("/reset status %d", resp.StatusCode)
	}
	return nil
}

// CompareVersions reads region HGET <key> ver for every key in state and tallies
// mismatches (region != source max) and regressions (region > source max).
func CompareVersions(ctx context.Context, region *StreamClient, st State) (checked, mismatches, regressions int, err error) {
	for key, srcMax := range st.Keys {
		regionVer, ok, e := region.HGetVer(ctx, key)
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

// StoreEmptyForEpoch samples up to n of the epoch's candidate keys and returns
// true iff none already has a stored version (the §3.4.1 empty-store guard).
// Called BEFORE traffic; state.Keys is empty then, so it probes the deterministic
// candidate keys lww:<epoch>:0..n-1.
func StoreEmptyForEpoch(ctx context.Context, region *StreamClient, epoch string, n int) (bool, error) {
	for i := 0; i < n; i++ {
		key := fmt.Sprintf("lww:%s:%d", epoch, i)
		if _, ok, err := region.HGetVer(ctx, key); err != nil {
			return false, err
		} else if ok {
			return false, nil
		}
	}
	return true, nil
}

// mintEpoch builds a unique epoch token from a caller-supplied seed (the Job
// passes one in; time is not used directly to keep runs reproducible/inspectable).
func mintEpoch(seed string) string {
	if seed == "" {
		return "run"
	}
	return seed
}
```

> `decodeJSON` and `stringsReader` are tiny helpers — add them to `scrapers.go` if not present:
> ```go
> import ("encoding/json"; "io"; "net/http"; "strings")
> func decodeJSON(resp *http.Response, v any) error { return json.NewDecoder(resp.Body).Decode(v) }
> func stringsReader(s string) io.Reader { return strings.NewReader(s) }
> ```
> If `scrapers.go` already imports some of these, merge rather than duplicate.

- [ ] **Step 5: Run tests**

Run: `cd labs/redis-connect-lww-k8s/verifier && go test -run TestLWW ./...`
Expected: PASS (2 tests). (Full-package build may still fail on main.go — fixed in 4.3.)

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/verifier/lww.go labs/redis-connect-lww-k8s/verifier/lww_test.go labs/redis-connect-lww-k8s/verifier/redis.go labs/redis-connect-lww-k8s/verifier/scrapers.go
git commit -m "lww-k8s: verifier LWW verdict + version-compare + precondition guards"
```

### Task 4.3: Rewrite `main.go` + `report.go` (run flow)

**Files:**
- Modify: `labs/redis-connect-lww-k8s/verifier/main.go`
- Modify: `labs/redis-connect-lww-k8s/verifier/report.go`

- [ ] **Step 1: Add a metric scraper for the lww counter to `scrapers.go`** (the parent already scrapes `/metrics` text; add a helper that extracts the three `lww_apply_total{result=...}` series):

```go
// ScrapeLWW fetches connect-sink /metrics and returns applied, stale, duplicate counters.
// Tolerates label order/spacing variations in the Prometheus text exposition.
func ScrapeLWW(ctx context.Context, sinkURL string) (applied, stale, duplicate int64, err error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, sinkURL+"/metrics", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, 0, 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	for _, line := range strings.Split(string(body), "\n") {
		if !strings.HasPrefix(line, "lww_apply") {
			continue
		}
		val := parseTrailingFloat(line)
		switch {
		case strings.Contains(line, `result="applied"`):
			applied = int64(val)
		case strings.Contains(line, `result="stale"`):
			stale = int64(val)
		case strings.Contains(line, `result="duplicate"`):
			duplicate = int64(val)
		}
	}
	return applied, stale, duplicate, nil
}

// parseTrailingFloat returns the last whitespace-delimited token of a metric line as a float.
func parseTrailingFloat(line string) float64 {
	f := strings.Fields(line)
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[len(f)-1], 64)
	return v
}
```

Add `"strconv"`, `"io"`, `"strings"` to `scrapers.go` imports as needed.

- [ ] **Step 2: Rewrite `main.go`** with the LWW run flow:

```go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	var (
		rate        = flag.Int("rate", 5000, "target msg/s")
		epochSeed   = flag.String("epoch", "", "unique per-run epoch token (required)")
		duration    = flag.Duration("duration", 30*time.Second, "sustain window")
		warmup      = flag.Duration("warmup", 5*time.Second, "warmup window")
		drain       = flag.Duration("drain", 10*time.Second, "drain window")
		extendOnce  = flag.Bool("extend-once", true, "extend sustain once if stale==0 before declaring inconclusive")
		writerURL   = flag.String("writer", "http://writer:8081", "writer URL")
		region      = flag.String("redis-region", "redis-region:6379", "")
		central     = flag.String("redis-central", "redis-central:6379", "")
		connectSink = flag.String("connect-sink", "http://connect-sink:4195", "")
		natsURL     = flag.String("nats", "http://nats:8222", "NATS monitoring URL")
		natsStream  = flag.String("nats-stream", "APP_EVENTS", "")
		sampleN     = flag.Int("empty-sample", 64, "keys to probe for empty-store precondition")
	)
	flag.Parse()
	if *epochSeed == "" {
		log.Fatal("--epoch required (unique per run)")
	}
	epoch := mintEpoch(*epochSeed)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		<-c
		cancel()
	}()

	regionC := NewStreamClient(*region)
	defer regionC.Close()
	centralC := NewStreamClient(*central)
	defer centralC.Close()

	// 0. Trim streams so we measure only this run.
	_ = centralC.Trim(ctx, "app.events")
	_ = regionC.Trim(ctx, "region-events")

	// 1. Reset writer to the fresh epoch; capture boot0.
	if err := PostResetEpoch(ctx, *writerURL, epoch); err != nil {
		log.Fatalf("reset writer: %v", err)
	}
	st0, err := FetchState(ctx, *writerURL)
	if err != nil {
		log.Fatalf("state0: %v", err)
	}
	boot0 := st0.BootID

	// 2. Empty-store precondition (region must have no ver for the epoch's keys).
	storeEmpty, err := StoreEmptyForEpoch(ctx, regionC, epoch, *sampleN)
	if err != nil {
		log.Fatalf("empty-store probe: %v", err)
	}

	// 3. Warmup at half rate.
	_ = PostRate(ctx, *writerURL, *rate/2)
	sleep(ctx, *warmup)

	// 4. Baseline counters at sustain start.
	a0, s0, d0, err := ScrapeLWW(ctx, *connectSink)
	if err != nil {
		log.Printf("WARN baseline scrape: %v", err)
	}
	sentBase := scrapeWriterSent(ctx, *writerURL)
	startedAt := time.Now()

	// 5. Sustain at full rate, sampling throughput each second.
	_ = PostRate(ctx, *writerURL, *rate)
	runStale := func(window time.Duration) (int64, int64, int64, float64) {
		end := time.Now().Add(window)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		var lastSent int64 = sentBase
		var lastAt = time.Now()
		var sumRate, n float64
		for time.Now().Before(end) {
			select {
			case <-ctx.Done():
				return 0, 0, 0, 0
			case <-ticker.C:
				sent := scrapeWriterSent(ctx, *writerURL)
				dt := time.Since(lastAt).Seconds()
				if dt > 0 && sent >= lastSent {
					sumRate += float64(sent-lastSent) / dt
					n++
				}
				lastSent, lastAt = sent, time.Now()
			}
		}
		a, s, d, _ := ScrapeLWW(ctx, *connectSink)
		rateAvg := 0.0
		if n > 0 {
			rateAvg = sumRate / n
		}
		return a - a0, s - s0, d - d0, rateAvg
	}
	applied, stale, duplicate, rateAvg := runStale(*duration)

	// 6. Drain + quiescence so all in-flight messages settle before we compare.
	_ = PostRate(ctx, *writerURL, 0)
	sleep(ctx, *drain)
	waitForPipelineQuiescence(ctx, "lww", centralC, *natsURL, *natsStream, 10*time.Second)
	sleep(ctx, 1500*time.Millisecond)

	// 6b. If no reordering was observed, extend once (still pre-quiescence semantics:
	// re-open traffic briefly) before declaring inconclusive.
	if stale == 0 && *extendOnce {
		log.Printf("stale==0 after first window; extending once")
		_ = PostRate(ctx, *writerURL, *rate)
		a, s, d, r2 := runStale(*duration)
		applied, stale, duplicate = a, s, d
		if r2 > rateAvg {
			rateAvg = r2
		}
		_ = PostRate(ctx, *writerURL, 0)
		sleep(ctx, *drain)
		waitForPipelineQuiescence(ctx, "lww", centralC, *natsURL, *natsStream, 10*time.Second)
		sleep(ctx, 1500*time.Millisecond)
	}

	// 7. Final source-of-truth + boot recheck.
	stFinal, err := FetchState(ctx, *writerURL)
	if err != nil {
		log.Fatalf("stateFinal: %v", err)
	}
	bootOK := stFinal.BootID == boot0

	// 8. Per-key version comparison.
	checked, mismatches, regressions, err := CompareVersions(ctx, regionC, stFinal)
	if err != nil {
		log.Fatalf("compare versions: %v", err)
	}

	wpk := 0.0
	if stFinal.DistinctKeys > 0 {
		wpk = float64(stFinal.TotalVersions) / float64(stFinal.DistinctKeys)
	}

	res := LWWResult{
		Epoch: epoch, KeysChecked: checked, Mismatches: mismatches, Regressions: regressions,
		Applied: applied, Stale: stale, Duplicate: duplicate,
		WritesPerKeyAvg: wpk, RateTarget: *rate, RateAchievedAvg: rateAvg,
		BootOK: bootOK, StoreEmptyAtStart: storeEmpty,
	}
	_ = startedAt
	emit(res)
}

func emit(res LWWResult) {
	rep := Report{LWW: res, Verdict: ComputeLWWVerdict(res)}
	b, _ := json.Marshal(rep)
	fmt.Printf("RESULT_JSON:%s\n", b)
	log.Printf("verdict.pass=%v reason=%q stale=%d mismatches=%d rate=%.1f wpk=%.1f",
		rep.Verdict.Pass, rep.Verdict.Reason, res.Stale, res.Mismatches, res.RateAchievedAvg, res.WritesPerKeyAvg)
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
```

> `PostRate`, `waitForPipelineQuiescence`, `NewStreamClient`, `Trim` are reused from the copied spine. **Caveat:** `waitForPipelineQuiescence` is profile-aware (parent switched on `alo`/`amo`/`eoe`); confirm its `switch` has a sane default for the unknown `"lww"` profile (it should just wait on central consumer-group lag draining to 0). If it `panic`s/early-returns on an unknown profile, add an `"lww"` case that mirrors `"alo"`. `scrapeWriterSent` is a small helper — add to `scrapers.go`:
> ```go
> func scrapeWriterSent(ctx context.Context, writerURL string) int64 {
> 	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, writerURL+"/metrics", nil)
> 	resp, err := http.DefaultClient.Do(req)
> 	if err != nil { return 0 }
> 	defer resp.Body.Close()
> 	body, _ := io.ReadAll(resp.Body)
> 	for _, line := range strings.Split(string(body), "\n") {
> 		if strings.HasPrefix(line, "stress_writer_sent_total") {
> 			return int64(parseTrailingFloat(line))
> 		}
> 	}
> 	return 0
> }
> ```

- [ ] **Step 3: Rewrite `report.go`** to the LWW shape:

```go
package main

type Report struct {
	LWW     LWWResult  `json:"lww"`
	Verdict LWWVerdict `json:"verdict"`
}
```

(Delete any other content in `report.go` that referenced latency/snapshots if it no longer compiles.)

- [ ] **Step 4: Build + test the whole module**

Run: `cd labs/redis-connect-lww-k8s/verifier && go build ./... && go test ./...`
Expected: PASS. Fix any leftover references to deleted symbols (e.g. `snapshot.go` fields used only by latency — trim them).

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add -A labs/redis-connect-lww-k8s/verifier
git commit -m "lww-k8s: verifier run flow — epoch reset, baseline, quiescence, compare, verdict"
```

### Task 4.4: Verifier Job template

**Files:**
- Create: `labs/redis-connect-lww-k8s/chart/templates/verifier-job.yaml`
- Delete: `labs/redis-connect-lww-k8s/chart/templates/collector-job.yaml`

- [ ] **Step 1: Delete the collector Job**

```bash
cd labs/redis-connect-lww-k8s
rm -f chart/templates/collector-job.yaml
```

- [ ] **Step 2: Create `verifier-job.yaml`**

```yaml
{{- if .Values.verifier.run }}
{{- $base := .Values.verifier.jobName | default (printf "verifier-%s" .Values.verifier.epoch) -}}
{{- $name := include "rrcs.name" (dict "root" $ "base" $base) -}}
{{- if gt (len $name) 57 -}}
{{- fail (printf "verifier Job name %q (%d chars) exceeds 57-char budget. Shorten resourcePrefix or verifier.epoch." $name (len $name)) -}}
{{- end -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $name }}
  labels: { app: verifier }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: { app: verifier }
    spec:
      restartPolicy: Never
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      containers:
        - name: verifier
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.verifier.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.verifier.pullPolicy) }}
          args:
            - --epoch={{ .Values.verifier.epoch }}
            - --rate={{ .Values.verifier.rate }}
            - --duration={{ .Values.verifier.durationS }}s
            - --warmup={{ .Values.verifier.warmupS }}s
            - --drain={{ .Values.verifier.drainS }}s
            - --writer=http://{{ include "rrcs.name" (dict "root" $ "base" "writer") }}:8081
            - --connect-sink=http://{{ include "rrcs.name" (dict "root" $ "base" "connect-sink") }}:4195
            - --redis-central={{ include "rrcs.redis.central.hostPort" . }}
            - --redis-region={{ include "rrcs.redis.region.hostPort" . }}
            - --nats={{ include "rrcs.nats.monitorUrl" . }}
            - --nats-stream={{ .Values.nats.stream.name }}
          resources:
            {{- toYaml .Values.resources.verifier | nindent 12 }}
{{- end }}
```

- [ ] **Step 3: Commit** (values keys for `verifier.*` land in Task 6.1; render verified there)

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add -A labs/redis-connect-lww-k8s/chart/templates/
git commit -m "lww-k8s: verifier Job template (replaces collector-job)"
```

---

## Phase 5 — Dashboard

> New module dir `labs/redis-connect-lww-k8s/dashboard` (module `dashboard`, go 1.25). Mirrors `labs/redis-multiregion-via-connect/dashboard`.

### Task 5.1: Dashboard server

**Files:**
- Create: `dashboard/main.go`, `dashboard/go.mod`

- [ ] **Step 1: Create `go.mod`**

```
module dashboard

go 1.25

require (
	github.com/gorilla/websocket v1.5.3
	github.com/redis/go-redis/v9 v9.7.0
)
```

> Pin to the versions already used elsewhere in the repo; run `go mod tidy` (Step 4) to populate `go.sum` and adjust patch versions to what's resolvable.

- [ ] **Step 2: Write `main.go`** (keyspace `hset` subscription + writer/sink pollers + WS hub). Uses the channel from Task 1.1 Step 2 (default `__keyevent@0__:hset`).

```go
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"
)

//go:embed static/index.html
var indexHTML []byte

type wsClient struct {
	conn   *websocket.Conn
	writeM sync.Mutex
}

func (c *wsClient) write(b []byte) error {
	c.writeM.Lock()
	defer c.writeM.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	return c.conn.WriteMessage(websocket.TextMessage, b)
}

type hub struct {
	mu      sync.Mutex
	clients map[*wsClient]struct{}
}

func newHub() *hub { return &hub{clients: map[*wsClient]struct{}{}} }
func (h *hub) add(c *wsClient) { h.mu.Lock(); h.clients[c] = struct{}{}; h.mu.Unlock() }
func (h *hub) remove(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[c]; ok {
		delete(h.clients, c)
		_ = c.conn.Close()
	}
}
func (h *hub) broadcast(b []byte) {
	h.mu.Lock()
	cs := make([]*wsClient, 0, len(h.clients))
	for c := range h.clients {
		cs = append(cs, c)
	}
	h.mu.Unlock()
	for _, c := range cs {
		if err := c.write(b); err != nil {
			h.remove(c)
		}
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	regionAddr := getenv("REGION_ADDR", "redis-region:6379")
	writerURL := getenv("WRITER_URL", "http://writer:8081")
	sinkURL := getenv("CONNECT_SINK_URL", "http://connect-sink:4195")
	listen := getenv("LISTEN_ADDR", ":8080")
	event := getenv("KEYSPACE_EVENT", "__keyevent@0__:hset")

	region := redis.NewClient(&redis.Options{Addr: regionAddr})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	for i := 0; i < 30; i++ {
		if region.Ping(ctx).Err() == nil {
			break
		}
		time.Sleep(time.Second)
	}
	if err := region.ConfigSet(ctx, "notify-keyspace-events", "KEA").Err(); err != nil {
		log.Printf("config set notify-keyspace-events failed (continuing): %v", err)
	}

	h := newHub()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); subscribeApplied(ctx, region, event, h) }()
	go func() { defer wg.Done(); pollStats(ctx, writerURL, sinkURL, h) }()

	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200); _, _ = w.Write([]byte("ok")) })
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		c := &wsClient{conn: conn}
		h.add(c)
		go func() {
			defer h.remove(c)
			for {
				if _, _, err := conn.ReadMessage(); err != nil {
					return
				}
			}
		}()
	})

	srv := &http.Server{Addr: listen, Handler: mux}
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		sc, cf := context.WithTimeout(context.Background(), 3*time.Second)
		defer cf()
		_ = srv.Shutdown(sc)
		cancel()
	}()

	log.Printf("dashboard listening on %s (event=%s)", listen, event)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
	wg.Wait()
	_ = region.Close()
}

// subscribeApplied streams every applied write (key,ver,value) to the browser.
func subscribeApplied(ctx context.Context, c *redis.Client, event string, h *hub) {
	sub := c.PSubscribe(ctx, event)
	defer func() { _ = sub.Close() }()
	ch := sub.Channel()
	log.Printf("subscribed keyspace event=%s", event)
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			key := msg.Payload // __keyevent@…__:hset payload is the key name
			if !strings.HasPrefix(key, "lww:") {
				continue
			}
			vals, err := c.HMGet(ctx, key, "ver", "val").Result()
			if err != nil || len(vals) < 2 {
				continue
			}
			ver, _ := toInt(vals[0])
			val, _ := vals[1].(string)
			b, _ := json.Marshal(map[string]any{
				"type": "event", "key": key, "ver": ver, "value": val,
				"ts_ms": time.Now().UnixMilli(),
			})
			h.broadcast(b)
		}
	}
}

// pollStats polls writer /state and sink /metrics once a second.
func pollStats(ctx context.Context, writerURL, sinkURL string, h *hub) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	var lastApplied int64
	var lastAt = time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			applied, stale, dup := scrapeLWW(ctx, sinkURL)
			sourceKeys, sourceEpoch := scrapeState(ctx, writerURL)
			dt := time.Since(lastAt).Seconds()
			perSec := 0.0
			if dt > 0 && applied >= lastApplied {
				perSec = float64(applied-lastApplied) / dt
			}
			lastApplied, lastAt = applied, time.Now()
			b, _ := json.Marshal(map[string]any{
				"type": "stats", "applied": applied, "stale": stale, "duplicate": dup,
				"applied_per_s": perSec, "source_keys": sourceKeys, "epoch": sourceEpoch,
			})
			h.broadcast(b)
		}
	}
}

func scrapeLWW(ctx context.Context, sinkURL string) (applied, stale, dup int64) {
	body := httpGet(ctx, sinkURL+"/metrics")
	for _, ln := range strings.Split(body, "\n") {
		if !strings.HasPrefix(ln, "lww_apply") {
			continue
		}
		v := trailingFloat(ln)
		switch {
		case strings.Contains(ln, `result="applied"`):
			applied = int64(v)
		case strings.Contains(ln, `result="stale"`):
			stale = int64(v)
		case strings.Contains(ln, `result="duplicate"`):
			dup = int64(v)
		}
	}
	return
}

func scrapeState(ctx context.Context, writerURL string) (int, string) {
	body := httpGet(ctx, writerURL+"/state")
	var st struct {
		DistinctKeys int    `json:"distinct_keys"`
		Epoch        string `json:"epoch"`
	}
	_ = json.Unmarshal([]byte(body), &st)
	return st.DistinctKeys, st.Epoch
}

func httpGet(ctx context.Context, url string) string {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return string(b)
}

func trailingFloat(line string) float64 {
	f := strings.Fields(line)
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[len(f)-1], 64)
	return v
}

func toInt(v any) (int64, bool) {
	s, ok := v.(string)
	if !ok {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}
```

- [ ] **Step 3: Create `static/index.html`** (Task 5.2 below writes it; create an empty placeholder so `//go:embed` compiles in the meantime).

```bash
mkdir -p labs/redis-connect-lww-k8s/dashboard/static
echo '<!doctype html><title>lww</title>placeholder' > labs/redis-connect-lww-k8s/dashboard/static/index.html
```

- [ ] **Step 4: Tidy + build**

```bash
cd labs/redis-connect-lww-k8s/dashboard && go mod tidy && go build ./...
```
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/dashboard/main.go labs/redis-connect-lww-k8s/dashboard/go.mod labs/redis-connect-lww-k8s/dashboard/go.sum labs/redis-connect-lww-k8s/dashboard/static/index.html
git commit -m "lww-k8s: dashboard server (keyspace applied-stream + writer/sink stats)"
```

### Task 5.2: Dashboard UI

**Files:**
- Modify: `labs/redis-connect-lww-k8s/dashboard/static/index.html`

- [ ] **Step 1: Replace the placeholder with the UI**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Redis Connect — Last-Write-Wins (live)</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 14px; background: #0e1117; color: #e6e6e6; }
  h1 { font-size: 16px; margin: 0 0 12px; color: #fff; }
  h2 { font-size: 13px; color: #b8c2cc; margin: 16px 0 6px; font-weight: 500; }
  table { border-collapse: collapse; width: 100%; font-size: 12px; }
  th, td { border-bottom: 1px solid #2a2f3a; padding: 4px 8px; text-align: left; }
  th { background: #161b22; color: #b8c2cc; font-weight: 500; }
  .stats { display: flex; gap: 12px; flex-wrap: wrap; }
  .card { background: #161b22; padding: 8px 12px; border-radius: 6px; min-width: 160px; }
  .card .name { font-size: 11px; color: #b8c2cc; text-transform: uppercase; letter-spacing: 0.04em; }
  .card .val { font-size: 20px; margin-top: 4px; }
  .applied { color: #7ee787; } .stale { color: #d29922; } .dup { color: #8b95a3; }
  #status { font-size: 11px; color: #8b95a3; margin-bottom: 8px; }
  #log-wrap { max-height: 60vh; overflow-y: auto; border: 1px solid #2a2f3a; border-radius: 6px; }
  code { background: #161b22; padding: 1px 4px; border-radius: 3px; }
</style>
</head>
<body>
<h1>Redis → Connect — Last-Write-Wins fence (single instance)</h1>
<div id="status">connecting…</div>

<h2>Counters (windowed by connect-sink)</h2>
<div class="stats" id="stats">
  <div class="card"><div class="name">applied</div><div class="val applied" id="c-applied">—</div></div>
  <div class="card"><div class="name">stale fenced (reorder)</div><div class="val stale" id="c-stale">—</div></div>
  <div class="card"><div class="name">duplicate (dedup)</div><div class="val dup" id="c-dup">—</div></div>
  <div class="card"><div class="name">applied / sec</div><div class="val" id="c-rate">—</div></div>
  <div class="card"><div class="name">source keys</div><div class="val" id="c-keys">—</div></div>
</div>

<h2>Live applied writes (winning versions)</h2>
<div id="log-wrap">
  <table>
    <thead><tr><th>time</th><th>key</th><th>ver</th><th>value (snippet)</th></tr></thead>
    <tbody id="rows"></tbody>
  </table>
</div>

<script>
const rows = document.getElementById("rows");
const status = document.getElementById("status");
const set = (id, v) => document.getElementById(id).textContent = v;

function onEvent(e) {
  const ts = new Date(e.ts_ms).toISOString().split("T")[1].replace("Z","");
  const tr = document.createElement("tr");
  const snippet = (e.value || "").slice(0, 48);
  tr.innerHTML = `<td>${ts}</td><td><code>${e.key}</code></td><td>${e.ver}</td><td>${snippet}</td>`;
  rows.prepend(tr);
  while (rows.childElementCount > 200) rows.removeChild(rows.lastChild);
}
function onStats(s) {
  set("c-applied", s.applied);
  set("c-stale", s.stale);
  set("c-dup", s.duplicate);
  set("c-rate", Math.round(s.applied_per_s));
  set("c-keys", s.source_keys + (s.epoch ? " ("+s.epoch+")" : ""));
}

let ws;
function connect() {
  ws = new WebSocket((location.protocol === "https:" ? "wss" : "ws") + "://" + location.host + "/ws");
  ws.onopen = () => status.textContent = "live · " + new Date().toISOString();
  ws.onclose = () => { status.textContent = "disconnected, retrying…"; setTimeout(connect, 1500); };
  ws.onmessage = (m) => {
    try {
      const e = JSON.parse(m.data);
      if (e.type === "event") onEvent(e);
      else if (e.type === "stats") onStats(e);
    } catch {}
  };
}
connect();
</script>
</body>
</html>
```

- [ ] **Step 2: Rebuild to confirm embed**

Run: `cd labs/redis-connect-lww-k8s/dashboard && go build ./...`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/dashboard/static/index.html
git commit -m "lww-k8s: dashboard UI — counters + live applied-writes stream"
```

### Task 5.3: Dashboard Dockerfile + chart template

**Files:**
- Create: `dashboard/Dockerfile`, `chart/templates/dashboard.yaml`

- [ ] **Step 1: Write `dashboard/Dockerfile`** (mirror the multiregion dashboard / parent writer Dockerfile conventions: multi-stage, `BASE_REGISTRY` arg, non-root)

```dockerfile
ARG BASE_REGISTRY=
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/dashboard .

FROM ${BASE_REGISTRY}gcr.io/distroless/static-debian12
COPY --from=build /out/dashboard /dashboard
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/dashboard"]
```

> If the parent writer Dockerfile uses `alpine:3.20` runtime instead of distroless, match it for consistency. Check `cat labs/redis-connect-lww-k8s/writer/Dockerfile` and mirror its base + non-root pattern.

- [ ] **Step 2: Write `chart/templates/dashboard.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "dashboard") }}
  labels: { app: dashboard }
spec:
  replicas: 1
  selector:
    matchLabels: { app: dashboard }
  template:
    metadata:
      labels: { app: dashboard }
    spec:
      {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
      {{- include "rrcs.scheduling" . | nindent 6 }}
      containers:
        - name: dashboard
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.dashboard.image) }}
          imagePullPolicy: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.dashboard.pullPolicy) }}
          env:
            - { name: REGION_ADDR,      value: {{ include "rrcs.redis.region.hostPort" . | quote }} }
            - { name: WRITER_URL,       value: "http://{{ include "rrcs.name" (dict "root" $ "base" "writer") }}:8081" }
            - { name: CONNECT_SINK_URL, value: "http://{{ include "rrcs.name" (dict "root" $ "base" "connect-sink") }}:4195" }
            - { name: LISTEN_ADDR,      value: ":8080" }
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          resources:
            {{- toYaml .Values.resources.dashboard | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "dashboard") }}
  labels: { app: dashboard }
spec:
  selector: { app: dashboard }
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

- [ ] **Step 3: Commit** (values keys land in 6.1)

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/dashboard/Dockerfile labs/redis-connect-lww-k8s/chart/templates/dashboard.yaml
git commit -m "lww-k8s: dashboard Dockerfile + Deployment/Service"
```

---

## Phase 6 — Values + harness

### Task 6.1: Chart values (profile lww, keyspace, verifier, dashboard, resources)

**Files:**
- Modify: `chart/values.yaml`, `chart/values-dev.yaml`

- [ ] **Step 1: Edit `chart/values.yaml`** — apply these changes:
  - `profile: alo` → `profile: lww`
  - under `writer.env`: `KEY_SPACE_SIZE: "100000"` → `KEY_SPACE_SIZE: "1000"`; `WORKERS: "8"` keep; `MAX_RATE: "20000"` keep.
  - Replace the whole `collector:` block with:

```yaml
verifier:
  image: redis-rrcs/verifier:dev
  pullPolicy: ""
  run: false           # harness renders the Job
  jobName: ""
  epoch: "run"         # harness sets a unique value per run
  rate: 5000
  durationS: 30
  warmupS: 5
  drainS: 10
```
  - Add a `dashboard:` block (after `writer:`):

```yaml
dashboard:
  image: redis-rrcs/dashboard:dev
  pullPolicy: ""
```
  - In `resources:`, rename `collector:` to `verifier:` (same numbers) and add `dashboard:`:

```yaml
  verifier:
    requests: { cpu: 100m, memory: 64Mi }
    limits:   { cpu: 500m, memory: 128Mi }
  dashboard:
    requests: { cpu: 100m, memory: 64Mi }
    limits:   { cpu: 500m, memory: 128Mi }
```

- [ ] **Step 2: Edit `chart/values-dev.yaml`** — set `writer.pullPolicy: Never`, add `verifier.pullPolicy: Never` and `dashboard.pullPolicy: Never` (mirror whatever the parent dev file did for collector). Confirm `nats.persistence.mode: emptyDir`.

- [ ] **Step 3: Render the full chart for the lww profile**

```bash
cd labs/redis-connect-lww-k8s
helm template lww ./chart -f chart/values-dev.yaml --set profile=lww > /tmp/lww-render.yaml
echo "exit=$?"
grep -c 'kind: Deployment' /tmp/lww-render.yaml   # writer, connect-source, connect-sink, dashboard, redis x2 (>=6)
grep -q 'lww_set.lua' /tmp/lww-render.yaml && echo "lua OK"
helm template lww ./chart --set profile=lww --set verifier.run=true --set verifier.epoch=run-test -s templates/verifier-job.yaml | grep -- '--epoch=run-test' && echo "verifier OK"
```
Expected: render exits 0, Lua present, verifier Job renders with the epoch flag.

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/chart/values.yaml labs/redis-connect-lww-k8s/chart/values-dev.yaml
git commit -m "lww-k8s: chart values — lww profile, keyspace=1000, verifier+dashboard"
```

### Task 6.2: Build + render scripts

**Files:**
- Modify: `scripts/build-images.sh`, `scripts/render.sh`

- [ ] **Step 1: Edit `scripts/build-images.sh`** — add the dashboard image alongside writer/verifier. Apply:
  - rename `COLLECTOR_IMG`/`redis-rrcs/collector` → `VERIFIER_IMG`/`redis-rrcs/verifier`, and its `build_one collector` → `build_one verifier`.
  - add `DASHBOARD_IMG="${prefix}redis-rrcs/dashboard:${TAG}"` and `build_one dashboard "${DASHBOARD_IMG}"`.
  - in the kind-load and push sections, add the dashboard + verifier images (replace the collector references).

Resulting build/kind-load lines:

```bash
build_one writer    "${WRITER_IMG}"
build_one verifier  "${VERIFIER_IMG}"
build_one dashboard "${DASHBOARD_IMG}"

if (( KIND )); then
  echo "[kind] loading images into cluster '${KIND_NAME}'"
  kind load docker-image "${WRITER_IMG}"    --name "${KIND_NAME}"
  kind load docker-image "${VERIFIER_IMG}"  --name "${KIND_NAME}"
  kind load docker-image "${DASHBOARD_IMG}" --name "${KIND_NAME}"
fi
```

(mirror the same triple in the `--push` block.)

- [ ] **Step 2: Edit `scripts/render.sh`** — change the default profile to `lww` (find where it sets `--set profile=` or `PROFILE=${...:-alo}` and make it `lww`).

- [ ] **Step 3: Smoke the build script help + a dry render**

```bash
cd labs/redis-connect-lww-k8s
bash scripts/build-images.sh -h | head -5
bash scripts/render.sh --profile=lww >/dev/null && echo "render OK" || echo "render needs profile fix"
```

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/scripts/build-images.sh labs/redis-connect-lww-k8s/scripts/render.sh
git commit -m "lww-k8s: build-images builds verifier+dashboard; render defaults to lww"
```

### Task 6.3: `verify-lww.sh` harness (Proof A + Proof B)

**Files:**
- Create: `scripts/verify-lww.sh`, `scripts/lib/run-defaults.sh`

- [ ] **Step 1: Write `scripts/lib/run-defaults.sh`**

```bash
# Run-window defaults for the LWW lab (env-overridable).
: "${DURATION_S:=30}"
: "${WARMUP_S:=5}"
: "${DRAIN_S:=10}"
: "${RATE:=5000}"
```

- [ ] **Step 2: Write `scripts/verify-lww.sh`**

```bash
#!/usr/bin/env bash
# LWW verification harness. Boots the chart (profile=lww), runs Proof A
# (deterministic 3->1->2 + duplicate, direct to redis-region) and Proof B
# (end-to-end verifier Job at a target rate). Exits 0 iff both pass.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/run-defaults.sh"

NS="${RRCS_NS:-lww-k8s}"
RELEASE="${RRCS_RELEASE:-lww}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
RESOURCE_PREFIX="lab-"
EPOCH="run-$(date +%s)-$$"

cleanup() { :; }
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "[boot] helm upgrade --install ${RELEASE} (profile=lww)"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  --set profile=lww -f "${VALUES_FILE}" --wait --timeout 5m
RESOURCE_PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

REGION_POD() { kubectl -n "${NS}" get pod -l app=redis-region -o jsonpath='{.items[0].metadata.name}'; }

echo "[proofA] deterministic 3->1->2 + duplicate, direct to redis-region"
LUA="$(cat chart/files/connect/lww_set.lua)"
PROOFA="$(kubectl -n "${NS}" exec "$(REGION_POD)" -- sh -c '
  S="'"$(printf '%s' "$LUA" | sed "s/'/'\\\\''/g")"'"
  redis-cli DEL lwwproof:1 >/dev/null
  a=$(redis-cli EVAL "$S" 1 lwwproof:1 v3 3)
  b=$(redis-cli EVAL "$S" 1 lwwproof:1 v1 1)
  c=$(redis-cli EVAL "$S" 1 lwwproof:1 v2 2)
  d=$(redis-cli EVAL "$S" 1 lwwproof:1 v3 3)
  ver=$(redis-cli HGET lwwproof:1 ver); val=$(redis-cli HGET lwwproof:1 val)
  echo "$a $b $c $d $ver $val"
')"
echo "[proofA] results (want: 1 0 0 -1 3 v3): ${PROOFA}"
read -r A B C D VER VAL <<<"${PROOFA}"
if [[ "$A" != "1" || "$B" != "0" || "$C" != "0" || "$D" != "-1" || "$VER" != "3" || "$VAL" != "v3" ]]; then
  echo "[proofA] FAIL"; exit 1
fi
echo "[proofA] PASS"

echo "[proofB] verifier Job at rate=${RATE} epoch=${EPOCH}"
JOB="verifier-${EPOCH}"
helm template "${RELEASE}" ./chart -n "${NS}" -s templates/verifier-job.yaml \
  -f "${VALUES_FILE}" --set profile=lww \
  --set verifier.run=true --set "verifier.jobName=${JOB}" --set "verifier.epoch=${EPOCH}" \
  --set "verifier.rate=${RATE}" --set "verifier.durationS=${DURATION_S}" \
  --set "verifier.warmupS=${WARMUP_S}" --set "verifier.drainS=${DRAIN_S}" \
  | kubectl apply -n "${NS}" -f -

JOB_FULL="${RESOURCE_PREFIX}${JOB}"
timeout_s=$(( DURATION_S*2 + WARMUP_S + DRAIN_S + 180 ))
deadline=$(( $(date +%s) + timeout_s ))
while (( $(date +%s) < deadline )); do
  st=$(kubectl -n "${NS}" get job/"${JOB_FULL}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
  fa=$(kubectl -n "${NS}" get job/"${JOB_FULL}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
  [[ "$st" == "True" || "$fa" == "True" ]] && break
  sleep 3
done

RESULT="$(kubectl -n "${NS}" logs job/"${JOB_FULL}" | sed -n 's/^RESULT_JSON://p' | tail -n1)"
echo "[proofB] ${RESULT:-<no result>}"
kubectl -n "${NS}" delete job/"${JOB_FULL}" --wait=false >/dev/null 2>&1 || true
[[ -z "$RESULT" ]] && { echo "[proofB] FAIL: no verdict"; kubectl -n "${NS}" logs job/"${JOB_FULL}" --tail=30 || true; exit 1; }

PASS=$(echo "$RESULT" | jq -r '.verdict.pass')
echo "$RESULT" | jq '{rate_achieved_avg:.lww.rate_achieved_avg, stale:.lww.stale, duplicate:.lww.duplicate, mismatches:.lww.mismatches, writes_per_key_avg:.lww.writes_per_key_avg, verdict:.verdict}'
if [[ "$PASS" == "true" ]]; then
  echo "[verify-lww] PASS — both proofs green"; exit 0
else
  echo "[verify-lww] FAIL — $(echo "$RESULT" | jq -r '.verdict.reason')"; exit 1
fi
```

- [ ] **Step 3: Lint the script**

```bash
cd labs/redis-connect-lww-k8s && bash -n scripts/verify-lww.sh && echo "syntax OK"
```

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/scripts/verify-lww.sh labs/redis-connect-lww-k8s/scripts/lib/run-defaults.sh
git commit -m "lww-k8s: verify-lww.sh harness (Proof A deterministic + Proof B e2e)"
```

### Task 6.4: `dashboard-forward.sh` (0.0.0.0 access)

**Files:**
- Create: `scripts/dashboard-forward.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Port-forward the dashboard Service to 0.0.0.0 for LAN access.
set -euo pipefail
NS="${RRCS_NS:-lww-k8s}"
RELEASE="${RRCS_RELEASE:-lww}"
LOCAL_PORT="${LOCAL_PORT:-8080}"
PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json 2>/dev/null | jq -r '.resourcePrefix // "lab-"')"
SVC="${PREFIX}dashboard"

echo "[dashboard] forwarding svc/${SVC} :8080 -> 0.0.0.0:${LOCAL_PORT} (ns=${NS})"
echo "[dashboard] reachable at:"
for ip in 127.0.0.1 $(hostname -I 2>/dev/null || true); do
  echo "    http://${ip}:${LOCAL_PORT}"
done
trap 'echo; echo "[dashboard] stopped"; exit 0' INT TERM
exec kubectl -n "${NS}" port-forward --address 0.0.0.0 "svc/${SVC}" "${LOCAL_PORT}:8080"
```

- [ ] **Step 2: Lint + commit**

```bash
cd labs/redis-connect-lww-k8s && bash -n scripts/dashboard-forward.sh && echo OK
chmod +x scripts/dashboard-forward.sh scripts/verify-lww.sh
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-connect-lww-k8s/scripts/dashboard-forward.sh
git commit -m "lww-k8s: dashboard-forward.sh binds port-forward to 0.0.0.0"
```

---

## Phase 7 — Docs + full validation

### Task 7.1: RESEARCH.md (skill format)

**Files:**
- Create: `labs/redis-connect-lww-k8s/RESEARCH.md` (overwrite the copied parent one)

- [ ] **Step 1: Write it** using `references/research-doc-format.md` sections. Required content:
  - **Property demonstrated** (verbatim from spec §1): "A stale change (lower version) can never overwrite a newer change at the Redis KV sink, regardless of arrival order across a parallel pipeline; plus the single-instance sustained applied-write throughput."
  - **Essentials:** the LWW CAS contract (3-way Lua), per-key monotonic version, the §3.4.1 precondition and why `stale>0` proves reorder-fencing.
  - **Design decisions:** chosen topology (single instance), per-key counter token, sink `threads:4`/`max_in_flight:64` relaxation; rejected alternatives (NATS-side discard, source-side timestamp) with reasons — lift from `last-write-wins-lab/research.md`.
  - **Deliberately excluded** (spec §1): HA/multi-pod sink, Redis Cluster, chaos/matrix, event-time LWW, deletes/tombstones.
  - **Cite** `last-write-wins-lab/research.md` as the upstream mechanism source.

- [ ] **Step 2: Commit**

```bash
git add labs/redis-connect-lww-k8s/RESEARCH.md
git commit -m "lww-k8s: RESEARCH.md (skill format, cites upstream research)"
```

### Task 7.2: README.md

**Files:**
- Create: `labs/redis-connect-lww-k8s/README.md` (overwrite parent's)

- [ ] **Step 1: Write it** with the lab-layout README sections, K8s-flavored:
  - **What this demonstrates** — one sentence (= RESEARCH property line).
  - **Run it (kind):**
    ```bash
    scripts/gen-nats-auth.sh
    kind create cluster --name lww
    scripts/build-images.sh --kind --kind-name=lww
    scripts/verify-lww.sh            # Proof A + Proof B; prints throughput + verdict
    scripts/dashboard-forward.sh     # then open http://<host>:8080
    ```
  - **Expected output** — quote a real `RESULT_JSON` verdict (filled in after Task 7.3): `verdict.pass=true`, a `stale>0`, a `rate_achieved_avg`.
  - **Teardown:** `helm uninstall lww -n lww-k8s; kind delete cluster --name lww`.
  - **Validation note:** state explicitly that research-lab's `validate_lab.sh` is compose-only and does not apply; `scripts/verify-lww.sh` is the validation (spec §4).
  - **Further reading:** link `RESEARCH.md`, `last-write-wins-lab/research.md`, the spec.

- [ ] **Step 2: Commit**

```bash
git add labs/redis-connect-lww-k8s/README.md
git commit -m "lww-k8s: README (kind quick-start, dashboard, validation note)"
```

### Task 7.3: Full end-to-end validation on kind

**Files:** none (validation run); then update README expected-output.

- [ ] **Step 1: Clean build + load + run**

```bash
cd labs/redis-connect-lww-k8s
scripts/gen-nats-auth.sh || true
kind get clusters | grep -q '^lww$' || kind create cluster --name lww
scripts/build-images.sh --kind --kind-name=lww
scripts/verify-lww.sh | tee /tmp/lww-verify.out
```
Expected: `[proofA] PASS`, then a `RESULT_JSON` line with `verdict.pass=true`, `stale > 0`, `mismatches == 0`, `rate_achieved_avg > 0`, and `writes_per_key_avg` in the hundreds. Final line `[verify-lww] PASS`.

- [ ] **Step 2: If `stale == 0` (inconclusive)** — raise reordering pressure and re-run: `RATE=8000 DURATION_S=45 scripts/verify-lww.sh`, or lower keyspace `helm upgrade ... --set writer.env.KEY_SPACE_SIZE=500`. Confirm `stale>0` then.

- [ ] **Step 3: Dashboard visual check**

```bash
scripts/dashboard-forward.sh &
sleep 2
curl -s http://127.0.0.1:8080/healthz   # expect: ok
# Open http://<host>:8080 in a browser during a verify run; confirm live rows + stale counter climbing.
kill %1 2>/dev/null || true
```

- [ ] **Step 4: Capture real numbers into README** expected-output section (replace the placeholder verdict with the actual `RESULT_JSON` from `/tmp/lww-verify.out`).

- [ ] **Step 5: Teardown check (no leftover artifacts)**

```bash
helm uninstall lww -n lww-k8s || true
kubectl get ns lww-k8s -o name 2>/dev/null && kubectl delete ns lww-k8s || true
# (kind cluster can stay for reuse; document delete in README)
```

- [ ] **Step 6: Remove the de-risk scratch doc (or fold into RESEARCH appendix) and final commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
rm -f labs/redis-connect-lww-k8s/docs/derisk-notes.md
rmdir labs/redis-connect-lww-k8s/docs 2>/dev/null || true
git add -A labs/redis-connect-lww-k8s
git commit -m "lww-k8s: validated on kind — capture throughput + verdict in README"
```

---

## Self-review checklist (run by the implementer before declaring done)

- [ ] `verify-lww.sh` exits 0 on a clean kind cluster (Proof A + Proof B both green).
- [ ] Verdict `pass` requires `store_empty_at_start && boot_ok && mismatches==0 && regressions==0 && rate_achieved_avg>0 && stale>0` (spec §3.4) — confirm in `lww_test.go`.
- [ ] `stale`/`applied`/`duplicate` are **windowed deltas** (baselined at sustain start) — confirm in `main.go`.
- [ ] Proof A runs **direct to redis-region** (never through connect-sink) and exercises all three return states.
- [ ] Writer keys are `lww:<epoch>:<id>`; `/state` returns `boot_id`+`epoch`; `/reset` requires `epoch`.
- [ ] Dashboard subscribes to the keyspace event class proven in Task 1.1; shows applied/stale/duplicate + live rows.
- [ ] `dashboard-forward.sh` uses `--address 0.0.0.0`.
- [ ] No `:latest` tags; every chart Deployment has a readiness probe; `restart`/`backoffLimit` sane.
- [ ] README states the `validate_lab.sh` divergence (spec §4).
```
