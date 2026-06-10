#!/usr/bin/env bash
# Proof C — NEGATIVE. Scaling the *writer* (two uncoordinated owners of one key)
# breaks LWW via a silent same-version lost update that the version-only
# CompareVersions check CANNOT detect. Scripted directly against redis-region with
# lww_set.lua (same style as Proof A); no pipeline involved.
#
# Two writers A and B each "own" the SAME key and each stamp versions 1..K with
# their own value namespace, interleaved (A:v1, B:v1, A:v2, B:v2, ...). A reaches
# each version first → applied(1); B's equal-version write → duplicate(-1), dropped.
# Result: region ends at ver=K (== writer B's max → a version-only verifier querying
# B would report mismatches=0, a FALSE pass) but val=A:vK — B's version-K commit is
# silently lost.
set -euo pipefail
NS="${1:?usage: proof-c.sh <namespace> <redis-region-pod> [K]}"
POD="${2:?redis-region pod name}"
K="${3:-5}"
KEY="lwwproofC:1"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl -n "$NS" cp "${LAB_DIR}/chart/files/connect/lww_set.lua" "${POD}:/tmp/lww_set.lua"
OUT="$(kubectl -n "$NS" exec "$POD" -- sh -c '
  K='"$K"'; KEY="'"$KEY"'"
  redis-cli DEL "$KEY" >/dev/null
  a=""; b=""
  v=1
  while [ "$v" -le "$K" ]; do
    a=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , "A:v$v" "$v")
    b=$(redis-cli --eval /tmp/lww_set.lua "$KEY" , "B:v$v" "$v")
    v=$((v+1))
  done
  echo "aK=$a bK=$b ver=$(redis-cli HGET "$KEY" ver) val=$(redis-cli HGET "$KEY" val)"
')"
echo "[proofC] ${OUT}"
AK="$(echo "$OUT"  | sed -n 's/.*aK=\([-0-9]*\).*/\1/p')"
BK="$(echo "$OUT"  | sed -n 's/.*bK=\([-0-9]*\).*/\1/p')"
VER="$(echo "$OUT" | sed -n 's/.*ver=\([0-9]*\).*/\1/p')"
VAL="$(echo "$OUT" | sed -n 's/.*val=\([A-Za-z0-9:]*\).*/\1/p')"

fail=0
# (a) version-only check is SATISFIED: region ver == K == each writer's max.
[ "$VER" = "$K" ]        || { echo "[proofC] FAIL: expected ver=$K (version-only check would pass), got '$VER'"; fail=1; }
# A's version-K write applied; B's equal-version write was dropped as duplicate.
[ "$AK" = "1" ]          || { echo "[proofC] FAIL: expected writer A v$K applied(1), got '$AK'"; fail=1; }
[ "$BK" = "-1" ]         || { echo "[proofC] FAIL: expected writer B v$K duplicate(-1), got '$BK'"; fail=1; }
# (b) value check REVEALS the loss: region holds A:vK; B's committed v$K vanished.
[ "$VAL" = "A:v$K" ]     || { echo "[proofC] FAIL: expected val=A:v$K (B's v$K lost), got '$VAL'"; fail=1; }
[ "$fail" = 0 ] || exit 1

echo "[proofC] PASS — multi-writer lost update CONFIRMED:"
echo "  region ver=$K equals writer B's max version → a version-only check (CompareVersions)"
echo "  reports mismatches=0 and would FALSELY pass; yet region val=A:v$K means writer B's"
echo "  version-$K commit was silently dropped as a duplicate. The single-writer-per-key"
echo "  precondition is load-bearing: multi-CONNECT is safe (connect never mints versions),"
echo "  multi-WRITER is not."
