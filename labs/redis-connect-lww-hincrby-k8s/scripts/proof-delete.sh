#!/usr/bin/env bash
# Proof delete. A delete writes a tombstone (deleted=1, ver retained); a later
# STALE (lower-version) set does NOT resurrect it; a NEWER set revives it.
set -euo pipefail
NS="${1:?usage: proof-delete.sh <namespace> <redis-region-pod>}"
POD="${2:?redis-region pod name}"
KEY="lwwproofDEL:1"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl -n "$NS" cp "${LAB_DIR}/chart/files/connect/lww_set.lua" "${POD}:/tmp/lww_set.lua"
OUT="$(kubectl -n "$NS" exec "$POD" -- sh -c '
  KEY="'"$KEY"'"
  redis-cli DEL "$KEY" >/dev/null
  s=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , hello 5 set 1000 e1)
  d=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , "" 6 delete 1001 e2)
  del1=$(redis-cli HGET "$KEY" deleted); ver1=$(redis-cli HGET "$KEY" ver)
  stale=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , resurrect 4 set 1002 e3)
  del2=$(redis-cli HGET "$KEY" deleted)
  rev=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , back 7 set 1003 e4)
  del3=$(redis-cli HGET "$KEY" deleted); ver3=$(redis-cli HGET "$KEY" ver)
  echo "s=$s d=$d del1=$del1 ver1=$ver1 stale=$stale del2=$del2 rev=$rev del3=$del3 ver3=$ver3"
')"
echo "[proofDEL] ${OUT}"
chk() { echo "$OUT" | grep -q "$1" || { echo "[proofDEL] FAIL: expected $1"; exit 1; }; }
chk "d=1"; chk "del1=1"; chk "ver1=6"; chk "stale=0"; chk "del2=1"; chk "rev=1"; chk "del3=0"; chk "ver3=7"
echo "[proofDEL] PASS — delete tombstones (ver retained), stale set cannot resurrect, newer set revives"
