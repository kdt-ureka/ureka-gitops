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
  [ "$kinds" = "ExternalSecret Role RoleBinding SecretStore ServiceAccount ValidatingAdmissionPolicy ValidatingAdmissionPolicyBinding " ] ||
    fail "${env}: 예상 밖 종류: ${kinds}"
  role="$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ServiceAccount") | .metadata.annotations."eks.amazonaws.com/role-arn"' -)"
  [ "$role" = "arn:aws:iam::${test_account}:role/ureka-eks-eso-${env}" ] || fail "${env}: 리더 역할 ARN이 다름"
  [ "$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ServiceAccount") | .automountServiceAccountToken' -)" = false ] ||
    fail "${env}: 리더 계정 토큰 자동 마운트가 켜져 있음"
  [ "$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.matchResources.namespaceSelector.matchLabels."kubernetes.io/metadata.name"' - | sort -u)" = "$env" ] ||
    fail "${env}: 리더 보호 정책 범위가 다름"
  [ "$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions[]' - | sort -u)" = Deny ] ||
    fail "${env}: 리더 보호 정책이 Deny가 아님"
  # ESO의 토큰 발급은 이 환경 리더 계정 하나로만(Role 1개·규칙 1개·resourceNames 고정)
  rules="$(printf '%s\n' "$out" | yq ea -N -o=json -I=0 'select(.kind == "Role") | .rules' -)"
  [ "$rules" = '[{"apiGroups":[""],"resources":["serviceaccounts/token"],"resourceNames":["ureka-secrets-reader"],"verbs":["create"]}]' ] ||
    fail "${env}: 리더 토큰 Role 범위가 다름: ${rules}"
  [ "$(printf '%s\n' "$out" | yq ea -N 'select(.kind == "Role") | .metadata.namespace' -)" = "$env" ] || fail "${env}: Role 네임스페이스가 다름"
  subjects="$(printf '%s\n' "$out" | yq ea -N -o=json -I=0 'select(.kind == "RoleBinding") | .subjects' -)"
  [ "$subjects" = '[{"kind":"ServiceAccount","name":"external-secrets","namespace":"external-secrets"}]' ] ||
    fail "${env}: 리더 토큰 RoleBinding 대상이 ESO 컨트롤러가 아님: ${subjects}"
  # 렌더 결과에 들어간 Secret 이름·키 목록
  printf '%s\n' "$out" | yq ea -N 'select(.kind == "ExternalSecret") | .spec.target.name + "/" + .spec.data[].secretKey' - |
    sort -u >"${TMPDIR:-/tmp}/eks-secrets-${env}.keys"
done

# 앱이 읽는 모든 secretKeyRef(이름/키). chat-ai는 optional로 읽는다(dev·prod 모두 켬, 아래 prod 전용 검사).
refs="$( { yq ea -N '.. | select(has("secretKeyRef")) | .secretKeyRef.name + "/" + .secretKeyRef.key' environments/base/ureka-*.yaml
  yq ea -N '.. | select(has("secretKeyRef")) | .secretKeyRef.name + "/" + .secretKeyRef.key' environments/ec2/dev/ingest/*.yaml; } |
  grep -v '^rds-master/' | sort -u)"
[ -n "$refs" ] || fail "secretKeyRef를 하나도 찾지 못함(검사 자체 오류)"
before=$status
while read -r ref; do
  # ureka-auth-mail(SES SMTP)은 prod만 만든다. base env의 참조는 optional이고 dev는 Mailpit이라 없어야 한다(아래 prod 전용 검사).
  case "$ref" in ureka-auth-mail/*) ;; *) grep -qxF "$ref" "${TMPDIR:-/tmp}/eks-secrets-dev.keys" || fail "dev에 ${ref}가 없음" ;; esac
  case "$ref" in ureka-chat-ai/*) continue ;; esac
  grep -qxF "$ref" "${TMPDIR:-/tmp}/eks-secrets-prod.keys" || fail "prod에 ${ref}가 없음"
done <<<"$refs"
[ "$status" != "$before" ] || echo "앱 secretKeyRef $(wc -l <<<"$refs" | tr -d ' ')개 모두 ExternalSecret과 일치"

# prod chat-ai(Gemini 키): prod도 ureka-chat-ai를 만들고, 원격 키는 ureka/eks/prod/chat-ai다(dev·prod 같은 키 값, 원격 비밀은 따로).
for key in AI_MODE AI_API_KEY; do
  grep -qxF "ureka-chat-ai/${key}" "${TMPDIR:-/tmp}/eks-secrets-prod.keys" || fail "prod에 ureka-chat-ai/${key}가 없음"
done
[ "$(render prod | yq ea -N 'select(.kind == "ExternalSecret" and .spec.target.name == "ureka-chat-ai") | .spec.data[].remoteRef.key' - | sort -u)" = "ureka/eks/prod/chat-ai" ] ||
  fail "prod ureka-chat-ai의 원격 키가 ureka/eks/prod/chat-ai가 아님"

# prod 메일(SES SMTP): prod만 ureka-auth-mail을 만들고, 원격 키는 ureka/eks/prod/ses-smtp다. dev는 Mailpit이라 만들지 않는다.
for key in MAIL_USERNAME MAIL_PASSWORD; do
  grep -qxF "ureka-auth-mail/${key}" "${TMPDIR:-/tmp}/eks-secrets-prod.keys" || fail "prod에 ureka-auth-mail/${key}가 없음"
done
grep -q '^ureka-auth-mail/' "${TMPDIR:-/tmp}/eks-secrets-dev.keys" && fail "dev에 ureka-auth-mail이 렌더링됨(dev는 Mailpit)"
[ "$(render prod | yq ea -N 'select(.kind == "ExternalSecret" and .spec.target.name == "ureka-auth-mail") | .spec.data[].remoteRef.key' - | sort -u)" = "ureka/eks/prod/ses-smtp" ] ||
  fail "prod ureka-auth-mail의 원격 키가 ureka/eks/prod/ses-smtp가 아님"
# 메일 자격은 서비스 묶음(app)에 섞지 않는다(시드가 만들지 않는 값, 교체 주기가 다름).
[ "$(yq '.bundles.app | to_entries | map(.value | to_entries | map(.value)) | flatten | map(select(test("^MAIL_"))) | length' "$chart/values.yaml")" = 0 ] ||
  fail "app 묶음에 MAIL_ 속성이 있음"

# 실패해야 하는 경우
render dev --set awsAccountId= >/dev/null 2>&1 && fail "계정 ID 빈칸인데 렌더링됨"
render dev --set awsAccountId=12345 >/dev/null 2>&1 && fail "계정 ID 형식이 틀렸는데 렌더링됨"
helm template x "$chart" --namespace prod -f environments/eks/dev/secrets.yaml --set "awsAccountId=${test_account}" >/dev/null 2>&1 &&
  fail "dev values가 prod 네임스페이스에 렌더링됨"
render dev --set environment=stage --namespace stage >/dev/null 2>&1 && fail "dev/prod 밖 환경이 렌더링됨"

# 등록용 Application: 계정 빈칸. dev는 자동 Sync(selfHeal, prune 끔), prod는 자동 Sync 없음(수동 승인)
for env in dev prod; do
  app="argocd/eks/secrets-${env}-app.yaml"
  [ "$(yq '.spec.source.helm.parameters[] | select(.name == "awsAccountId") | .value' "$app")" = "" ] || fail "${app}: 계정 ID가 Git에 있음"
  [ "$(yq '.spec.destination.namespace' "$app")" = "$env" ] || fail "${app}: 대상 네임스페이스가 다름"
done
[ "$(yq -o=json -I=0 '.spec.syncPolicy.automated' argocd/eks/secrets-dev-app.yaml)" = '{"prune":false,"selfHeal":true}' ] ||
  fail "dev: 자동 Sync는 selfHeal만(prune 끔)이어야 함"
[ "$(yq '.spec.syncPolicy.automated' argocd/eks/secrets-prod-app.yaml)" = null ] ||
  fail "prod: 자동 Sync가 켜져 있음(main 변경이 승인 없이 반영됨)"

# ESO 앱: 버전 고정, 클러스터 범위 기능 끔
eso=argocd/eks/external-secrets-app.yaml
[[ "$(yq '.spec.source.targetRevision' "$eso")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "ESO 차트 버전이 고정되지 않음"
for key in processClusterExternalSecret processClusterStore processClusterGenerator processClusterPushSecret processPushSecret \
  crds.createClusterExternalSecret crds.createClusterSecretStore crds.createClusterGenerator crds.createClusterPushSecret crds.createPushSecret; do
  [ "$(yq ".spec.source.helm.valuesObject.${key}" "$eso")" = false ] || fail "ESO ${key}가 false가 아님"
done
[ "$(yq '.spec.source.helm.valuesObject.serviceAccount.name' "$eso")" = external-secrets ] || fail "ESO 서비스계정 이름이 다름"
[ "$(yq '.spec.destination.namespace' "$eso")/external-secrets" = "$(yq '.esoControllerServiceAccount.namespace + "/" + .esoControllerServiceAccount.name' "$chart/values.yaml")" ] ||
  fail "리더 토큰 허용 주체가 ESO 컨트롤러와 다름"
# 차트 기본의 클러스터 전체 토큰 발급 권한과 edit·admin 합성은 끈다(환경 Role만 남김)
for key in rbac.serviceAccountTokenCreate rbac.aggregateToEdit rbac.aggregateToAdmin; do
  [ "$(yq ".spec.source.helm.valuesObject.${key}" "$eso")" = false ] || fail "ESO ${key}가 false가 아님"
done
[ "$(yq '.spec.syncPolicy.managedNamespaceMetadata.labels."pod-security.kubernetes.io/enforce"' "$eso")" = restricted ] ||
  fail "ESO 네임스페이스가 restricted가 아님"

[ "$status" -eq 0 ] && echo "EKS 비밀 연결 렌더링 검사 통과"
exit "$status"
