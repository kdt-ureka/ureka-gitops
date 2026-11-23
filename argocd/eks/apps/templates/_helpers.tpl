{{- define "eksapps.registry" -}}
{{- $r := required "ecrRegistry is required (scripts/eks/register_root_app.py injects it; never write it in Git)" .Values.ecrRegistry -}}
{{- if not (regexMatch "^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com$" $r) -}}
{{- fail "ecrRegistry must look like <12-digit account>.dkr.ecr.<region>.amazonaws.com" -}}
{{- end -}}
{{- $r -}}
{{- end -}}

{{- /* 환경 이름 검사: dev·prod만. 네임스페이스·프로젝트·values 경로가 모두 이 이름에서 나온다. */ -}}
{{- define "eksapps.envName" -}}
{{- if not (has .name (list "dev" "prod")) -}}
{{- fail (printf "environments[].name은 dev 또는 prod만 된다: %s" .name) -}}
{{- end -}}
{{- .name -}}
{{- end -}}

{{- define "eksapps.retry" -}}
retry:
  limit: 5
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 3m
{{- end -}}

{{- /* 업무 앱 동기화. autoSync=false(prod)면 automated를 넣지 않는다: Git이 바뀌면 OutOfSync로 보이고 사람이 Sync해야 반영된다. */ -}}
{{- define "eksapps.syncPolicy" -}}
syncPolicy:
  {{- if .autoSync }}
  automated:
    prune: true
    selfHeal: true
  {{- end }}
  {{- include "eksapps.retry" . | nindent 2 }}
{{- end -}}
