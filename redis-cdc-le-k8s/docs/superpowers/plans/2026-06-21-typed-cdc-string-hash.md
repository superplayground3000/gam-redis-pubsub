# Typed CDC (string + hash) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Propagate a `type` discriminator (`string`|`hash`) through the fence-free CDC relay so both the writer's authoritative central-KV apply and the sink's region apply do multi-field `HSET` for hashes and key-level `DEL` for both types, with central↔region convergence proven end to end.

**Architecture:** Add `type` to the CDC envelope (XADD field → Connect metadata → JSON envelope). The writer's `applyCentral` and the sink pipeline both branch on `type`. A dedicated hash key family keeps strings and hashes from ever colliding. Pure logic (event construction, op-mix, verdict, hash serialization) is unit-tested; Redis/Connect paths are validated by `verify-cdc.sh` via a new verifier `HashOps` parity check.

**Tech Stack:** Go 1.25, go-redis v9, Redpanda Connect (Bloblang), Helm, bash. No Redis test double is available offline (no miniredis), so Redis-touching code is covered E2E — matching the repo's existing test split.

**Spec:** `docs/superpowers/specs/2026-06-18-typed-cdc-string-hash-design.md`

**Working branch:** `feat/typed-cdc-string-hash` (already created; the spec is committed there).

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `internal/writer/payload.go` | modify | `Event.Type`/`Fields`, hash constructors, `StreamValues` emits `type` |
| `internal/writer/payload_test.go` | modify | unit tests for hash events + `type` field |
| `internal/writer/worker.go` | modify | `applyCentral` hash branch; `buildEvent` hash family; `HashRatio` |
| `internal/writer/worker_test.go` | modify | unit tests for hash-family event building |
| `internal/writer/main.go` | modify | wire `HASH_RATIO` env → `Worker.HashRatio` |
| `chart/files/connect/cdc-forward.yaml` | modify | propagate `type` into the envelope |
| `chart/files/connect/cdc-reverse.yaml` | modify | type-aware apply: `HSET` for hash, `SET` for string; `type` metric label |
| `internal/verifier/redis.go` | modify | `eventValues` emits `type`; `GetHash`/`SetHash`/`Del` helpers |
| `internal/verifier/redis_test.go` | modify | `type` in expected field list |
| `internal/verifier/checks.go` | modify | `HashOps` parity check + helpers |
| `internal/verifier/report.go` | modify | `HashOpsOK` + verdict case |
| `internal/verifier/report_test.go` | modify | verdict fixtures include `HashOpsOK` |
| `internal/verifier/main.go` | modify | run `HashOps`, record + log |
| `internal/dashboard/main.go` | modify | type-aware `scanAll` + `serializeHash` |
| `internal/dashboard/divergence_test.go` | modify | `serializeHash` canonical test |
| `scripts/insert-msgs.sh` | modify | printed hash `XADD` examples |

---

## Task 1: Writer Event gains `type` + `Fields` and hash constructors

**Files:**
- Modify: `internal/writer/payload.go`
- Test: `internal/writer/payload_test.go`

- [ ] **Step 1: Write the failing tests**

Add to `internal/writer/payload_test.go` (keep existing tests):

```go
func TestStringEventTypeIsString(t *testing.T) {
	if e := NewCreateEvent("k", 8); e.Type != "string" {
		t.Fatalf("string event must have type=string, got %q", e.Type)
	}
	if e := NewDeleteEvent("k"); e.Type != "string" {
		t.Fatalf("delete event must have type=string, got %q", e.Type)
	}
}

func TestCreateHashEvent(t *testing.T) {
	fields := map[string]string{"name": "a", "tier": "pro"}
	e := NewCreateHashEvent("lb:hash:active:{profiles:1}", fields)
	if e.Op != "create" || e.Type != "hash" {
		t.Fatalf("bad hash create: %+v", e)
	}
	if len(e.Fields) != 2 {
		t.Fatalf("fields not stored: %+v", e)
	}
	var body map[string]string
	if err := json.Unmarshal([]byte(e.Body), &body); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
	if body["name"] != "a" || body["tier"] != "pro" {
		t.Fatalf("body must equal field map: %v", body)
	}
}

func TestUpdateHashEventOp(t *testing.T) {
	e := NewUpdateHashEvent("k", map[string]string{"f": "v"})
	if e.Op != "update" || e.Type != "hash" {
		t.Fatalf("bad hash update: %+v", e)
	}
}

func TestStreamValuesIncludesType(t *testing.T) {
	vals := NewCreateHashEvent("k", map[string]string{"f": "v"}).StreamValues()
	found := false
	for i := 0; i+1 < len(vals); i += 2 {
		if vals[i] == "type" && vals[i+1] == "hash" {
			found = true
		}
	}
	if !found {
		t.Fatalf("StreamValues missing type=hash: %v", vals)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd redis-cdc-le-k8s && go test ./internal/writer/ -run 'HashEvent|TypeIsString|StreamValuesIncludesType' -v`
Expected: FAIL — `NewCreateHashEvent`/`NewUpdateHashEvent` undefined, `e.Type` undefined.

- [ ] **Step 3: Implement in `payload.go`**

Replace the `Event` struct (lines 14-22) with:

```go
type Event struct {
	EventID string
	Op      string // create|update|delete|rename
	Type    string // string|hash (hash applies HSET; default string)
	KvKey   string // create/update/delete
	OldKey  string // rename
	NewKey  string // rename
	TsMs    int64
	Body    string            // JSON snapshot (string) or JSON field-map (hash); "" for delete/rename
	Fields  map[string]string // hash field map (nil for strings); source of Body + central HSET
}
```

Add `Type: "string"` to each existing constructor return. `NewCreateEvent`:

```go
func NewCreateEvent(kvKey string, padBytes int) Event {
	return Event{EventID: uuid.NewString(), Op: "create", Type: "string", KvKey: kvKey, TsMs: nowMs(), Body: snapshot(padBytes)}
}
```

`NewUpdateEvent`:

```go
func NewUpdateEvent(kvKey string, padBytes int) Event {
	return Event{EventID: uuid.NewString(), Op: "update", Type: "string", KvKey: kvKey, TsMs: nowMs(), Body: snapshot(padBytes)}
}
```

`NewDeleteEvent`:

```go
func NewDeleteEvent(kvKey string) Event {
	return Event{EventID: uuid.NewString(), Op: "delete", Type: "string", KvKey: kvKey, TsMs: nowMs(), Body: ""}
}
```

`NewRenameEvent`:

```go
func NewRenameEvent(oldKey, newKey string) Event {
	return Event{EventID: uuid.NewString(), Op: "rename", Type: "string", OldKey: oldKey, NewKey: newKey, TsMs: nowMs()}
}
```

Add the hash constructors after `NewRenameEvent`:

```go
// NewCreateHashEvent / NewUpdateHashEvent carry a hash field map. Body is the
// canonical JSON of the same map (encoding/json sorts map keys), so the stream
// payload the sink reads and the central HSET the writer applies derive from one
// source. create/update differ only in Op; both merge fields (no field clearing).
func NewCreateHashEvent(kvKey string, fields map[string]string) Event {
	return newHashEvent("create", kvKey, fields)
}

func NewUpdateHashEvent(kvKey string, fields map[string]string) Event {
	return newHashEvent("update", kvKey, fields)
}

func newHashEvent(op, kvKey string, fields map[string]string) Event {
	b, _ := json.Marshal(fields)
	return Event{
		EventID: uuid.NewString(), Op: op, Type: "hash",
		KvKey: kvKey, TsMs: nowMs(), Body: string(b), Fields: fields,
	}
}
```

Update `StreamValues` to insert `"type", e.Type` after the `op` pair:

```go
func (e Event) StreamValues() []any {
	return []any{
		"event_id", e.EventID,
		"op", e.Op,
		"type", e.Type,
		"kv_key", e.KvKey,
		"old_key", e.OldKey,
		"new_key", e.NewKey,
		"ts", e.TsMs,
		"body", e.Body,
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd redis-cdc-le-k8s && go test ./internal/writer/ -v`
Expected: PASS (new tests + existing `TestStreamValuesOrderedSlice` still green — `vals[0]` is still `event_id`).

- [ ] **Step 5: Commit**

```bash
git add redis-cdc-le-k8s/internal/writer/payload.go redis-cdc-le-k8s/internal/writer/payload_test.go
git commit -m "feat(writer): typed CDC events (string|hash) with hash constructors"
```

---

## Task 2: Writer `applyCentral` becomes type-aware

**Files:**
- Modify: `internal/writer/worker.go:107-119`

No unit test: `applyCentral` writes a `redis.Pipeliner` and there is no offline
Redis double. Its correctness is proven E2E by the verifier `HashOps` parity check
(Task 9) and by a live run's dashboard convergence.

- [ ] **Step 1: Replace `applyCentral`**

Replace the function body (lines 107-119) with:

```go
func applyCentral(pipe redis.Pipeliner, ctx context.Context, e Event) {
	switch e.Op {
	case "create", "update":
		// Type-aware authoritative apply, mirroring the sink. A hash applied as a
		// SET (or vice versa) would diverge central from region and make GetString
		// reads hit WRONGTYPE. HSet merges fields (no clearing), like the sink HSET.
		if e.Type == "hash" {
			pipe.HSet(ctx, e.KvKey, e.Fields)
		} else {
			pipe.Set(ctx, e.KvKey, e.Body, 0)
		}
	case "delete":
		pipe.Del(ctx, e.KvKey) // DEL removes a hash too
	case "rename":
		// Value-preserving rename (new_key inherits old_key's central value),
		// matching the sink. EXISTS-guarded so a missing old_key is a no-op
		// instead of erroring the pipeline. See renamePreserveScript.
		pipe.Eval(ctx, renamePreserveScript, []string{e.OldKey, e.NewKey})
	}
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd redis-cdc-le-k8s && go build ./...`
Expected: no output (success).

- [ ] **Step 3: Commit**

```bash
git add redis-cdc-le-k8s/internal/writer/worker.go
git commit -m "feat(writer): type-aware central-KV apply (HSET for hashes)"
```

---

## Task 3: Writer emits hash traffic via a dedicated key family

**Files:**
- Modify: `internal/writer/worker.go` (struct field, `buildEvent`, helpers)
- Modify: `internal/writer/main.go` (env wiring)
- Test: `internal/writer/worker_test.go`

- [ ] **Step 1: Write the failing tests**

Add to `internal/writer/worker_test.go` (add `encoding/json` to its imports; `strings`/`math/rand` already imported):

```go
func TestBuildEventHashFamily(t *testing.T) {
	w := &Worker{Mix: OpMix{Create: 1}, KeySpaceSize: 100, HashRatio: 1, rng: rand.New(rand.NewSource(1))}
	e := w.buildEvent(0)
	if e.Type != "hash" {
		t.Fatalf("HashRatio=1 create must be a hash event, got type %q", e.Type)
	}
	if !strings.Contains(e.KvKey, ":hash:") {
		t.Fatalf("hash event must use the hash key family, got %q", e.KvKey)
	}
	if len(e.Fields) == 0 {
		t.Fatalf("hash create must populate Fields: %+v", e)
	}
	var body map[string]string
	if err := json.Unmarshal([]byte(e.Body), &body); err != nil {
		t.Fatalf("hash body not JSON: %v", err)
	}
	if len(body) != len(e.Fields) {
		t.Fatalf("Body must equal Fields JSON: body=%v fields=%v", body, e.Fields)
	}
}

func TestBuildEventStringWhenHashRatioZero(t *testing.T) {
	w := &Worker{Mix: OpMix{Create: 1}, KeySpaceSize: 100, HashRatio: 0, rng: rand.New(rand.NewSource(1))}
	e := w.buildEvent(0)
	if e.Type != "string" {
		t.Fatalf("HashRatio=0 must produce string events, got type %q", e.Type)
	}
	if !strings.Contains(e.KvKey, ":standby:") {
		t.Fatalf("string create must target standby, got %q", e.KvKey)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd redis-cdc-le-k8s && go test ./internal/writer/ -run 'BuildEventHash|BuildEventString' -v`
Expected: FAIL — `Worker` has no `HashRatio` field.

- [ ] **Step 3: Implement in `worker.go`**

Add `"fmt"` to the imports. Add a field to the `Worker` struct (after `Mix OpMix`):

```go
	HashRatio     float64 // fraction of non-rename ops routed to the hash key family
```

Add the hash key family + field builder above `buildEvent`:

```go
// hashKeyFmt is the dedicated hash key family — disjoint from the string
// standby/active families so a key never changes type (which would WRONGTYPE).
const hashKeyFmt = "lb:hash:active:{profiles:%d}"

func (w *Worker) hashKey(id int64) string { return fmt.Sprintf(hashKeyFmt, id) }

// hashFields builds a small multi-field hash body; "rev" varies per call so a
// later update visibly overwrites it while other fields merge.
func (w *Worker) hashFields() map[string]string {
	return map[string]string{
		"name": fmt.Sprintf("profile-%d", w.rng.Int63n(w.KeySpaceSize)),
		"tier": []string{"free", "pro", "ent"}[w.rng.Intn(3)],
		"rev":  fmt.Sprintf("%d", w.rng.Int63()),
	}
}
```

Replace `buildEvent` (lines 78-91) with:

```go
func (w *Worker) buildEvent(seq uint64) Event {
	op := w.Mix.pick(seq)
	// A fraction of create/update/delete traffic targets the hash family. Rename
	// stays string-only — it models the standby→active promotion lifecycle, a
	// string concept; hashes never rename here.
	if op != "rename" && w.HashRatio > 0 && w.rng.Float64() < w.HashRatio {
		id := w.rng.Int63n(w.KeySpaceSize)
		key := w.hashKey(id)
		switch op {
		case "delete":
			return NewDeleteEvent(key) // DEL is type-agnostic
		case "update":
			return NewUpdateHashEvent(key, w.hashFields())
		default: // create
			return NewCreateHashEvent(key, w.hashFields())
		}
	}
	p := Patterns[w.rng.Intn(len(Patterns))]
	id := w.rng.Int63n(w.KeySpaceSize)
	switch op {
	case "create":
		return NewCreateEvent(p.StandbyKey(id), w.PayloadBytes)
	case "update":
		return NewUpdateEvent(p.StandbyKey(id), w.PayloadBytes)
	case "delete":
		return NewDeleteEvent(p.ActiveKey(id))
	default: // rename: promote standby->active for the same entity (same slot)
		return NewRenameEvent(p.StandbyKey(id), p.ActiveKey(id))
	}
}
```

- [ ] **Step 4: Wire the env var in `main.go`**

In `internal/writer/main.go`, add after the `payloadBytes` line (line 27):

```go
	hashRatio := envFloat("HASH_RATIO", 0.2)
```

Set it on the `Worker` literal (in the `for i := 0; i < workers; i++` loop, add to the struct):

```go
			Mix: mix, Lim: lim, Counters: counters, State: state, HashRatio: hashRatio,
```

Add the helper next to `envInt` at the bottom of the file:

```go
func envFloat(k string, def float64) float64 {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		log.Printf("WARN: %s=%q not a float, using %g", k, v, def)
		return def
	}
	return f
}
```

- [ ] **Step 5: Run tests + build**

Run: `cd redis-cdc-le-k8s && go test ./internal/writer/ -v && go build ./...`
Expected: PASS and clean build. `TestBuildEventOpKeyMapping` still passes (its `Worker` has `HashRatio` zero-valued → string path).

- [ ] **Step 6: Commit**

```bash
git add redis-cdc-le-k8s/internal/writer/worker.go redis-cdc-le-k8s/internal/writer/worker_test.go redis-cdc-le-k8s/internal/writer/main.go
git commit -m "feat(writer): emit hash traffic on a dedicated key family (HASH_RATIO)"
```

---

## Task 4: Source pipeline propagates `type`

**Files:**
- Modify: `chart/files/connect/cdc-forward.yaml:36-45`

No offline test (no Bloblang linter / Connect binary); validated E2E in Task 11.

- [ ] **Step 1: Add the `type` field to the envelope mapping**

In the `root = { ... }` mapping, add a `"type"` line after the `"op"` line:

```yaml
        root = {
          "event_id": $eid,
          "op":       meta("op").or("update"),
          "type":     meta("type").or("string"),
          "kv_key":   meta("kv_key").or(""),
          "old_key":  meta("old_key").or(""),
          "new_key":  meta("new_key").or(""),
          "ts":       meta("ts").or("0"),
          "body":     $body
        }
```

(Producers that omit `type` default to `string`, preserving existing behavior.)

- [ ] **Step 2: Render the chart to confirm valid YAML**

Run: `cd redis-cdc-le-k8s && helm template . --set profile=cdc -s templates/connect-configmaps.yaml | grep -A2 '"op":' | head`
Expected: the rendered ConfigMap shows the `"type": meta("type").or("string")` line. No template error.

- [ ] **Step 3: Commit**

```bash
git add redis-cdc-le-k8s/chart/files/connect/cdc-forward.yaml
git commit -m "feat(connect): propagate type into the CDC envelope (source)"
```

---

## Task 5: Sink pipeline applies HSET for hashes, SET for strings

**Files:**
- Modify: `chart/files/connect/cdc-reverse.yaml`

- [ ] **Step 1: Stash `type` into metadata**

In the first stash `mapping` (lines 41-46), add a `type` line:

```yaml
    - mapping: |
        meta op      = this.op
        meta type    = this.type.or("string")
        meta kv_key  = this.kv_key
        meta old_key = this.old_key
        meta new_key = this.new_key
        meta body    = this.body
```

- [ ] **Step 2: Replace the authoritative string SET with a type switch**

In the `create || update` branch, replace the single authoritative `redis`/`set`
processor (lines 78-83) with a nested `switch` (keep the preceding latency
try/catch and the following `metric` block):

```yaml
            # Authoritative apply, type-aware. NOT wrapped — a failure must nack/redeliver.
            - switch:
                - check: meta("type") == "hash"
                  processors:
                    - redis:
                        url: {{ include "rrcs.redis.region.url" . }}
                        kind: {{ include "rrcs.redis.region.connectKind" . }}
                        command: hset
                        # Flatten the JSON field-map body into HSET args:
                        # key_values() -> [{key,value}]; map_each -> [[k,v]];
                        # flatten -> [k,v,...]; concat prepends the key.
                        args_mapping: |
                          root = [ meta("kv_key") ].concat(
                            meta("body").parse_json().key_values()
                              .map_each(kv -> [ kv.key, kv.value.string() ]).flatten() )
                - processors:
                    - redis:
                        url: {{ include "rrcs.redis.region.url" . }}
                        kind: {{ include "rrcs.redis.region.connectKind" . }}
                        command: set
                        args_mapping: 'root = [ meta("kv_key"), meta("body") ]'
```

- [ ] **Step 3: Add a `type` label to the create/update metric**

The `metric` block right after (lines 84-88) gains a `type` label:

```yaml
            - metric:
                type: counter
                name: cdc_apply
                labels:
                  op: '${! meta("op") }'
                  type: '${! meta("type") }'
```

(The dashboard's `scrapeApply` matches `op="…"` via substring, so the extra label is backward-safe; `delete`/`rename` metric blocks are left unchanged.)

- [ ] **Step 4: Render the chart to confirm valid YAML**

Run: `cd redis-cdc-le-k8s && helm template . --set profile=cdc -s templates/connect-configmaps.yaml | grep -E 'command: hset|key_values' | head`
Expected: the `hset` command and `key_values()` mapping appear; no template error.

- [ ] **Step 5: Commit**

```bash
git add redis-cdc-le-k8s/chart/files/connect/cdc-reverse.yaml
git commit -m "feat(connect): type-aware sink apply — HSET hashes, SET strings"
```

---

## Task 6: Verifier `eventValues` carries `type`

**Files:**
- Modify: `internal/verifier/redis.go:22-35`
- Test: `internal/verifier/redis_test.go:21`

- [ ] **Step 1: Update the failing test**

In `internal/verifier/redis_test.go`, add `"type"` to the expected field list (line 21):

```go
	for _, k := range []string{"event_id", "op", "type", "kv_key", "old_key", "new_key", "ts", "body"} {
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd redis-cdc-le-k8s && go test ./internal/verifier/ -run TestEventValuesOrder -v`
Expected: FAIL — `missing field "type"`.

- [ ] **Step 3: Implement in `redis.go`**

Replace `eventValues` (lines 24-35) with:

```go
func eventValues(f map[string]string) []any {
	get := func(k string) string { return f[k] }
	typ := get("type")
	if typ == "" {
		typ = "string" // default so emitted envelopes always carry a concrete type
	}
	return []any{
		"event_id", get("event_id"),
		"op", get("op"),
		"type", typ,
		"kv_key", get("kv_key"),
		"old_key", get("old_key"),
		"new_key", get("new_key"),
		"ts", get("ts"),
		"body", get("body"),
	}
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd redis-cdc-le-k8s && go test ./internal/verifier/ -run TestEventValuesOrder -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add redis-cdc-le-k8s/internal/verifier/redis.go redis-cdc-le-k8s/internal/verifier/redis_test.go
git commit -m "feat(verifier): emit type field in CDC events (default string)"
```

---

## Task 7: Verifier Redis hash helpers

**Files:**
- Modify: `internal/verifier/redis.go`

No unit test (Redis-touching); used by `HashOps` (Task 9), covered E2E.

- [ ] **Step 1: Add `GetHash`, `SetHash`, `Del` after `Set` (around line 61)**

```go
// GetHash returns (fields, exists). HGETALL on a missing key yields an empty map;
// Redis has no empty hashes, so len>0 == exists.
func (c *RedisClient) GetHash(ctx context.Context, key string) (map[string]string, bool, error) {
	m, err := c.rdb.HGetAll(ctx, key).Result()
	if err != nil {
		return nil, false, err
	}
	return m, len(m) > 0, nil
}

// SetHash merges fields into a hash (HSET), mimicking the writer's authoritative
// central apply so HashOps can assert central<->region convergence.
func (c *RedisClient) SetHash(ctx context.Context, key string, fields map[string]string) error {
	return c.rdb.HSet(ctx, key, fields).Err()
}

// Del removes a key (string or hash), mimicking the central delete apply.
func (c *RedisClient) Del(ctx context.Context, key string) error {
	return c.rdb.Del(ctx, key).Err()
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd redis-cdc-le-k8s && go build ./...`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add redis-cdc-le-k8s/internal/verifier/redis.go
git commit -m "feat(verifier): GetHash/SetHash/Del helpers for hash checks"
```

---

## Task 8: Verifier verdict gains `HashOpsOK`

**Files:**
- Modify: `internal/verifier/report.go`
- Test: `internal/verifier/report_test.go`

- [ ] **Step 1: Update the failing test**

Replace `TestVerdictPassOnlyWhenAllGreen` in `report_test.go` with (adds `HashOpsOK` to fixtures + a new failure case):

```go
func TestVerdictPassOnlyWhenAllGreen(t *testing.T) {
	all := CDCResult{DedupOK: true, OpsOK: true, ReplayOK: true, RenameParityOK: true, HashOpsOK: true}
	if v := ComputeVerdict(all); !v.Pass {
		t.Fatalf("all-green should pass: %+v", v)
	}
	bad := CDCResult{DedupOK: true, OpsOK: false, ReplayOK: true, RenameParityOK: true, HashOpsOK: true}
	if v := ComputeVerdict(bad); v.Pass {
		t.Fatal("ops failure must fail the verdict")
	}
	noParity := CDCResult{DedupOK: true, OpsOK: true, ReplayOK: true, RenameParityOK: false, HashOpsOK: true}
	if v := ComputeVerdict(noParity); v.Pass {
		t.Fatal("rename-parity failure must fail the verdict")
	}
	noHash := CDCResult{DedupOK: true, OpsOK: true, ReplayOK: true, RenameParityOK: true, HashOpsOK: false}
	if v := ComputeVerdict(noHash); v.Pass {
		t.Fatal("hash-ops failure must fail the verdict")
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd redis-cdc-le-k8s && go test ./internal/verifier/ -run TestVerdictPassOnlyWhenAllGreen -v`
Expected: FAIL — `CDCResult` has no `HashOpsOK` field.

- [ ] **Step 3: Implement in `report.go`**

Add the field to `CDCResult` (after `RenameParityOK`, line 18):

```go
	// HashOpsOK: hash create/update merge and delete converged central<->region.
	HashOpsOK bool `json:"hash_ops_ok"`
```

Add a verdict case in `ComputeVerdict` (after the `RenameParityOK` case, before `default`):

```go
	case !r.HashOpsOK:
		return Verdict{false, "hash ops failed: HSET merge or delete did not converge central<->region"}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd redis-cdc-le-k8s && go test ./internal/verifier/ -run TestVerdictPassOnlyWhenAllGreen -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add redis-cdc-le-k8s/internal/verifier/report.go redis-cdc-le-k8s/internal/verifier/report_test.go
git commit -m "feat(verifier): HashOpsOK gates the verdict"
```

---

## Task 9: Verifier `HashOps` parity check

**Files:**
- Modify: `internal/verifier/checks.go`

No unit test (Redis-touching); this IS the E2E gate, run by `verify-cdc.sh` (Task 11).

- [ ] **Step 1: Add `HashOps` + helpers at the end of `checks.go`**

```go
// HashOps exercises the hash path end-to-end. Like RenameParity, it reproduces
// the writer's authoritative CENTRAL apply (the verifier's emitted events bypass
// the writer) and asserts the sink's REGION apply converges with it:
//   create -> central HSET + emit -> central==region=={fields}
//   update -> central HSET merge + emit -> central==region=={merged superset}
//   delete -> central DEL + emit -> gone on both sides
func (c *Checks) HashOps(ctx context.Context, epoch string) (ok bool, err error) {
	key := fmt.Sprintf("lb:hash:active:{verify-%s-h}", epoch)

	f1 := map[string]string{"name": "alice", "tier": "free"}
	if err = c.Central.SetHash(ctx, key, f1); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{
		"event_id": "vhc-" + epoch, "op": "create", "type": "hash", "kv_key": key,
		"body": `{"name":"alice","tier":"free"}`,
	}); err != nil {
		return
	}
	if ok, err = c.hashParity(ctx, key, f1); err != nil || !ok {
		return
	}

	// Merge update: overwrite tier, add region; name must persist (merge).
	if err = c.Central.SetHash(ctx, key, map[string]string{"tier": "pro", "region": "apac"}); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{
		"event_id": "vhu-" + epoch, "op": "update", "type": "hash", "kv_key": key,
		"body": `{"tier":"pro","region":"apac"}`,
	}); err != nil {
		return
	}
	want := map[string]string{"name": "alice", "tier": "pro", "region": "apac"}
	if ok, err = c.hashParity(ctx, key, want); err != nil || !ok {
		return
	}

	// Delete removes the whole hash on both sides.
	if err = c.Central.Del(ctx, key); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{
		"event_id": "vhd-" + epoch, "op": "delete", "type": "hash", "kv_key": key,
	}); err != nil {
		return
	}
	_, cEx, e := c.Central.GetHash(ctx, key)
	if e != nil {
		err = e
		return
	}
	_, rEx, e := c.Region.GetHash(ctx, key)
	if e != nil {
		err = e
		return
	}
	ok = !cEx && !rEx
	return
}

// hashParity asserts central AND region both hold exactly want.
func (c *Checks) hashParity(ctx context.Context, key string, want map[string]string) (bool, error) {
	cv, _, err := c.Central.GetHash(ctx, key)
	if err != nil {
		return false, err
	}
	rv, _, err := c.Region.GetHash(ctx, key)
	if err != nil {
		return false, err
	}
	return mapsEqual(cv, want) && mapsEqual(rv, want), nil
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd redis-cdc-le-k8s && go build ./... && go vet ./internal/verifier/`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add redis-cdc-le-k8s/internal/verifier/checks.go
git commit -m "feat(verifier): HashOps central<->region parity check"
```

---

## Task 10: Wire `HashOps` into the verifier run

**Files:**
- Modify: `internal/verifier/main.go:66-76`

- [ ] **Step 1: Call `HashOps` after `RenameParity` (after line 70)**

```go
	hok, err := checks.HashOps(ctx, *epoch)
	if err != nil {
		log.Printf("hash-ops error: %v", err)
	}
	res.HashOpsOK = hok
```

- [ ] **Step 2: Add `hash_ops_ok` to the summary log (line 75-76)**

```go
	log.Printf("verdict.pass=%v reason=%q dedup_delta=%d ops_ok=%v replay_ok=%v rename_parity_ok=%v hash_ops_ok=%v",
		rep.Verdict.Pass, rep.Verdict.Reason, res.DedupDelta, res.OpsOK, res.ReplayOK, res.RenameParityOK, res.HashOpsOK)
```

- [ ] **Step 3: Verify it builds + all verifier unit tests pass**

Run: `cd redis-cdc-le-k8s && go build ./... && go test ./internal/verifier/ -v`
Expected: success; all PASS.

- [ ] **Step 4: Commit**

```bash
git add redis-cdc-le-k8s/internal/verifier/main.go
git commit -m "feat(verifier): run HashOps in the verifier and report it"
```

---

## Task 11: Dashboard divergence sees hashes

**Files:**
- Modify: `internal/dashboard/main.go` (`scanAll` ~lines 211-236; add `serializeHash`; import `sort`)
- Test: `internal/dashboard/divergence_test.go`

- [ ] **Step 1: Write the failing test**

Add to `internal/dashboard/divergence_test.go`:

```go
func TestSerializeHashCanonical(t *testing.T) {
	a := serializeHash(map[string]string{"b": "2", "a": "1"})
	b := serializeHash(map[string]string{"a": "1", "b": "2"})
	if a != b {
		t.Fatalf("serialization must be order-independent: %q vs %q", a, b)
	}
	if a != "hash:{a=1,b=2}" {
		t.Fatalf("unexpected canonical form: %q", a)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd redis-cdc-le-k8s && go test ./internal/dashboard/ -run TestSerializeHashCanonical -v`
Expected: FAIL — `serializeHash` undefined.

- [ ] **Step 3: Implement in `main.go`**

Add `"sort"` to the imports. Add `serializeHash` near `scanAll`:

```go
// serializeHash renders a hash as a canonical "k=v" string (fields sorted) so the
// central/region divergence comparison is order-independent and stable.
func serializeHash(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(m))
	for _, k := range keys {
		parts = append(parts, k+"="+m[k])
	}
	return "hash:{" + strings.Join(parts, ",") + "}"
}
```

Replace the per-key read loop inside `scanAll` (lines 221-227) with a type-aware read:

```go
			for _, k := range keys {
				typ, terr := shard.Type(ctx, k).Result()
				if terr != nil {
					continue // key vanished or moved mid-scan; tolerate
				}
				if typ == "hash" {
					if m, herr := shard.HGetAll(ctx, k).Result(); herr == nil && len(m) > 0 {
						mu.Lock()
						out[k] = serializeHash(m)
						mu.Unlock()
					}
					continue
				}
				if v, gerr := shard.Get(ctx, k).Result(); gerr == nil {
					mu.Lock()
					out[k] = v
					mu.Unlock()
				}
			}
```

- [ ] **Step 4: Run tests + build**

Run: `cd redis-cdc-le-k8s && go test ./internal/dashboard/ -v && go build ./...`
Expected: PASS (including existing `TestDivergence`); clean build.

- [ ] **Step 5: Commit**

```bash
git add redis-cdc-le-k8s/internal/dashboard/main.go redis-cdc-le-k8s/internal/dashboard/divergence_test.go
git commit -m "feat(dashboard): type-aware scan so hashes appear in divergence"
```

---

## Task 12: Manual driving examples for hashes

**Files:**
- Modify: `scripts/insert-msgs.sh`

- [ ] **Step 1: Add hash examples to the `cat <<EOF` heredoc**

After the existing `# delete an employee` block, add:

```bash
# create a hash (profile) with multiple fields
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op create type hash kv_key "lb:hash:active:{profiles:${ITEM_ID}}" ts "$(ts)" body '{"name":"alice","tier":"free"}'

# merge-update several hash fields at once (name persists, tier overwritten, region added)
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op update type hash kv_key "lb:hash:active:{profiles:${ITEM_ID}}" ts "$(ts)" body '{"tier":"pro","region":"apac"}'

# delete the whole hash
${REDIS_CLI} XADD ${STREAM} '*' event_id "$(uuid)" op delete type hash kv_key "lb:hash:active:{profiles:${ITEM_ID}}" ts "$(ts)" body ''
```

(The existing string examples omit `type`; the source defaults them to `string`.)

- [ ] **Step 2: Verify the script still parses and prints**

Run: `cd redis-cdc-le-k8s && bash -n scripts/insert-msgs.sh && bash scripts/insert-msgs.sh | grep -c 'type hash'`
Expected: `bash -n` clean; grep prints `3`.

- [ ] **Step 3: Commit**

```bash
git add redis-cdc-le-k8s/scripts/insert-msgs.sh
git commit -m "docs(scripts): print hash XADD examples in insert-msgs.sh"
```

---

## Task 13: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Whole-module build, vet, unit tests**

Run: `cd redis-cdc-le-k8s && go build ./... && go vet ./... && go test ./...`
Expected: all PASS.

- [ ] **Step 2: Render the full chart**

Run: `cd redis-cdc-le-k8s && helm template . --set profile=cdc >/dev/null && echo OK`
Expected: `OK` (no template errors).

- [ ] **Step 3: End-to-end on kind (the real gate for the Bloblang + Redis paths)**

Run:
```bash
cd redis-cdc-le-k8s
kind create cluster --name cdc        # skip if it already exists
scripts/build-images.sh --kind --kind-name=cdc
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh
```
Expected: `verify-cdc.sh` exits 0; the verifier log line shows `hash_ops_ok=true` alongside the existing checks, and `verdict.pass=true`.

- [ ] **Step 4: (Optional) Eyeball the hash path**

Run `scripts/insert-msgs.sh`, copy the `type hash` lines into the central Redis, then:
```bash
kubectl -n cdc-k8s exec deploy/redis-region -- redis-cli HGETALL "lb:hash:active:{profiles:9123}"
```
Expected: after create+update, the hash holds `name=alice tier=pro region=apac`; after delete, it is empty. The dashboard divergence view counts the hash key.

- [ ] **Step 5: Final commit (if any verification-driven fixups were needed)**

```bash
git add -A
git commit -m "test(cdc): verify typed string+hash path end to end"
```

---

## Self-review notes

- **Spec coverage:** envelope `type` (Tasks 1,4,6) ✓; sink HSET/SET/DEL (Task 5) ✓; writer central HSET/DEL (Task 2) ✓; multi-field merge (Tasks 1,5,9) ✓; verifier HashOps central↔region parity (Tasks 8,9,10) ✓; dashboard hash visibility (Task 11) ✓; insert-msgs (Task 12) ✓; backward-compat default `string` (Tasks 4,6) ✓.
- **Type consistency:** `Event.Type`/`Event.Fields`, `NewCreateHashEvent`/`NewUpdateHashEvent`, `Worker.HashRatio`, `RedisClient.GetHash/SetHash/Del`, `CDCResult.HashOpsOK`, `Checks.HashOps/hashParity`, `serializeHash` — names used consistently across tasks.
- **No offline Redis double:** `applyCentral`, `GetHash/SetHash/Del`, `HashOps`, and the sink Bloblang are validated by Task 13's `verify-cdc.sh` E2E, consistent with the repo's existing test split (no miniredis dependency added).
