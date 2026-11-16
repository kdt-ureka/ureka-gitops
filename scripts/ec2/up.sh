#!/usr/bin/env bash
# EC2 dev(k3s) 첫 설치: Argo CD → dev 네임스페이스 → 비밀값 Secret → root 앱 등록. 여러 번 실행해도 된다.
# EC2 서버 안(SSM 셸)에서 root로 실행한다: sudo bash scripts/ec2/up.sh
#   sudo bash scripts/ec2/up.sh --chat-ai   (선택) chat AI 키 Secret만 만든다. 키는 표준 입력(화면에 보이지 않음)
# k3s는 첫 부팅(user data)이 이미 설치했다. 이 스크립트는 AWS 자격 증명을 쓰지 않는다(이미지는 노드가 ECR에서 받는다).
#
# 레지스트리 주소(계정 ID 포함)는 /etc/ureka/registry.env(첫 부팅이 만든 파일)에서 읽어 root 앱 파라미터로만 넣는다.
# 화면·명령 인자·Git에 싣지 않는다. 비밀값은 scripts/kind/create-secrets.sh(UREKA_TARGET=ec2)가 이 서버에서 만든다.
# 받는 파일(Argo CD 설치 manifest)은 버전·SHA-256을 고정하고, 맞지 않으면 멈춘다.
{ set +x; } 2>/dev/null
set -euo pipefail

argocd_version=v3.6.0
argocd_sha256=c1d7ec243fa63ce675d71e564775ae42bf11608d35436d5c5951365b6c86fa6a
registry_file=/etc/ureka/registry.env
root="$(cd "$(dirname "$0")/../.." && pwd)"

[ "$(id -u)" = 0 ] || { echo "root로 실행하세요: sudo bash scripts/ec2/up.sh" >&2; exit 1; }
# k3s가 설치한 kubectl(/usr/local/bin)을 쓴다. sudo의 PATH에 없을 수 있다.
export PATH="/usr/local/bin:$PATH"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k() { kubectl --context default "$@"; }
for c in kubectl curl sha256sum python3 openssl; do
  command -v "$c" >/dev/null || { echo "$c가 필요합니다" >&2; exit 1; }
done
if [ $# -eq 1 ] && [ "$1" = --chat-ai ]; then
  exec env UREKA_TARGET=ec2 KUBE_CONTEXT=default bash "$root/scripts/kind/create-secrets.sh" --chat-ai
elif [ $# -ne 0 ]; then
  echo "사용법: sudo bash scripts/ec2/up.sh [--chat-ai]" >&2; exit 2
fi

# 0. 레지스트리 주소 읽기(형식만 확인, 값은 출력하지 않는다)
[ -f "$registry_file" ] || { echo "${registry_file}이 없습니다. EC2 dev 서버(첫 부팅 완료)에서 실행하세요." >&2; exit 1; }
ecr_registry="$(sed -n 's/^ECR_REGISTRY=//p' "$registry_file" | head -n1)"
if ! [[ "$ecr_registry" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]]; then
  echo "${registry_file}의 ECR_REGISTRY 형식이 아닙니다(값은 출력하지 않음)." >&2; exit 1
fi
k get node -o name >/dev/null || { echo "k3s에 연결하지 못했습니다(systemctl status k3s)." >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. Argo CD(버전·체크섬 고정). 안 쓰는 dex(SSO 로그인)·notifications는 0개로 줄인다.
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 120 --retry 3 \
  -o "$work/argocd-install.yaml" \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_version}/manifests/install.yaml"
echo "${argocd_sha256}  $work/argocd-install.yaml" | sha256sum -c - >/dev/null ||
  { echo "Argo CD manifest 체크섬이 다릅니다. 멈춥니다." >&2; exit 1; }
k create namespace argocd --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -n argocd --server-side --force-conflicts -f "$work/argocd-install.yaml" >/dev/null
k -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0 >/dev/null
k -n argocd rollout status deployment/argocd-server --timeout=300s
k -n argocd rollout status deployment/argocd-repo-server --timeout=300s
k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
echo "Argo CD ${argocd_version} 준비"

# 2. dev 네임스페이스(PSA restricted). 비밀값을 넣으려면 먼저 있어야 한다. 이후에는 Argo CD 앱이 같은 파일로 관리한다.
k apply -f "$root/environments/ec2/dev/namespace/dev.yaml" >/dev/null
echo "네임스페이스 dev 준비"

# 3. 비밀값 Secret(이미 있으면 바꾸지 않는다). 값은 이 서버에서만 생긴다.
UREKA_TARGET=ec2 KUBE_CONTEXT=default bash "$root/scripts/kind/create-secrets.sh"

# 4. root 앱 등록: Git의 빈칸(ecrRegistry)에 주소를 채워 표준 입력으로 넘긴다(명령 인자에 싣지 않는다).
ECR_REGISTRY="$ecr_registry" python3 -I -c '
import os, sys
src = open(sys.argv[1]).read()
old = "        - name: ecrRegistry\n          value: \"\"\n"
if src.count(old) != 1:
    sys.exit("root-app.yaml의 ecrRegistry 빈칸을 찾지 못했습니다")
sys.stdout.write(src.replace(old, "        - name: ecrRegistry\n          value: \"%s\"\n" % os.environ["ECR_REGISTRY"]))
' "$root/argocd/ec2/root-app.yaml" | k apply -f - >/dev/null
ecr_registry=""
echo "root 앱(ureka-ec2-dev-root) 등록"

cat <<'EOF'
준비 완료. 앱이 다 뜨는 데 몇 분 걸린다(이미지 첫 pull, DB 초기화).
  상태:   sudo k3s kubectl -n argocd get applications
  Pod:    sudo k3s kubectl -n dev get pods
  (선택) chat AI 켜기: sudo bash scripts/ec2/up.sh --chat-ai   (키는 화면에 보이지 않게 입력)
화면 확인은 내 PC에서 80번 포트 포워딩 문서로 연결한다(infra/README.md).
EOF
