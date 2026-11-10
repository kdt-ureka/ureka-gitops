#!/usr/bin/env bash
# P11(함수 역할/배포) 부정 시험을 kind PostgreSQL에서 실행한다. DB 상태는 바꾸지 않는다.
#
#   scripts/kind/p11-check.sh                 # content_db, 로그인 계정 content_db_recommend (Secret db-accounts의 비밀번호)
#   P11_PASSWORD_FILE=<파일> scripts/kind/p11-check.sh <DB>   # 다른 DB(예: V14 미리보기 DB). 로그인 계정 = <DB>_recommend
#
# 1부 tests/db/p11-recommend-login.sql   recommend 로그인 계정으로: 검색 함수 실행 허용, 원본 표 SELECT·쓰기·DDL·SET ROLE 거절
# 2부 tests/db/p11-function-metadata.sql 관리자로: 함수 소유자·SECURITY DEFINER·search_path·PUBLIC EXECUTE·역할 구성
# 3부 다른 서비스 DB(auth_db) 접속 거절
# 'P11 FAIL'이 하나라도 있으면 종료 코드 1. 비밀번호는 명령 인자에 싣지 않고 표준 입력으로 Pod에 넘긴다.
set -euo pipefail
cd "$(dirname "$0")/../.."

ctx="${KUBE_CONTEXT:-kind-ureka}"
db="${1:-content_db}"
login="${db}_recommend"
k() { kubectl --context "$ctx" -n dev "$@"; }

if [ -n "${P11_PASSWORD_FILE:-}" ]; then
  login_pw="$(cat "$P11_PASSWORD_FILE")"
else
  login_pw="$(k get secret db-accounts -o jsonpath='{.data.CONTENT_DB_RECOMMEND_PASSWORD}' | base64 -d)"
fi

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# 1부: Pod 안에서 TCP(127.0.0.1)로 접속해야 비밀번호 인증을 거친다(소켓 접속은 trust).
{ printf '%s\n' "$login_pw"; cat tests/db/p11-recommend-login.sql; } |
  k exec -i postgres-0 -- sh -c 'read -r PGPASSWORD; export PGPASSWORD; exec psql -X -h 127.0.0.1 -U "$1" -d "$2" -f -' _ "$login" "$db" \
  >"$out" 2>&1 || true

# 2부: 관리자(소켓, 컨테이너 안 postgres 사용자)
k exec -i postgres-0 -- psql -X -U postgres -d "$db" -f - <tests/db/p11-function-metadata.sql >>"$out" 2>&1 || true

# 3부: 다른 서비스 DB 접속
if printf '%s\n' "$login_pw" |
  k exec -i postgres-0 -- sh -c 'read -r PGPASSWORD; export PGPASSWORD; exec psql -X -h 127.0.0.1 -U "$1" -d auth_db -c "select 1"' _ "$login" >/dev/null 2>&1; then
  echo "WARNING:  P11 FAIL X01 ${login}이 auth_db에 접속됨" >>"$out"
else
  echo "NOTICE:  P11 PASS X01 ${login}의 auth_db 접속 거절" >>"$out"
fi

grep -E 'P11 (PASS|FAIL|INFO)|ERROR|FATAL' "$out" | sed -E 's/^(psql:[^ ]+ )?(NOTICE|WARNING|ERROR|FATAL): +//'
pass="$(grep -c 'P11 PASS' "$out" || true)"
fail="$(grep -c 'P11 FAIL' "$out" || true)"
errors="$(grep -cE '(^|: )(ERROR|FATAL):' "$out" || true)"
echo "---"
echo "P11 ${db} (${login}): PASS ${pass} / FAIL ${fail} / 스크립트 오류 ${errors}"
[ "$fail" -eq 0 ] && [ "$errors" -eq 0 ]
