{{- define "ureka-public-ingress.labels" -}}
app.kubernetes.io/part-of: ureka
app.kubernetes.io/component: public-ingress
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
