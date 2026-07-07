#!/usr/bin/env bash
# test-forward-routing.sh — fast (~15 s, helm+docker only) behavioral test of the
# forward leg's kv_prefix routing, run against the REAL rendered pipeline (no
# copied mapping that can drift). Exists because Bloblang errors surface only at
# runtime (rules/50-lessons.md: the $raw_key bug passed lint/template/L2 and died
# on kind). How: render the source-pipeline ConfigMap with a representative
# sinkGroups set (two-seg tg:* groups + one legacy one-seg group + an others
# catchAll), extract data."pipeline.yaml", keep its pipeline: section VERBATIM,
# wrap it in a generate input (a case table of kv_key -> expected token, the
# expectation carried in metadata) plus a stdout output and one verifier
# mapping, run it in the Connect docker image, assert got==want per message.
# Usage: scripts/test-forward-routing.sh          (CONNECT_IMAGE to override)
set -euo pipefail
cd "$(dirname "$0")/.."
IMG="${CONNECT_IMAGE:-hpdevelop/connect:4.92.0-claudefix}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
chmod 755 "$WORK"   # mktemp -d gives 0700; the connect container runs non-root and must read the mount
log() { echo "[test-routing] $*"; }
die() { echo "[test-routing] FAIL: $*" >&2; exit 1; }

SETS=(--set connect.sinkGroups[0].name=caveat         --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat'
      --set connect.sinkGroups[1].name=caveat-context --set 'connect.sinkGroups[1].prefixes[0]=tg:caveat_context'
      --set connect.sinkGroups[2].name=g2m            --set 'connect.sinkGroups[2].prefixes[0]=tg:g2m'
      --set connect.sinkGroups[3].name=legacy1        --set 'connect.sinkGroups[3].prefixes[0]=prefix-a'
      --set connect.sinkGroups[4].name=others         --set connect.sinkGroups[4].catchAll=true)

log "render + extract the forward pipeline"
helm template chart/ "${SETS[@]}" --show-only templates/connect-configmaps.yaml > "$WORK/cms.yaml" \
  || die "helm render failed (two-seg prefixes / catchAll not implemented yet, or validation bug)"
# The source pipeline CM is named *connect-source-pipeline with data key
# "pipeline.yaml: |-" whose content is indented 4 (see connect-configmaps.yaml).
awk '
  /name: .*connect-source-pipeline$/ { incm=1 }
  incm && /^  pipeline\.yaml: \|/    { f=1; next }
  f && /^    /                       { print substr($0, 5); next }
  f && /^[[:space:]]*$/              { print ""; next }
  f                                  { exit }
' "$WORK/cms.yaml" > "$WORK/forward.yaml"
grep -q '^pipeline:' "$WORK/forward.yaml" || die "could not extract pipeline.yaml from the source-pipeline ConfigMap"
grep -q 'let routes'  "$WORK/forward.yaml" || die "rendered forward pipeline has no route map (set-based routing missing)"

# Case table. Presence/absence of kv_key/new_key matters: the mapping's
# meta(...).or(...) falls through on ABSENT metadata (null), not on "".
cat > "$WORK/cases.json" <<'EOF'
[
 {"kv_key":"tg:caveat:123",         "want":"tg.caveat",         "want_reason":"matched"},
 {"kv_key":"tg:caveat",             "want":"tg.caveat",         "want_reason":"matched"},
 {"kv_key":"tg:caveat_context:9:z", "want":"tg.caveat_context", "want_reason":"matched"},
 {"kv_key":"tg:g2m:x",              "want":"tg.g2m",            "want_reason":"matched"},
 {"new_key":"tg:g2m:renamed",       "want":"tg.g2m",            "want_reason":"matched"},
 {"kv_key":"prefix-a:77:k1",        "want":"prefix-a",          "want_reason":"matched"},
 {"kv_key":"prefix-a",              "want":"prefix-a",          "want_reason":"matched"},
 {"kv_key":"tg:stray:1",            "want":"others",            "want_reason":"no_match"},
 {"kv_key":"tg",                    "want":"others",            "want_reason":"no_match"},
 {"kv_key":"zz:1",                  "want":"others",            "want_reason":"no_match"},
 {"kv_key":"",                      "want":"others",            "want_reason":"empty_prefix"},
 {"want":"others",                  "want_reason":"empty_prefix"}
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
      meta new_key     = if \$c.exists("new_key") { \$c.new_key } else { deleted() }
      meta op          = "create"
      meta event_id    = "e" + counter().string()
      meta ts          = "0"
      meta want        = \$c.want
      meta want_reason = \$c.want_reason
EOF
  # the REAL pipeline: section, verbatim, minus the output: that follows it
  awk '/^pipeline:/ { f=1 } f && /^output:/ { exit } f { print }' "$WORK/forward.yaml"
  cat <<'EOF'
    - mapping: |
        root = { "got":         meta("kv_prefix").or("MISSING"),
                 "want":        meta("want"),
                 "reason":      meta("kv_prefix_reason").or("MISSING"),
                 "want_reason": meta("want_reason"),
                 "key":         meta("kv_key").or("<absent>") }
output:
  stdout: {}
logger:
  level: ERROR
EOF
} > "$WORK/test.yaml"

log "running ${N} routing cases in ${IMG}"
docker run --rm -i -v "$WORK:/w:ro" "$IMG" run /w/test.yaml > "$WORK/out.log" 2> "$WORK/err.log" \
  || { cat "$WORK/err.log" >&2; die "connect run failed (Bloblang runtime error?)"; }
grep '^{' "$WORK/out.log" | jq -c 'select(has("got"))' > "$WORK/results.jsonl" || true
GOT_N=$(wc -l < "$WORK/results.jsonl")
[ "$GOT_N" -eq "$N" ] || { cat "$WORK/out.log" "$WORK/err.log" >&2; die "expected $N results, got $GOT_N"; }
BAD=$(jq -c 'select(.got != .want or .reason != .want_reason)' "$WORK/results.jsonl")
[ -z "$BAD" ] || { echo "$BAD" >&2; die "routing mismatches above (got vs want)"; }
log "PASS — all $N kv_prefix routing cases matched"
