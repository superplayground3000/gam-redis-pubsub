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
{{- printf "%s.>" $p -}}
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

{{/*
rrcs.connect.prefixRouting — "true" iff any ENABLED sinkGroup routes by key-prefix.
Gates the forward leg's kv_prefix subject segment (design §3): a pure default /
non-prefix install stays on the legacy <subjectPrefix>.<op> subject and grant.
*/}}
{{- define "rrcs.connect.prefixRouting" -}}
{{- $any := false -}}
{{- range $g := (include "rrcs.connect.sinkGroups" . | fromYamlArray) -}}
{{- if and $g.enabled $g.prefixed -}}{{- $any = true -}}{{- end -}}
{{- end -}}
{{- ternary "true" "false" $any -}}
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
