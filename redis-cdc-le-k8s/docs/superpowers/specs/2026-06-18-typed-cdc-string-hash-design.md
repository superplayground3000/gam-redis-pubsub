# Typed CDC: string + hash support (DEL string, HSET hash)

**Date:** 2026-06-18
**Status:** Approved design — ready for implementation plan
**Scope:** `redis-cdc-le-k8s/`

## Goal

Extend the fence-free CDC relay so it propagates **Redis hashes** alongside the
strings it handles today. The sink must apply hash create/update as a multi-field
`HSET` and hash delete as a key-level `DEL`. String behaviour (`SET`/`DEL`/rename)
is unchanged.

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

### 3. Producer — `internal/writer/payload.go`
- `Event` gains `Type string` (`"string"` | `"hash"`).
- Existing constructors set `Type: "string"`.
- New `NewCreateHashEvent(kvKey string, fields map[string]string)` and
  `NewUpdateHashEvent(...)` set `Type: "hash"` and marshal `fields` to the JSON
  body. (Hash bodies carry no `ts`/`pad` snapshot; they are the field map itself.)
- `StreamValues()` appends `"type", e.Type` to the ordered XADD slice.
- The writer worker emits some hash events so a live run exercises the path.
  Exact wiring (a hash key pattern / mix ratio) is an implementation detail for
  the plan; it must not change the existing string/rename traffic guarantees.

### 4. Verifier — `internal/verifier/`
- `redis.go`: `eventValues` appends `"type", get("type")`; add a `GetHash(ctx,key)`
  read (`HGETALL` → `map[string]string`, plus an exists bool).
- `redis_test.go`: the field-list assertion adds `type`.
- `checks.go`: add a `HashOps` check — emit `op=create,type=hash` then
  `op=update,type=hash` with multi-field bodies, asserting region `HGETALL` after
  each quiesced step (create sets fields; update merges/adds fields), then
  `op=delete` and assert the hash is gone. Untyped emits in existing checks keep
  working because the source defaults `type` to `string`.
- `report.go`: `CDCResult` gains `HashOpsOK bool`; `ComputeVerdict` fails closed
  when it is false.
- `main.go`: call `HashOps`, record the result, include it in the summary line.

### 5. Manual driving — `scripts/insert-msgs.sh`
Add printed (never executed) `XADD` examples for hashes:
- a hash create with several fields (`type hash`, `body '{"f1":"v1","f2":"v2"}'`),
- a hash multi-field update,
- a hash delete (`type hash`, `body ''`).
Existing string/rename/dedup examples are unchanged; new ones carry `type hash`.

## Data flow (hash create/update)

```
writer NewCreateHashEvent
  → XADD app.events  event_id … op create type hash kv_key K body {"f1":"v1","f2":"v2"}
  → source: redis_streams → mapping builds envelope incl. "type":"hash"
  → NATS JetStream (Nats-Msg-Id dedup)
  → sink: stash meta(type) → switch op=create → switch type=hash
  → HSET K f1 v1 f2 v2   (region Redis)   → cdc_apply{op="create",type="hash"}++
```

Delete (either type): `op=delete → DEL K`. Rename: unchanged value-preserving Lua.

## Idempotency & ordering (no-LWW, unchanged)

`HSET` is idempotent under redelivery for the same body (re-setting identical
fields is a no-op net of value). Merge semantics mean a redelivered older update
can re-add a field a newer update already overwrote — accepted by this lab's
explicit no-LWW, order-insensitive design (same caveat already documented for
`SET`/rename in `cdc-reverse.yaml`). `DEL` of an absent key is a no-op. No version
fence is introduced.

## Out of scope / YAGNI

- Per-field `HDEL` (no individual field deletion).
- Full-snapshot hash replace (`DEL`+`HSET`) — merge was chosen.
- Other Redis types (lists, sets, zsets, streams as values).
- Hash-field latency telemetry (latency XADD stays string-`ts`-driven, best-effort).
- Any change to leader election, NATS auth, RBAC, or rename semantics.

## Testing

- **Unit:** `payload_test.go` (hash constructors set `type=hash`, body is the
  field-map JSON, `StreamValues` includes `type`); verifier `redis_test.go`
  (field list includes `type`).
- **Bloblang shape:** assert the HSET args mapping flattens `{f1:v1,f2:v2}` to
  `[K,f1,v1,f2,v2]` (covered via the verifier `HashOps` end-to-end check; a focused
  Connect mapping test is optional if a harness exists).
- **End-to-end:** `verify-cdc.sh` runs the verifier Job including the new
  `HashOps` check; the run exits 0 only when string ops, hash ops, dedup, replay,
  and rename parity all pass.
- **Manual:** `scripts/insert-msgs.sh` hash examples applied against a running
  chart; confirm region `HGETALL` and the dashboard `cdc_apply` counters.
