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
to: <subjectPrefix>.<op>. The ".${! meta(\"op\") }" suffix is a Redpanda Connect
interpolation evaluated at publish time, not by Helm.
*/}}
{{- define "rrcs.nats.stream.publishSubject" -}}
{{- $p := required "nats.stream.subjectPrefix is required" .Values.nats.stream.subjectPrefix -}}
{{- printf "%s.${! meta(\"op\") }" $p -}}
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
