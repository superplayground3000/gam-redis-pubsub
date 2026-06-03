{{/*
rrcs.image — join the global registry prefix with a per-image ref.
Usage: {{ include "rrcs.image" (dict "root" $ "ref" .Values.writer.image) }}
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
nats://nats:{{ .Values.nats.clientPort }}
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
http://nats:{{ .Values.nats.monitorPort }}
{{- end -}}
{{- end -}}

{{/*
rrcs.redis.central.url / rrcs.redis.region.url — connection URL form.
*/}}
{{- define "rrcs.redis.central.url" -}}
{{- if .Values.redis.central.external.enabled -}}
{{- required "redis.central.external.url is required when enabled" .Values.redis.central.external.url -}}
{{- else -}}
redis://redis-central:6379
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.url" -}}
{{- if .Values.redis.region.external.enabled -}}
{{- required "redis.region.external.url is required when enabled" .Values.redis.region.external.url -}}
{{- else -}}
redis://redis-region:6379
{{- end -}}
{{- end -}}

{{/*
rrcs.redis.{central,region}.hostPort — host:port form (URL scheme stripped),
for the writer's REDIS_ADDR env, the collector's --redis-* flags, and the
init-container redis-cli ping.
*/}}
{{- define "rrcs.redis.central.hostPort" -}}
{{- $u := include "rrcs.redis.central.url" . -}}
{{- regexReplaceAll "^rediss?://" $u "" -}}
{{- end -}}

{{- define "rrcs.redis.region.hostPort" -}}
{{- $u := include "rrcs.redis.region.url" . -}}
{{- regexReplaceAll "^rediss?://" $u "" -}}
{{- end -}}

{{/*
rrcs.nats.credsSecret.{publisher,subscriber,admin} — Secret name to mount.
Bundled: the chart-rendered Secret name from values. External: user-supplied
Secret name (may be empty for admin, in which case purge is skipped).
*/}}
{{- define "rrcs.nats.credsSecret.publisher" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.publisherSecret is required when external" .Values.nats.external.auth.publisherSecret -}}
{{- else -}}
{{- .Values.nats.auth.secrets.publisher -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.subscriber" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.subscriberSecret is required when external" .Values.nats.external.auth.subscriberSecret -}}
{{- else -}}
{{- .Values.nats.auth.secrets.subscriber -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.admin" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.auth.adminSecret -}}
{{- else -}}
{{- .Values.nats.auth.secrets.admin -}}
{{- end -}}
{{- end -}}
