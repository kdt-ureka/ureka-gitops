#!/usr/bin/env bash
# ECR에 CI가 게시한 이미지를 kind 로컬 레지스트리(localhost:5001)로 digest 그대로 복사한다.
#
#   scripts/kind/sync-ecr-image.sh <서비스> <커밋 SHA 40자>
#   예: scripts/kind/sync-ecr-image.sh auth 83891abf5633de987a908464bc8cfae249fa3bef
#
# - 내 PC의 SSO 프로필(기본 ureka-admin)로만 ECR에 접근한다. 클러스터·저장소에는 AWS 자격 증명을 두지 않는다.
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
profile="${AWS_PROFILE:-ureka-admin}"
region="${AWS_REGION:-ap-northeast-2}"
dest="localhost:5001/ureka/${service}:${tag}"

command -v crane >/dev/null || { echo "crane이 필요합니다: brew install crane" >&2; exit 1; }

account="$(aws sts get-caller-identity --profile "$profile" --query Account --output text)"
registry="${account}.dkr.ecr.${region}.amazonaws.com"
src="${registry}/ureka/${service}:${tag}"

DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
# 오류 메시지에 계정 ID가 섞여 나오지 않게 가린다
redact() { sed -E 's/[0-9]{12}/<ACCOUNT_ID>/g' >&2; }

aws ecr get-login-password --profile "$profile" --region "$region" |
  crane auth login "$registry" -u AWS --password-stdin >/dev/null 2> >(redact)

src_digest="$(crane digest "$src" 2> >(redact))"
crane copy "$src" "$dest" 2> >(redact) | redact
dest_digest="$(crane digest --insecure "$dest" 2> >(redact))"

if [ "$src_digest" != "$dest_digest" ]; then
  echo "digest가 다릅니다: ECR ${src_digest} / 로컬 ${dest_digest}" >&2
  exit 1
fi
echo "복사 완료: ureka/${service}:${tag}"
echo "digest: ${dest_digest}"
