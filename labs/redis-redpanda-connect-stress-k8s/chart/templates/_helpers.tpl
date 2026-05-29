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
