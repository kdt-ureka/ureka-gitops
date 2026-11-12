#!/bin/sh
# db-bootstrap Job 본문. 1) verifier 형식 검사 → 2) DB 준비 대기 → 3) db-bootstrap.sql 실행.
# 1)이 모두 통과하기 전에는 pg_isready·psql을 부르지 않는다(잘못 들어간 원문이 서버로 가지 않게).
# 회귀 시험: scripts/test-run-bootstrap.sh (가짜 pg_isready·psql로 호출 횟수까지 본다).
set -eu

dir="${BOOTSTRAP_DIR:-/bootstrap}"

# 이 생성기(scripts/kind/create-secrets.sh)가 만드는 형식만 받는다. PostgreSQL의 모든 verifier를 받으려는 검사가 아니다.
#   SCRAM-SHA-256$4096:<salt 16바이트 base64 24자>$<StoredKey 32바이트 base64 44자>:<ServerKey 32바이트 base64 44자>
# 값은 어떤 오류에서도 출력하지 않는다.
nl='
'
cr="$(printf '\r')"
b64_ok() { # base64 문자열, 디코딩 바이트 수: 디코딩되고, 길이가 맞고, 다시 인코딩하면 같은(정규형) 경우만 통과
  decoded_len="$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" || return 1
  [ "$decoded_len" = "$2" ] || return 1
  [ "$(printf '%s' "$1" | base64 -d 2>/dev/null | base64 | tr -d '\n')" = "$1" ]
}
check_verifier() { # 변수 이름
  name="$1"
  eval "val=\${$name:-}"
  bad() { echo "$name: $1 (값은 출력하지 않음). scripts/kind/create-secrets.sh로 만든 Secret인지 확인" >&2; exit 1; }
  [ -n "$val" ] || bad "비어 있음"
  case "$val" in *"$nl"* | *"$cr"*) bad "줄바꿈(CR/LF)이 들어 있음" ;; esac
  case "$val" in 'SCRAM-SHA-256$4096:'*) ;; *) bad "SCRAM-SHA-256\$4096: 형식이 아님" ;; esac
  rest="${val#SCRAM-SHA-256\$4096:}"
  salt="${rest%%\$*}"
  keys="${rest#*\$}"
  [ "$salt" != "$rest" ] || bad "salt 뒤 구분자(\$)가 없음"
  stored="${keys%%:*}"
  server="${keys#*:}"
  [ "$stored" != "$keys" ] || bad "키 구분자(:)가 없음"
  case "$salt$stored$server" in *[!A-Za-z0-9+/=]*) bad "base64가 아닌 문자" ;; esac
  b64_ok "$salt" 16 || bad "salt가 16바이트 base64가 아님"
  b64_ok "$stored" 32 || bad "StoredKey가 32바이트 base64가 아님"
  b64_ok "$server" 32 || bad "ServerKey가 32바이트 base64가 아님"
}
for v in AUTH_DB_APP_SCRAM CONTENT_DB_APP_SCRAM CONTENT_DB_RECOMMEND_SCRAM CONTENT_DB_INGEST_SCRAM CHAT_DB_APP_SCRAM OPS_DB_APP_SCRAM; do
  check_verifier "$v"
done

i=0
until pg_isready -q; do
  i=$((i + 1))
  [ "$i" -gt 60 ] && { echo "postgres 준비 안 됨"; exit 1; }
  sleep 2
done
psql -v ON_ERROR_STOP=1 -X -q -f "$dir/db-bootstrap.sql"
echo "db-bootstrap 완료"
