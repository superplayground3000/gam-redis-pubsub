-- cdc_rename.lua — replay-idempotent rename via native Redis RENAME.
-- KEYS[1]=old_key  KEYS[2]=new_key   (no ARGV: value is NOT carried)
-- Value-preserving: new_key inherits old_key's CURRENT region value.
-- Guarded by EXISTS because bare RENAME raises "ERR no such key" when old_key is
-- already gone — which happens on every JetStream redelivery (at-least-once) and
-- whenever a reordered delete/rename ran first. Without the guard that error
-- nacks the message -> redelivery loop. With it, a second delivery is a no-op.
-- RENAME overwrites new_key if it already exists (no-LWW: last delivered wins).
-- Single EVAL = atomic per Redis; KEYS[1]/KEYS[2] must share a hash tag (same
-- slot) on Redis Cluster — the writer's {entity:id} key patterns guarantee this.
-- NOTE: if old_key is absent at apply time (its create/update hasn't propagated
-- yet, or it was already deleted), new_key is NOT created — there is no carried
-- body to fall back on. That gap is an expected no-LWW anomaly, not a bug.
if redis.call('EXISTS', KEYS[1]) == 1 then
  redis.call('RENAME', KEYS[1], KEYS[2])
end
return 1
