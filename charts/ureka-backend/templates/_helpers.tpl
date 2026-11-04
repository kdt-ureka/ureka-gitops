{{- define "ureka-backend.name" -}}
{{- required "values.name is required (e.g. ureka-auth)" .Values.name -}}
{{- end -}}

{{- define "ureka-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ureka-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ureka-backend.labels" -}}
{{ include "ureka-backend.selectorLabels" . }}
app.kubernetes.io/part-of: ureka
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "ureka-backend.image" -}}
{{- $repo := required "values.image.repository is required" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{ $repo }}@{{ .Values.image.digest }}
{{- else -}}
{{ $repo }}:{{ required "values.image.tag or values.image.digest is required" .Values.image.tag }}
{{- end -}}
{{- end -}}
