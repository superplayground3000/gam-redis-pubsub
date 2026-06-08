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
  -- INTENTIONAL self-heal: a non-numeric stored ver (c == nil) skips the compare
  -- and falls through to apply the incoming write — a corrupt ver heals to the
  -- next write rather than erroring forever (matches the parent fence).
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
