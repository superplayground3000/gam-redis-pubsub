-- lww_set.lua — last-write-wins compare-and-set fence.
-- KEYS[1]=key  ARGV[1]=value  ARGV[2]=version (monotonic integer per key)
-- returns: 1 = applied (strictly newer; or first write for the key)
--          0 = stale     (ARGV[2] strictly OLDER than stored — only under reordering)
--         -1 = duplicate (ARGV[2] == stored — routine at-least-once redelivery)
-- Validate the incoming version up front so a malformed value fails loud (a clear
-- error reply) instead of corrupting state and crashing the next CAS for this key.
local v = tonumber(ARGV[2])
if v == nil then
  return redis.error_reply('lww_set: non-numeric version: ' .. tostring(ARGV[2]))
end
local cur = redis.call('HGET', KEYS[1], 'ver')
if cur == false then
  redis.call('HSET', KEYS[1], 'val', ARGV[1], 'ver', v)
  return 1
end
-- Stored ver is only ever written by this script (always numeric); guard anyway so a
-- corrupt value self-heals to the incoming write rather than erroring forever.
local c = tonumber(cur)
if c == nil or v > c then
  redis.call('HSET', KEYS[1], 'val', ARGV[1], 'ver', v)
  return 1
elseif v < c then
  return 0
else
  return -1
end
