-- lww_rename.lua — atomic standby->active promotion under one global version.
-- KEYS[1]=old_key (…standby…)  KEYS[2]=new_key (…active…)  -- same hash tag => same slot
-- ARGV[1]=value (new active snapshot)  ARGV[2]=version (global)  ARGV[3]=now_ms  ARGV[4]=event_id
-- returns: 1 applied, 0 stale (lost the active CAS), -1 duplicate
local v = tonumber(ARGV[2])
if v == nil then
  return redis.error_reply('lww_rename: non-numeric version: ' .. tostring(ARGV[2]))
end
local now = ARGV[3]
local eid = ARGV[4]
-- Gate the whole promotion on the NEW (active) key: apply only if strictly newest.
local curNew = redis.call('HGET', KEYS[2], 'ver')
if curNew ~= false then
  local cn = tonumber(curNew)
  if cn ~= nil then
    if v < cn then return 0 end
    if v == cn then return -1 end
  end
end
redis.call('HSET', KEYS[2], 'ver', v, 'deleted', '0', 'updated_at', now, 'val', ARGV[1], 'src_event_id', eid)
-- Tombstone the old (standby) key, but never roll its ver backwards.
local curOld = redis.call('HGET', KEYS[1], 'ver')
local applyOld = true
if curOld ~= false then
  local co = tonumber(curOld)
  if co ~= nil and v <= co then applyOld = false end
end
if applyOld then
  redis.call('HSET', KEYS[1], 'ver', v, 'deleted', '1', 'deleted_at', now, 'val', '', 'src_event_id', eid)
end
return 1
