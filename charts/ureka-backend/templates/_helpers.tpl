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

{{- /*
Pod·컨테이너 보안 설정. Deployment와 마이그레이션 Job이 같이 쓴다(PSA restricted: 비root, seccomp, 권한 상승 금지, capability 제거, 읽기 전용 루트 FS).
*/ -}}
{{- define "ureka-backend.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "ureka-backend.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- /*
기본 HTTP 헬스 체크를 쓰려면 http 포트(Service)가 있어야 한다. Service를 끄고 헬스 체크를 켤 때는 probes.startup·liveness·readiness를 직접 준다.
*/ -}}
{{- define "ureka-backend.validate" -}}
{{- if and (not .Values.service.enabled) .Values.probes.enabled -}}
{{- if not (and .Values.probes.startup .Values.probes.liveness .Values.probes.readiness) -}}
{{- fail "service.enabled=false이면 probes.enabled=false로 끄거나 probes.startup·liveness·readiness를 모두 직접 지정해야 한다(기본 HTTP 헬스 체크는 http 포트를 쓴다)" -}}
{{- end -}}
{{- end -}}
{{- if .Values.migration.enabled -}}
{{- if not .Values.migration.command -}}
{{- fail "migration.enabled=true이면 migration.command가 필요하다 (예: [python, -m, alembic, upgrade, head])" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ureka-backend.migrationLabels" -}}
app.kubernetes.io/name: {{ include "ureka-backend.name" . }}-migrate
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: migration
app.kubernetes.io/part-of: ureka
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
