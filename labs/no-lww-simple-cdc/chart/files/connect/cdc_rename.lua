-- cdc_rename.lua — replay-idempotent rename: DEL old, SET new(snapshot).
-- KEYS[1]=old_key  KEYS[2]=new_key  ARGV[1]=body(json snapshot)
-- Always returns 1. Unlike Redis RENAME this never errors when old_key is gone
-- (second delivery), so JetStream redelivery is safe. Single EVAL = atomic per
-- Redis; KEYS[1]/KEYS[2] must share a hash tag (same slot) on Redis Cluster.
redis.call('DEL', KEYS[1])
redis.call('SET', KEYS[2], ARGV[1])
return 1
