#!/usr/bin/env bash
# Unit-tests the sink Lua scripts against an ephemeral Redis container.
# No host changes: spins `redis:7.4-alpine`, evals scripts, asserts, tears down.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA="${LAB_DIR}/chart/files/connect"
CID="$(docker run -d --rm redis:7.4-alpine)"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# wait for ready — fail loudly on timeout instead of testing an unready container
ready=0
for _ in $(seq 1 30); do if docker exec "$CID" redis-cli ping 2>/dev/null | grep -q PONG; then ready=1; break; fi; sleep 0.3; done
[ "$ready" = 1 ] || { echo "FAIL: redis did not become ready"; exit 1; }

docker cp "${LUA}/lww_set.lua" "$CID":/tmp/lww_set.lua
docker cp "${LUA}/lww_rename.lua" "$CID":/tmp/lww_rename.lua
docker cp "${LUA}/hmax.lua" "$CID":/tmp/hmax.lua
EV() { docker exec "$CID" redis-cli --eval "$@"; }
HGET() { docker exec "$CID" redis-cli HGET "$@"; }
fail=0
assert() { # $1=desc $2=got $3=want
  if [ "$2" != "$3" ]; then echo "FAIL: $1: got '$2' want '$3'"; fail=1; else echo "ok: $1"; fi
}

# ---- lww_set: set newer wins, older stale, equal duplicate ----
docker exec "$CID" redis-cli DEL k1 >/dev/null
assert "set v3 applied"   "$(EV /tmp/lww_set.lua k1 , v3 3 set 1000 e1)" "1"
assert "set v1 stale"     "$(EV /tmp/lww_set.lua k1 , v1 1 set 1001 e2)" "0"
assert "set v3 duplicate" "$(EV /tmp/lww_set.lua k1 , v3 3 set 1002 e3)" "-1"
assert "k1 ver==3"        "$(HGET k1 ver)" "3"
assert "k1 val==v3"       "$(HGET k1 val)" "v3"
assert "k1 deleted==0"    "$(HGET k1 deleted)" "0"

# ---- lww_set: delete tombstone retains ver, blocks resurrection ----
docker exec "$CID" redis-cli DEL k2 >/dev/null
EV /tmp/lww_set.lua k2 , a 5 set 2000 e4 >/dev/null
assert "delete v6 applied"   "$(EV /tmp/lww_set.lua k2 , '' 6 delete 2001 e5)" "1"
assert "k2 deleted==1"       "$(HGET k2 deleted)" "1"
assert "k2 tombstone ver==6" "$(HGET k2 ver)" "6"
assert "stale set v4 after delete -> stale" "$(EV /tmp/lww_set.lua k2 , resurrect 4 set 2002 e6)" "0"
assert "k2 still deleted==1 (no resurrect)" "$(HGET k2 deleted)" "1"
assert "newer set v7 after delete revives"  "$(EV /tmp/lww_set.lua k2 , back 7 set 2003 e7)" "1"
assert "k2 deleted==0 after revive"         "$(HGET k2 deleted)" "0"

# ---- lww_rename: atomic standby->active ----
OLD='lb:company:standby:{employees:run-9}'
NEW='lb:company:active:{employees:run-9}'
docker exec "$CID" redis-cli DEL "$OLD" "$NEW" >/dev/null
EV /tmp/lww_set.lua "$OLD" , standbyval 2 set 3000 e8 >/dev/null
assert "rename v10 applied" "$(docker exec "$CID" redis-cli --eval /tmp/lww_rename.lua "$OLD" "$NEW" , activeval 10 3001 e9)" "1"
assert "new active ver==10"  "$(HGET "$NEW" ver)" "10"
assert "new active val"      "$(HGET "$NEW" val)" "activeval"
assert "new active live"     "$(HGET "$NEW" deleted)" "0"
assert "old standby tombstoned" "$(HGET "$OLD" deleted)" "1"
assert "rename v10 duplicate" "$(docker exec "$CID" redis-cli --eval /tmp/lww_rename.lua "$OLD" "$NEW" , again 10 3002 e10)" "-1"
assert "stale rename v8 -> stale" "$(docker exec "$CID" redis-cli --eval /tmp/lww_rename.lua "$OLD" "$NEW" , older 8 3003 e11)" "0"

# ---- hmax: max(current, incoming) + corrupt-field self-heal ----
docker exec "$CID" redis-cli DEL hmaxh >/dev/null
assert "hmax first=5"  "$(EV /tmp/hmax.lua hmaxh , f 5)" "5"
assert "hmax keep=5"   "$(EV /tmp/hmax.lua hmaxh , f 3)" "5"
assert "hmax higher=9" "$(EV /tmp/hmax.lua hmaxh , f 9)" "9"
docker exec "$CID" redis-cli HSET hmaxh g notanumber >/dev/null
assert "hmax corrupt-field self-heals to 7" "$(EV /tmp/hmax.lua hmaxh , g 7)" "7"
assert "hmax corrupt field overwritten to 7" "$(HGET hmaxh g)" "7"

[ "$fail" = 0 ] && echo "ALL LUA TESTS PASS" || { echo "LUA TESTS FAILED"; exit 1; }
