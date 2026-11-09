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

{{- /*
이미지 참조. digest가 있으면 digest로 고정한다(태그를 다시 밀어도 배포가 바뀌지 않는다).
tag도 함께 있으면 사람이 읽기 쉽게 repository:tag@digest로 쓴다. 이때도 실제로 받는 것은 digest다.
*/ -}}
{{- define "ureka-backend.image" -}}
{{- $repo := required "values.image.repository is required" .Values.image.repository -}}
{{- $tag := .Values.image.tag -}}
{{- $digest := .Values.image.digest -}}
{{- if $digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail "values.image.digest must be sha256:<64 hex>" -}}
{{- end -}}
{{- if $tag -}}
{{ $repo }}:{{ $tag }}@{{ $digest }}
{{- else -}}
{{ $repo }}@{{ $digest }}
{{- end -}}
{{- else -}}
{{ $repo }}:{{ required "values.image.tag or values.image.digest is required" $tag }}
{{- end -}}
{{- end -}}
