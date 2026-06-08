#!/usr/bin/env bash
# Proof MW+ (POSITIVE). With versions minted by a SHARED HINCRBY counter, two
# writers hammering the SAME key never collide — every write gets a distinct,
# strictly-increasing version, so none is silently lost (contrast proof-c.sh,
# where local same-version counters DO lose updates).
set -euo pipefail
NS="${1:?usage: proof-mwplus.sh <namespace> <redis-region-pod> [K]}"
POD="${2:?redis-region pod name}"
K="${3:-5}"
KEY="lwwproofMW:1"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl -n "$NS" cp "${LAB_DIR}/chart/files/connect/lww_set.lua" "${POD}:/tmp/lww_set.lua"
OUT="$(kubectl -n "$NS" exec "$POD" -- sh -c '
  K='"$K"'; KEY="'"$KEY"'"
  redis-cli DEL "$KEY" vKEY >/dev/null
  applied=0; dup=0
  i=1
  while [ "$i" -le "$K" ]; do
    for wr in A B; do
      v=$(redis-cli HINCRBY vKEY "$KEY" 1)
      r=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , "$wr:v$v" "$v" set 0 e)
      [ "$r" = "1" ] && applied=$((applied+1))
      [ "$r" = "-1" ] && dup=$((dup+1))
    done
    i=$((i+1))
  done
  echo "applied=$applied dup=$dup ver=$(redis-cli HGET "$KEY" ver) want_ver=$((K*2))"
')"
echo "[proofMW+] ${OUT}"
DUP=$(echo "$OUT"|sed -n "s/.*dup=\([0-9]*\).*/\1/p")
VER=$(echo "$OUT"|sed -n "s/.*ver=\([0-9]*\).*/\1/p")
WANT=$(echo "$OUT"|sed -n "s/.*want_ver=\([0-9]*\).*/\1/p")
fail=0
[ "$DUP" = "0" ]    || { echo "[proofMW+] FAIL: expected dup=0 (HINCRBY never collides), got $DUP"; fail=1; }
[ "$VER" = "$WANT" ] || { echo "[proofMW+] FAIL: expected ver=$WANT (all writes distinct), got $VER"; fail=1; }
[ "$fail" = 0 ] || exit 1
echo "[proofMW+] PASS — HINCRBY makes multi-writer-same-key safe (no lost update, dup=0, ver=$VER)"
