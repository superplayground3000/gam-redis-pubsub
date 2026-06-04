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
