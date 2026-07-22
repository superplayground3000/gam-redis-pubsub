# First-Two-Segment Key-Prefix Routing + "others" Catch-All — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route CDC events by the key's first TWO `:`-segments (e.g. `tg:caveat`, `tg:g2m`) instead of only the first, and add an "others" catch-all subject/sink-group that receives every message not matched by a configured prefix — per `docs/requests/first-two-seg-routing.md`.

**Architecture:** Routing becomes **set-based with longest-match**: Helm renders a route map `{raw key prefix → NATS subject token}` from the configured `connect.sinkGroups[].prefixes` into the forward-leg Bloblang mapping. At publish time the mapping tries the key's first-two-segment prefix, then its first-one-segment prefix, against that map; a hit publishes to `kv.cdc.<token>.<op>` (token = prefix with `:` → `.`, so `tg:caveat` → subject `kv.cdc.tg.caveat.<op>`, filter `kv.cdc.tg.caveat.>`); a miss publishes to `kv.cdc.others.<op>`, consumed by a new `catchAll: true` sink group. The stream already binds `kv.cdc.>` (any depth), so no stream change is needed. Existing one-segment groups (`prefix-a` etc.) keep working via the same map — the L3/L4 prefix scripts must keep passing **unchanged**.

**Tech Stack:** Helm/Sprig templates (`chart/templates/_helpers.tpl`), Redpanda Connect Bloblang (`chart/files/connect/cdc-forward.yaml`), NATS JetStream filter subjects, bash test scripts, kind.

## Requirements traceability (the request, item by item)

| Request line | Where satisfied |
|---|---|
| "use first and second of ':' for key prefix routing" | Task 2 (route map + two-seg prefix grammar), Task 3 (Bloblang longest-match) |
| The six prefixes `tg:caveat`, `tg:caveat_context`, `tg:g2m`, `tg:m2g`, `tg:r2g`, `tg:uint32id` | Task 4 values.yaml documented example; Task 1 harness + Task 6 kind test use representatives |
| "create a 'others' subject to receive all other msgs" | `catchAll: true` group → filter `kv.cdc.others.>` (Task 2); forward fallback token `others` (Task 3) |
| "Make sure naming of subjects and consumer name are valid" | `:` is illegal in a NATS subject token → mapped to `.`; `_` (needed for `caveat_context`) is legal in a subject token and in a durable name; group **names** stay DNS-1123 (they feed K8s object names); durables stay `cdc_sink_<name>`. Fail-loud validation in Task 2. |

Note: the request's prose says all keys share prefix "tp" but its list enumerates `tg:*` — treat "tp" as a typo for "tg" (the enumerated list governs; these are values-file entries either way).

## Key design decisions (already made — do not re-litigate)

1. **Token encoding `:` → `.`** — `tg:caveat` publishes to `kv.cdc.tg.caveat.<op>` (hierarchical NATS subject; the `_` in `caveat_context` never doubles as a separator, so tokens are unambiguous). Verified: the stream binds `kv.cdc.>` (`rrcs.nats.stream.subjects`), which matches any depth.
2. **Set-based matching, not blind segment extraction** — only configured prefixes route to their own subject; everything else (including previously "unknown") goes to the single fallback token `others`. The legacy `unknown` token is retired (kept reserved so nobody claims it).
3. **Longest-match order: two segments, then one** — so `prefix-a:77:k1` still matches the one-segment prefix `prefix-a` (backward compat with the existing L3/L4 prefix scripts), while `tg:caveat:123` matches `tg:caveat` and NOT a hypothetical `tg` group. A one-segment prefix that is the first segment of any two-segment prefix is a render-time **error** (its consumer filter `kv.cdc.tg.>` would also match `kv.cdc.tg.caveat.<op>` → double delivery).
4. **Counters** (INV-2): `empty_prefix` (no derivable segment — malformed event) always increments `cdc_forward_unrouted`. A set-miss (`no_match`) increments `cdc_forward_others` when a catchAll group is deployed (it's routed, legitimate traffic), but `cdc_forward_unrouted{reason=no_match}` when NO catchAll exists (the event parks on `kv.cdc.others.<op>` unconsumed — alert-worthy; the existing `CDCForwardUnrouted` alert covers it with no rule change).
5. **Byte-identical default render** — `helm template chart/` with no sinkGroups must not change AT ALL (empty diff; this feature adds no exceptions).

**Verified Bloblang semantics** (pinned against the real image `hpdevelop/connect:4.92.0-claudefix` on 2026-07-07 — do not "improve" these expressions):
```
{"x:y":"x.y"}.get("nope")            -> null   (no error)
null.or("others")                    -> "others"
"".split(":")                        -> [""]
"tg:caveat:123".split(":").slice(0,2).join(":") -> "tg:caveat"
"solo".split(":").slice(0,2).join(":")          -> "solo"   (slice is safe on short arrays)
```
Also remember (rules/50-lessons.md): a Bloblang `let x` MUST be referenced as `$x` — bare `x` means `this.x` and fails at runtime only.

## Global Constraints

- **INV-1 hands-off zones** in `chart/files/connect/cdc-forward.yaml`: do NOT touch the `input:` block, the envelope `root = {...}` mapping, `meta op` / `meta event_id` lines, or the `output:` block (`fallback`, `Nats-Msg-Id`, `reject` child). Only the two blocks this plan explicitly replaces (both gated on `rrcs.connect.prefixRouting`) may change.
- **Byte-identity:** after every chart-touching task, `diff /tmp/twoseg-baseline.yaml <(helm template chart/)` must be empty.
- **Hard rule 5 / INV-2:** the new `cdc_forward_others` counter ships with its dashboard panel in the same change (Task 4, before any commit that could be the last).
- **Reporting rule (INV-4):** never claim a test passed without running it in-session; paste command + exit status + the PASS/RESULT_JSON line.
- Commit per task on the current branch (`master`, per repo convention). **Do not push** unless the user asks.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- If you edit anything under `rules/` (only Task 7 optionally does): back it up first — `cp <file> <file>.bak-$(date +%Y%m%d-%H%M%S)`.
- Required test ladder for this change set (from `rules/05-invariants.md`): L0, L1 (extended), L2 (alert/dashboard files touched), L3 (pipeline YAML touched), L4 prefix variant (the sinkGroups helper feeds nats-init consumer creation). The default `verify-failover.sh` is NOT required because the default render is byte-identical (prove with the diff).

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `scripts/test-forward-routing.sh` | Create | Fast (~15 s, docker-only) behavioral test of the rendered forward-leg routing mapping — the tier that would have caught the 2026-07-07 `$raw_key` Bloblang bug in seconds |
| `chart/templates/_helpers.tpl` | Modify | Two-seg prefix grammar, `catchAll` groups, reserved/overlap/dup validation, new `rrcs.connect.routeMap` + `rrcs.connect.hasCatchAll` helpers |
| `chart/files/connect/cdc-forward.yaml` | Modify | Set-based longest-match routing mapping + reason-driven counter switch (both inside the existing prefix-routing gates) |
| `chart/values.yaml` | Modify | Document two-seg prefixes, `catchAll`, the six-prefix example |
| `chart/files/grafana/cdc-dashboard.json` | Modify | Rework panel 11 text, add panel 12 (`cdc_forward_others`) |
| `chart/files/prometheus/cdc-alerts.yaml` | Modify | Comment/description text only (`unknown` → `others`, `no_match` reason); alert expr unchanged |
| `scripts/run-all-tests.sh` | Modify | L1 two-seg render + fail-loud assertions; wire the routing harness into the L2 tier; wire the new L3 script into `RUN_PREFIX` |
| `scripts/verify-cdc-twoseg.sh` | Create | L3 kind proof: two-seg routing + others catch-all + isolation + no-loss + dedup |

No Go code changes. `chart/templates/nats-init-job.yaml`, `rbac.yaml`, `connect-sink.yaml`, `connect-configmaps.yaml`, `servicemonitor.yaml` are all consumed via `rrcs.connect.sinkGroups` fields and need **no edits** (the catchAll group flows through them like any named group).

---

### Task 1: Baseline snapshot + failing routing test harness

**Files:**
- Create: `scripts/test-forward-routing.sh`

**Interfaces:**
- Produces: `scripts/test-forward-routing.sh` (exit 0 = all routing cases match). Consumed verbatim by Task 5's `run-all-tests.sh` wiring. It renders the chart with sinkGroups shaped `{name, prefixes: ["tg:caveat"]}` and `{name: others, catchAll: true}` — the exact values schema Task 2 must implement.

- [ ] **Step 1: Capture the byte-identity baseline (used by every later task)**

```bash
cd /media/hp/secondary/projects/connect-project/gam-redis-pubsub
helm template chart/ > /tmp/twoseg-baseline.yaml
wc -l /tmp/twoseg-baseline.yaml
```
Expected: a line count > 500, no error. Keep this file for the whole session.

- [ ] **Step 2: Write the harness**

Create `scripts/test-forward-routing.sh` with EXACTLY this content, then `chmod +x` it:

```bash
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
```

- [ ] **Step 3: Run it — verify it FAILS (nothing implemented yet)**

```bash
chmod +x scripts/test-forward-routing.sh
scripts/test-forward-routing.sh; echo "exit=$?"
```
Expected: FAIL with `helm render failed` — the current chart's prefix regex rejects `tg:caveat` (`is not a valid NATS+DNS token`) and `catchAll` is unknown (a group with neither prefixes nor filterSubject currently filters the whole stream, but the render dies at the `tg:caveat` group first). exit=1.

- [ ] **Step 4: Commit**

```bash
git add scripts/test-forward-routing.sh
git commit -m "test: forward-leg kv_prefix routing harness (two-seg cases, currently failing)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Helpers — two-seg prefix grammar, catchAll groups, route map

**Files:**
- Modify: `chart/templates/_helpers.tpl` (the `rrcs.connect.sinkGroups` define, currently lines 263–367; add two defines after `rrcs.connect.anySinkEnabled`, currently ending line 393)

**Interfaces:**
- Consumes: values schema `connect.sinkGroups[].{name,enabled,mode,prefixes,filterSubject,catchAll,streamID,replicas,consumer.*,lease.*}`.
- Produces:
  - Each `rrcs.connect.sinkGroups` element gains two fields consumed later: `prefixes` (raw list, e.g. `["tg:caveat"]`) and `catchAll` (bool). All pre-existing fields keep their exact names and meanings.
  - `rrcs.connect.routeMap` — renders a JSON object `{"prefix-a":"prefix-a","tg:caveat":"tg.caveat",...}` over every ENABLED prefixed group (JSON object keys sorted by `toJson` → deterministic render/checksum). Task 3 includes it inside Bloblang.
  - `rrcs.connect.hasCatchAll` — `"true"`/`"false"`; Task 3 gates the no_match counter branch on it.
  - A `catchAll: true` group's `filter` field renders as `<subjectPrefix>.others.>` and flows unmodified through connect-sink.yaml, connect-configmaps.yaml, rbac.yaml, nats-init-job.yaml, servicemonitor.yaml.

- [ ] **Step 1: Replace the whole `rrcs.connect.sinkGroups` define**

In `chart/templates/_helpers.tpl`, replace the block that starts at `{{- define "rrcs.connect.sinkGroups" -}}` and ends at its matching `{{- end -}}` (currently lines 279–367) with:

```gotmpl
{{- define "rrcs.connect.sinkGroups" -}}
{{- $root := . -}}
{{- $v := .Values -}}
{{- $prefix := required "nats.stream.subjectPrefix is required" $v.nats.stream.subjectPrefix -}}
{{- $defs := $v.connect.sinkDefaults | default dict -}}
{{- $defLease := $defs.lease | default dict -}}
{{- $defCons := $defs.consumer | default dict -}}
{{- $legSink := $v.connect.sink -}}
{{- $legLease := $legSink.lease -}}
{{- $legCons := $v.nats.stream.consumer -}}
{{- $baseDurable := $legCons.durable -}}
{{- $tokenRe := "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" -}}
{{- /* Key-prefix grammar: ONE or TWO ':'-separated segments (first-two-seg
     routing). Segment charset [a-z0-9_-], alnum first+last: '_' is legal in a
     NATS subject token and needed for real prefixes like tg:caveat_context;
     ':' is NOT legal in a subject token, so rrcs.connect.routeMap maps it to
     '.' (tg:caveat -> subject kv.cdc.tg.caveat.<op>, filter kv.cdc.tg.caveat.>;
     the stream binds kv.cdc.> so subject depth is free). */ -}}
{{- $prefixRe := "^[a-z0-9]([a-z0-9_-]*[a-z0-9])?(:[a-z0-9]([a-z0-9_-]*[a-z0-9])?)?$" -}}
{{- $groups := $v.connect.sinkGroups -}}
{{- if not $groups -}}
{{-   $groups = list (dict "name" "default" "enabled" $legSink.enabled) -}}
{{- end -}}
{{- $out := list -}}
{{- $seenPrefixes := dict -}}
{{- $catchAllCount := 0 -}}
{{- $anyPrefixedEnabled := false -}}
{{- range $g := $groups -}}
{{-   $name := $g.name | default "default" -}}
{{-   if not (regexMatch $tokenRe $name) -}}
{{-     fail (printf "connect.sinkGroups: group name %q is not a valid NATS+DNS token (^[a-z0-9]([a-z0-9-]*[a-z0-9])?$: lowercase alnum + dash, no leading/trailing dash)" $name) -}}
{{-   end -}}
{{-   $isDefault := eq $name "default" -}}
{{-   $mode := $g.mode | default "ha" -}}
{{-   if not (has $mode (list "ha")) -}}
{{-     fail (printf "connect.sinkGroups[%s].mode=%q — only \"ha\" is implemented in this pass; \"shared\" (concurrent pullers on one durable) is a documented follow-up (design §10.4)." $name $mode) -}}
{{-   end -}}
{{-   $enabled := $g.enabled -}}
{{-   if eq (kindOf $enabled) "invalid" -}}{{- $enabled = true -}}{{- end -}}
{{-   $prefixes := $g.prefixes | default list -}}
{{-   $filterSubject := $g.filterSubject | default "" -}}
{{-   $catchAll := $g.catchAll | default false -}}
{{-   if and $catchAll $isDefault -}}
{{-     fail "connect.sinkGroups: the \"default\" group cannot be catchAll (default = the legacy whole-stream sink; name the catch-all group e.g. \"others\")" -}}
{{-   end -}}
{{-   if and $catchAll (or (gt (len $prefixes) 0) (ne $filterSubject "")) -}}
{{-     fail (printf "connect.sinkGroups[%s]: catchAll=true excludes prefixes and filterSubject (the catch-all filter is derived: %s.others.>)" $name $prefix) -}}
{{-   end -}}
{{-   if and (gt (len $prefixes) 0) (ne $filterSubject "") -}}
{{-     fail (printf "connect.sinkGroups[%s]: set only ONE of prefixes or filterSubject, not both" $name) -}}
{{-   end -}}
{{-   $prefixed := gt (len $prefixes) 0 -}}
{{-   $filter := printf "%s.>" $prefix -}}
{{-   if $prefixed -}}
{{-     if $enabled -}}{{- $anyPrefixedEnabled = true -}}{{- end -}}
{{-     $subs := list -}}
{{-     range $p := $prefixes -}}
{{-       if not (regexMatch $prefixRe $p) -}}
{{-         fail (printf "connect.sinkGroups[%s].prefixes: %q must be one or two ':'-separated segments, each matching ^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$ (e.g. \"tg:caveat\", \"tg:caveat_context\", \"prefix-a\")" $name $p) -}}
{{-       end -}}
{{-       $seg0 := index (splitList ":" $p) 0 -}}
{{-       if or (eq $seg0 "others") (eq $seg0 "unknown") -}}
{{-         fail (printf "connect.sinkGroups[%s].prefixes: %q — first segment %q is reserved (\"others\" is the catch-all subject token; \"unknown\" is the retired legacy parking token)" $name $p $seg0) -}}
{{-       end -}}
{{-       if $enabled -}}
{{-         if hasKey $seenPrefixes $p -}}
{{-           fail (printf "connect.sinkGroups[%s].prefixes: %q is already owned by enabled group %q — a prefix may belong to exactly one enabled group" $name $p (get $seenPrefixes $p)) -}}
{{-         end -}}
{{-         $_ := set $seenPrefixes $p $name -}}
{{-       end -}}
{{-       $subs = append $subs (printf "%s.%s.>" $prefix (replace ":" "." $p)) -}}
{{-     end -}}
{{-     $filter = join "," $subs -}}
{{-   else if ne $filterSubject "" -}}
{{-     $filter = $filterSubject -}}
{{-   else if $catchAll -}}
{{-     if $enabled -}}{{- $catchAllCount = add1 $catchAllCount -}}{{- end -}}
{{-     $filter = printf "%s.others.>" $prefix -}}
{{-   end -}}
{{-   $durable := $baseDurable -}}
{{-   $deployBase := "connect-sink" -}}
{{-   $pipelineBase := "connect-sink-pipeline" -}}
{{-   $saBase := $legLease.name -}}
{{-   $streamID := $legSink.streamID -}}
{{-   if not $isDefault -}}
{{-     $durable = printf "%s_%s" $baseDurable $name -}}
{{-     $deployBase = printf "connect-sink-%s" $name -}}
{{-     $pipelineBase = printf "connect-sink-%s-pipeline" $name -}}
{{-     $saBase = printf "connect-sink-%s-elector" $name -}}
{{-     $streamID = printf "reverse_leg_%s" $name -}}
{{-   end -}}
{{-   $fullName := printf "%s%s" $root.Values.resourcePrefix $deployBase -}}
{{-   if gt (len $fullName) 57 -}}
{{-     fail (printf "connect.sinkGroups[%s]: derived resource name %q (%d chars) exceeds the 57-char budget — shorten resourcePrefix or the group name" $name $fullName (len $fullName)) -}}
{{-   end -}}
{{-   $glease := $g.lease | default dict -}}
{{-   $gcons := $g.consumer | default dict -}}
{{-   $elem := dict
             "name" $name
             "enabled" $enabled
             "isDefault" $isDefault
             "prefixed" $prefixed
             "prefixes" $prefixes
             "catchAll" $catchAll
             "durable" $durable
             "filter" $filter
             "streamID" ($g.streamID | default $streamID)
             "replicas" ($g.replicas | default $defs.replicas | default $legSink.replicas)
             "ackWait" ($gcons.ackWait | default $defCons.ackWait | default $legCons.ackWait)
             "maxAckPending" ($gcons.maxAckPending | default $defCons.maxAckPending | default $legCons.maxAckPending)
             "maxDeliver" ($gcons.maxDeliver | default $defCons.maxDeliver | default $legCons.maxDeliver)
             "leaseDuration" ($glease.duration | default $defLease.duration | default $legLease.duration)
             "renewDeadline" ($glease.renewDeadline | default $defLease.renewDeadline | default $legLease.renewDeadline)
             "retryPeriod" ($glease.retryPeriod | default $defLease.retryPeriod | default $legLease.retryPeriod)
             "deployBase" $deployBase
             "pipelineBase" $pipelineBase
             "saBase" $saBase
             "appLabel" $deployBase -}}
{{-   $out = append $out $elem -}}
{{- end -}}
{{- if gt $catchAllCount 1 -}}
{{-   fail "connect.sinkGroups: at most ONE enabled catchAll group (two would double-deliver kv.cdc.others.>)" -}}
{{- end -}}
{{- if and (gt $catchAllCount 0) (not $anyPrefixedEnabled) -}}
{{-   fail "connect.sinkGroups: a catchAll group requires at least one enabled group with prefixes — without prefix routing the forward leg publishes <subjectPrefix>.<op> and the catch-all filter <subjectPrefix>.others.> would never match" -}}
{{- end -}}
{{- range $p1x, $own1 := $seenPrefixes -}}
{{-   if not (contains ":" $p1x) -}}
{{-     range $p2x, $own2 := $seenPrefixes -}}
{{-       if hasPrefix (printf "%s:" $p1x) $p2x -}}
{{-         fail (printf "connect.sinkGroups: prefixes %q (group %q) and %q (group %q) overlap — consumer filter %s.%s.> would ALSO match every %s.%s.<op> subject (double delivery). Use explicit two-segment prefixes instead of the bare %q." $p1x $own1 $p2x $own2 $prefix $p1x $prefix (replace ":" "." $p2x) $p1x) -}}
{{-       end -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}
```

Also update the doc comment ABOVE the define (currently lines 263–278): replace the sentence starting `Each element carries:` with:

```
Each element carries: name enabled isDefault prefixed prefixes catchAll durable
filter streamID replicas ackWait maxAckPending maxDeliver leaseDuration
renewDeadline retryPeriod deployBase pipelineBase saBase appLabel.
Validation (fail-loud at render): DNS-1123 name; prefix grammar ^seg(:seg)?$
with seg=[a-z0-9]([a-z0-9_-]*[a-z0-9])? (first-two-seg routing); reserved first
segments "others"/"unknown"; duplicate-prefix and 1-seg/2-seg overlap checks
across enabled groups; prefixes XOR filterSubject XOR catchAll; at most one
enabled catchAll and only alongside >=1 enabled prefixed group; mode ("ha" only
in this pass); the 57-char name budget.
```

- [ ] **Step 2: Add the two new defines**

Immediately AFTER the `rrcs.connect.anySinkEnabled` define's closing `{{- end -}}` (currently line 393), insert:

```gotmpl

{{/*
rrcs.connect.routeMap — JSON object {rawKeyPrefix: subjectToken} over every
ENABLED prefixed sinkGroup, e.g. {"prefix-a":"prefix-a","tg:caveat":"tg.caveat"}.
Rendered into the forward leg's routing mapping as a Bloblang object literal
(JSON is valid Bloblang; toJson emits sorted keys => deterministic render, so
the pipeline ConfigMap checksum is stable). Token = prefix with ':' -> '.'
(':' is illegal in a NATS subject token): a two-segment prefix publishes to
<subjectPrefix>.<seg0>.<seg1>.<op> and its group's consumer filters
<subjectPrefix>.<seg0>.<seg1>.> — the stream binds <subjectPrefix>.> (any depth).
*/}}
{{- define "rrcs.connect.routeMap" -}}
{{- $m := dict -}}
{{- range $g := (include "rrcs.connect.sinkGroups" . | fromYamlArray) -}}
{{- if and $g.enabled $g.prefixed -}}
{{- range $p := $g.prefixes -}}
{{- $_ := set $m $p (replace ":" "." $p) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $m | toJson -}}
{{- end -}}

{{/*
rrcs.connect.hasCatchAll — "true" iff an ENABLED catchAll sinkGroup exists.
Gates the forward leg's no_match counter branch: with a catch-all deployed a
set-miss is ROUTED traffic (cdc_forward_others); without one it PARKS on
<subjectPrefix>.others.<op> (cdc_forward_unrouted{reason=no_match} => the
existing CDCForwardUnrouted alert fires, unchanged).
*/}}
{{- define "rrcs.connect.hasCatchAll" -}}
{{- $any := false -}}
{{- range $g := (include "rrcs.connect.sinkGroups" . | fromYamlArray) -}}
{{- if and $g.enabled $g.catchAll -}}{{- $any = true -}}{{- end -}}
{{- end -}}
{{- ternary "true" "false" $any -}}
{{- end -}}
```

- [ ] **Step 3: Verify renders — positive, byte-identity, fail-loud**

```bash
# positive: two-seg groups + catchAll render, with the right filters
TSG=(--set connect.sinkGroups[0].name=caveat --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat'
     --set connect.sinkGroups[1].name=g2m    --set 'connect.sinkGroups[1].prefixes[0]=tg:g2m'
     --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true)
helm lint chart/ && helm template chart/ "${TSG[@]}" > /tmp/twoseg-render.yaml; echo "exit=$?"
grep -c 'kv\.cdc\.tg\.caveat\.>' /tmp/twoseg-render.yaml   # expect >= 1
grep -c 'kv\.cdc\.others\.>'     /tmp/twoseg-render.yaml   # expect >= 1
grep -c 'name: lab-connect-sink-others' /tmp/twoseg-render.yaml  # expect >= 1
grep -oE "SINK_GROUPS='[^']*'" /tmp/twoseg-render.yaml          # expect cdc_sink_caveat|kv.cdc.tg.caveat.>|... and cdc_sink_others|kv.cdc.others.>|...

# byte-identity: default render UNCHANGED
diff /tmp/twoseg-baseline.yaml <(helm template chart/) && echo "BYTE-IDENTICAL"
```
Expected: exit=0, all greps hit, final line prints `BYTE-IDENTICAL`.

```bash
# fail-loud: each of these must FAIL the render (nonzero exit)
base2=(--set connect.sinkGroups[0].name=caveat --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat')
for bad in \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=a:b:c" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=Tg:caveat" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=others" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=others:x" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=unknown" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=tg:caveat" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=tg" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].catchAll=true --set connect.sinkGroups[1].prefixes[0]=q" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].catchAll=true --set connect.sinkGroups[2].name=z2 --set connect.sinkGroups[2].catchAll=true"; do
  if helm template chart/ "${base2[@]}" $bad >/dev/null 2>&1; then echo "MISSED fail-loud: $bad"; fi
done
# catchAll with no prefixed group must fail too
helm template chart/ --set connect.sinkGroups[0].name=others --set connect.sinkGroups[0].catchAll=true >/dev/null 2>&1 \
  && echo "MISSED fail-loud: lone catchAll" || echo "lone-catchAll OK (failed loud)"
```
Expected: NO `MISSED fail-loud` lines; last line `lone-catchAll OK (failed loud)`. (`tg` after `tg:caveat` fails via the overlap check; the second `tg:caveat` via the dup check.)

- [ ] **Step 4: Run the existing 1-seg L1 renders (regression) — the multi-group block from run-all-tests**

```bash
MG=(--set connect.sinkGroups[0].name=default
    --set connect.sinkGroups[1].name=a --set connect.sinkGroups[1].prefixes[0]=prefix-a
    --set connect.sinkGroups[2].name=b --set connect.sinkGroups[2].prefixes[0]=prefix-b)
helm template chart/ "${MG[@]}" >/dev/null; echo "exit=$?"
helm template chart/ "${MG[@]}" | grep -c 'kv\.cdc\.prefix-a\.>'   # expect >= 1 (1-seg unchanged)
```
Expected: exit=0, grep hits.

- [ ] **Step 5: Commit**

```bash
git add chart/templates/_helpers.tpl
git commit -m "chart: two-segment prefix grammar, catchAll sink groups, forward route map helpers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Forward-leg routing mapping — set-based longest-match + reason counters

**Files:**
- Modify: `chart/files/connect/cdc-forward.yaml` (ONLY the two gated blocks below; everything else is INV-1 territory — hands off)

**Interfaces:**
- Consumes: `rrcs.connect.routeMap` (JSON object literal) and `rrcs.connect.hasCatchAll` (`"true"`/`"false"`) from Task 2.
- Produces: per message, `meta kv_prefix` ∈ {route-map tokens} ∪ {"others"} (drives the publish subject `kv.cdc.<kv_prefix>.<op>` via the untouched `rrcs.nats.stream.publishSubject`), and `meta kv_prefix_reason` ∈ {"matched","no_match","empty_prefix"} (drives the counter switch and Task 1's harness assertions; NOT published — the NATS output sends only its explicit `headers:`). Metrics: `cdc_forward_unrouted{reason=empty_prefix|no_match}` and `cdc_forward_others{reason=no_match}` as decided in design decision 4.

- [ ] **Step 1: Replace the derivation block**

In `chart/files/connect/cdc-forward.yaml`, replace exactly this block (currently lines 82–93):

```
        {{- if eq (include "rrcs.connect.prefixRouting" .) "true" }}
        # Prefix routing (design D3 §3.1a): derive the key-prefix segment so the
        # publish subject becomes <subjectPrefix>.<kv_prefix>.<op> and per-group
        # durables can filter kv.cdc.<prefix>.>. The segment is the part before the
        # first ':' of the key; rename/delete may carry an empty kv_key, so fall
        # back to new_key, then to "unknown" (a subject NO group filters, so the
        # message parks in the stream instead of vanishing — surfaced by the
        # cdc_forward_unrouted counter added with the per-group dashboard work).
        let raw_key    = meta("kv_key").or(meta("new_key")).or("")
        let seg        = $raw_key.split(":").index(0)
        meta kv_prefix = if $seg == null || $seg == "" { "unknown" } else { $seg }
        {{- end }}
```

with:

```
        {{- if eq (include "rrcs.connect.prefixRouting" .) "true" }}
        # Prefix routing (first-two-segment, set-based): match the key's first
        # TWO ':'-segments, then its first ONE, against the configured prefix
        # set (rrcs.connect.routeMap: raw prefix -> subject token, ':' -> '.').
        # A hit publishes to <subjectPrefix>.<token>.<op>, which exactly one
        # group's durable filters (<subjectPrefix>.<token>.>). NO hit => token
        # "others" (<subjectPrefix>.others.<op>): consumed by the catchAll group
        # when one is deployed, otherwise it parks in the stream — either way
        # counted by the switch below via kv_prefix_reason. rename/delete may
        # omit kv_key, so fall back to new_key (.or() fires on ABSENT metadata);
        # a key with no derivable first segment is "empty_prefix" (malformed).
        # kv_prefix_reason is internal: the NATS output sends only explicit
        # headers, so neither meta leaves this process.
        let raw_key = meta("kv_key").or(meta("new_key")).or("")
        let segs    = $raw_key.split(":")
        let p1      = $segs.index(0)
        let p2      = $segs.slice(0, 2).join(":")
        let routes  = {{ include "rrcs.connect.routeMap" . }}
        let hit     = $routes.get($p2).or($routes.get($p1))
        meta kv_prefix        = $hit.or("others")
        meta kv_prefix_reason = if $p1 == "" { "empty_prefix" } else if $hit == null { "no_match" } else { "matched" }
        {{- end }}
```

(Reminder from the lessons file: every `let` here is referenced as `$raw_key`/`$segs`/`$p1`/`$p2`/`$routes`/`$hit` — bare names would be silent `this.<field>` lookups that only explode at runtime.)

- [ ] **Step 2: Replace the counter switch**

In the same file, replace exactly this block (currently lines 94–110):

```
    {{- if eq (include "rrcs.connect.prefixRouting" .) "true" }}
    # cdc_forward_unrouted (INV-2 / design §3.1): fires when no key-prefix could be
    # derived (empty/rename-without-key), so the event publishes to
    # kv.cdc.unknown.<op> — a subject NO sink group filters. The message parks in
    # the stream instead of vanishing; this counter makes the routing miss LOUD
    # (dashboard panel + CDCForwardUnrouted alert). The `switch` passes every other
    # message through untouched. Gated on prefix routing so the default
    # (non-prefix) render is byte-identical.
    - switch:
        - check: meta("kv_prefix") == "unknown"
          processors:
            - metric:
                type: counter
                name: cdc_forward_unrouted
                labels:
                  reason: empty_prefix
    {{- end }}
```

with:

```
    {{- if eq (include "rrcs.connect.prefixRouting" .) "true" }}
    # Routing-miss visibility (INV-2). empty_prefix (no derivable key segment —
    # malformed event) is ALWAYS cdc_forward_unrouted. A set-miss (no_match) is
    # cdc_forward_others when a catchAll group consumes kv.cdc.others.> (routed,
    # legitimate traffic), but cdc_forward_unrouted when NO catchAll exists (the
    # event parks unconsumed => the CDCForwardUnrouted alert fires, unchanged).
    # The `switch` passes every message through untouched. Gated on prefix
    # routing so the default (non-prefix) render is byte-identical.
    - switch:
        - check: meta("kv_prefix_reason") == "empty_prefix"
          processors:
            - metric:
                type: counter
                name: cdc_forward_unrouted
                labels:
                  reason: empty_prefix
        - check: meta("kv_prefix_reason") == "no_match"
          processors:
            {{- if eq (include "rrcs.connect.hasCatchAll" .) "true" }}
            - metric:
                type: counter
                name: cdc_forward_others
                labels:
                  reason: no_match
            {{- else }}
            - metric:
                type: counter
                name: cdc_forward_unrouted
                labels:
                  reason: no_match
            {{- end }}
    {{- end }}
```

- [ ] **Step 3: Run the routing harness — must now PASS**

```bash
scripts/test-forward-routing.sh; echo "exit=$?"
```
Expected: `[test-routing] PASS — all 12 kv_prefix routing cases matched`, exit=0.
If it fails with a Bloblang error, the error text names the offending line — fix THIS task's blocks only; do not touch the harness to make it pass.

- [ ] **Step 4: Byte-identity + 1-seg regression renders**

```bash
diff /tmp/twoseg-baseline.yaml <(helm template chart/) && echo "BYTE-IDENTICAL"
MG=(--set connect.sinkGroups[0].name=default
    --set connect.sinkGroups[1].name=a --set connect.sinkGroups[1].prefixes[0]=prefix-a
    --set connect.sinkGroups[2].name=b --set connect.sinkGroups[2].prefixes[0]=prefix-b)
helm template chart/ "${MG[@]}" | grep -qF '"prefix-a":"prefix-a"' && echo "route-map OK"
helm template chart/ "${MG[@]}" | grep -q 'name: cdc_forward_others' && echo "LEAK: others counter without catchAll" || echo "no-catchAll branch OK"
```
Expected: `BYTE-IDENTICAL`, `route-map OK`, `no-catchAll branch OK`.

- [ ] **Step 5: Commit**

```bash
git add chart/files/connect/cdc-forward.yaml
git commit -m "chart: forward leg routes by first-two-seg longest match; misses go to others

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Observability + values documentation (INV-2, hard rule 5)

**Files:**
- Modify: `chart/files/grafana/cdc-dashboard.json` (panel 11 text; new panel 12)
- Modify: `chart/files/prometheus/cdc-alerts.yaml` (comment/description text only — the alert `expr` must NOT change; this file is bind-mounted verbatim by the L2 lab)
- Modify: `chart/values.yaml` (sinkGroups doc block + example)

**Interfaces:**
- Consumes: metric names `cdc_forward_unrouted` (now with reasons `empty_prefix`, `no_match`) and `cdc_forward_others{reason=no_match}` from Task 3.
- Produces: user-facing docs of the values schema (`prefixes` two-seg grammar, `catchAll`) that Task 6's script and real deployments follow.

- [ ] **Step 1: Dashboard — rework panel 11, add panel 12**

In `chart/files/grafana/cdc-dashboard.json`, replace exactly:

```json
    { "id": 11, "title": "Forward-leg unrouted — empty prefix", "type": "timeseries", "datasource": { "type": "prometheus", "uid": "${datasource}" }, "gridPos": { "h": 8, "w": 12, "x": 12, "y": 32 },
      "description": "cdc_forward_unrouted: events with no derivable key-prefix, published to kv.cdc.unknown.<op> which no sink group filters (design §3.1). Only nonzero when prefix routing is configured. Nonzero => fix the key/prefix derivation or add a sink group that filters the missing prefix; this metric drives the CDCForwardUnrouted alert.",
      "targets": [
        { "expr": "sum by (reason) (increase({__name__=~\"cdc_forward_unrouted(_total)?\",namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval]))", "legendFormat": "{{reason}}" }
      ] }
  ]
}
```

with:

```json
    { "id": 11, "title": "Forward-leg unrouted (parked)", "type": "timeseries", "datasource": { "type": "prometheus", "uid": "${datasource}" }, "gridPos": { "h": 8, "w": 12, "x": 12, "y": 32 },
      "description": "cdc_forward_unrouted by reason: empty_prefix = no derivable key segment (malformed event); no_match = key matched no configured prefix AND no catchAll group is deployed — either way the event publishes to kv.cdc.others.<op>, which nothing consumes, and parks in the stream. Only nonzero when prefix routing is configured. Drives the CDCForwardUnrouted alert. Fix the key format, add a sinkGroup for the missing prefix, or deploy a catchAll group.",
      "targets": [
        { "expr": "sum by (reason) (increase({__name__=~\"cdc_forward_unrouted(_total)?\",namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval]))", "legendFormat": "{{reason}}" }
      ] },
    { "id": 12, "title": "Forward-leg catch-all traffic (others)", "type": "timeseries", "datasource": { "type": "prometheus", "uid": "${datasource}" }, "gridPos": { "h": 8, "w": 12, "x": 0, "y": 40 },
      "description": "cdc_forward_others: events whose key matched no configured prefix, published to kv.cdc.others.<op> and consumed by the catchAll sink group (reason=no_match). Emitted ONLY when a catchAll group is deployed — without one the same miss increments cdc_forward_unrouted (panel 11) and alerts. A sustained rate here means a key family is flowing through the catch-all: consider giving it its own sinkGroup.",
      "targets": [
        { "expr": "sum by (reason) (increase({__name__=~\"cdc_forward_others(_total)?\",namespace=~\"$namespace\",job=~\"$job\"}[$__rate_interval]))", "legendFormat": "others {{reason}}" }
      ] }
  ]
}
```

Validate: `python3 -c "import json; json.load(open('chart/files/grafana/cdc-dashboard.json')); print('JSON OK')"` → `JSON OK`.

- [ ] **Step 2: Alerts file — update the two stale text passages (text only)**

In `chart/files/prometheus/cdc-alerts.yaml`, replace:

```
      # Forward-leg routing miss (multi-subject / design §3.1). Fires when the
      # source cannot derive a key-prefix and publishes to kv.cdc.unknown.<op>,
      # which NO sink group filters — the event parks in the stream unconsumed.
      # Only ever nonzero when prefix routing is configured (the counter is emitted
      # by a gated processor). METRIC NAME: cdc_forward_unrouted scrapes as
```

with:

```
      # Forward-leg routing miss (first-two-seg routing). Fires when an event
      # ends up PARKED on kv.cdc.others.<op> with nothing consuming it:
      # reason=empty_prefix (no derivable key segment — malformed event) or
      # reason=no_match with NO catchAll group deployed. With a catchAll group
      # the same miss is routed traffic and counts cdc_forward_others instead
      # (dashboard panel 12; deliberately not alerted). Only ever nonzero when
      # prefix routing is configured. METRIC NAME: cdc_forward_unrouted scrapes as
```

and replace:

```
            published events with no derivable key-prefix to kv.cdc.unknown.<op>, a
            subject no sink group filters — they accumulate in the stream unconsumed.
            Check the writer's key format / prefix derivation (design §3.1). Add a
            sink group that filters the missing prefix, or fix the key so a prefix
            can be derived.
```

with:

```
            published events to kv.cdc.others.<op> with nothing consuming them
            (reason=empty_prefix: malformed key; reason=no_match: no catchAll
            group deployed) — they accumulate in the stream unconsumed. Fix the
            writer's key format, add a sink group whose prefixes cover the
            missing key family, or deploy a catchAll: true group to drain them.
```

- [ ] **Step 3: values.yaml — document two-seg prefixes, catchAll, and the real six-prefix example**

In `chart/values.yaml`, replace:

```
  #   Routing — set at most ONE of:
  #     prefixes:      key-prefix tokens this group owns; the chart derives the
  #                    consumer filter kv.cdc.<prefix>.> for each (union if many)
  #                    and turns ON forward-leg prefix routing (publish subject
  #                    becomes kv.cdc.<kv_prefix>.<op>). Requires the writer/keys
  #                    to carry a prefix segment (design §3).
  #     filterSubject: explicit NATS filter subject (escape hatch, non-prefix).
  #     (neither) => the group filters the whole stream kv.cdc.> (the default).
```

with:

```
  #   Routing — set at most ONE of:
  #     prefixes:      key prefixes this group owns: ONE or TWO ':'-separated
  #                    segments, each ^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$ (e.g.
  #                    "prefix-a", "tg:caveat", "tg:caveat_context"). ':' is not
  #                    a legal NATS subject character, so the subject token is
  #                    the prefix with ':' -> '.': filter kv.cdc.tg.caveat.>,
  #                    publish kv.cdc.tg.caveat.<op> (union if many; turns ON
  #                    forward-leg prefix routing). Matching is set-based and
  #                    longest-first: a key matches its first-two-seg prefix,
  #                    then its first-one-seg prefix, else routes to "others".
  #                    First segments "others"/"unknown" are reserved; a one-seg
  #                    prefix overlapping a two-seg one (tg + tg:caveat) and
  #                    duplicate prefixes across enabled groups fail the render.
  #     filterSubject: explicit NATS filter subject (escape hatch, non-prefix).
  #     catchAll:      true => this group consumes kv.cdc.others.>: every event
  #                    whose key matches NO configured prefix (counted by
  #                    cdc_forward_others). At most one enabled catchAll group,
  #                    only alongside >=1 enabled prefixes group. WITHOUT a
  #                    catchAll group, unmatched events park on kv.cdc.others.<op>
  #                    and fire CDCForwardUnrouted (reason=no_match).
  #     (none)      => the group filters the whole stream kv.cdc.> (the default).
```

and replace:

```
  # Example (4 prefix groups, each its own active puller):
  #   sinkGroups:
  #     - { name: a, prefixes: [prefix-a] }
  #     - { name: b, prefixes: [prefix-b] }
  #     - { name: c, prefixes: [prefix-c] }
  #     - { name: d, prefixes: [prefix-d], consumer: { maxAckPending: 8192 } }
```

with:

```
  # Example — first-two-segment routing for the tg:* key families
  # (docs/requests/first-two-seg-routing.md), plus the others catch-all:
  #   sinkGroups:
  #     - { name: caveat,         prefixes: ["tg:caveat"] }
  #     - { name: caveat-context, prefixes: ["tg:caveat_context"] }
  #     - { name: g2m,            prefixes: ["tg:g2m"] }
  #     - { name: m2g,            prefixes: ["tg:m2g"] }
  #     - { name: r2g,            prefixes: ["tg:r2g"] }
  #     - { name: uint32id,       prefixes: ["tg:uint32id"] }
  #     - { name: others,         catchAll: true }
  # Durables become cdc_sink_caveat ... cdc_sink_others; a key like
  # tg:caveat:123 publishes to kv.cdc.tg.caveat.<op>; any other key (e.g.
  # tg:new_family:1) flows to kv.cdc.others.<op> via the others group.
```

- [ ] **Step 4: INV-2 grep + render + L2**

```bash
grep -n "cdc_forward_unrouted\|cdc_forward_others" chart/files/grafana/cdc-dashboard.json chart/files/prometheus/cdc-alerts.yaml chart/files/connect/cdc-forward.yaml
helm lint chart/ && helm template chart/ >/dev/null && diff /tmp/twoseg-baseline.yaml <(helm template chart/) && echo "BYTE-IDENTICAL"
```
Expected: both metric names appear in dashboard + pipeline; `cdc_forward_unrouted` in alerts; `BYTE-IDENTICAL`.

Run L2 (~7 min, foreground — do NOT background it; a prior session's `nohup` truncated the run):

```bash
labs/redis-cdc-error-alerting/scripts/verify-alert.sh; echo "exit=$?"
docker compose -f labs/redis-cdc-error-alerting/docker-compose.yml down -v >/dev/null 2>&1
```
Expected: PASS output, exit=0. (Required because the alert/dashboard files the lab bind-mounts changed.)

- [ ] **Step 5: Commit**

```bash
git add chart/files/grafana/cdc-dashboard.json chart/files/prometheus/cdc-alerts.yaml chart/values.yaml
git commit -m "chart: dashboard/alert/docs for first-two-seg routing and others catch-all

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Wire the new checks into run-all-tests.sh (L1 + L2 tiers)

**Files:**
- Modify: `scripts/run-all-tests.sh`

**Interfaces:**
- Consumes: Task 1's harness, Task 2's validation behavior.
- Produces: `RUN_PREFIX=1` will ALSO run `scripts/verify-cdc-twoseg.sh` at L3 — that line is added in Task 6 together with the script; this task only touches L1 and L2.

- [ ] **Step 1: Add the two-seg L1 block**

In `scripts/run-all-tests.sh`, insert immediately BEFORE the line `pass L1` (currently line 102), after the existing fail-loud loop's `done`:

```bash

# ── First-two-segment routing + others catch-all ──
TSG=(--set connect.sinkGroups[0].name=caveat --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat'
     --set connect.sinkGroups[1].name=g2m    --set 'connect.sinkGroups[1].prefixes[0]=tg:g2m'
     --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true)
helm template chart/ "${TSG[@]}" >/dev/null || fail L1
for want in 'kv.cdc.tg.caveat.>' 'kv.cdc.tg.g2m.>' 'kv.cdc.others.>' \
            '"tg:caveat":"tg.caveat"' 'name: lab-connect-sink-others' 'name: cdc_forward_others'; do
  helm template chart/ "${TSG[@]}" | grep -qF "$want" \
    || { echo "[run-all-tests] two-seg render missing $want"; fail L1; }
done
helm template chart/ "${TSG[@]}" | grep -oE "SINK_GROUPS='[^']*'" | grep -q 'cdc_sink_others' \
  || { echo "[run-all-tests] others durable missing from nats-init"; fail L1; }
# default render must stay clean of ALL two-seg machinery
if helm template chart/ | grep -qE 'cdc_forward_others|let routes'; then
  echo "[run-all-tests] default render leaked two-seg routing"; fail L1
fi
# no-catchAll render: a set-miss must count as unrouted, not others (match the
# metric block, not the explanatory comment that also names the counter)
MG2=(--set connect.sinkGroups[0].name=caveat --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat')
if helm template chart/ "${MG2[@]}" | grep -q 'name: cdc_forward_others'; then
  echo "[run-all-tests] cdc_forward_others rendered WITHOUT a catchAll group"; fail L1
fi
# fail-loud grammar/structure set (§ two-seg): each render must exit nonzero
for badset in \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=a:b:c" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=Tg:caveat" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=others" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=others:x" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=unknown" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=tg:caveat" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].prefixes[0]=tg" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].catchAll=true --set connect.sinkGroups[1].prefixes[0]=q" \
  "--set connect.sinkGroups[1].name=z --set connect.sinkGroups[1].catchAll=true --set connect.sinkGroups[2].name=z2 --set connect.sinkGroups[2].catchAll=true"; do
  # shellcheck disable=SC2086
  if helm template chart/ "${MG2[@]}" $badset >/dev/null 2>&1; then
    echo "[run-all-tests] expected fail-loud render for '$badset' but it succeeded"; fail L1
  fi
done
if helm template chart/ --set connect.sinkGroups[0].name=others --set connect.sinkGroups[0].catchAll=true >/dev/null 2>&1; then
  echo "[run-all-tests] catchAll without any prefixed group should fail-loud"; fail L1
fi
```

- [ ] **Step 2: Run the routing harness in the L2 tier**

In the L2 block, insert the harness line before the lab (it is docker-dependent but fast, so it belongs in the first docker tier). Replace:

```bash
else
  labs/redis-cdc-error-alerting/scripts/verify-alert.sh || fail L2
```

with:

```bash
else
  scripts/test-forward-routing.sh || fail L2
  labs/redis-cdc-error-alerting/scripts/verify-alert.sh || fail L2
```

Also update the header comment (line 5) from
`#   L2  labs/redis-cdc-error-alerting proof        (~7 min; skip: SKIP_L2=1)` to
`#   L2  routing harness + error-alerting lab proof (~8 min; skip: SKIP_L2=1)`.

- [ ] **Step 3: Run the fast tiers**

```bash
SKIP_L2=1 SKIP_L3=1 scripts/run-all-tests.sh; echo "exit=$?"
```
Expected: `L0 PASS`, `L1 PASS`, L2/L3 SKIPPED, L4 SKIPPED, final `[run-all-tests] PASS`, exit=0. (L2 already ran in Task 4; the harness ran in Task 3.)

- [ ] **Step 4: Commit**

```bash
git add scripts/run-all-tests.sh
git commit -m "tests: L1 two-seg render+fail-loud assertions; routing harness in L2 tier

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: L3 kind proof — verify-cdc-twoseg.sh

**Files:**
- Create: `scripts/verify-cdc-twoseg.sh`
- Modify: `scripts/run-all-tests.sh` (one line in the L3 `RUN_PREFIX` block)

**Interfaces:**
- Consumes: the deployed chart with groups `caveat` (`tg:caveat`), `g2m` (`tg:g2m`), `others` (catchAll); metrics `cdc_apply`, `cdc_forward_unrouted`, `cdc_forward_others`.
- Produces: `RESULT_JSON:{...}` line + `[verify-twoseg] PASS`; exit 0 on success. Modeled on `scripts/verify-cdc-prefix.sh` (same ns/release/env contract: `RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg`).

- [ ] **Step 1: Write the script**

Create `scripts/verify-cdc-twoseg.sh` with EXACTLY this content, then `chmod +x`:

```bash
#!/usr/bin/env bash
# verify-cdc-twoseg.sh — L3 variant proving FIRST-TWO-SEGMENT key-prefix routing
# plus the "others" catch-all (docs/requests/first-two-seg-routing.md). Deploys
# the chart with THREE sink groups — caveat (tg:caveat), g2m (tg:g2m), others
# (catchAll) — drives prefixed CDC traffic straight into central Redis
# (redis-cli, deterministic; no writer/verifier Job), and asserts:
#   - two-seg routing + ISOLATION: cdc_apply on group caveat == tg:caveat op
#     count, on g2m == tg:g2m op count (a group applies ONLY its prefix);
#   - catch-all: keys matching NO configured prefix (tg:stray:*, misc:*) land in
#     region via the others group; cdc_apply(others) == their count and
#     cdc_forward_others == their count (reason=no_match is ROUTED, not parked);
#   - cdc_forward_unrouted == 0 (no malformed keys were produced);
#   - op semantics on a two-seg family (update/delete/rename on tg:caveat),
#     ZERO loss, and dedup (replaying identical event_ids changes nothing).
# Each run starts PRISTINE (helm uninstall first) so exact counts are
# deterministic. Needs the wildcard subscriber grant (already committed).
# Usage: RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-twoseg.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-mg}"
RELEASE="${RRCS_RELEASE:-cdcmg}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
NC="${NC:-80}"                  # tg:caveat creates
NG="${NG:-40}"                  # tg:g2m creates (deliberately != NC)
NS1="${NS1:-20}"                # tg:stray creates  -> others (2-seg miss)
NS2="${NS2:-10}"                # misc creates      -> others (1-seg miss)
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-180}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
STREAM="app.events"
GROUP="cdc_propagator"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
now_ms() { date +%s%3N; }
log() { echo "[verify-twoseg] $*"; }
die() { echo "[verify-twoseg] FAIL: $*" >&2; exit 1; }

cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }   # $1=pattern
# every test key embeds ":${runid}:" (misc included), so this counts them all
region_total() { cnt "*:${runid}:*"; }
wait_region() { # $1=want — settle when the count holds for 2 polls
  local want="$1" deadline cur ok=0
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    cur="$(region_total)"
    if (( cur == want )); then ok=$(( ok+1 )); (( ok>=2 )) && { echo "$cur"; return 0; }; else ok=0; fi
    sleep 3
  done
  echo "$cur"; return 1
}
# sum a metric across every pod of a Deployment's connect container (standbys
# expose no series, so the sum equals the leader's value)
metric_sum() { # $1=app-label  $2=metric-base
  local dep="$1" metric="$2" pod tot=0 v
  for pod in $(kubectl -n "$NS" get pods -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v="$(kubectl -n "$NS" exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
         | awk -v m="$metric" '$1 ~ "^"m"(_total)?[{ ]" {s+=$2} END{printf "%.0f", s+0}')" || v=0
    tot=$(( tot + ${v:-0} ))
  done
  echo "$tot"
}

log "=== fresh install: caveat(tg:caveat) + g2m(tg:g2m) + others(catchAll) (ns=$NS) ==="
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  --set profile=cdc -f "$VALUES_FILE" \
  --set connect.sinkGroups[0].name=caveat --set 'connect.sinkGroups[0].prefixes[0]=tg:caveat' \
  --set connect.sinkGroups[1].name=g2m    --set 'connect.sinkGroups[1].prefixes[0]=tg:g2m' \
  --set connect.sinkGroups[2].name=others --set connect.sinkGroups[2].catchAll=true \
  "${EXTRA_SET[@]}" --wait --timeout 6m

for d in connect-source connect-sink-caveat connect-sink-g2m connect-sink-others; do
  kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout=180s
done
# let the electors win and POST their pipelines before producing
sleep 5

rr FLUSHDB >/dev/null
rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true

runid="$(now_ms)"; ts="$(now_ms)"
emit_creates() { # $1=key-prefix (e.g. tg:caveat)  $2=count  $3=id-tag
  local p="$1" n="$2" tag="$3" i cmds; cmds="$(mktemp)"
  for (( i=1; i<=n; i++ )); do
    echo "XADD $STREAM * event_id ${runid}-${tag}-c${i} op create type string kv_key ${p}:${runid}:k${i} ts ${ts} body ${tag}-v${i}"
  done > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"
}
emit_extra_caveat() { # update k1, delete k2, rename k3 -> k3r (all tg:caveat)
  local p="tg:caveat" cmds; cmds="$(mktemp)"
  {
    echo "XADD $STREAM * event_id ${runid}-cv-u1 op update type string kv_key ${p}:${runid}:k1 ts ${ts} body cv-v1b"
    echo "XADD $STREAM * event_id ${runid}-cv-d1 op delete type string kv_key ${p}:${runid}:k2 ts ${ts} body x"
    echo "XADD $STREAM * event_id ${runid}-cv-r1 op rename type string kv_key ${p}:${runid}:k3 old_key ${p}:${runid}:k3 new_key ${p}:${runid}:k3r ts ${ts} body x"
  } > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"
}

T1=$(( NC + NG + NS1 + NS2 ))
log "phase 1: creates — tg:caveat=$NC tg:g2m=$NG tg:stray=$NS1 misc=$NS2 -> wait region == $T1"
emit_creates "tg:caveat" "$NC"  cv
emit_creates "tg:g2m"    "$NG"  gm
emit_creates "tg:stray"  "$NS1" st
emit_creates "misc"      "$NS2" ms
c1="$(wait_region "$T1")" || die "phase1: region reached only $c1 / $T1 keys"
log "phase 1 settled at $c1 keys"

T2=$(( T1 - 1 ))   # k2 deleted; k3->k3r is net 0
log "phase 2: tg:caveat update/delete/rename -> wait region == $T2"
emit_extra_caveat
c2="$(wait_region "$T2")" || die "phase2: region at $c2, want $T2"
log "phase 2 settled at $c2 keys"

# Countable cdc_apply per group. NOTE (pre-existing, single-group too):
# delete/rename emit cdc_apply{op} while create/update emit cdc_apply{op,type};
# Connect skips the mismatched series, so delete/rename are NOT countable —
# their apply is proven by region membership (k2 gone, k3r present).
CV_OPS=$(( NC + 1 )); GM_OPS=$(( NG )); OT_OPS=$(( NS1 + NS2 ))

# ── assertions ──
cv_present="$(cnt "tg:caveat:${runid}:*")"
gm_present="$(cnt "tg:g2m:${runid}:*")"
st_present="$(cnt "tg:stray:${runid}:*")"
ms_present="$(cnt "misc:${runid}:*")"
log "region: caveat=$cv_present/$(( NC-1 )) g2m=$gm_present/$NG stray=$st_present/$NS1 misc=$ms_present/$NS2"
(( cv_present == NC - 1 )) || die "tg:caveat loss/mismatch: region has $cv_present, want $(( NC-1 ))"
(( gm_present == NG ))     || die "tg:g2m loss/mismatch: region has $gm_present, want $NG"
(( st_present == NS1 ))    || die "tg:stray (others) loss: region has $st_present, want $NS1"
(( ms_present == NS2 ))    || die "misc (others) loss: region has $ms_present, want $NS2"
rr EXISTS "tg:caveat:${runid}:k3r" | grep -q 1 || die "rename target k3r missing"
rr EXISTS "tg:caveat:${runid}:k3"  | grep -q 0 || die "rename source k3 still present"
rr EXISTS "tg:caveat:${runid}:k2"  | grep -q 0 || die "deleted k2 still present"

unrouted="$(metric_sum connect-source cdc_forward_unrouted)"
others_m="$(metric_sum connect-source cdc_forward_others)"
log "cdc_forward_unrouted=$unrouted (want 0), cdc_forward_others=$others_m (want $OT_OPS)"
(( unrouted == 0 ))       || die "cdc_forward_unrouted=$unrouted (malformed key or routing regression)"
(( others_m == OT_OPS ))  || die "cdc_forward_others=$others_m, want $OT_OPS (catch-all accounting broken)"

cv_apply="$(metric_sum connect-sink-caveat cdc_apply)"
gm_apply="$(metric_sum connect-sink-g2m    cdc_apply)"
ot_apply="$(metric_sum connect-sink-others cdc_apply)"
log "cdc_apply caveat=$cv_apply/$CV_OPS g2m=$gm_apply/$GM_OPS others=$ot_apply/$OT_OPS"
(( cv_apply == CV_OPS )) || die "group caveat applied $cv_apply, want $CV_OPS (routing/isolation broken)"
(( gm_apply == GM_OPS )) || die "group g2m applied $gm_apply, want $GM_OPS (routing/isolation broken)"
(( ot_apply == OT_OPS )) || die "group others applied $ot_apply, want $OT_OPS (catch-all broken)"

# dedup: replay the same event_ids; region must not change
log "replaying identical event_ids (dedup check) ..."
emit_creates "tg:caveat" "$NC"  cv
emit_creates "tg:g2m"    "$NG"  gm
emit_creates "tg:stray"  "$NS1" st
emit_creates "misc"      "$NS2" ms
emit_extra_caveat
sleep 10
r2="$(region_total)"
(( r2 == c2 )) || die "dedup broken: region changed from $c2 to $r2 after replay"
log "dedup OK: region stable at $r2 after replay"

echo "RESULT_JSON:{\"caveat_present\":$cv_present,\"g2m_present\":$gm_present,\"others_present\":$(( st_present + ms_present )),\"cv_apply\":$cv_apply,\"gm_apply\":$gm_apply,\"ot_apply\":$ot_apply,\"unrouted\":$unrouted,\"forward_others\":$others_m,\"dedup_stable\":$r2}"
echo "[verify-twoseg] PASS — two-seg routing + others catch-all + isolation + no-loss + dedup"
```

- [ ] **Step 2: Wire into run-all-tests L3**

In `scripts/run-all-tests.sh`, in the L3 block, replace:

```bash
  if [ "${RUN_PREFIX:-0}" = "1" ]; then
    RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-prefix.sh || fail L3
  fi
```

with:

```bash
  if [ "${RUN_PREFIX:-0}" = "1" ]; then
    RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-prefix.sh || fail L3
    RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-twoseg.sh || fail L3
  fi
```

Also extend the header comment (lines 9–12) to mention it, e.g. change
`verify-cdc-prefix.sh at L3 and (with` to
`verify-cdc-prefix.sh + verify-cdc-twoseg.sh at L3 and (with`.

- [ ] **Step 3: Run on kind — new proof + both regressions**

The kind cluster is named `cdc`. Images must contain the current code:

```bash
chmod +x scripts/verify-cdc-twoseg.sh
scripts/build-images.sh --kind --kind-name=cdc; echo "exit=$?"
RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-twoseg.sh; echo "exit=$?"
```
Expected: `[verify-twoseg] PASS ...` and its RESULT_JSON, exit=0.

```bash
# 1-seg regression (must pass UNCHANGED — proves backward compat of set-based routing)
RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-cdc-prefix.sh; echo "exit=$?"
# default-render regression (INV-1 functional proof)
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh; echo "exit=$?"
```
Expected: `[verify-prefix] PASS ...` exit=0; verify-cdc RESULT_JSON with `verdict.pass=true` / `[verify-cdc] PASS`, exit=0.

If verify-cdc-twoseg fails on metric counts, debug with:
`kubectl -n cdc-mg exec deploy/lab-connect-source -c connect -- wget -qO- localhost:4195/metrics | grep cdc_forward` and
`kubectl -n cdc-mg logs deploy/lab-connect-source -c connect --tail=50`.

- [ ] **Step 4: Commit**

```bash
git add scripts/verify-cdc-twoseg.sh scripts/run-all-tests.sh
git commit -m "tests: L3 kind proof for first-two-seg routing + others catch-all

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: L4 gate, cleanup, final report

**Files:** none created; runs tests, cleans up, reports.

- [ ] **Step 1: L4 — per-group failover with the new routing code path**

`rules/05-invariants.md` requires L4 for changes feeding nats-init consumer creation (the sinkGroups helper does). The prefix variant covers it — its two 1-seg groups now flow through the NEW set-based mapping and the same nats-init loop; failover mechanics (lease, `bind:true`, PEL replay) are independent of how many segments derived the token. The default `verify-failover.sh` is not required: the default render is byte-identical (diff proven in Tasks 2–4).

```bash
RRCS_NS=cdc-mg RRCS_RELEASE=cdcmg scripts/verify-failover-prefix.sh; echo "exit=$?"
```
Expected (~6–10 min): `[failover-prefix] PASS — group-a durable replayed with ZERO loss after SIGKILL; group-b unaffected (isolation held)`, exit=0.

- [ ] **Step 2: Cleanup test namespaces**

```bash
helm uninstall cdcmg -n cdc-mg >/dev/null 2>&1 || true
kubectl delete ns cdc-mg --wait=false 2>/dev/null || true
```

- [ ] **Step 3: Final report (INV-4 reporting rule)**

Paste in the final message: every command run in Tasks 3–7 with exit status and the PASS/RESULT_JSON lines — harness PASS (12/12 cases), L0/L1 PASS, L2 PASS, byte-identity diff empty, verify-cdc-twoseg PASS, verify-cdc-prefix PASS, verify-cdc PASS, verify-failover-prefix PASS. State explicitly that `verify-failover.sh` (default) was skipped and why (byte-identical default render).

- [ ] **Step 4 (optional): record a lesson**

If anything non-obvious surfaced during implementation (e.g. a Helm/Sprig scoping trap or a Bloblang behavior not in this plan), append it to `rules/50-lessons.md` in that file's format — after backing it up:
`cp rules/50-lessons.md rules/50-lessons.md.bak-$(date +%Y%m%d-%H%M%S)`.

---

## Self-review notes (already applied)

- **Spec coverage:** two-seg routing (Tasks 2–3), the six `tg:*` prefixes (values example, Task 4; harness cases, Task 1), "others" subject (Tasks 2–3, proven Task 6), naming validity (Task 2 grammar + reserved/overlap/dup checks; `:`→`.` encoding; durables unchanged `cdc_sink_<dns-name>`).
- **Type/name consistency:** `kv_prefix_reason` values `matched|no_match|empty_prefix` are identical in Task 1 (harness cases), Task 3 (mapping + switch), Task 6 (implicitly via counters). Metric names `cdc_forward_unrouted` / `cdc_forward_others` identical across Tasks 3, 4, 5, 6. Group fields `prefixes`/`catchAll` identical across Tasks 1, 2, 5, 6.
- **Known accepted limitations (documented, not bugs):** `cdc_apply` for delete/rename is uncountable (pre-existing label-cardinality mismatch — noted in both L3 scripts); a catchAll group cannot coexist with a `filterSubject: kv.cdc.>` whole-stream group without double delivery (unchanged semantics of the escape hatch — the operator owns explicit filterSubjects); replays through the forward leg re-increment forward counters, so Task 6 asserts counters BEFORE the dedup replay phase (same ordering as verify-cdc-prefix.sh).
