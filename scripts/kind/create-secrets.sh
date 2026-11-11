#!/usr/bin/env bash
# kind dev 네임스페이스에 로컬 전용 비밀값 Secret을 처음 한 번 만든다. 값은 이 PC에서 새로 만들고 Git에 남기지 않는다.
#
#   scripts/kind/create-secrets.sh
#
# 만드는 Secret (네임스페이스 dev)
#   postgres-admin         POSTGRES_PASSWORD                       PostgreSQL 슈퍼유저(kind 전용). 데이터 디렉터리를 처음 만들 때만 쓰인다
#   db-accounts            AUTH_DB_APP_SCRAM, CONTENT_DB_APP_SCRAM, CONTENT_DB_RECOMMEND_SCRAM, CONTENT_DB_INGEST_SCRAM
#                                                                  계정 비밀번호의 SCRAM-SHA-256 해시. db-bootstrap Job이 쓴다(원문은 없다)
#   ureka-auth-secrets     DB_PASSWORD, JWT_PRIVATE_KEY, JWT_PUBLIC_KEY, EMAIL_CODE_SECRET, INTERNAL_SERVICE_TOKEN
#   ureka-content-secrets  DB_PASSWORD, JWT_PUBLIC_KEY, INTERNAL_SERVICE_TOKEN
#   ureka-recommend-db     DB_USERNAME, DB_PASSWORD               recommend 실제 모드 연결용(아직 values에서 쓰지 않음)
#   ureka-ingest-db        DB_USERNAME, DB_PASSWORD               ingest Job 연결용(아직 쓰지 않음)
#
# 서비스마다 필요한 값만 따로 담는다(content는 JWT 개인키를 받지 않는다).
#
# 값이 지나가는 곳: 이 스크립트의 임시 디렉터리(권한 700, 끝나면 삭제)와 kubectl create 표준 입력뿐이다.
# 명령 인자(argv)와 화면에는 싣지 않는다. 비밀번호 원문은 DB 서버로 보내지 않는다(SCRAM 해시만 보낸다).
#
# 교체(rotate)는 제공하지 않는다. kind는 로컬 임시 환경이라 값을 바꾸려면 클러스터를 새로 만든다
# (kind delete cluster --name ureka → scripts/kind/up.sh → 이 스크립트). 이유: DB 계정 비밀번호·슈퍼유저
# 비밀번호·앱 재시작을 한 번에 맞추고 실패를 되돌리는 절차를 이 PR에서 검증하지 않았다.
# 운영(EKS)은 이 스크립트를 쓰지 않는다. Secrets Manager → ESO로 넣는다.
set -euo pipefail

ctx="${KUBE_CONTEXT:-kind-ureka}"
ns=dev
secrets=(postgres-admin db-accounts ureka-auth-secrets ureka-content-secrets ureka-recommend-db ureka-ingest-db)
k() { kubectl --context "$ctx" -n "$ns" "$@"; }

if [ $# -ne 0 ]; then
  echo "사용법: $0   (인자 없음. 값 교체는 클러스터 재생성, 스크립트 주석 참고)" >&2
  exit 2
fi
# 로컬 kind 클러스터에만 쓴다. 다른 클러스터(EKS 등)에 실수로 만들지 않게 막는다.
if ! [[ "$ctx" =~ ^kind- ]]; then
  echo "kind 클러스터 컨텍스트(kind-*)에만 쓸 수 있습니다: $ctx" >&2
  exit 2
fi
command -v openssl >/dev/null || { echo "openssl이 필요합니다" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3이 필요합니다(SCRAM 해시 계산)" >&2; exit 1; }
# 있는지 확인: 있으면 0, NotFound면 1. 권한(Forbidden)·연결 오류 등 그 밖의 실패는 "없음"으로 보지 않고 멈춘다.
# (권한이 없어 안 보이는 Secret을 없다고 보고 새로 만들면 값이 서로 어긋난다.)
exists() { # kubectl get 인자...
  local err
  if err="$(kubectl --context "$ctx" get "$@" -o name 2>&1 >/dev/null)"; then return 0; fi
  if printf '%s' "$err" | grep -q '(NotFound)'; then return 1; fi
  echo "확인 실패(없음이 아닌 오류라 멈춥니다): kubectl get $*" >&2
  printf '%s\n' "$err" >&2
  exit 1
}

exists namespace "$ns" ||
  { echo "네임스페이스 $ns가 없습니다. kubectl apply -f argocd/kind/ureka-dev-namespace.yaml 후 다시 실행하세요" >&2; exit 1; }

existing=0
for s in "${secrets[@]}"; do
  if exists -n "$ns" secret "$s"; then existing=$((existing + 1)); fi
done
if [ "$existing" -eq "${#secrets[@]}" ]; then
  echo "Secret ${#secrets[@]}개가 이미 있습니다. 아무것도 바꾸지 않았습니다."
  exit 0
elif [ "$existing" -ne 0 ]; then
  echo "Secret이 일부(${existing}/${#secrets[@]})만 있습니다. 값이 서로 맞지 않을 수 있어 멈춥니다." >&2
  echo "클러스터를 새로 만들거나, 남은 Secret을 지우고(kubectl -n $ns delete secret -l ureka.io/created-by=create-secrets.sh) DB 볼륨도 지운 뒤 다시 실행하세요." >&2
  exit 1
fi
# Secret이 하나도 없는데 DB 볼륨이 남아 있으면, 새 슈퍼유저 비밀번호가 기존 DB에 적용되지 않는다.
if exists -n "$ns" pvc data-postgres-0; then
  echo "Secret은 없는데 DB 볼륨(pvc/data-postgres-0)이 남아 있습니다. 새 비밀번호가 기존 DB에 맞지 않습니다." >&2
  echo "kind dev 데이터를 버려도 되면: kubectl -n $ns delete statefulset postgres && kubectl -n $ns delete pvc data-postgres-0 후 다시 실행" >&2
  exit 1
fi

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rand() { openssl rand -hex 32 | tr -d '\n' >"$work/$1"; }
# SCRAM-SHA-256 verifier(PostgreSQL rolpassword 형식). 원문은 표준 입력으로만 넘긴다.
scram() { # 원문 파일, 결과 파일
  python3 -I -c '
import base64, hashlib, hmac, os, sys
pw = sys.stdin.read().strip().encode()
salt, it = os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", pw, salt, it)
ck = hmac.new(salted, b"Client Key", "sha256").digest()
sk = hmac.new(salted, b"Server Key", "sha256").digest()
b = lambda x: base64.b64encode(x).decode()
sys.stdout.write("SCRAM-SHA-256$%d:%s$%s:%s" % (it, b(salt), b(hashlib.sha256(ck).digest()), b(sk)))
' <"$1" >"$2"
}

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/jwt-private.pem" 2>/dev/null
openssl pkey -in "$work/jwt-private.pem" -pubout -out "$work/jwt-public.pem"
for v in postgres internal email auth_db content_db recommend_db ingest_db; do rand "$v"; done
for v in auth_db content_db recommend_db ingest_db; do scram "$work/$v" "$work/$v.scram"; done
printf 'content_db_recommend' >"$work/recommend_user"
printf 'content_db_ingest' >"$work/ingest_user"

# create로 만든다(apply가 아니다). 위 확인과 이 사이에 누가 같은 이름을 만들었으면 덮어쓰지 않고 실패한다.
apply_secret() { # 이름, KEY=파일 ...
  local name="$1"; shift
  local args=()
  for kv in "$@"; do args+=("--from-file=$kv"); done
  k create secret generic "$name" "${args[@]}" --dry-run=client -o yaml |
    k label --local -f - app.kubernetes.io/part-of=ureka ureka.io/created-by=create-secrets.sh -o yaml |
    k create -f - >/dev/null
  echo "Secret ${name} 생성"
}

apply_secret postgres-admin POSTGRES_PASSWORD="$work/postgres"
apply_secret db-accounts \
  AUTH_DB_APP_SCRAM="$work/auth_db.scram" \
  CONTENT_DB_APP_SCRAM="$work/content_db.scram" \
  CONTENT_DB_RECOMMEND_SCRAM="$work/recommend_db.scram" \
  CONTENT_DB_INGEST_SCRAM="$work/ingest_db.scram"
apply_secret ureka-auth-secrets \
  DB_PASSWORD="$work/auth_db" \
  JWT_PRIVATE_KEY="$work/jwt-private.pem" \
  JWT_PUBLIC_KEY="$work/jwt-public.pem" \
  EMAIL_CODE_SECRET="$work/email" \
  INTERNAL_SERVICE_TOKEN="$work/internal"
apply_secret ureka-content-secrets \
  DB_PASSWORD="$work/content_db" \
  JWT_PUBLIC_KEY="$work/jwt-public.pem" \
  INTERNAL_SERVICE_TOKEN="$work/internal"
apply_secret ureka-recommend-db DB_USERNAME="$work/recommend_user" DB_PASSWORD="$work/recommend_db"
apply_secret ureka-ingest-db DB_USERNAME="$work/ingest_user" DB_PASSWORD="$work/ingest_db"

echo "완료. 값은 출력하지 않는다. 확인: kubectl --context $ctx -n $ns get secret -l ureka.io/created-by=create-secrets.sh"
