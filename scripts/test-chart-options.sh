#!/usr/bin/env bash
# charts/ureka-backend 선택 칸 회귀 시험. 클러스터 없이 helm template + yq로 본다(CI Helm 워크플로와 로컬).
# - 선택 칸을 안 쓰면 Deployment·Service만 나오고 command·args·Job이 없다(기존 서비스와 같은 모양).
# - command/args, Service·포트 끄기, 헬스 체크 끄기·직접 지정, 마이그레이션 Job(PreSync)이 각각 의도대로 렌더링된다.
# - 마이그레이션 Job은 Deployment와 같은 이미지·env·보안 설정이고, Pod 라벨이 Service selector에 잡히지 않는다.
# - 잘못된 조합(Service 끄고 기본 HTTP 헬스 체크, 명령 없는 마이그레이션)은 렌더링이 실패한다.
# 기존 서비스 렌더링이 바이트 단위로 같은지는 이 시험이 아니라 PR에서 변경 전후 diff로 확인한다.
set -euo pipefail
cd "$(dirname "$0")/.."

chart=charts/ureka-backend
status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
# 이름, 렌더링 결과, yq 식(참이면 통과)
expect() {
  if [ "$(printf '%s\n' "$2" | yq ea "$3" -)" = true ]; then ok "$1"; else fail "$1 ($3)"; fi
}
render() { helm template t "$chart" -f "$@"; }
kinds() { printf '%s\n' "$1" | yq ea '[.kind] | join(",")' -; }

# 1) 선택 칸 없음: 기존 값 파일 그대로 (environments/kind/ureka-auth.yaml)
out="$(render environments/kind/ureka-auth.yaml)"
[ "$(kinds "$out")" = "Service,Deployment" ] && ok "default: Service+Deployment만" || fail "default: 종류 $(kinds "$out")"
expect "default: command·args 없음" "$out" 'select(.kind=="Deployment") | .spec.template.spec.containers[0] | (has("command") or has("args")) | not'
expect "default: http 포트·HTTP 헬스 체크 3개" "$out" 'select(.kind=="Deployment") | .spec.template.spec.containers[0] | ((.ports[0].name=="http") and (.startupProbe.httpGet.port=="http") and (.livenessProbe.httpGet.path=="/healthz") and (.readinessProbe.httpGet.path=="/readyz"))'

# 2) API + 마이그레이션
out="$(render tests/chart/api-with-migration.yaml)"
[ "$(kinds "$out")" = "Service,Deployment,Job" ] && ok "migration: Service+Deployment+Job" || fail "migration: 종류 $(kinds "$out")"
expect "migration: command·args 그대로" "$out" 'select(.kind=="Deployment") | .spec.template.spec.containers[0] | ((.command | join(" "))=="python -m uvicorn app.main:app --host 0.0.0.0" and (.args | join(" "))=="--port 8080")'
expect "migration: PreSync 훅·BeforeHookCreation" "$out" 'select(.kind=="Job") | ((.metadata.annotations["argocd.argoproj.io/hook"]=="PreSync") and (.metadata.annotations["argocd.argoproj.io/hook-delete-policy"]=="BeforeHookCreation"))'
expect "migration: Job 명령은 alembic, args 없음" "$out" 'select(.kind=="Job") | .spec.template.spec.containers[0] | ((.command | join(" "))=="python -m alembic upgrade head" and (has("args") | not))'
expect "migration: 재시도 0·제한 시간·restartPolicy Never" "$out" 'select(.kind=="Job") | ((.spec.backoffLimit==0) and (.spec.activeDeadlineSeconds==600) and (.spec.template.spec.restartPolicy=="Never"))'
# Deployment와 같아야 하는 것: 이미지, env, Pod·컨테이너 보안 설정, 토큰 미탑재, /tmp
for path in '.image' '.env' '.securityContext' '.volumeMounts'; do
  d="$(printf '%s\n' "$out" | yq ea "select(.kind==\"Deployment\") | .spec.template.spec.containers[0] | ${path}" -o json -)"
  j="$(printf '%s\n' "$out" | yq ea "select(.kind==\"Job\") | .spec.template.spec.containers[0] | ${path}" -o json -)"
  [ "$d" = "$j" ] && [ "$d" != null ] && ok "migration: 컨테이너 ${path} Deployment와 같음" || fail "migration: 컨테이너 ${path} 다름"
done
for path in '.securityContext' '.automountServiceAccountToken' '.volumes'; do
  d="$(printf '%s\n' "$out" | yq ea "select(.kind==\"Deployment\") | .spec.template.spec | ${path}" -o json -)"
  j="$(printf '%s\n' "$out" | yq ea "select(.kind==\"Job\") | .spec.template.spec | ${path}" -o json -)"
  [ "$d" = "$j" ] && [ "$d" != null ] && ok "migration: Pod ${path} Deployment와 같음" || fail "migration: Pod ${path} 다름"
done
sel="$(printf '%s\n' "$out" | yq ea 'select(.kind=="Service") | .spec.selector' -o json -)"
lbl="$(printf '%s\n' "$out" | yq ea 'select(.kind=="Job") | .spec.template.metadata.labels' -o json -)"
if python3 -I -c 'import json,sys; s,l=json.loads(sys.argv[1]),json.loads(sys.argv[2]); sys.exit(0 if s and not all(l.get(k)==v for k,v in s.items()) else 1)' "$sel" "$lbl"; then
  ok "migration: Job Pod는 Service selector에 안 잡힘"
else
  fail "migration: Job Pod가 Service selector에 잡힌다"
fi
expect "migration: Job은 포트·헬스 체크 없음" "$out" 'select(.kind=="Job") | .spec.template.spec.containers[0] | (has("ports") or has("livenessProbe") or has("readinessProbe") or has("startupProbe")) | not'

# 3) worker: Service·포트·헬스 체크 없음
out="$(render tests/chart/worker-no-service.yaml)"
[ "$(kinds "$out")" = "Deployment" ] && ok "worker: Deployment만(Service 없음)" || fail "worker: 종류 $(kinds "$out")"
expect "worker: 포트·헬스 체크 없음, command 있음" "$out" 'select(.kind=="Deployment") | .spec.template.spec.containers[0] | ((has("ports") or has("livenessProbe") or has("readinessProbe") or has("startupProbe") | not) and (.command | join(" "))=="python -m app.worker")'
expect "worker: 보안 설정 유지" "$out" 'select(.kind=="Deployment") | .spec.template.spec | ((.securityContext.runAsNonRoot==true) and (.securityContext.seccompProfile.type=="RuntimeDefault") and (.containers[0].securityContext.readOnlyRootFilesystem==true) and (.containers[0].securityContext.allowPrivilegeEscalation==false) and (.containers[0].securityContext.capabilities.drop[0]=="ALL"))'

# 4) worker: 헬스 체크 직접 지정
out="$(render tests/chart/worker-exec-probe.yaml)"
expect "custom probe: exec 3개, httpGet 없음" "$out" 'select(.kind=="Deployment") | .spec.template.spec.containers[0] | (.startupProbe.exec != null and .livenessProbe.exec != null and .readinessProbe.exec != null and .startupProbe.failureThreshold==12 and ([.startupProbe, .livenessProbe, .readinessProbe] | map(has("httpGet")) | any | not) and (has("ports") | not))'

# 5) 잘못된 조합은 실패해야 한다
must_fail() { # 이름, helm 추가 인자...
  local name="$1"; shift
  if helm template t "$chart" -f tests/chart/worker-no-service.yaml "$@" >/dev/null 2>&1; then fail "${name}: 렌더링이 성공했다"; else ok "${name}: 렌더링 실패"; fi
}
must_fail "Service 끄고 기본 헬스 체크" --set probes.enabled=true
must_fail "Service 끄고 헬스 체크 일부만 지정" --set probes.enabled=true --set probes.liveness.exec.command[0]=true
must_fail "마이그레이션 명령 없음" --set migration.enabled=true
# Service가 없으면 이름 포트(http)가 없다: 직접 지정한 probe가 이름 포트를 쓰면 거부(숫자 포트·exec는 허용)
named=(--set probes.enabled=true)
for p in startup liveness readiness; do named+=(--set "probes.${p}.httpGet.path=/healthz" --set "probes.${p}.httpGet.port=http"); done
must_fail "Service 끄고 probe가 이름 포트(httpGet http)" "${named[@]}"
must_fail "Service 끄고 probe 하나만 이름 포트(tcpSocket http)" -f tests/chart/worker-exec-probe.yaml --set probes.enabled=true --set probes.liveness.tcpSocket.port=http
numeric=(--set probes.enabled=true)
for p in startup liveness readiness; do numeric+=(--set "probes.${p}.tcpSocket.port=8080"); done
if helm template t "$chart" -f tests/chart/worker-no-service.yaml "${numeric[@]}" >/dev/null 2>&1; then ok "Service 끄고 probe 숫자 포트: 허용"; else fail "Service 끄고 probe 숫자 포트가 거부됐다"; fi
# 6) 레지스트리 주입(EC2·EKS): registry를 앞에 붙이고, 필수인데 비면·형식이 틀리면 실패한다
reg=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com
ec2=(-f environments/kind/ureka-frontend.yaml --set image.repository=ureka/frontend --set image.requireRegistry=true)
out="$(helm template t "$chart" "${ec2[@]}" --set "image.registry=${reg}")"
expect "registry: registry/repository:tag@digest" "$out" "select(.kind==\"Deployment\") | .spec.template.spec.containers[0].image | test(\"^${reg//./\\\\.}/ureka/frontend:sha-[0-9a-f]{40}@sha256:[0-9a-f]{64}\$\")"
must_render_fail() { # 이름, helm 추가 인자...
  local name="$1"; shift
  if helm template t "$chart" "$@" >/dev/null 2>&1; then fail "${name}: 렌더링이 성공했다"; else ok "${name}: 렌더링 실패"; fi
}
must_render_fail "registry 필수인데 비어 있음" "${ec2[@]}"
for bad in "https://${reg}" "${reg}/ureka" "${reg}:" "-${reg}" "UPPER.example.com"; do
  must_render_fail "registry 형식 틀림(${bad})" "${ec2[@]}" --set "image.registry=${bad}"
done
must_render_fail "registry와 /로 시작하는 repository" "${ec2[@]}" --set "image.registry=${reg}" --set image.repository=/ureka/frontend

# 7) Ingress: 기본 없음(1·3에서 종류로 확인), 켜면 이 Service의 포트로 넘긴다
ing=(-f environments/kind/ureka-frontend.yaml --set ingress.enabled=true --set ingress.className=traefik)
out="$(helm template t "$chart" "${ing[@]}")"
[ "$(kinds "$out")" = "Service,Deployment,Ingress" ] && ok "ingress: Service+Deployment+Ingress" || fail "ingress: 종류 $(kinds "$out")"
expect "ingress: traefik, / Prefix → ureka-frontend:80, host 없음" "$out" 'select(.kind=="Ingress") | .spec | ((.ingressClassName=="traefik") and (.rules | length==1) and (.rules[0] | has("host") | not) and (.rules[0].http.paths[0].path=="/") and (.rules[0].http.paths[0].pathType=="Prefix") and (.rules[0].http.paths[0].backend.service.name=="ureka-frontend") and (.rules[0].http.paths[0].backend.service.port.number==80))'
out="$(helm template t "$chart" "${ing[@]}" --set ingress.host=dev.example.com)"
expect "ingress: host 지정" "$out" 'select(.kind=="Ingress") | .spec.rules[0].host=="dev.example.com"'
must_render_fail "ingress className 없음" -f environments/kind/ureka-frontend.yaml --set ingress.enabled=true
must_render_fail "ingress인데 Service 끔" -f tests/chart/worker-no-service.yaml --set ingress.enabled=true --set ingress.className=traefik

# 8) 카나리(Argo Rollouts, gitops#47): 켜면 Deployment 대신 Rollout, 나머지 Pod 내용은 Deployment와 같다
base="$(render environments/kind/ureka-auth.yaml)"
out="$(render environments/kind/ureka-auth.yaml -f tests/chart/rollout-canary.yaml)"
[ "$(kinds "$out")" = "Service,Rollout" ] && ok "rollout: Service+Rollout (Deployment 없음)" || fail "rollout: 종류 $(kinds "$out")"
expect "rollout: argoproj.io/v1alpha1, replicas 2, 50% → pause" "$out" 'select(.kind=="Rollout") | ((.apiVersion=="argoproj.io/v1alpha1") and (.spec.replicas==2) and (.spec.strategy.canary.steps[0].setWeight==50) and (.spec.strategy.canary.steps[1] | has("pause")))'
d="$(printf '%s\n' "$base" | yq ea 'select(.kind=="Deployment") | .spec.template' -o json -)"
r="$(printf '%s\n' "$out" | yq ea 'select(.kind=="Rollout") | .spec.template' -o json -)"
[ "$d" = "$r" ] && [ "$d" != null ] && ok "rollout: Pod 템플릿이 Deployment와 같음" || fail "rollout: Pod 템플릿이 Deployment와 다름"
must_render_fail "rollout 켰는데 steps 없음" -f environments/kind/ureka-auth.yaml --set rollout.enabled=true
exit "$status"
