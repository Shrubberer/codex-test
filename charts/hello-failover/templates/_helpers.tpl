{{- define "hello-failover.baseName" -}}
{{- .Values.app.baseName -}}
{{- end -}}

{{- define "hello-failover.commonLabels" -}}
app.kubernetes.io/name: {{ include "hello-failover.baseName" . }}
app.kubernetes.io/part-of: codex-test
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
