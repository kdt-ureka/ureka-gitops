#!/usr/bin/env bash
# kind dev 네임스페이스에 로컬 전용 비밀값 Secret을 만든다. 값은 이 PC에서 새로 만들고 Git·파일에 남기지 않는다.
#
#   scripts/kind/create-secrets.sh            # 없으면 만든다. 이미 다 있으면 아무것도 안 한다.
#   scripts/kind/create-secrets.sh --rotate   # 모두 새 값으로 바꾸고 DB 계정 비밀번호·앱 Pod를 다시 맞춘다.
#
# 만드는 Secret (네임스페이스 dev)
#   postgres-admin         POSTGRES_PASSWORD                     PostgreSQL 슈퍼유저(kind 전용)
#   db-accounts            AUTH_DB_APP_PASSWORD, CONTENT_DB_APP_PASSWORD, CONTENT_DB_RECOMMEND_PASSWORD, CONTENT_DB_INGEST_PASSWORD
#                                                                db-bootstrap Job이 계정 비밀번호로 쓴다
#   ureka-auth-secrets     DB_PASSWORD, JWT_PRIVATE_KEY, JWT_PUBLIC_KEY, EMAIL_CODE_SECRET, INTERNAL_SERVICE_TOKEN
#   ureka-content-secrets  DB_PASSWORD, JWT_PUBLIC_KEY, INTERNAL_SERVICE_TOKEN
#
# 서비스마다 필요한 값만 따로 담는다(content는 JWT 개인키를 받지 않는다).
# kind 클러스터를 지우면 Secret도 사라진다. 다시 만들면 이전 토큰·DB 비밀번호는 쓸 수 없다(로컬 dev라 그대로 둔다).
# 운영(EKS)은 이 스크립트를 쓰지 않는다. Secrets Manager → ESO로 넣는다.
set -euo pipefail

ctx="${KUBE_CONTEXT:-kind-ureka}"
ns=dev
secrets=(postgres-admin db-accounts ureka-auth-secrets ureka-content-secrets)
k() { kubectl --context "$ctx" -n "$ns" "$@"; }

rotate=false
case "${1:-}" in
  "") ;;
  --rotate) rotate=true ;;
  *) echo "사용법: $0 [--rotate]" >&2; exit 2 ;;
esac

command -v openssl >/dev/null || { echo "openssl이 필요합니다" >&2; exit 1; }
kubectl --context "$ctx" get namespace "$ns" >/dev/null 2>&1 ||
  { echo "네임스페이스 $ns가 없습니다. kubectl apply -f argocd/kind/ureka-dev-namespace.yaml 후 다시 실행하세요" >&2; exit 1; }

existing=0
for s in "${secrets[@]}"; do
  if k get secret "$s" >/dev/null 2>&1; then existing=$((existing + 1)); fi
done

if ! $rotate; then
  if [ "$existing" -eq "${#secrets[@]}" ]; then
    echo "Secret ${#secrets[@]}개가 이미 있습니다. 새 값으로 바꾸려면 --rotate"
    exit 0
  elif [ "$existing" -ne 0 ]; then
    # 일부만 있으면 DB 비밀번호·토큰이 서로 안 맞을 수 있다. 섞지 않고 한 번에 다시 만든다.
    echo "Secret이 일부(${existing}/${#secrets[@]})만 있습니다. 값이 서로 맞지 않을 수 있어 멈춥니다. --rotate로 한 번에 다시 만드세요" >&2
    exit 1
  fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077

rand() { openssl rand -hex 32; }
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/jwt-private.pem" 2>/dev/null
openssl pkey -in "$work/jwt-private.pem" -pubout -out "$work/jwt-public.pem"
rand >"$work/internal-token"
auth_db_pw="$(rand)"
content_db_pw="$(rand)"

label=(app.kubernetes.io/part-of=ureka ureka.io/created-by=create-secrets.sh)
apply_secret() { # 이름, kubectl create secret generic 인자...
  local name="$1"; shift
  k create secret generic "$name" "$@" --dry-run=client -o yaml | k apply -f - >/dev/null
  k label secret "$name" "${label[@]}" --overwrite >/dev/null
  echo "Secret ${name} 저장"
}

apply_secret postgres-admin --from-literal=POSTGRES_PASSWORD="$(rand)"
apply_secret db-accounts \
  --from-literal=AUTH_DB_APP_PASSWORD="$auth_db_pw" \
  --from-literal=CONTENT_DB_APP_PASSWORD="$content_db_pw" \
  --from-literal=CONTENT_DB_RECOMMEND_PASSWORD="$(rand)" \
  --from-literal=CONTENT_DB_INGEST_PASSWORD="$(rand)"
apply_secret ureka-auth-secrets \
  --from-literal=DB_PASSWORD="$auth_db_pw" \
  --from-file=JWT_PRIVATE_KEY="$work/jwt-private.pem" \
  --from-file=JWT_PUBLIC_KEY="$work/jwt-public.pem" \
  --from-literal=EMAIL_CODE_SECRET="$(rand)" \
  --from-file=INTERNAL_SERVICE_TOKEN="$work/internal-token"
apply_secret ureka-content-secrets \
  --from-literal=DB_PASSWORD="$content_db_pw" \
  --from-file=JWT_PUBLIC_KEY="$work/jwt-public.pem" \
  --from-file=INTERNAL_SERVICE_TOKEN="$work/internal-token"

if $rotate && [ "$existing" -ne 0 ]; then
  # postgres 슈퍼유저 비밀번호는 데이터 디렉터리를 처음 만들 때만 적용된다. 이미 있는 DB에는 직접 바꾼다.
  if k get pod postgres-0 >/dev/null 2>&1; then
    # 비밀번호는 명령 인자가 아니라 표준 입력으로 넘긴다(hex라 따옴표 문제가 없다).
    printf "ALTER ROLE postgres PASSWORD '%s';\n" \
      "$(k get secret postgres-admin -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)" |
      k exec -i postgres-0 -- psql -X -q -v ON_ERROR_STOP=1 -U postgres >/dev/null
    echo "postgres 슈퍼유저 비밀번호 변경"
  fi
  # 계정 비밀번호는 db-bootstrap Job(PostSync)이 맞춘다. 데이터 Application을 다시 동기화한다.
  kubectl --context "$ctx" -n argocd patch application ureka-dev-data-kind --type merge \
    -p '{"operation":{"initiatedBy":{"username":"create-secrets.sh"},"sync":{"revision":"main"}}}' >/dev/null 2>&1 &&
    echo "ureka-dev-data-kind 동기화 요청(db-bootstrap Job이 계정 비밀번호를 다시 맞춘다)" ||
    echo "Argo CD Application ureka-dev-data-kind가 아직 없습니다. kubectl apply -f argocd/kind/ 후 자동으로 맞춰진다"
  for d in ureka-auth ureka-content; do
    k rollout restart deployment "$d" >/dev/null 2>&1 && echo "$d 재시작(새 Secret 적용)" || true
  done
fi
echo "완료. 값은 출력하지 않는다. 확인: kubectl --context $ctx -n $ns get secret -l ureka.io/created-by=create-secrets.sh"
