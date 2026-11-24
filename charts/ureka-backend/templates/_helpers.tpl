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
{{- /* registry가 있으면 앞에 붙인다(EC2·EKS: ECR 주소는 계정 ID가 있어 Git에 쓰지 않고 배포할 때 넣는다). */ -}}
{{- $registry := .Values.image.registry | default "" -}}
{{- if $registry -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$" $registry) -}}
{{- fail "values.image.registry must be a host[:port] without scheme or path (e.g. <account>.dkr.ecr.<region>.amazonaws.com)" -}}
{{- end -}}
{{- if hasPrefix "/" $repo -}}
{{- fail "values.image.repository must not start with / when image.registry is set" -}}
{{- end -}}
{{- $repo = printf "%s/%s" $registry $repo -}}
{{- else if .Values.image.requireRegistry -}}
{{- fail "values.image.registry is required here (image.requireRegistry=true). It is injected at deploy time, never written in Git." -}}
{{- end -}}
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
{{- /* Service를 끄면 컨테이너에 이름 붙은 포트가 없다. port: http 같은 이름 포트는 probe가 항상 실패하므로 막는다(exec 또는 숫자 포트를 쓴다). */ -}}
{{- range $probe := list "startup" "liveness" "readiness" -}}
{{- $spec := index $.Values.probes $probe | default dict -}}
{{- range $handler := list "httpGet" "tcpSocket" -}}
{{- $h := index $spec $handler -}}
{{- if and $h (kindIs "string" $h.port) -}}
{{- fail (printf "service.enabled=false이면 컨테이너 포트 이름이 없다: probes.%s.%s.port에 이름(%s) 대신 숫자 포트를 쓰거나 exec를 쓴다" $probe $handler $h.port) -}}
{{- end -}}
{{- end -}}
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

{{- define "ureka-backend.validateMetrics" -}}
{{- if .Values.metrics.enabled -}}
{{- if not (and .Values.service.enabled (or (eq .Values.name "ureka-auth") (eq .Values.name "ureka-content"))) -}}
{{- fail "metrics.enabled supports only auth/content HTTP workloads" -}}
{{- end -}}
{{- range .Values.env -}}
{{- if or (eq .name "SPRING_PROFILES_INCLUDE") (eq .name "METRICS_SCRAPE_TOKEN") -}}
{{- fail "metrics.enabled manages SPRING_PROFILES_INCLUDE and METRICS_SCRAPE_TOKEN" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
컨테이너 env 목록. env(목록)에 envOverrides(이름 → 문자열 값)를 겹친다. Deployment·Rollout·마이그레이션 Job이 같이 쓴다.
Helm은 목록을 합치지 못하고 통째로 바꾸므로, 환경 values(예: EKS prod)가 base env 전체를 복사하지 않고 다른 값만 바꾸게 한다.
- 순서·나머지 항목은 그대로다($(DB_PASSWORD) 같은 치환 순서가 유지된다).
- env에 없는 이름은 실패한다(오타로 조용히 무시되지 않게). 새 변수는 base env에 추가한다.
- Secret 참조(valueFrom) 항목은 바꿀 수 없다(비밀값을 평문 values로 덮어쓰지 않게). 값은 문자열만 받는다.
- requiredSecretEnv(이름 목록)에 적은 항목은 이 환경에서 Secret 참조를 필수로 바꾼다(optional=false). Secret·키가 없으면 Pod가 시작되지 않는다.
  base env는 Mailpit 같은 선택 구성을 위해 optional=true로 두고, 실제 서비스(EKS prod)만 필수로 올린다. env에 없거나 Secret 참조가 아닌 이름은 실패한다.
*/ -}}
{{- define "ureka-backend.env" -}}
{{- $overrides := .Values.envOverrides | default dict -}}
{{- $names := list -}}
{{- $out := list -}}
{{- $required := .Values.requiredSecretEnv | default list -}}
{{- range .Values.env -}}
{{- $item := . -}}
{{- $names = append $names .name -}}
{{- if hasKey $overrides .name -}}
{{- if hasKey . "valueFrom" -}}
{{- fail (printf "envOverrides.%s: Secret 참조(valueFrom) 항목은 덮어쓸 수 없다" .name) -}}
{{- end -}}
{{- $value := index $overrides .name -}}
{{- if not (kindIs "string" $value) -}}
{{- fail (printf "envOverrides.%s: 값은 문자열이어야 한다(숫자·불리언은 따옴표로 감싼다)" .name) -}}
{{- end -}}
{{- $item = dict "name" .name "value" $value -}}
{{- end -}}
{{- if has .name $required -}}
{{- if not (and (hasKey . "valueFrom") (hasKey .valueFrom "secretKeyRef")) -}}
{{- fail (printf "requiredSecretEnv.%s: Secret 참조(valueFrom.secretKeyRef) 항목만 필수로 바꿀 수 있다" .name) -}}
{{- end -}}
{{- $item = deepCopy $item -}}
{{- $unused := set $item.valueFrom.secretKeyRef "optional" false -}}
{{- end -}}
{{- $out = append $out $item -}}
{{- end -}}
{{- range $required -}}
{{- if not (has . $names) -}}
{{- fail (printf "requiredSecretEnv.%s: env에 없는 이름이다" .) -}}
{{- end -}}
{{- end -}}
{{- range $name, $_ := $overrides -}}
{{- if not (has $name $names) -}}
{{- fail (printf "envOverrides.%s: env에 없는 이름이다(새 변수는 base env에 추가한다)" $name) -}}
{{- end -}}
{{- end -}}
{{- if $out -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}
