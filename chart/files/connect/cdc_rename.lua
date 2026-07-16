-- cdc_rename.lua — replay-idempotent rename via native Redis RENAME.
-- KEYS[1]=old_key  KEYS[2]=new_key   (no ARGV: value is NOT carried)
-- Value-preserving: new_key inherits old_key's CURRENT region value.
--
-- Load-bearing (INV-1 row 9, rules/05-invariants.md): the EXISTS guard is what makes
-- rename safe under at-least-once. Because messages can be redelivered, this script
-- WILL run again for a rename whose old_key is already gone. A bare RENAME on a
-- missing key raises "ERR no such key", which errors the processor -> nacks the
-- message -> JetStream redelivers it -> it errors again: a redelivery loop that never
-- drains. The EXISTS check turns that second delivery into a clean no-op, so the
-- rename is idempotent and the loop can never form. Do not remove the guard.
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
