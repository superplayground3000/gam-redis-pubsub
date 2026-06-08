-- hmax.lua — set hash field to max(current, incoming). Used by the writer to
-- record the authoritative per-key source max version into srcmax:<epoch>.
-- KEYS[1]=hash  ARGV[1]=field  ARGV[2]=value(int)
local cur = redis.call('HGET', KEYS[1], ARGV[1])
local v = tonumber(ARGV[2])
if cur == false or v > tonumber(cur) then
  redis.call('HSET', KEYS[1], ARGV[1], v)
  return v
end
return tonumber(cur)
