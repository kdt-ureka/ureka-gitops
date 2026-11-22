#!/usr/bin/env bash
# EKS 비밀 연결(#63) 렌더링 검사. 클러스터·AWS 없이 helm·yq만 쓴다.
# - 앱 values·ingest가 읽는 모든 secretKeyRef(이름·키)를 dev ExternalSecret이 만드는지(앱 values를 바꾸지 않기 위해)
# - 원격 키가 자기 환경 경로(ureka/eks/<env>/…)뿐인지, 클러스터 범위 저장소가 없는지, 리더 보호 정책이 있는지
# - 계정 ID 빈칸·네임스페이스 불일치·잘못된 환경은 렌더링이 실패하는지
# - ESO 앱 차트 버전 고정·클러스터 범위 기능 꺼짐, 등록용 Application의 계정 빈칸
set -euo pipefail
cd "$(dirname "$0")/.."
chart=charts/ureka-eks-secrets
test_account=123456789012
status=0
fail() { echo "::error::$*"; status=1; }

render() { # env [추가 인자]
  local env="$1"; shift
  helm template "ureka-eks-secrets-${env}" "$chart" --namespace "$env" \
    -f "environments/eks/${env}/secrets.yaml" --set "awsAccountId=${test_account}" "$@"
}

helm lint "$chart" --namespace dev -f environments/eks/dev/secrets.yaml --set "awsAccountId=${test_account}" --strict >/dev/null ||
  fail "helm lint 실패"

for env in dev prod; do
  out="$(render "$env")" || { fail "${env} 렌더링 실패"; continue; }
  other=$([ "$env" = dev ] && echo prod || echo dev)
  # 원격 키는 자기 환경 경로만
  bad_keys="$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ExternalSecret") | .spec.data[].remoteRef.key' - |
    grep -v "^ureka/eks/${env}/" || true)"
  [ -z "$bad_keys" ] || fail "${env}: 다른 경로를 읽는 ExternalSecret: ${bad_keys}"
  printf '%s\n' "$out" | grep -q "ureka/eks/${other}/" && fail "${env}: ${other} 경로가 렌더링됨"
  # 네임스페이스 SecretStore만, 리더 역할 이름은 자기 환경
  kinds="$(printf '%s\n' "$out" | yq ea -N 'select(.kind != null) | .kind' - | sort -u | tr '\n' ' ')"
  [ "$kinds" = "ExternalSecret SecretStore ServiceAccount ValidatingAdmissionPolicy ValidatingAdmissionPolicyBinding " ] ||
    fail "${env}: 예상 밖 종류: ${kinds}"
  role="$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ServiceAccount") | .metadata.annotations."eks.amazonaws.com/role-arn"' -)"
  [ "$role" = "arn:aws:iam::${test_account}:role/ureka-eks-eso-${env}" ] || fail "${env}: 리더 역할 ARN이 다름"
  [ "$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ServiceAccount") | .automountServiceAccountToken' -)" = false ] ||
    fail "${env}: 리더 계정 토큰 자동 마운트가 켜져 있음"
  [ "$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.matchResources.namespaceSelector.matchLabels."kubernetes.io/metadata.name"' - | sort -u)" = "$env" ] ||
    fail "${env}: 리더 보호 정책 범위가 다름"
  [ "$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions[]' - | sort -u)" = Deny ] ||
    fail "${env}: 리더 보호 정책이 Deny가 아님"
  # 렌더 결과에 들어간 Secret 이름·키 목록
  printf '%s\n' "$out" | yq ea -N 'select(.kind == "ExternalSecret") | .spec.target.name + "/" + .spec.data[].secretKey' - |
    sort -u >"${TMPDIR:-/tmp}/eks-secrets-${env}.keys"
done

# 앱이 읽는 모든 secretKeyRef(이름/키). chat-ai는 prod에서 아직 끔(앱은 optional로 읽는다).
refs="$( { yq ea -N '.. | select(has("secretKeyRef")) | .secretKeyRef.name + "/" + .secretKeyRef.key' environments/base/ureka-*.yaml
  yq ea -N '.. | select(has("secretKeyRef")) | .secretKeyRef.name + "/" + .secretKeyRef.key' environments/ec2/dev/ingest/*.yaml; } |
  grep -v '^rds-master/' | sort -u)"
[ -n "$refs" ] || fail "secretKeyRef를 하나도 찾지 못함(검사 자체 오류)"
before=$status
while read -r ref; do
  grep -qxF "$ref" "${TMPDIR:-/tmp}/eks-secrets-dev.keys" || fail "dev에 ${ref}가 없음"
  case "$ref" in ureka-chat-ai/*) continue ;; esac
  grep -qxF "$ref" "${TMPDIR:-/tmp}/eks-secrets-prod.keys" || fail "prod에 ${ref}가 없음"
done <<<"$refs"
[ "$status" != "$before" ] || echo "앱 secretKeyRef $(wc -l <<<"$refs" | tr -d ' ')개 모두 ExternalSecret과 일치"

# 실패해야 하는 경우
render dev --set awsAccountId= >/dev/null 2>&1 && fail "계정 ID 빈칸인데 렌더링됨"
render dev --set awsAccountId=12345 >/dev/null 2>&1 && fail "계정 ID 형식이 틀렸는데 렌더링됨"
helm template x "$chart" --namespace prod -f environments/eks/dev/secrets.yaml --set "awsAccountId=${test_account}" >/dev/null 2>&1 &&
  fail "dev values가 prod 네임스페이스에 렌더링됨"
render dev --set environment=stage --namespace stage >/dev/null 2>&1 && fail "dev/prod 밖 환경이 렌더링됨"

# 등록용 Application: 계정 빈칸, prune 끔
for env in dev prod; do
  app="argocd/eks/secrets-${env}-app.yaml"
  [ "$(yq '.spec.source.helm.parameters[] | select(.name == "awsAccountId") | .value' "$app")" = "" ] || fail "${app}: 계정 ID가 Git에 있음"
  [ "$(yq '.spec.destination.namespace' "$app")" = "$env" ] || fail "${app}: 대상 네임스페이스가 다름"
  [ "$(yq '.spec.syncPolicy.automated.prune' "$app")" = false ] || fail "${app}: prune이 켜져 있음(Secret 삭제 위험)"
done

# ESO 앱: 버전 고정, 클러스터 범위 기능 끔
eso=argocd/eks/external-secrets-app.yaml
[[ "$(yq '.spec.source.targetRevision' "$eso")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "ESO 차트 버전이 고정되지 않음"
for key in processClusterExternalSecret processClusterStore processClusterGenerator processClusterPushSecret processPushSecret \
  crds.createClusterExternalSecret crds.createClusterSecretStore crds.createClusterGenerator crds.createClusterPushSecret crds.createPushSecret; do
  [ "$(yq ".spec.source.helm.valuesObject.${key}" "$eso")" = false ] || fail "ESO ${key}가 false가 아님"
done
[ "$(yq '.spec.source.helm.valuesObject.serviceAccount.name' "$eso")" = external-secrets ] || fail "ESO 서비스계정 이름이 다름"
[ "system:serviceaccount:$(yq '.spec.destination.namespace' "$eso"):external-secrets" = "$(yq '.esoControllerUser' "$chart/values.yaml")" ] ||
  fail "리더 토큰 허용 주체가 ESO 컨트롤러와 다름"
[ "$(yq '.spec.syncPolicy.managedNamespaceMetadata.labels."pod-security.kubernetes.io/enforce"' "$eso")" = restricted ] ||
  fail "ESO 네임스페이스가 restricted가 아님"

[ "$status" -eq 0 ] && echo "EKS 비밀 연결 렌더링 검사 통과"
exit "$status"
