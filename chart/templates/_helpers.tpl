{{/*
rrcs.image — join the global registry prefix with a per-image ref.
Usage: {{ include "rrcs.image" (dict "root" $ "ref" .Values.images.app) }}
*/}}
{{- define "rrcs.image" -}}
{{- printf "%s%s" .root.Values.images.registry .ref -}}
{{- end -}}

{{/*
rrcs.pullPolicy — per-image override or global default.
Usage: {{ include "rrcs.pullPolicy" (dict "root" $ "override" .Values.writer.pullPolicy) }}
*/}}
{{- define "rrcs.pullPolicy" -}}
{{- if .override }}{{ .override }}{{- else }}{{ .root.Values.images.pullPolicy }}{{- end -}}
{{- end -}}

{{/*
rrcs.imagePullSecrets — render imagePullSecrets if any are configured.
Usage (at pod-spec indent): {{- include "rrcs.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "rrcs.imagePullSecrets" -}}
{{- with .Values.images.pullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ .name }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
rrcs.podLabels — pod-template labels for a workload: the mandatory `app`
selector label plus any user-supplied common labels from .Values.podLabels.
`app` is emitted first; podLabels cannot override it because each workload's
selector.matchLabels pins `app` and the selector is immutable after install.
Usage (at template.metadata.labels indent):
  labels:
    {{- include "rrcs.podLabels" (dict "root" $ "app" "writer") | nindent 8 }}
*/}}
{{- define "rrcs.podLabels" -}}
app: {{ .app }}
{{- with omit .root.Values.podLabels "app" }}
{{ toYaml . | trim }}
{{- end }}
{{- end -}}

{{/*
rrcs.scheduling — global nodeSelector / tolerations / affinity for every pod.
Usage (at pod-spec indent): {{- include "rrcs.scheduling" . | nindent 6 }}
*/}}
{{- define "rrcs.scheduling" -}}
{{- with .Values.scheduling.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.scheduling.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.scheduling.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
rrcs.nats.url — client URL. Bundled: in-cluster Service. External: user-supplied.
Usage: {{ include "rrcs.nats.url" . }}
*/}}
{{- define "rrcs.nats.url" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.url is required when nats.external.enabled=true" .Values.nats.external.url -}}
{{- else -}}
{{- printf "nats://%s:%v" (include "rrcs.name" (dict "root" $ "base" "nats")) .Values.nats.clientPort -}}
{{- end -}}
{{- end -}}

{{/*
rrcs.nats.monitorUrl — HTTP /jsz endpoint. Bundled: in-cluster Service.
External: user-supplied; returns "" if unset (callers gate).
*/}}
{{- define "rrcs.nats.monitorUrl" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.monitorUrl -}}
{{- else -}}
{{- printf "http://%s:%v" (include "rrcs.name" (dict "root" $ "base" "nats")) .Values.nats.monitorPort -}}
{{- end -}}
{{- end -}}

{{/*
rrcs.redis.central.url / rrcs.redis.region.url — connection URL form.
*/}}
{{- define "rrcs.redis.central.url" -}}
{{- if .Values.redis.central.external.enabled -}}
{{- required "redis.central.external.url is required when enabled" .Values.redis.central.external.url -}}
{{- else -}}
{{- printf "redis://%s:6379" (include "rrcs.name" (dict "root" $ "base" "redis-central")) -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.url" -}}
{{- if .Values.redis.region.external.enabled -}}
{{- required "redis.region.external.url is required when enabled" .Values.redis.region.external.url -}}
{{- else -}}
{{- printf "redis://%s:6379" (include "rrcs.name" (dict "root" $ "base" "redis-region")) -}}
{{- end -}}
{{- end -}}

{{/*
rrcs.redis.{central,region}.hostPort — host:port form (URL scheme stripped),
for the writer's REDIS_ADDR env, the verifier's --redis-* flags, and the
init-container redis-cli ping. These consumers DO NOT speak TLS in v1, so a
rediss:// URL would silently downgrade to plain TCP everywhere outside the
connect configs. Fail-closed: external Redis TLS belongs in the same
follow-up that wires writer/verifier auth (spec §2 non-goal).
*/}}
{{- define "rrcs.redis.central.hostPort" -}}
{{- $u := include "rrcs.redis.central.url" . -}}
{{- if hasPrefix "rediss://" $u -}}
{{- fail (printf "redis.central.external: TLS (rediss://) is not supported in v1 — writer/verifier/init-container redis clients consume host:port only and would silently use plain TCP. URL: %s. Use redis:// for v1; TLS is deferred to the same follow-up as external Redis auth (spec §2)." $u) -}}
{{- end -}}
{{- regexReplaceAll "^redis://" $u "" -}}
{{- end -}}

{{- define "rrcs.redis.region.hostPort" -}}
{{- $u := include "rrcs.redis.region.url" . -}}
{{- if hasPrefix "rediss://" $u -}}
{{- fail (printf "redis.region.external: TLS (rediss://) is not supported in v1 — writer/verifier/init-container redis clients consume host:port only and would silently use plain TCP. URL: %s. Use redis:// for v1; TLS is deferred to the same follow-up as external Redis auth (spec §2)." $u) -}}
{{- end -}}
{{- regexReplaceAll "^redis://" $u "" -}}
{{- end -}}

{{/*
rrcs.redis.validateMode — fail-closed enum guard for redis.<side>.mode. mode
selects the bundled topology (standalone single-node vs a minimal 3-master
cluster) and is ignored when external.enabled=true. Validated unconditionally so
a typo surfaces at template time rather than as a silent standalone fallback.
Usage: {{ include "rrcs.redis.validateMode" (dict "side" "central" "mode" .Values.redis.central.mode) }}
*/}}
{{- define "rrcs.redis.validateMode" -}}
{{- if not (has .mode (list "standalone" "cluster")) -}}
{{- fail (printf "redis.%s.mode=%q is invalid — must be \"standalone\" or \"cluster\"." .side .mode) -}}
{{- end -}}
{{- end -}}

{{/*
rrcs.connect.bodyEncoding — fail-closed enum guard for the forward leg's body wire
format; returns the validated value. Validated at template time so a typo (e.g.
"gzip", "GZIP:BASE64") fails the render instead of silently selecting the lossy
legacy content().string() path, which corrupts binary/invalid-UTF-8 bodies.
Usage: {{ include "rrcs.connect.bodyEncoding" . }}
*/}}
{{- define "rrcs.connect.bodyEncoding" -}}
{{- $e := .Values.connect.bodyEncoding | default "none" -}}
{{- if not (has $e (list "none" "gzip:base64")) -}}
{{- fail (printf "connect.bodyEncoding=%q is invalid — must be \"none\" or \"gzip:base64\"." $e) -}}
{{- end -}}
{{- $e -}}
{{- end -}}

{{/*
rrcs.redis.{central,region}.cluster — "true"/"false" for the Go components'
*_CLUSTER env, the verifier's -redis-*-cluster flags, and connectKind. One
source of truth for "talk to this Redis as a cluster":
  external.enabled=true  → external.cluster (the user-supplied Redis is/ isn't a cluster).
  external.enabled=false → mode=="cluster" (the bundled topology this chart deploys).
Fail-closed: external.cluster=true with external.enabled=false is a contradiction
(no external Redis to be a cluster), caught at template time.
*/}}
{{- define "rrcs.redis.central.cluster" -}}
{{- if .Values.redis.central.external.enabled -}}
{{- if .Values.redis.central.external.cluster -}}true{{- else -}}false{{- end -}}
{{- else -}}
{{- if .Values.redis.central.external.cluster -}}
{{- fail "redis.central.external.cluster=true requires redis.central.external.enabled=true (it describes an external Redis Cluster). For a bundled in-cluster Redis, set redis.central.mode=cluster instead." -}}
{{- end -}}
{{- if eq .Values.redis.central.mode "cluster" -}}true{{- else -}}false{{- end -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.cluster" -}}
{{- if .Values.redis.region.external.enabled -}}
{{- if .Values.redis.region.external.cluster -}}true{{- else -}}false{{- end -}}
{{- else -}}
{{- if .Values.redis.region.external.cluster -}}
{{- fail "redis.region.external.cluster=true requires redis.region.external.enabled=true (it describes an external Redis Cluster). For a bundled in-cluster Redis, set redis.region.mode=cluster instead." -}}
{{- end -}}
{{- if eq .Values.redis.region.mode "cluster" -}}true{{- else -}}false{{- end -}}
{{- end -}}
{{- end -}}

{{/*
rrcs.redis.{central,region}.waitCmd — the shell line an init container uses to
block until the Redis is usable. Standalone waits for PONG; cluster waits for
cluster_state:ok (a freshly-booted cluster node answers PING before the slots
are assigned, so PONG alone would let clients start too early and hit
CLUSTERDOWN). Driven by the same .cluster source of truth.
*/}}
{{- define "rrcs.redis.central.waitCmd" -}}
{{- $hp := include "rrcs.redis.central.hostPort" . -}}
{{- if eq (include "rrcs.redis.central.cluster" .) "true" -}}
HP="{{ $hp }}"; HOST="${HP%%:*}"; PORT="${HP##*:}"; until redis-cli -h "$HOST" -p "$PORT" cluster info 2>/dev/null | grep -q cluster_state:ok; do echo waiting redis-central cluster; sleep 1; done
{{- else -}}
HP="{{ $hp }}"; HOST="${HP%%:*}"; PORT="${HP##*:}"; until redis-cli -h "$HOST" -p "$PORT" ping | grep -q PONG; do echo waiting redis-central; sleep 1; done
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.waitCmd" -}}
{{- $hp := include "rrcs.redis.region.hostPort" . -}}
{{- if eq (include "rrcs.redis.region.cluster" .) "true" -}}
HP="{{ $hp }}"; HOST="${HP%%:*}"; PORT="${HP##*:}"; until redis-cli -h "$HOST" -p "$PORT" cluster info 2>/dev/null | grep -q cluster_state:ok; do echo waiting redis-region cluster; sleep 1; done
{{- else -}}
HP="{{ $hp }}"; HOST="${HP%%:*}"; PORT="${HP##*:}"; until redis-cli -h "$HOST" -p "$PORT" ping | grep -q PONG; do echo waiting redis-region; sleep 1; done
{{- end -}}
{{- end -}}

{{/*
rrcs.redis.{central,region}.connectKind — "cluster"/"simple" for the redpanda-
connect redis components. Wraps the guarded .cluster helper so the toggle has one
source of truth.
*/}}
{{- define "rrcs.redis.central.connectKind" -}}
{{- if eq (include "rrcs.redis.central.cluster" .) "true" -}}cluster{{- else -}}simple{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.connectKind" -}}
{{- if eq (include "rrcs.redis.region.cluster" .) "true" -}}cluster{{- else -}}simple{{- end -}}
{{- end -}}

{{/*
rrcs.nats.credsSecret.{publisher,subscriber,admin} — Secret name to mount.
Bundled: the chart-rendered Secret name from values. External: user-supplied
Secret name (may be empty for admin, in which case purge is skipped).
*/}}
{{/*
rrcs.nats.stream.subjects — wildcard pattern the JetStream stream binds to.
Derived from .Values.nats.stream.subjectPrefix so the bound subjects, the
publish subject, and the publisher's --allow-pub grant cannot drift.
Usage: {{ include "rrcs.nats.stream.subjects" . }}
*/}}
{{- define "rrcs.nats.stream.subjects" -}}
{{- $p := required "nats.stream.subjectPrefix is required" .Values.nats.stream.subjectPrefix -}}
{{- $dl := .Values.connect.deadLetter | default dict -}}
{{- if $dl.enabled -}}
{{-   $families := (.Values.connect.sharding | default dict).families | default dict -}}
{{-   if gt (len $families) 0 -}}
{{-     fail (printf "connect.deadLetter.enabled=true is not supported with subject-sharding v2 (connect.sharding.families is set) — the sharded sink pipeline (cdc-reverse-sharded.yaml) has no DLQ routing, so a mixed topology would be silently half-protected (unsharded poison parked, sharded poison still loops). Disable one of them.") -}}
{{-   end -}}
{{-   $sub := required "connect.deadLetter.subject is required when deadLetter.enabled" $dl.subject -}}
{{- /* The base subject must be a LITERAL: it is used verbatim both in the stream's
     subjects list ("<sub>.>") and in the sink's publish subject
     ("<sub>.<reason>"). Wildcards (* / >), empty segments (".."), leading or
     trailing dots, and whitespace all render fine here and only blow up later
     inside NATS (bad stream config or failed publishes) — fail at render time
     instead. Tokens are conservatively [A-Za-z0-9_-]. */}}
{{-   if not (regexMatch "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)*$" $sub) -}}
{{-     fail (printf "connect.deadLetter.subject %q must be a literal dot-separated NATS subject: tokens of [A-Za-z0-9_-] only — no wildcards (* or >), no empty segments, no leading/trailing dots, no whitespace. Use e.g. dlq.cdc." $sub) -}}
{{-   end -}}
{{-   if or (eq $sub $p) (hasPrefix (printf "%s." $p) $sub) -}}
{{-     fail (printf "connect.deadLetter.subject %q must be OUTSIDE nats.stream.subjectPrefix %q — a subject under %s.> would be re-consumed by a whole-stream sink. Use e.g. dlq.cdc." $sub $p $p) -}}
{{-   end -}}
{{-   printf "%s.>,%s.>" $p $sub -}}
{{- else -}}
{{-   printf "%s.>" $p -}}
{{- end -}}
{{- end -}}

{{/*
rrcs.nats.stream.publishSubject — subject connect-source publishes each CDC event
to. Legacy (no prefix routing): <subjectPrefix>.<op>. When ANY enabled sinkGroup
routes by key-prefix (rrcs.connect.prefixRouting == "true", D3 §3), it becomes
<subjectPrefix>.<kv_prefix>.<op> so messages split into per-prefix subjects the
per-group durables filter on. The ".${! meta(...) }" tokens are Redpanda Connect
interpolations evaluated at publish time, not by Helm. The default render (no
prefix groups) is byte-identical to the pre-D3 <subjectPrefix>.<op>.
*/}}
{{- define "rrcs.nats.stream.publishSubject" -}}
{{- $p := required "nats.stream.subjectPrefix is required" .Values.nats.stream.subjectPrefix -}}
{{- if eq (include "rrcs.connect.prefixRouting" .) "true" -}}
{{- printf "%s.${! meta(\"kv_prefix\") }.${! meta(\"op\") }" $p -}}
{{- else -}}
{{- printf "%s.${! meta(\"op\") }" $p -}}
{{- end -}}
{{- end -}}

{{/*
rrcs.connect.sinkGroups — normalized sink-group list (multi-subject support, D3).
Emits a YAML array; consume it with fromYamlArray:
  {{- range $g := (include "rrcs.connect.sinkGroups" $ | fromYamlArray) }}
When .Values.connect.sinkGroups is empty/unset the chart synthesises ONE group
named "default" whose every field resolves to today's legacy single-sink values
(connect.sink.* + nats.stream.consumer.*), so the default render is byte-for-byte
identical to the pre-D3 chart (design §1). Field resolution precedence:
  group value  ->  connect.sinkDefaults  ->  legacy connect.sink.* / consumer.*
Each element carries: name enabled isDefault prefixed prefixes catchAll durable
filter streamID replicas ackWait maxAckPending maxDeliver leaseDuration
renewDeadline retryPeriod deployBase pipelineBase saBase appLabel.
Validation (fail-loud at render): DNS-1123 name; prefix grammar ^seg(:seg)?$
with seg=[a-z0-9]([a-z0-9_-]*[a-z0-9])? (first-two-seg routing); reserved first
segments "others"/"unknown"; duplicate-prefix and 1-seg/2-seg overlap checks
across enabled groups; prefixes XOR filterSubject XOR catchAll; at most one
enabled catchAll and only alongside >=1 enabled prefixed group; mode ("ha" only
in this pass); the 57-char name budget.
*/}}
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
{{- /* ── per-key sharding config (subject-sharding v2) ──
     families = { "<family>": { shards: N } }. A family is a key prefix (same
     grammar as group prefixes) whose subjects gain a shard token derived from
     the employee id: kv.cdc.<family dotted>.s<K>.<op>. Groups claim shards via
     shardsOf + shards; the union across ENABLED groups must equal
     {0..N-1, "x"} exactly once (INV-S4). All checks fail-loud at render. */ -}}
{{- $shardCfg := $v.connect.sharding | default dict -}}
{{- $families := $shardCfg.families | default dict -}}
{{- $shardingOn := gt (len $families) 0 -}}
{{- if $shardingOn -}}
{{-   $kp := include "rrcs.connect.sharding.keyPattern" $root -}}
{{-   if not (contains "(?P<id>" $kp) -}}
{{-     fail (printf "connect.sharding.keyPattern=%q must contain the named capture group (?P<id>...) — the forward leg extracts the numeric shard key from it" $kp) -}}
{{-   end -}}
{{-   if not (eq (kindOf $v.connect.source.maxInFlight) "invalid") -}}
{{-     fail (printf "connect.source.maxInFlight=%v is set while connect.sharding.families is configured — sharding hard-codes the forward output to max_in_flight: 1 (ordering link O-4, design v2 §4.1); REMOVE the key. A leftover value would otherwise silently loosen publish serialization and reintroduce old-overwrites-new with no detecting metric." $v.connect.source.maxInFlight) -}}
{{-   end -}}
{{- end -}}
{{- range $fam, $fcfg := $families -}}
{{-   if not (regexMatch $prefixRe $fam) -}}
{{-     fail (printf "connect.sharding.families: family %q must be one or two ':'-separated segments, each matching ^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$ (same grammar as sinkGroup prefixes)" $fam) -}}
{{-   end -}}
{{-   $seg0f := index (splitList ":" $fam) 0 -}}
{{-   if or (eq $seg0f "others") (eq $seg0f "unknown") -}}
{{-     fail (printf "connect.sharding.families: family %q — first segment %q is reserved" $fam $seg0f) -}}
{{-   end -}}
{{-   $nRaw := $fcfg.shards | default 0 -}}
{{-   if ne (printf "%v" $nRaw) (printf "%d" (int $nRaw)) -}}
{{-     fail (printf "connect.sharding.families[%s].shards=%v must be an integer" $fam $nRaw) -}}
{{-   end -}}
{{-   if lt (int $nRaw) 2 -}}
{{-     fail (printf "connect.sharding.families[%s].shards=%v must be an integer >= 2 (virtual-shard over-provision, design D-10: pick N once, large)" $fam $nRaw) -}}
{{-   end -}}
{{- end -}}
{{- $groups := $v.connect.sinkGroups -}}
{{- if not $groups -}}
{{-   $groups = list (dict "name" "default" "enabled" $legSink.enabled) -}}
{{- end -}}
{{- $out := list -}}
{{- $seenPrefixes := dict -}}
{{- $seenNames := dict -}}
{{- /* Families join the prefix-conflict domain: a family may not double as a
     group prefix (double delivery: the group filter <p>.<fam>.> is a superset
     of every <p>.<fam>.s<K>.> shard filter), and the 1-seg/2-seg overlap sweep
     below must see them too. */ -}}
{{- range $fam, $fcfg := $families -}}
{{-   $_ := set $seenPrefixes $fam (printf "connect.sharding.families[%s]" $fam) -}}
{{- end -}}
{{- $famClaims := dict -}}
{{- $catchAllCount := 0 -}}
{{- $anyPrefixedEnabled := false -}}
{{- $wholeStream := list -}}
{{- range $g := $groups -}}
{{-   $name := $g.name | default "default" -}}
{{-   if not (regexMatch $tokenRe $name) -}}
{{-     fail (printf "connect.sinkGroups: group name %q is not a valid NATS+DNS token (^[a-z0-9]([a-z0-9-]*[a-z0-9])?$: lowercase alnum + dash, no leading/trailing dash)" $name) -}}
{{-   end -}}
{{- /* Name uniqueness across ALL groups AS WRITTEN — checked here, before the
     enabled flag is read, so it fires even when a duplicate is disabled. This is
     DELIBERATELY stricter than the enabled-gated duplicate-prefix sweep below
     (seenPrefixes only registers enabled groups): a duplicate NAME has no inert
     interpretation — two groups with one name derive one Deployment (K8s name
     collision, one silently wins) and one durable in the nats-init SINK_GROUPS
     record carrying two conflicting FilterSubjects; drift-reconcile flips that
     filter and one group's traffic is published but never consumed (silent
     delivery loss). A disabled duplicate is a config smell that becomes exactly
     that bug the moment it is enabled, so it is rejected up front. Groups that
     omit name resolve to "default", so two un-named (or two literal "default")
     groups collide here too. */ -}}
{{-   if hasKey $seenNames $name -}}
{{-     fail (printf "connect.sinkGroups: group name %q is used by more than one group — names must be UNIQUE across all groups as written (checked regardless of enabled: a disabled duplicate is a config smell that becomes a correctness bug the moment it is enabled). Two groups sharing a name derive the SAME sink Deployment (Kubernetes name collision — one silently wins) and the SAME durable %q in the nats-init SINK_GROUPS record, which then carries two conflicting FilterSubjects; drift-reconcile flips the durable's filter so one group's traffic is published to JetStream but never consumed — silent delivery loss. Give each group a distinct name." $name (printf "%s_%s" $baseDurable $name)) -}}
{{-   end -}}
{{-   $_ := set $seenNames $name $name -}}
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
{{-   $shardsOf := $g.shardsOf | default "" -}}
{{-   $sharded := ne $shardsOf "" -}}
{{-   if and $sharded (or (gt (len $prefixes) 0) (ne $filterSubject "") $catchAll) -}}
{{-     fail (printf "connect.sinkGroups[%s]: shardsOf excludes prefixes, filterSubject and catchAll — a shard group's filters are derived from its claimed shards" $name) -}}
{{-   end -}}
{{-   if and $sharded $isDefault -}}
{{-     fail "connect.sinkGroups: the \"default\" group cannot be sharded (default = the legacy whole-stream sink names; give shard groups explicit names, e.g. m2g-a)" -}}
{{-   end -}}
{{-   if and $sharded (not (hasKey $families $shardsOf)) -}}
{{-     fail (printf "connect.sinkGroups[%s].shardsOf=%q — no such family under connect.sharding.families (configured: %v)" $name $shardsOf (keys $families | sortAlpha)) -}}
{{-   end -}}
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
{{-   $consumers := list -}}
{{-   if $sharded -}}
{{- /* One durable + filter PER claimed shard (D-3: 1 durable = 1
     FilterSubject). max_ack_pending is HARD-CODED to 1 — ordering link O-6:
     with MAP=1 a redelivery can never overtake a later message; the
     group→sinkDefaults→legacy inheritance chain (default 1024) is DELIBERATELY
     not consulted (design v2 §3 asymmetry #2). */ -}}
{{-     if $enabled -}}{{- $anyPrefixedEnabled = true -}}{{- end -}}
{{-     $fcfg := get $families $shardsOf -}}
{{-     $n := int $fcfg.shards -}}
{{-     $famUs := replace ":" "_" $shardsOf -}}
{{-     $famDot := replace ":" "." $shardsOf -}}
{{-     $claims := get $famClaims $shardsOf | default dict -}}
{{-     $gshards := $g.shards | default list -}}
{{-     if eq (len $gshards) 0 -}}
{{-       fail (printf "connect.sinkGroups[%s]: shardsOf=%q requires a non-empty shards list (e.g. shards: [0,1,2,3] or [28,29,30,31,\"x\"])" $name $shardsOf) -}}
{{-     end -}}
{{-     $subs := list -}}
{{-     range $s := $gshards -}}
{{-       $sv := printf "%v" $s -}}
{{-       $tok := "" -}}
{{-       if eq $sv "x" -}}
{{-         $tok = "sx" -}}
{{-       else if regexMatch "^[0-9]+$" $sv -}}
{{-         if ge (atoi $sv) $n -}}
{{-           fail (printf "connect.sinkGroups[%s].shards: %v is out of range for family %q (shards: %d — valid: 0..%d and \"x\")" $name $s $shardsOf $n (sub $n 1)) -}}
{{-         end -}}
{{-         $tok = printf "s%d" (atoi $sv) -}}
{{-       else -}}
{{-         fail (printf "connect.sinkGroups[%s].shards: %q is neither an integer in 0..%d nor the isolation token \"x\"" $name $sv (sub $n 1)) -}}
{{-       end -}}
{{-       if $enabled -}}
{{-         if hasKey $claims $tok -}}
{{-           fail (printf "connect.sinkGroups[%s].shards: shard %q of family %q is already claimed by enabled group %q — every shard belongs to exactly one enabled group (INV-S4)" $name $tok $shardsOf (get $claims $tok)) -}}
{{-         end -}}
{{-         $_ := set $claims $tok $name -}}
{{-       end -}}
{{-       $durableK := printf "%s_%s_%s" $baseDurable $famUs $tok -}}
{{-       $filterK := printf "%s.%s.%s.>" $prefix $famDot $tok -}}
{{-       $subs = append $subs $filterK -}}
{{-       $consumers = append $consumers (dict "token" $tok "durable" $durableK "filter" $filterK "maxAckPending" 1) -}}
{{-     end -}}
{{-     $_ := set $famClaims $shardsOf $claims -}}
{{-     $filter = join "," $subs -}}
{{-   else if $prefixed -}}
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
{{-           fail (printf "connect.sinkGroups[%s].prefixes: %q is already owned by %q — a prefix may belong to exactly one enabled owner (a sinkGroup's prefixes or a connect.sharding family)" $name $p (get $seenPrefixes $p)) -}}
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
{{-   if and $enabled (not $prefixed) (not $sharded) (eq $filterSubject "") (not $catchAll) -}}
{{-     $wholeStream = append $wholeStream $name -}}
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
{{-   if and $sharded (not (eq (kindOf $gcons.maxAckPending) "invalid")) -}}
{{-     fail (printf "connect.sinkGroups[%s].consumer.maxAckPending=%v — a shard group's durables are HARD-CODED to max_ack_pending: 1 (ordering link O-6, design D-8) and cannot be overridden; remove the key" $name $gcons.maxAckPending) -}}
{{-   end -}}
{{-   $ackWait := ($gcons.ackWait | default $defCons.ackWait | default $legCons.ackWait) -}}
{{-   $maxAckPending := ($gcons.maxAckPending | default $defCons.maxAckPending | default $legCons.maxAckPending) -}}
{{-   $maxDeliver := ($gcons.maxDeliver | default $defCons.maxDeliver | default $legCons.maxDeliver) -}}
{{-   if $sharded -}}
{{-     $maxAckPending = 1 -}}
{{-     $durable = "" -}}
{{-   else -}}
{{-     $consumers = list (dict "token" "" "durable" $durable "filter" $filter "maxAckPending" $maxAckPending) -}}
{{-   end -}}
{{-   $elem := dict
             "name" $name
             "enabled" $enabled
             "isDefault" $isDefault
             "prefixed" $prefixed
             "prefixes" $prefixes
             "catchAll" $catchAll
             "sharded" $sharded
             "family" $shardsOf
             "consumers" $consumers
             "durable" $durable
             "filter" $filter
             "streamID" ($g.streamID | default $streamID)
             "replicas" ($g.replicas | default $defs.replicas | default $legSink.replicas)
             "ackWait" $ackWait
             "maxAckPending" $maxAckPending
             "maxDeliver" $maxDeliver
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
{{- if and (gt (len $wholeStream) 0) $anyPrefixedEnabled -}}
{{-   fail (printf "connect.sinkGroups: group(s) %v filter the WHOLE stream (%s.>) while prefix-routed groups are enabled — every routed subject would be consumed TWICE (double delivery). Use catchAll: true for a catch-all group, or an explicit filterSubject if you really mean to tap the whole stream." $wholeStream $prefix) -}}
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
{{- /* INV-S4: every configured family must have {0..N-1} plus the isolation
     shard "x" claimed EXACTLY once by enabled shardsOf groups. An unclaimed
     shard means a subject nobody consumes — its messages would park in the
     stream until maxAge silently discards them. */ -}}
{{- range $fam, $fcfg := $families -}}
{{-   $claims := get $famClaims $fam | default dict -}}
{{-   $n := int $fcfg.shards -}}
{{-   range $i := until $n -}}
{{-     if not (hasKey $claims (printf "s%d" $i)) -}}
{{-       fail (printf "connect.sharding.families[%s]: shard %d is not claimed by any ENABLED sinkGroup — enabled shardsOf groups must cover {0..%d} plus \"x\" exactly once (INV-S4); messages published to its subject would never be consumed" $fam $i (sub $n 1)) -}}
{{-     end -}}
{{-   end -}}
{{-   if not (hasKey $claims "sx") -}}
{{-     fail (printf "connect.sharding.families[%s]: the isolation shard \"x\" is not claimed by any ENABLED sinkGroup — add \"x\" to one group's shards list (it receives unparseable-key and cross-shard-rename events; INV-S4)" $fam) -}}
{{-   end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}

{{/*
rrcs.connect.prefixRouting — "true" iff any ENABLED sinkGroup routes by key-prefix.
Gates the forward leg's kv_prefix subject segment (design §3): a pure default /
non-prefix install stays on the legacy <subjectPrefix>.<op> subject and grant.
*/}}
{{- define "rrcs.connect.prefixRouting" -}}
{{- $any := false -}}
{{- range $g := (include "rrcs.connect.sinkGroups" . | fromYamlArray) -}}
{{- if and $g.enabled (or $g.prefixed $g.sharded) -}}{{- $any = true -}}{{- end -}}
{{- end -}}
{{- ternary "true" "false" $any -}}
{{- end -}}

{{/*
rrcs.connect.shardingEnabled — "true" iff connect.sharding.families is non-empty
(subject-sharding v2). Gates the forward leg's shard mapping, its serialized
output variant (threads:1 + max_in_flight:1 + no fallback — ordering links
O-3/O-4), and the nats-init prune gate. Validation of the sharding config lives
in rrcs.connect.sinkGroups (invoked by every consumer of this helper's result).
*/}}
{{- define "rrcs.connect.shardingEnabled" -}}
{{- $s := .Values.connect.sharding | default dict -}}
{{- ternary "true" "false" (gt (len ($s.families | default dict)) 0) -}}
{{- end -}}

{{/*
rrcs.connect.sharding.keyPattern — the RE2 pattern (with a (?P<id>...) named
capture) the forward leg uses to extract the numeric shard key from a kv key.
One default in one place; consumers quote it into Bloblang.
*/}}
{{- define "rrcs.connect.sharding.keyPattern" -}}
{{- $s := .Values.connect.sharding | default dict -}}
{{- $s.keyPattern | default "\\{employee:(?P<id>[0-9]+)\\}" -}}
{{- end -}}

{{/*
rrcs.connect.sharding.keyPatternLit — the keyPattern as a QUOTED BLOBLANG STRING
LITERAL. Bloblang strings are double-quoted with Go-style escapes; sprig's
`quote` is %q-style and already doubles every regex backslash ("\{" becomes
"\\{"), which is exactly the Bloblang (and Go) escaping needed. Do NOT add
another escaping pass on top — that renders "\\\\{" and the regex silently
matches nothing (every key would land on sx).
*/}}
{{- define "rrcs.connect.sharding.keyPatternLit" -}}
{{- include "rrcs.connect.sharding.keyPattern" . | quote -}}
{{- end -}}

{{/*
rrcs.connect.shardMap — JSON object {rawFamily: shardCount} over
connect.sharding.families, e.g. {"lp:m2g":32}. Rendered into the forward leg's
shard mapping as a Bloblang object literal. Keyed by the RAW (colon) family —
NOT the dotted subject token — because Bloblang's .get() treats '.' as a path
separator ("lp.m2g" would be looked up as obj["lp"]["m2g"] and always miss);
the mapping looks it up with the same $p2/$p1 keys as the routeMap. toJson
emits sorted keys => deterministic render.
*/}}
{{- define "rrcs.connect.shardMap" -}}
{{- $m := dict -}}
{{- $s := .Values.connect.sharding | default dict -}}
{{- range $fam, $fcfg := ($s.families | default dict) -}}
{{- $_ := set $m $fam (int $fcfg.shards) -}}
{{- end -}}
{{- $m | toJson -}}
{{- end -}}

{{/*
rrcs.connect.anySinkEnabled — "true" iff at least one sinkGroup is enabled. Used
where the chart previously keyed off connect.sink.enabled (e.g. the shared
observability ConfigMap). Default single-group => equals connect.sink.enabled.
*/}}
{{- define "rrcs.connect.anySinkEnabled" -}}
{{- $any := false -}}
{{- range $g := (include "rrcs.connect.sinkGroups" . | fromYamlArray) -}}
{{- if $g.enabled -}}{{- $any = true -}}{{- end -}}
{{- end -}}
{{- ternary "true" "false" $any -}}
{{- end -}}

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
{{- /* Sharded families are routed prefixes too (v1 §4.4 rule 5: the routeMap
     auto-includes every family — no duplicate declaration). The shard token is
     appended to kv_prefix afterwards by the forward leg's shard mapping. The
     coverage validation in rrcs.connect.sinkGroups guarantees a configured
     family always has enabled consumers, so this is unconditional. */ -}}
{{- $s := .Values.connect.sharding | default dict -}}
{{- range $fam, $fcfg := ($s.families | default dict) -}}
{{- $_ := set $m $fam (replace ":" "." $fam) -}}
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

{{- define "rrcs.nats.credsSecret.publisher" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.publisherSecret is required when external" .Values.nats.external.auth.publisherSecret -}}
{{- else -}}
{{- include "rrcs.name" (dict "root" $ "base" .Values.nats.auth.secrets.publisher) -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.subscriber" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.subscriberSecret is required when external" .Values.nats.external.auth.subscriberSecret -}}
{{- else -}}
{{- include "rrcs.name" (dict "root" $ "base" .Values.nats.auth.secrets.subscriber) -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.admin" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.auth.adminSecret -}}
{{- else -}}
{{- include "rrcs.name" (dict "root" $ "base" .Values.nats.auth.secrets.admin) -}}
{{- end -}}
{{- end -}}

{{/*
rrcs.name — prepend resourcePrefix to a base name. Every chart-rendered
Kubernetes resource name flows through this helper (after subsequent
commits wire it in), so the prefix lives in exactly one place. Returns
the empty string when the base is empty, so optional Secret/URL helpers
that may yield "" do not collapse to the bare prefix.
Usage: {{ include "rrcs.name" (dict "root" $ "base" "writer") }}
*/}}
{{- define "rrcs.name" -}}
{{- if ne .base "" -}}
{{- printf "%s%s" .root.Values.resourcePrefix .base -}}
{{- end -}}
{{- end -}}
