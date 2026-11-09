#!/usr/bin/env bash
# kind 클러스터 `ureka` + 로컬 레지스트리(localhost:5001) + Argo CD를 만든다. 여러 번 실행해도 된다.
# AWS 자격 증명은 쓰지 않는다. 이미지는 scripts/kind/sync-ecr-image.sh로 따로 넣는다.
set -euo pipefail

cluster=ureka
reg_name=kind-registry
reg_port=5001
argocd_version=v3.6.0
root="$(cd "$(dirname "$0")/../.." && pwd)"

# 1. 로컬 레지스트리 (내 PC에서만 접속: 127.0.0.1에만 연다)
if [ "$(docker inspect -f '{{.State.Running}}' "$reg_name" 2>/dev/null || true)" != "true" ]; then
  docker rm -f "$reg_name" >/dev/null 2>&1 || true
  docker run -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "$reg_name" registry:2
fi

# 2. 클러스터
if ! kind get clusters | grep -qx "$cluster"; then
  kind create cluster --config "$root/kind/cluster.yaml" --wait 120s
fi

# 3. 노드가 localhost:5001 요청을 kind-registry:5000으로 보내게 한다
for node in $(kind get nodes --name "$cluster"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${reg_port}"
  printf '[host."http://%s:5000"]\n' "$reg_name" |
    docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:${reg_port}/hosts.toml"
done
if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$reg_name")" = "null" ]; then
  docker network connect kind "$reg_name"
fi

# 4. 레지스트리 위치를 클러스터에 알린다 (KEP-1755 표준 ConfigMap)
kubectl --context "kind-$cluster" apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
YAML

# 5. Argo CD
kubectl --context "kind-$cluster" create namespace argocd --dry-run=client -o yaml |
  kubectl --context "kind-$cluster" apply -f -
kubectl --context "kind-$cluster" apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_version}/manifests/install.yaml"
kubectl --context "kind-$cluster" -n argocd rollout status deploy/argocd-server --timeout=300s

echo "준비 완료. 다음: scripts/kind/sync-ecr-image.sh 로 이미지를 넣고 kubectl apply -f argocd/kind/"
