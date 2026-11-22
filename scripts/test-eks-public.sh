#!/usr/bin/env bash
# prod 공개 입구(#64·#81) 매니페스트 시험. 클러스터·AWS 없이 렌더링과 값 대조만 한다(CI Helm 워크플로와 로컬에서 같이 쓴다).
# - 공개 Ingress: 경로 5줄(화면 + API 4줄)만, recommend 없음, prod 밖·주소 없음·검토 안 한 경로는 렌더링 실패
# - ARN·계정 ID를 쓰는 주석(인증서·WAF)이 없다(인증서는 tls.hosts로 찾고 WAF는 IngressClassParams가 이름으로 강제)
# - 컨트롤러 앱: 차트 버전·IAM 정책 파일 버전·WAF 이름·ALB group 이름이 Terraform과 같다
set -euo pipefail
cd "$(dirname "$0")/.."

chart=charts/ureka-public-ingress
values=environments/eks/prod/public-ingress.yaml
app=argocd/eks/aws-load-balancer-controller-app.yaml
status=0
fail() { echo "::error::$*"; status=1; }

helm lint "$chart" -n prod -f "$values" --strict >/dev/null || fail "공개 Ingress helm lint 실패"
rendered="$(helm template t "$chart" -n prod -f "$values")" || { echo "::error::렌더링 실패"; exit 1; }

ingress="$(printf '%s\n' "$rendered" | yq ea 'select(.kind == "Ingress")' -)"
[ "$(printf '%s\n' "$ingress" | yq '.spec.ingressClassName')" = alb ] || fail "ingressClassName이 alb가 아니다"
paths="$(printf '%s\n' "$ingress" | yq -o=tsv '.spec.rules[] | select(.host == "ureka.magonjal.com") | .http.paths[] | [.path, .backend.service.name]' | sort)"
expected="$(printf '%s\n' $'/\tureka-frontend' $'/api/admin\tureka-ops' $'/api/auth\tureka-auth' $'/api/chat\tureka-chat' $'/api/content\tureka-content' | sort)"
[ "$paths" = "$expected" ] || fail "공개 경로가 검토한 5줄과 다르다: ${paths//$'\n'/, }"
if printf '%s\n' "$rendered" | grep -q recommend; then fail "recommend가 공개 매니페스트에 있다"; fi
# 공개 주소는 하위 도메인 하나. apex·www 규칙이나 리다이렉트 동작이 없어야 한다.
[ "$(printf '%s\n' "$ingress" | yq '[.spec.rules[].host] | join(",")')" = "ureka.magonjal.com" ] || fail "호스트 규칙이 ureka.magonjal.com 하나가 아니다"
[ "$(printf '%s\n' "$ingress" | yq '.spec.tls[0].hosts | join(",")')" = "ureka.magonjal.com" ] || fail "인증서 찾기용 tls.hosts가 ureka.magonjal.com 하나가 아니다"
if printf '%s\n' "$ingress" | yq '.metadata.annotations | keys | .[]' | grep -q '^alb.ingress.kubernetes.io/actions\.'; then fail "리다이렉트 등 actions 주석은 쓰지 않는다(www 공개 안 함)"; fi
grep -q 'default     = "ureka.magonjal.com"' infra/environments/eks/public_variables.tf || fail "Terraform public_host 기본값이 Ingress 호스트와 다르다"
# 프런트엔드 SG는 Terraform 소유 SG를 이름으로만(IP가 Git에 남지 않고, 시험자 단계 → open 단계를 Terraform이 정한다).
[ "$(printf '%s\n' "$ingress" | yq '.metadata.annotations["alb.ingress.kubernetes.io/security-groups"]')" = ureka-eks-alb-public ] || fail "ALB SG가 Terraform의 ureka-eks-alb-public이 아니다"
grep -q 'alb_security_group = "${local.name}-alb-public"' infra/environments/eks/public.tf || fail "Terraform ALB SG 이름 규칙이 바뀌었다"
[ "$(printf '%s\n' "$ingress" | yq '.metadata.annotations["alb.ingress.kubernetes.io/manage-backend-security-group-rules"]')" = "true" ] || fail "SG를 직접 지정하면 백엔드 규칙 관리를 켜야 ALB→Pod가 열린다"
for key in certificate-arn wafv2-acl-arn wafv2-acl-name scheme group.name target-type ssl-policy inbound-cidrs; do
  if printf '%s\n' "$ingress" | yq -e ".metadata.annotations | has(\"alb.ingress.kubernetes.io/${key}\")" >/dev/null 2>&1; then
    fail "Ingress 주석 ${key}는 쓰지 않는다(IngressClassParams가 강제하거나 ARN·IP가 Git에 남는다)"
  fi
done
# ALB 허용 NetworkPolicy: 기본은 없음(먼저 넣으면 공개 5서비스가 격리돼 내부 호출이 끊긴다). 켰을 때 모양만 본다.
if printf '%s\n' "$rendered" | grep -q 'kind: NetworkPolicy'; then fail "ALB NetworkPolicy는 prod 내부 허용 정책과 함께 켤 때까지 기본 꺼짐이어야 한다"; fi
netpol="$(helm template t "$chart" -n prod -f "$values" --set albNetworkPolicy.enabled=true | yq ea 'select(.kind == "NetworkPolicy")' -)"
[ "$(printf '%s\n' "$netpol" | yq '.spec.podSelector.matchExpressions[0].values | sort | join(",")')" = "ureka-auth,ureka-chat,ureka-content,ureka-frontend,ureka-ops" ] || fail "ALB 허용 NetworkPolicy 대상이 공개 서비스 5개가 아니다"
[ "$(printf '%s\n' "$netpol" | yq '[.spec.ingress[0].from[].ipBlock.cidr] | join(",")')" = "10.0.0.0/24,10.0.1.0/24" ] || fail "ALB 출발지가 공개 서브넷 2개가 아니다"

# 렌더링이 실패해야 하는 경우
expect_fail() {
  local why="$1"; shift
  if helm template t "$chart" "$@" >/dev/null 2>&1; then fail "렌더링이 실패해야 한다: ${why}"; else echo "ok (거부): ${why}"; fi
}
expect_fail "dev 네임스페이스" -n dev -f "$values"
expect_fail "주소 없음" -n prod
expect_fail "apex 주소" -n prod -f "$values" --set host=magonjal.com
expect_fail "recommend 경로" -n prod -f "$values" --set 'routes[0].path=/api/recommend' --set 'routes[0].service=ureka-recommend'
expect_fail "검토 안 한 경로" -n prod -f "$values" --set 'routes[0].path=/internal'
expect_fail "중복 경로" -n prod -f "$values" --set 'routes[1].path=/api/auth'

# 컨트롤러 앱 ↔ Terraform 값 대조
v() { yq "$1" "$app"; }
version="$(v '.spec.source.targetRevision')"
[ "$version" = 3.6.3 ] || fail "컨트롤러 차트 버전이 검토한 3.6.3이 아니다: ${version}"
[ -f "infra/environments/eks/policies/aws-load-balancer-controller-v${version}.json" ] || fail "차트 ${version}에 맞는 IAM 정책 파일이 없다"
grep -q "aws-load-balancer-controller-v${version}.json" infra/environments/eks/public.tf || fail "Terraform이 차트 ${version}의 정책 파일을 쓰지 않는다"
p='.spec.source.helm.valuesObject'
[ "$(v "$p.ingressClassParams.spec.wafv2AclName")" = ureka-eks-public ] || fail "IngressClassParams WAF 이름이 Terraform ACL(\${local.name}-public)과 다르다"
grep -q 'name        = "${local.name}-public"' infra/environments/eks/public.tf || fail "Terraform WAF 이름 규칙이 바뀌었다"
[ "$(v "$p.ingressClassParams.spec.group.name")" = ureka-prod ] || fail "ALB group 이름이 Terraform 조회 태그와 다르다"
grep -q 'public_alb_group    = "ureka-prod"' infra/environments/eks/public.tf || fail "Terraform ALB group 이름이 바뀌었다"
[ "$(v "$p.ingressClassParams.spec.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]")" = prod ] || fail "alb 클래스가 prod 밖에서도 쓰일 수 있다"
[ "$(v "$p.ingressClassParams.spec.scheme")" = internet-facing ] || fail "scheme"
[ "$(v "$p.ingressClassParams.spec.targetType")" = ip ] || fail "targetType"
[ "$(v "$p.enableServiceMutatorWebhook")" = false ] || fail "Service 웹훅은 꺼야 한다"
[ "$(v "$p.region")" = ap-northeast-2 ] && [ "$(v "$p.clusterName")" = ureka-eks ] || fail "IMDS hop 1이라 region·clusterName을 직접 줘야 한다"
[ "$(v "$p.vpcTags.Stack")" = network ] || fail "VPC를 network 스택 태그로 찾아야 한다"
role="$(v "$p.serviceAccount.annotations[\"eks.amazonaws.com/role-arn\"]")"
[ "$role" = "arn:aws:iam::ACCOUNT_ID_INJECTED_AT_REGISTRATION:role/ureka-eks-aws-load-balancer-controller" ] || fail "역할 ARN 자리표시가 바뀌었다(계정 ID가 Git에 들어갔는지 확인)"
[ "$(v "$p.serviceAccount.name")" = aws-load-balancer-controller ] || fail "ServiceAccount 이름이 IRSA 신뢰 조건과 다르다"
grep -q 'system:serviceaccount:kube-system:aws-load-balancer-controller' infra/environments/eks/public.tf || fail "IRSA 신뢰 ServiceAccount가 바뀌었다"
[ "$(v '.spec.syncPolicy.automated')" = null ] || fail "컨트롤러는 사람이 Sync한다"
[ "$(yq '.spec.syncPolicy.automated' argocd/eks/prod-public-ingress-app.yaml)" = null ] || fail "prod 공개 Ingress는 사람이 Sync한다"
[ "$(yq '.spec.destination.namespace' argocd/eks/prod-public-ingress-app.yaml)" = prod ] || fail "공개 Ingress 대상은 prod"

# 컨트롤러 차트를 실제로 렌더링해 같은 버전 CRD 스키마로 IngressClassParams 등을 검사한다(이름 대조만으로는 자료형 오류를 못 잡는다).
# 차트는 index.yaml에 있는 digest와 같은지 확인한다. 오프라인이면 UREKA_LBC_CHART_TGZ로 미리 받은 파일을 준다.
chart_sha=5c123ddd6a9f847963d98d513551a9d31f3645b663caca5b118c132dd7a49e76
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tgz="${UREKA_LBC_CHART_TGZ:-$work/lbc.tgz}"
if [ -z "${UREKA_LBC_CHART_TGZ:-}" ]; then
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --max-time 60 \
    "https://aws.github.io/eks-charts/aws-load-balancer-controller-${version}.tgz" -o "$tgz" || fail "컨트롤러 차트 내려받기 실패"
fi
if [ -f "$tgz" ] && echo "${chart_sha}  ${tgz}" | shasum -a 256 -c - >/dev/null 2>&1; then
  mkdir -p "$work/chart" && tar -xzf "$tgz" -C "$work/chart"
  yq "$p" "$app" > "$work/values.yaml"
  if helm template aws-load-balancer-controller "$work/chart/aws-load-balancer-controller" -n kube-system -f "$work/values.yaml" > "$work/rendered.yaml"; then
    yq -o=json ea '[.]' "$work/chart/aws-load-balancer-controller/crds/"*.yaml > "$work/crds.json"
    yq -o=json ea '[.] | map(select(. != null)) | map(select(.kind == "List") | .items[]) + map(select(.kind != "List"))' "$work/rendered.yaml" > "$work/objects.json"
    python3 -I tests/schema/check_crd.py "$work/crds.json" "$work/objects.json" || fail "컨트롤러 차트 렌더 결과가 CRD 스키마와 맞지 않는다"
    [ "$(yq ea 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args | contains(["--aws-region=ap-northeast-2", "--aws-vpc-tags=Project=ureka,Stack=network", "--cluster-name=ureka-eks"])' "$work/rendered.yaml")" = true ] || fail "컨트롤러 인자에 region·vpcTags·cluster가 없다"
  else
    fail "컨트롤러 차트 렌더링 실패"
  fi
else
  fail "컨트롤러 차트 digest가 검토한 값과 다르다"
fi

if [ "$status" -eq 0 ]; then echo "공개 입구 매니페스트 시험 통과"; fi
exit "$status"
