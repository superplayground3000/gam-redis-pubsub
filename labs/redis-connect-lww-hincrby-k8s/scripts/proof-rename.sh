#!/usr/bin/env bash
# Proof rename. Atomic standby->active: after the rename, the active key is live
# (deleted=0, ver=global) AND the standby key is tombstoned (deleted=1) — the
# pairing is complete with no split. A stale rename (lower version) is rejected.
set -euo pipefail
NS="${1:?usage: proof-rename.sh <namespace> <redis-region-pod>}"
POD="${2:?redis-region pod name}"
OLD='lb:company:standby:{employees:proof-1}'
NEW='lb:company:active:{employees:proof-1}'
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl -n "$NS" cp "${LAB_DIR}/chart/files/connect/lww_set.lua" "${POD}:/tmp/lww_set.lua"
kubectl -n "$NS" cp "${LAB_DIR}/chart/files/connect/lww_rename.lua" "${POD}:/tmp/lww_rename.lua"
OUT="$(kubectl -n "$NS" exec "$POD" -- sh -c '
  OLD="'"$OLD"'"; NEW="'"$NEW"'"
  redis-cli DEL "$OLD" "$NEW" >/dev/null
  redis-cli --eval /tmp/lww_set.lua "$OLD" , standbyval 2 set 1000 e1 >/dev/null
  r=$(redis-cli --eval /tmp/lww_rename.lua "$OLD" "$NEW" , activeval 10 1001 e2)
  ndel=$(redis-cli HGET "$NEW" deleted); nver=$(redis-cli HGET "$NEW" ver); nval=$(redis-cli HGET "$NEW" val)
  odel=$(redis-cli HGET "$OLD" deleted)
  stale=$(redis-cli --eval /tmp/lww_rename.lua "$OLD" "$NEW" , older 8 1002 e3)
  nver2=$(redis-cli HGET "$NEW" ver)
  echo "r=$r ndel=$ndel nver=$nver nval=$nval odel=$odel stale=$stale nver2=$nver2"
')"
echo "[proofRENAME] ${OUT}"
chk() { echo "$OUT" | grep -q "$1" || { echo "[proofRENAME] FAIL: expected $1"; exit 1; }; }
chk "r=1"; chk "ndel=0"; chk "nver=10"; chk "nval=activeval"; chk "odel=1"; chk "stale=0"; chk "nver2=10"
echo "[proofRENAME] PASS — atomic standby->active (active live, standby tombstoned), stale rename rejected"
