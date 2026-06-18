# Typed CDC: string + hash support (DEL string, HSET hash)

**Date:** 2026-06-18
**Status:** Approved design — ready for implementation plan
**Scope:** `redis-cdc-le-k8s/`

## Goal

Extend the fence-free CDC relay so it propagates **Redis hashes** alongside the
strings it handles today. Because the relay is a **dual write**, both halves must
learn hashes: the writer's authoritative central-KV apply AND the sink's region
apply must do hash create/update as a multi-field `HSET` and hash delete as a
key-level `DEL`, so central and region converge. String behaviour
(`SET`/`DEL`/rename) is unchanged.

The original ask — "modify connect source and sink pipeline YAML to support
DEL string, hset hash" — expands to a **full vertical slice** (chosen during
brainstorming): the pipeline YAMLs plus the producer (writer), the automated
verifier, and the manual driving script, so `verify-cdc.sh` proves the hash path
end to end.

## Decisions (locked during brainstorming)

1. **Type discriminator: a new `type` field in the CDC envelope** (`string` |
   `hash`). It rides the existing XADD-fields → Connect-metadata → JSON-envelope
   path. Defaults to `string` when absent (backward compatible with existing
   producers and replayed history).
2. **Hash body = JSON object of `field → value`.** One event may carry many fields
   ("一次要更新多個 hash 內的欄位" — multi-field updates must be supported).
3. **Hash create/update = merge `HSET key f1 v1 f2 v2 …`** — unspecified fields are
   left untouched. **Hash delete = key-level `DEL key`** (Redis `DEL` removes a hash
   too). No per-field `HDEL`.
4. **Rename stays type-agnostic** — Redis `RENAME` works on any value type, so the
   existing value-preserving rename-Lua path is unchanged and ignores `type`.

## The CDC envelope

```
{ event_id, op, type, kv_key, old_key, new_key, ts, body }
```

| op            | type             | body                         | sink action                       |
|---------------|------------------|------------------------------|-----------------------------------|
| create/update | `string`         | opaque JSON snapshot         | `SET kv_key body`                 |
| create/update | `hash`           | JSON object `{field:value}`  | `HSET kv_key f1 v1 f2 v2 …` (merge)|
| delete        | `string`\|`hash` | `""`                         | `DEL kv_key`                      |
| rename        | (ignored)        | `""`                         | value-preserving `EVAL` rename-Lua|
| unknown       | —                | —                            | `throw` → nack                    |

## Components & changes

### 1. Source leg — `chart/files/connect/cdc-forward.yaml`
Add one line to the envelope mapping so `type` propagates, defaulting to `string`:

```
"type": meta("type").or("string"),
```

No other change. (The `type` XADD field arrives as metadata exactly like
`op`/`kv_key`; absent producers → `"string"`.)

### 2. Sink leg — `chart/files/connect/cdc-reverse.yaml`
- Stash the field first: `meta type = this.type` in the metadata-stash mapping.
- In the `create || update` branch: **keep** the existing best-effort latency `XADD`
  (it self-skips when `body` has no `ts`, which hash bodies generally won't have),
  then **nest a switch on `meta("type")`**:
  - `meta("type") == "hash"` → `redis` processor `command: hset`, args flattened
    from the body object:
    ```
    root = [ meta("kv_key") ].concat(
      meta("body").parse_json().key_values()
        .map_each(kv -> [ kv.key, kv.value.string() ]).flatten() )
    ```
    (`key_values()` → `[{key,value},…]`; `map_each` → `[[k,v],…]`; `flatten` →
    `[k,v,…]`; `concat` prepends the key → `[key,k1,v1,…]`.)
  - default (string) → existing `SET kv_key body`.
- `delete` branch unchanged (`DEL kv_key` already covers hashes).
- `cdc_apply` metric gains a `type` label: `labels: { op: …, type: '${! meta("type") }' }`.
  **Backward-safe:** the dashboard's `scrapeApply` matches `op="…"` via substring
  `Contains` (`internal/dashboard/main.go`), so the extra label does not break
  per-op scraping; hash and string `create` both still aggregate under `op=create`.

### 3. Producer — `internal/writer/`

**Event shape (`payload.go`)**
- `Event` gains `Type string` (`"string"` | `"hash"`) and `Fields
  map[string]string` (the parsed hash field map; nil for strings).
- Existing constructors set `Type: "string"`, `Fields: nil`.
- New `NewCreateHashEvent(kvKey string, fields map[string]string)` and
  `NewUpdateHashEvent(...)` set `Type: "hash"`, store `Fields`, and marshal the
  same map to `Body` (canonical JSON) so the stream payload and the central apply
  derive from one source. (Hash bodies carry no `ts`/`pad` snapshot; they are the
  field map itself.)
- `StreamValues()` appends `"type", e.Type` to the ordered XADD slice. (`body`
  still carries the JSON field-map for the sink; `Fields` is writer-internal.)

**Authoritative central-KV apply (`worker.go` `applyCentral`) — REQUIRED**
This is the *central* half of the dual write. It MUST branch on `e.Type` and
mirror the sink exactly, or central and region diverge by construction and the
verifier's `GetString` reads hit `WRONGTYPE` on hash keys:
- `create`/`update` + `string` → `pipe.Set(ctx, KvKey, Body, 0)` (existing).
- `create`/`update` + `hash`   → `pipe.HSet(ctx, KvKey, Fields)` (merge — same
  semantics as the sink's `HSET`).
- `delete` (either type) → `pipe.Del(ctx, KvKey)` (existing; `DEL` removes a hash).
- `rename` → existing value-preserving `EVAL` (type-agnostic).
The central apply and the `XADD` stay in the same non-atomic pipeline (the no-LWW
looseness is unchanged).

**Worker traffic (`worker.go` `buildEvent`)**
- The worker emits some hash events so a live run exercises the path. The exact
  wiring — a dedicated hash key pattern (so hash and string keys never collide on
  the same key, which would itself be a `WRONGTYPE` bug) and the mix weight — is a
  plan-level detail. It must not change the existing string/rename traffic
  guarantees, and hash keys must use their own key family distinct from the
  string `standby`/`active` keys.

### 4. Verifier — `internal/verifier/`
- `redis.go`: `eventValues` appends `"type", get("type")`; add a `GetHash(ctx,key)`
  read (`HGETALL` → `map[string]string`, plus an exists bool). The same
  `RedisClient` type backs both the central and region clients, so `GetHash`
  serves both sides — needed for hash parity (below).
- `redis_test.go`: the field-list assertion adds `type`.
- `checks.go`: add a `HashOps` check that emits typed hash events and asserts
  **both** region correctness **and** central↔region convergence (the dual-write
  parity that `RenameParity` gives strings):
  1. emit `op=create,type=hash` with a multi-field body → assert region `HGETALL`
     equals the fields, AND central `HGETALL` equals region (writer's `applyCentral`
     HSET vs the sink's HSET).
  2. emit `op=update,type=hash` adding/overwriting fields → assert region reflects
     the merge, AND central equals region.
  3. emit `op=delete` → assert the hash is gone on both central and region.

  Untyped emits in the existing checks keep working because the source defaults
  `type` to `string`. The existing string checks must keep using string keys so
  their `GetString` reads never touch a hash key.
- `report.go`: `CDCResult` gains `HashOpsOK bool`; `ComputeVerdict` fails closed
  when it is false.
- `main.go`: call `HashOps`, record the result, include it in the summary line.

### 4b. Dashboard — `internal/dashboard/main.go` (observability, REQUIRED)
`scanAll` currently reads every key with `GET` and silently drops keys whose
`GET` errors — a hash key returns `WRONGTYPE`, so hashes would be **invisible** to
the central-vs-region divergence view, the very thing this lab demonstrates. Make
the per-key read type-aware: `TYPE key` → `GET` for strings, `HGETALL` for hashes
serialized to a **canonical string** (fields sorted, `field=value` joined). Both
central and region serialize identically, so `computeDivergence`'s
`map[string]string` comparison stays meaningful for hashes (matching hashes are
equal; a stale-field merge shows as `Differing`). String keys are unaffected.

### 5. Manual driving — `scripts/insert-msgs.sh`
Add printed (never executed) `XADD` examples for hashes:
- a hash create with several fields (`type hash`, `body '{"f1":"v1","f2":"v2"}'`),
- a hash multi-field update,
- a hash delete (`type hash`, `body ''`).
Existing string/rename/dedup examples are unchanged; new ones carry `type hash`.

## Data flow (hash create/update)

```
writer NewCreateHashEvent  (one non-atomic pipeline, dual write):
  ├─ applyCentral: HSET K f1 v1 f2 v2          (CENTRAL Redis — authoritative)
  └─ XADD app.events  event_id … op create type hash kv_key K body {"f1":"v1","f2":"v2"}
       → source: redis_streams → mapping builds envelope incl. "type":"hash"
       → NATS JetStream (Nats-Msg-Id dedup)
       → sink: stash meta(type) → switch op=create → switch type=hash
       → HSET K f1 v1 f2 v2   (REGION Redis)   → cdc_apply{op="create",type="hash"}++
```

Central and region apply the **same** `HSET` merge from the same event, so they
converge (verified by `HashOps`). Delete (either type): central `DEL K` +
region `DEL K`. Rename: unchanged value-preserving Lua on both sides.

## Idempotency & ordering (no-LWW, unchanged)

`HSET` is idempotent under redelivery for the same body (re-setting identical
fields is a no-op net of value). Merge semantics mean a redelivered older update
can re-add a field a newer update already overwrote — accepted by this lab's
explicit no-LWW, order-insensitive design (same caveat already documented for
`SET`/rename in `cdc-reverse.yaml`). `DEL` of an absent key is a no-op. No version
fence is introduced. Because the writer's central `applyCentral` and the sink both
apply the identical merge from the identical event, central and region reach the
same terminal hash state — the dual-write convergence `HashOps` asserts.

## Out of scope / YAGNI

- Per-field `HDEL` (no individual field deletion).
- Full-snapshot hash replace (`DEL`+`HSET`) — merge was chosen.
- Other Redis types (lists, sets, zsets, streams as values).
- Hash-field latency telemetry (latency XADD stays string-`ts`-driven, best-effort).
- Any change to leader election, NATS auth, RBAC, or rename semantics.
- **String/hash key collisions:** strings and hashes live in disjoint key families,
  so no key ever changes type. Mid-life type changes are not modeled (a `SET` over a
  hash key would be a `WRONGTYPE` error — avoided by construction, not handled).

## Testing

- **Unit:** `payload_test.go` (hash constructors set `type=hash`, populate
  `Fields`, body is the field-map JSON, `StreamValues` includes `type`);
  `worker_test.go` (`applyCentral` issues `HSET` for hash create/update and `DEL`
  for delete — not `SET`); verifier `redis_test.go` (field list includes `type`).
- **Bloblang shape:** assert the HSET args mapping flattens `{f1:v1,f2:v2}` to
  `[K,f1,v1,f2,v2]` (covered via the verifier `HashOps` end-to-end check; a focused
  Connect mapping test is optional if a harness exists).
- **End-to-end:** `verify-cdc.sh` runs the verifier Job including the new
  `HashOps` check; the run exits 0 only when string ops, hash ops, dedup, replay,
  and rename parity all pass.
- **Manual:** `scripts/insert-msgs.sh` hash examples applied against a running
  chart; confirm region `HGETALL` and the dashboard `cdc_apply` counters.
