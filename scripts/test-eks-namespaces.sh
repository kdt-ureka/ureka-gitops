#!/usr/bin/env bash
# EKS dev·prod 네임스페이스(#62) 정적 시험. 클러스터 없이 돈다(CI Helm 워크플로와 로컬 공통).
# 1) environments/eks/<env>/namespace를 kustomize로 렌더링한다(prod는 ../rbac 포함).
# 2) 서비스 7개를 그 환경 values로 렌더링한다. EKS 서비스 values(#43)가 아직 없으면 EC2 dev values를 대신 쓴다
#    (같은 이미지·같은 자원 값을 그대로 옮기는 흐름이라 대용으로 쓴다). #43이 파일을 만들면 자동으로 그 값을 본다.
# 3) tests/namespaces/check_eks_namespaces.py: Pod Security 라벨·Quota 안에 카나리 최대치·LimitRange·RBAC 최소 권한.
# 4) 시험이 헛돌지 않는지: 값 하나씩 망가뜨린 입력은 모두 실패해야 한다(test_check_eks_namespaces.py).
# 실제 거부 동작(Pod Security·Quota·can-i)은 docs/eks-namespaces.md의 임시 kind 시험을 본다.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
test_registry=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com

to_jsonl() { yq ea -o=json -I=0 'select(. != null)' -; }

yq -o=json -I=0 '.' environments/ec2/dev/namespace/dev.yaml > "$work/ec2-ns.jsonl"
for env in dev prod; do
  kubectl kustomize "environments/eks/${env}/namespace" | to_jsonl > "$work/${env}-ns.jsonl"
  : > "$work/${env}-workloads.jsonl"
  for base in environments/base/ureka-*.yaml; do
    file="$(basename "$base")"
    values="environments/eks/${env}/${file}"
    [ -f "$values" ] || values="environments/ec2/dev/${file}"
    echo "== ${env}: ${base} + ${values}"
    helm template "${file%.yaml}" charts/ureka-backend -n "$env" -f "$base" -f "$values" \
      --set "image.registry=${test_registry}" | to_jsonl >> "$work/${env}-workloads.jsonl"
  done
done

status=0
echo "== 정적 검사"
python3 tests/namespaces/check_eks_namespaces.py "$work" || status=1
echo "== 검사기 자체 시험(망가뜨린 입력은 실패해야 한다)"
UREKA_NS_WORKDIR="$work" python3 -m unittest discover -s tests/namespaces -p 'test_*.py' || status=1
exit "$status"
