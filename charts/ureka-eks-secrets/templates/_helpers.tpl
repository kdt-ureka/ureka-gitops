{{- define "ekssecrets.env" -}}
{{- $env := required "environment(dev|prod)가 필요합니다" .Values.environment -}}
{{- if not (has $env (list "dev" "prod")) -}}{{- fail "environment는 dev 또는 prod만 됩니다" -}}{{- end -}}
{{- if ne .Release.Namespace $env -}}{{- fail "릴리스 네임스페이스와 environment가 같아야 합니다(dev 리더가 prod에 놓이지 않게)" -}}{{- end -}}
{{- $env -}}
{{- end -}}

{{- define "ekssecrets.account" -}}
{{- $id := toString .Values.awsAccountId -}}
{{- if not (regexMatch "^[0-9]{12}$" $id) -}}{{- fail "awsAccountId(12자리)가 비었습니다. Git에 쓰지 말고 scripts/eks/register_secrets_app.py로 등록하세요" -}}{{- end -}}
{{- $id -}}
{{- end -}}

{{- define "ekssecrets.labels" -}}
app.kubernetes.io/part-of: ureka
app.kubernetes.io/managed-by: {{ .Release.Service }}
ureka.io/component: secrets
{{- end -}}
