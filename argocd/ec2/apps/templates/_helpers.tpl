{{- define "ec2apps.registry" -}}
{{- $r := required "ecrRegistry is required (scripts/ec2/up.sh injects it; never write it in Git)" .Values.ecrRegistry -}}
{{- if not (regexMatch "^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com$" $r) -}}
{{- fail "ecrRegistry must look like <12-digit account>.dkr.ecr.<region>.amazonaws.com" -}}
{{- end -}}
{{- $r -}}
{{- end -}}

{{- define "ec2apps.syncPolicy" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  retry:
    limit: 5
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 3m
{{- end -}}
