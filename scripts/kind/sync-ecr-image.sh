#!/usr/bin/env bash
# ECR에 CI가 게시한 이미지를 kind 로컬 레지스트리(localhost:5001)로 digest 그대로 복사한다.
#
#   scripts/kind/sync-ecr-image.sh <서비스> <커밋 SHA 40자>
#   예: scripts/kind/sync-ecr-image.sh auth 83891abf5633de987a908464bc8cfae249fa3bef
#
# - 내 PC의 조회 전용 SSO 프로필(기본 ureka-readonly, 권한 세트 ReadOnlyAccess)로만 ECR에서 받는다. push 권한은 쓰지 않는다. 클러스터·저장소에는 AWS 자격 증명을 두지 않는다.
# - ECR 토큰은 임시 DOCKER_CONFIG에만 두고 끝나면 지운다.
# - 계정 ID·ECR 주소는 출력하지 않는다(이 저장소는 PUBLIC, 로그를 PR에 붙일 수 있다).
# - 출력한 digest를 environments/kind/<서비스>.yaml에 적는다. CI artifact image-ref.json의 digest와 같아야 한다.
set -euo pipefail

if [ $# -ne 2 ] || ! [[ "$2" =~ ^[0-9a-f]{40}$ ]]; then
  echo "사용법: $0 <auth|chat|content|ops|recommend|frontend|ingest> <커밋 SHA 40자>" >&2
  exit 2
fi
service="$1"
tag="sha-$2"
profile="${AWS_PROFILE:-ureka-readonly}"
region="${AWS_REGION:-ap-northeast-2}"
dest="localhost:5001/ureka/${service}:${tag}"

command -v crane >/dev/null || { echo "crane이 필요합니다: brew install crane" >&2; exit 1; }

account="$(aws sts get-caller-identity --profile "$profile" --query Account --output text)"
registry="${account}.dkr.ecr.${region}.amazonaws.com"
src="${registry}/ureka/${service}:${tag}"

DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
# crane 출력은 임시 로그에만 남기고, 실패하면 계정 ID를 가려서 보여 준다
log="${DOCKER_CONFIG}/crane.log"
fail() {
  echo "$1 실패. crane 로그(계정 ID 가림):" >&2
  sed -E 's/[0-9]{12}/<ACCOUNT_ID>/g' "$log" >&2
  exit 1
}

aws ecr get-login-password --profile "$profile" --region "$region" |
  crane auth login "$registry" -u AWS --password-stdin >"$log" 2>&1 || fail "ECR 로그인"
src_digest="$(crane digest "$src" 2>>"$log")" || fail "ECR digest 조회(이미지가 없거나 권한 없음)"
crane copy "$src" "$dest" >>"$log" 2>&1 || fail "복사"
dest_digest="$(crane digest --insecure "$dest" 2>>"$log")" || fail "로컬 레지스트리 digest 조회(scripts/kind/up.sh 실행 여부)"

if [ "$src_digest" != "$dest_digest" ]; then
  echo "digest가 다릅니다: ECR ${src_digest} / 로컬 ${dest_digest}" >&2
  exit 1
fi
echo "복사 완료: ureka/${service}:${tag}"
echo "digest: ${dest_digest}"
