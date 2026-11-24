#!/usr/bin/env bash
# EKS #49 정적 검증만. kubeconfig·AWS·클러스터 연결 없이 helm/yq/Python 표준 라이브러리로 실행.
set -euo pipefail
cd "$(dirname "$0")/.."
for env in dev prod; do
  helm lint charts/ureka-networkpolicy -n "$env" -f "environments/eks/$env/networkpolicy/values.yaml" \
    --set alb.enabled=false --strict >/dev/null
done
python3 -m unittest discover -s tests/eksnetworkpolicy -p 'test_eks*.py' -v
