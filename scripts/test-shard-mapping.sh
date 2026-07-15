#!/usr/bin/env bash
# test-shard-mapping.sh — fast (~15 s, helm+docker only) behavioral test of the
# forward leg's per-key SHARD mapping (subject-sharding v2, INV-S2), run against
# the REAL rendered pipeline exactly like test-forward-routing.sh (Bloblang
# errors surface only at runtime — rules/50-lessons.md). Renders the source
# pipeline with one sharded family (lb:company, N=4, keyPattern {employees:id}),
# one plain prefix group and an others catchAll, extracts data."pipeline.yaml",
# keeps its pipeline: section VERBATIM, wraps it in a generate input carrying a
# case table (kv_key/old_key/new_key -> expected kv_prefix + shard reason) and
# asserts got==want per message.
# Table cases (v1 spec T-2): same employee active/standby -> same shard;
# different ids -> id mod N shards; leading zeros parse numerically; no
# {employees:N} tag -> sx + unparseable; cross-shard rename -> sx +
# cross_shard_rename; same-shard rename passes; kv_key absent -> new_key
# fallback; non-family keys keep their un-sharded routing.
# Usage: scripts/test-shard-mapping.sh          (CONNECT_IMAGE to override)
set -euo pipefail
cd "$(dirname "$0")/.."
IMG="${CONNECT_IMAGE:-hpdevelop/connect:4.92.0-claudefix}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
chmod 755 "$WORK"   # the connect container runs non-root and must read the mount
log() { echo "[test-shard] $*"; }
die() { echo "[test-shard] FAIL: $*" >&2; exit 1; }

cat > "$WORK/values.yaml" <<'EOF'
connect:
  sharding:
    keyPattern: '\{employees:(?P<id>[0-9]+)\}'
    families:
      "lb:company":
        shards: 4
  sinkGroups:
    - { name: shard-a, shardsOf: "lb:company", shards: [0, 1] }
    - { name: shard-b, shardsOf: "lb:company", shards: [2, 3, "x"] }
    - { name: caveat,  prefixes: ["tg:caveat"] }
    - { name: others,  catchAll: true }
EOF

log "render + extract the forward pipeline (sharding on)"
helm template chart/ -f "$WORK/values.yaml" --show-only templates/connect-configmaps.yaml > "$WORK/cms.yaml" \
  || die "helm render failed (sharding values rejected?)"
awk '
  /name: .*connect-source-pipeline$/ { incm=1 }
  incm && /^  pipeline\.yaml: \|/    { f=1; next }
  f && /^    /                       { print substr($0, 5); next }
  f && /^[[:space:]]*$/              { print ""; next }
  f                                  { exit }
' "$WORK/cms.yaml" > "$WORK/forward.yaml"
grep -q '^pipeline:' "$WORK/forward.yaml" || die "could not extract pipeline.yaml from the source-pipeline ConfigMap"
grep -q 'shard_map'  "$WORK/forward.yaml" || die "rendered forward pipeline has no shard_map (shard mapping missing)"
grep -q 'threads: 1' "$WORK/forward.yaml" || die "sharded forward pipeline must render threads: 1 (O-3)"

# Case table. Presence/absence of kv_key/new_key/old_key matters (absent
# metadata falls through .or()). N=4: shard = employees-id mod 4.
cat > "$WORK/cases.json" <<'EOF'
[
 {"kv_key":"lb:company:active:{employees:1}",  "want":"lb.company.s1", "want_shard":"sharded",
  "note":"id 1 mod 4 = s1"},
 {"kv_key":"lb:company:standby:{employees:1}", "want":"lb.company.s1", "want_shard":"sharded",
  "note":"same employee, standby variant -> SAME shard (INV-S2)"},
 {"kv_key":"lb:company:active:{employees:6}",  "want":"lb.company.s2", "want_shard":"sharded",
  "note":"id 6 mod 4 = s2"},
 {"kv_key":"lb:company:active:{employees:8}",  "want":"lb.company.s0", "want_shard":"sharded",
  "note":"id 8 mod 4 = s0"},
 {"kv_key":"lb:company:standby:{employees:0007}", "want":"lb.company.s3", "want_shard":"sharded",
  "note":"leading zeros parse numerically: 7 mod 4 = s3"},
 {"kv_key":"lb:company:active:no-tag-here",    "want":"lb.company.sx", "want_shard":"unparseable",
  "note":"family key without {employees:N} -> isolation shard"},
 {"op":"rename",
  "old_key":"lb:company:standby:{employees:5}", "new_key":"lb:company:active:{employees:5}",
  "want":"lb.company.s1", "want_shard":"sharded",
  "note":"same-employee rename (kv_key absent -> new_key fallback): 5 mod 4 = s1"},
 {"op":"rename",
  "old_key":"lb:company:standby:{employees:1}", "new_key":"lb:company:active:{employees:2}",
  "want":"lb.company.sx", "want_shard":"cross_shard_rename",
  "note":"old s1 vs new s2 -> INV-S7 quarantine"},
 {"kv_key":"tg:caveat:123", "want":"tg.caveat", "want_shard":"none",
  "note":"non-family prefix group unaffected by sharding"},
 {"kv_key":"zz:1",          "want":"others",    "want_shard":"none",
  "note":"set miss still routes to others"},
 {"kv_key":"",               "want":"others",    "want_shard":"none",
  "note":"empty key -> others (empty_prefix)"}
]
EOF
N=$(jq length "$WORK/cases.json")

{
  cat <<EOF
input:
  generate:
    count: ${N}
    interval: ""
    mapping: |
      let cases = $(jq -c . "$WORK/cases.json")
      let c = \$cases.index(counter() - 1)
      root = {"case": counter()}
      meta kv_key      = if \$c.exists("kv_key")  { \$c.kv_key }  else { deleted() }
      meta old_key     = if \$c.exists("old_key") { \$c.old_key } else { deleted() }
      meta new_key     = if \$c.exists("new_key") { \$c.new_key } else { deleted() }
      meta op          = \$c.op.or("create")
      meta event_id    = "e" + counter().string()
      meta ts          = "0"
      meta want        = \$c.want
      meta want_shard  = \$c.want_shard
EOF
  # the REAL pipeline: section, verbatim, minus the output: that follows it
  awk '/^pipeline:/ { f=1 } f && /^output:/ { exit } f { print }' "$WORK/forward.yaml"
  cat <<'EOF'
    - mapping: |
        root = { "got":        meta("kv_prefix").or("MISSING"),
                 "want":       meta("want"),
                 "shard":      meta("kv_shard_reason").or("MISSING"),
                 "want_shard": meta("want_shard"),
                 "key":        meta("kv_key").or("<absent>") }
output:
  stdout: {}
logger:
  level: ERROR
EOF
} > "$WORK/test.yaml"

log "running ${N} shard-mapping cases in ${IMG}"
docker run --rm -i -v "$WORK:/w:ro" "$IMG" run /w/test.yaml > "$WORK/out.log" 2> "$WORK/err.log" \
  || { cat "$WORK/err.log" >&2; die "connect run failed (Bloblang runtime error?)"; }
grep '^{' "$WORK/out.log" | jq -c 'select(has("got"))' > "$WORK/results.jsonl" || true
GOT_N=$(wc -l < "$WORK/results.jsonl")
[ "$GOT_N" -eq "$N" ] || { cat "$WORK/out.log" "$WORK/err.log" >&2; die "expected $N results, got $GOT_N"; }
BAD=$(jq -c 'select(.got != .want or .shard != .want_shard)' "$WORK/results.jsonl")
[ -z "$BAD" ] || { echo "$BAD" >&2; die "shard-mapping mismatches above (got vs want)"; }
log "PASS — all $N shard-mapping cases matched (INV-S2)"
