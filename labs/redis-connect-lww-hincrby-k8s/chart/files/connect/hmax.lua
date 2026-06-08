-- hmax.lua — set hash field to max(current, incoming). Used by the writer to
-- record the authoritative per-key source max version into srcmax:<epoch>.
-- KEYS[1]=hash  ARGV[1]=field  ARGV[2]=value(int)
local v = tonumber(ARGV[2])
if v == nil then
  return redis.error_reply('hmax: non-numeric value: ' .. tostring(ARGV[2]))
end
local cur = redis.call('HGET', KEYS[1], ARGV[1])
local cn = cur and tonumber(cur) or nil
if cur == false or cn == nil or v > cn then
  redis.call('HSET', KEYS[1], ARGV[1], v)
  return v
end
return cn
