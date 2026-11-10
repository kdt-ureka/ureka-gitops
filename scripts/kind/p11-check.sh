#!/usr/bin/env bash
# P11(함수 역할/배포) 부정 시험을 kind PostgreSQL에서 실행한다. DB 상태는 바꾸지 않는다.
#
#   scripts/kind/p11-check.sh                 # content_db, 로그인 계정 content_db_recommend (Secret ureka-recommend-db의 비밀번호)
#   P11_PASSWORD_FILE=<파일> scripts/kind/p11-check.sh <DB>   # 다른 DB(예: V14 미리보기 DB). 로그인 계정 = <DB>_recommend
#
# 1부 tests/db/p11-recommend-login.sql   recommend 로그인 계정으로: 검색 함수 실행 허용, 원본 표 SELECT·쓰기·DDL·SET ROLE 거절
# 2부 tests/db/p11-function-metadata.sql 관리자로: 함수 소유자·SECURITY DEFINER·search_path·PUBLIC EXECUTE·역할 구성
# 3부 접속: 같은 계정으로 자기 DB 접속 성공 확인 → 다른 DB(auth_db, postgres) 접속이 CONNECT 권한으로 거절되는지
#
# 성공 조건(모두 만족해야 종료 코드 0):
#   - 1·2부 psql 종료 코드 0 (SQL이 실제로 끝까지 실행됨)
#   - 아래 필수 체크 ID가 빠짐없이 PASS(또는 허용된 EXCEPTION)로 나옴
#   - P11 FAIL 0
# 비밀번호는 명령 인자에 싣지 않고 표준 입력으로 Pod에 넘긴다.
set -euo pipefail
cd "$(dirname "$0")/../.."

ctx="${KUBE_CONTEXT:-kind-ureka}"
pod="${P11_POD:-postgres-0}"
db="${1:-content_db}"
login="${db}_recommend"
k() { kubectl --context "$ctx" -n dev "$@"; }

if ! [[ "$ctx" =~ ^kind- ]]; then
  echo "kind 클러스터 컨텍스트(kind-*)에서만 실행한다: $ctx" >&2
  exit 2
fi

required=(
  A1 A2 B1 B2 B3
  C01 C02 C03 C04 C05 C06 C07 C08 C09 C10 C11 C12 C13 C14
  D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13
  M01 M02 M03 M04 M05 M06a M06b M07 M08 M09a M09b M10 M11 M12 M13
  X00 X01 X02
)
# 알고 받아들인 예외(문서 docs/kind-db-secrets.md 4장). 이 ID만 EXCEPTION을 통과로 센다.
allowed_exceptions=(M06b)

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
fatal=0
note() { printf '%s\n' "$1" >>"$out"; }

if [ -n "${P11_PASSWORD_FILE:-}" ]; then
  login_pw="$(cat "$P11_PASSWORD_FILE")"
else
  login_pw="$(k get secret ureka-recommend-db -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)" ||
    { echo "Secret ureka-recommend-db를 읽지 못했다(컨텍스트 ${ctx})" >&2; exit 1; }
fi
[ -n "$login_pw" ] || { echo "로그인 비밀번호가 비어 있다" >&2; exit 1; }

# Pod 안에서 TCP(127.0.0.1)로 접속해야 비밀번호 인증을 거친다(소켓 접속은 trust).
as_login() { # DB, psql 인자...
  local target="$1"; shift
  printf '%s\n' "$login_pw" |
    k exec -i "$pod" -- sh -c 'read -r PGPASSWORD; export PGPASSWORD; u="$1"; d="$2"; shift 2; exec psql -X -h 127.0.0.1 -U "$u" -d "$d" "$@"' _ "$login" "$target" "$@"
}

# 관리자가 검색 가능 작품 수를 센다(B3 기대값). V14 전 DB에는 표가 있어도 0일 수 있다.
searchable="$(k exec "$pod" -- psql -X -At -U postgres -d "$db" -c 'select count(*) from catalog.contents where is_searchable' 2>>"$out")" ||
  { note "SCRIPT_ERROR 검색 가능 작품 수를 세지 못했다(Pod ${pod}, DB ${db})"; fatal=1; searchable=""; }

# 1부
if ! { printf '%s\n' "$login_pw"; cat tests/db/p11-recommend-login.sql; } |
  k exec -i "$pod" -- sh -c 'read -r PGPASSWORD; export PGPASSWORD; exec psql -X -h 127.0.0.1 -U "$1" -d "$2" -v searchable_count="$3" -f -' _ "$login" "$db" "$searchable" >>"$out" 2>&1; then
  note "SCRIPT_ERROR 1부(recommend 로그인 SQL)가 끝까지 실행되지 않았다"
  fatal=1
fi

# 2부: 관리자(소켓, 컨테이너 안 postgres 사용자)
if ! k exec -i "$pod" -- psql -X -U postgres -d "$db" -f - <tests/db/p11-function-metadata.sql >>"$out" 2>&1; then
  note "SCRIPT_ERROR 2부(관리자 카탈로그 SQL)가 끝까지 실행되지 않았다"
  fatal=1
fi

# 3부: 같은 자격으로 자기 DB 접속이 되는지 먼저 본다. 이게 안 되면 아래 거절은 의미가 없다.
self="$(as_login "$db" -Atc 'select current_user' 2>&1)" || true
if [ "$self" = "$login" ]; then
  note "P11 PASS X00 ${login}으로 ${db} 접속 성공(같은 자격으로 아래 거절 시험)"
  for other in auth_db postgres; do
    id=X01; [ "$other" = postgres ] && id=X02
    if err="$(as_login "$other" -Atc 'select 1' 2>&1)"; then
      note "P11 FAIL ${id} ${login}이 ${other}에 접속됨"
    elif printf '%s' "$err" | grep -q "permission denied for database"; then
      note "P11 PASS ${id} ${login}의 ${other} 접속이 CONNECT 권한으로 거절"
    else
      note "P11 FAIL ${id} ${other} 접속 실패 이유가 권한 거절이 아님: $(printf '%s' "$err" | tail -1)"
    fi
  done
else
  note "SCRIPT_ERROR 3부: ${login}으로 ${db}에 접속하지 못했다: $(printf '%s' "$self" | tail -1)"
  fatal=1
fi

grep -E 'P11 (PASS|FAIL|INFO|EXCEPTION)|SCRIPT_ERROR|ERROR|FATAL' "$out" | sed -E 's/^(psql:[^ ]+ )?(NOTICE|WARNING|ERROR|FATAL): +//'

fail="$(grep -c 'P11 FAIL' "$out" || true)"
missing=()
for id in "${required[@]}"; do
  if grep -qE "P11 PASS ${id}( |$)" "$out"; then continue; fi
  if grep -qE "P11 EXCEPTION ${id}( |$)" "$out" && [[ " ${allowed_exceptions[*]} " == *" ${id} "* ]]; then continue; fi
  missing+=("$id")
done
pass="$(grep -c 'P11 PASS' "$out" || true)"
exc="$(grep -c 'P11 EXCEPTION' "$out" || true)"
echo "---"
echo "P11 ${db} (${login}): PASS ${pass} / FAIL ${fail} / EXCEPTION ${exc} / 필수 미확인 ${#missing[@]} / 스크립트 오류 ${fatal}"
[ "${#missing[@]}" -eq 0 ] || echo "필수 체크 미확인: ${missing[*]}"
[ "$fatal" -eq 0 ] && [ "$fail" -eq 0 ] && [ "${#missing[@]}" -eq 0 ]
