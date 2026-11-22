#!/usr/bin/env bash
# EKS dev·prod 네임스페이스(#62)를 임시 kind 클러스터에 실제로 적용해 거부 동작을 본다. 로컬 전용(CI 아님).
# - Pod Security restricted: 특권·hostPath·hostNetwork·root 실행 Pod 거부, 지키는 Pod 허용
# - LimitRange: 기본값 주입, 최대 초과 거부 / ResourceQuota: LB·NodePort·PVC(prod) 거부, 메모리 누적 초과 거부
# - RBAC: kubectl auth can-i로 그룹별 허용·거부 표
# 사용: kind create cluster --name ureka-ns62-test --kubeconfig <임시 파일>
#       KUBECONFIG=<임시 파일> bash scripts/test-eks-namespaces-kind.sh
#       kind delete cluster --name ureka-ns62-test --kubeconfig <임시 파일>
# 현재 context가 kind-로 시작하지 않으면 멈춘다(EKS·EC2·기존 kind 개발 클러스터에 실수로 적용하지 않게 이름도 고정).
set -euo pipefail
cd "$(dirname "$0")/.."

ctx="$(kubectl config current-context)"
[ "$ctx" = "kind-ureka-ns62-test" ] || { echo "context가 kind-ureka-ns62-test가 아니다: ${ctx}" >&2; exit 2; }
k() { kubectl --context "$ctx" "$@"; }

pass=0; fail=0
ok() { echo "  통과: $*"; pass=$((pass + 1)); }
ng() { echo "  실패: $*"; fail=$((fail + 1)); }
# expect_reject <설명> <찾을 문구> -- 명령...
expect_reject() {
  local desc="$1" needle="$2"; shift 3
  local out
  if out="$("$@" 2>&1)"; then ng "${desc}: 허용됐다"; return; fi
  if grep -q -- "$needle" <<<"$out"; then ok "$desc"; else ng "${desc}: 다른 이유로 거부: ${out}"; fi
}
expect_allow() {
  local desc="$1"; shift 2
  local out
  if out="$("$@" 2>&1)"; then ok "$desc"; else ng "${desc}: ${out}"; fi
}

echo "== 적용"
# can-i가 Rollout 자원을 찾도록 시험용 최소 CRD(실제 Argo Rollouts 설치 아님)
k apply --server-side -f tests/namespaces/kind-rollout-crd.yaml >/dev/null
k wait --for=condition=Established crd/rollouts.argoproj.io --timeout=60s >/dev/null
for env in dev prod; do
  kubectl kustomize "environments/eks/${env}/namespace" | k apply --server-side -f - >/dev/null
done
k get ns dev prod -o custom-columns=NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\\.kubernetes\\.io/enforce

pod() { # pod <name> <ns> <추가 spec yaml(컨테이너 securityContext 등)>
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $2}
spec:
$3
EOF
}
restricted_container='  containers:
    - name: c
      image: registry.k8s.io/pause:3.10
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        seccompProfile: {type: RuntimeDefault}'

echo "== Pod Security restricted"
for env in dev prod; do
  expect_allow "${env}: restricted를 지키는 Pod" -- k apply --dry-run=server -f - <<<"$(pod ok "$env" "$restricted_container")"
  expect_reject "${env}: privileged Pod" 'violates PodSecurity "restricted' -- k apply --dry-run=server -f - <<<"$(pod p "$env" '  containers:
    - name: c
      image: registry.k8s.io/pause:3.10
      securityContext: {privileged: true}')"
  expect_reject "${env}: hostPath·hostNetwork Pod" 'violates PodSecurity "restricted' -- k apply --dry-run=server -f - <<<"$(pod h "$env" "  hostNetwork: true
  volumes: [{name: v, hostPath: {path: /}}]
${restricted_container}")"
  expect_reject "${env}: securityContext 없는 Pod(root 가능)" 'violates PodSecurity "restricted' -- k apply --dry-run=server -f - <<<"$(pod r "$env" '  containers:
    - name: c
      image: registry.k8s.io/pause:3.10')"
done

echo "== LimitRange"
for env in dev prod; do
  got="$(k apply --dry-run=server -o jsonpath='{.spec.containers[0].resources}' -f - <<<"$(pod d "$env" "$restricted_container")")"
  if [ "$got" = '{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}' ]; then
    ok "${env}: resources 없는 컨테이너에 기본값 주입"
  else ng "${env}: 기본값이 다르다: ${got}"; fi
  expect_reject "${env}: 메모리 상한 2Gi 컨테이너" 'maximum memory usage per Container is 1Gi' -- k apply --dry-run=server -f - <<<"$(pod big "$env" "${restricted_container}
      resources: {limits: {cpu: 500m, memory: 2Gi}}")"
done

echo "== ResourceQuota"
svc() { printf 'apiVersion: v1\nkind: Service\nmetadata: {name: s, namespace: %s}\nspec: {type: %s, ports: [{port: 80}]}\n' "$1" "$2"; }
for env in dev prod; do
  expect_reject "${env}: LoadBalancer Service" 'exceeded quota' -- k apply --dry-run=server -f - <<<"$(svc "$env" LoadBalancer)"
  expect_reject "${env}: NodePort Service" 'exceeded quota' -- k apply --dry-run=server -f - <<<"$(svc "$env" NodePort)"
  expect_allow "${env}: ClusterIP Service" -- k apply --dry-run=server -f - <<<"$(svc "$env" ClusterIP)"
done
pvc='apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: v, namespace: NS}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}'
expect_reject "prod: PVC" 'exceeded quota' -- k apply --dry-run=server -f - <<<"${pvc//NS/prod}"
expect_allow "dev: PVC 1Gi(ingest용)" -- k apply --dry-run=server -f - <<<"${pvc//NS/dev}"
# prod 메모리 요청 5Gi: 1Gi 요청 Pod 5개는 들어가고 6번째는 거부(실제 생성, 끝나면 지운다).
for i in 1 2 3 4 5; do
  k apply -f - >/dev/null <<<"$(pod "q$i" prod "${restricted_container}
      resources: {requests: {cpu: 50m, memory: 1Gi}, limits: {cpu: 100m, memory: 1Gi}}")"
done
expect_reject "prod: 메모리 요청 누적 6Gi" 'exceeded quota: prod-quota' -- k apply -f - <<<"$(pod q6 prod "${restricted_container}
      resources: {requests: {cpu: 50m, memory: 1Gi}, limits: {cpu: 100m, memory: 1Gi}}")"
k -n prod delete pod q1 q2 q3 q4 q5 --wait=false >/dev/null

echo "== RBAC (kubectl auth can-i)"
# can <기대 yes|no> <그룹> <ns> <동사> <자원> [추가 인자]
can() {
  local want="$1" group="$2" ns="$3"; shift 3
  local got
  got="$(k auth can-i "$@" -n "$ns" --as "tester" --as-group "$group" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then ok "${group} ${ns}: $* → ${got}"; else ng "${group} ${ns}: $* → ${got:-오류} (기대 ${want})"; fi
}
V=ureka-prod-viewers
can yes "$V" prod get pods
can yes "$V" prod list rollouts.argoproj.io
can yes "$V" prod watch events
can yes "$V" prod get configmaps
can no "$V" prod get secrets
can no "$V" prod get serviceaccounts
can no "$V" prod create serviceaccounts --subresource=token
can no "$V" prod get pods --subresource=log
can no "$V" prod create pods --subresource=exec
can no "$V" prod create pods --subresource=portforward
can no "$V" prod patch pods --subresource=ephemeralcontainers
can no "$V" prod delete pods
can no "$V" prod get rollouts.argoproj.io/ureka-auth --subresource=status
can no "$V" prod patch rollouts.argoproj.io/ureka-auth
can no "$V" prod patch rollouts.argoproj.io/ureka-auth --subresource=status
can no "$V" prod patch deployments.apps
can no "$V" dev get pods
can no "$V" prod create rolebindings.rbac.authorization.k8s.io
# 교차 검토 필수 1: 카나리 운영자 그룹은 Kubernetes 권한이 없다(승격·중단은 #43 Argo CD 권한).
O=ureka-prod-rollout-operators
can no "$O" prod get pods
can no "$O" prod patch rollouts.argoproj.io/ureka-auth
can no "$O" prod patch rollouts.argoproj.io/ureka-auth --subresource=status
can no "$O" prod get pods --subresource=log

echo "== 사람 그룹의 Rollout 직접 변경 거부(실제 patch, 시험용 Rollout 객체)"
printf 'apiVersion: argoproj.io/v1alpha1\nkind: Rollout\nmetadata: {name: ureka-auth, namespace: prod}\nspec: {paused: true}\n' | k apply -f - >/dev/null
for g in "$V" "$O"; do
  expect_reject "${g}: ureka-auth 이미지 변경(spec patch)" 'forbidden' -- k -n prod patch rollout ureka-auth --type merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"c","image":"x"}]}}}}' --as tester --as-group "$g"
  expect_reject "${g}: ureka-auth 승격(spec patch)" 'forbidden' -- k -n prod patch rollout ureka-auth --type merge -p '{"spec":{"paused":false}}' --as tester --as-group "$g"
  expect_reject "${g}: ureka-auth 중단(status patch)" 'forbidden' -- k -n prod patch rollout ureka-auth --subresource=status --type merge -p '{"status":{"abort":true}}' --as tester --as-group "$g"
done
k -n prod delete rollout ureka-auth >/dev/null

echo "== 결과: 통과 ${pass}, 실패 ${fail}"
[ "$fail" -eq 0 ]
