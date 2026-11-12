#!/usr/bin/env bash
# environments/kind/data/run-bootstrap.sh 회귀 시험. 클러스터 없이 가짜 pg_isready·psql로 돈다(CI Helm 워크플로와 로컬).
# - 정상 verifier 6개(auth·content 4 + chat·ops 2): 종료 0, psql 1회.
# - 한 변수만 잘못 바꾼 경우: 종료 0이 아니고 pg_isready·psql 호출 0회, 출력에 값이 나오지 않음.
# - 6개 변수 각각이 없거나 비었거나 원문일 때도 같다(새 변수가 검사 목록에서 빠지지 않게).
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/bootstrap"
cp environments/kind/data/db-bootstrap.sql "$work/bootstrap/"
for c in pg_isready psql; do
  printf '#!/bin/sh\necho %s >>"$FAKE_LOG"\nexit 0\n' "$c" >"$work/bin/$c"
  chmod +x "$work/bin/$c"
done

# create-secrets.sh와 같은 방식으로 정상 verifier를 만든다(salt 16바이트, 4096회).
verifier() {
  printf '%s' "$1" | python3 -I -c '
import base64, hashlib, hmac, os, sys
pw = sys.stdin.read().encode()
salt, it = os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", pw, salt, it)
ck = hmac.new(salted, b"Client Key", "sha256").digest()
sk = hmac.new(salted, b"Server Key", "sha256").digest()
b = lambda x: base64.b64encode(x).decode()
sys.stdout.write("SCRAM-SHA-256$%d:%s$%s:%s" % (it, b(salt), b(hashlib.sha256(ck).digest()), b(sk)))'
}
plain="plaintext-marker-$(openssl rand -hex 8)"
good="$(verifier "$plain")"
good2="$(verifier other)"
salt="${good#*:}"; salt="${salt%%\$*}"
keys="${good#*\$*\$}"; stored="${keys%%:*}"; server="${keys#*:}"
b64() { python3 -I -c 'import base64,sys; sys.stdout.write(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$1"; }

run() { # 이름, CONTENT_DB_RECOMMEND_SCRAM 값 → 종료 코드를 rc에, 호출 수를 calls에
  : >"$work/log"
  rc=0
  env -i PATH="$work/bin:/usr/bin:/bin" FAKE_LOG="$work/log" BOOTSTRAP_DIR="$work/bootstrap" \
    AUTH_DB_APP_SCRAM="$good2" CONTENT_DB_APP_SCRAM="$good2" CONTENT_DB_INGEST_SCRAM="$good2" \
    CHAT_DB_APP_SCRAM="$good2" OPS_DB_APP_SCRAM="$good2" \
    CONTENT_DB_RECOMMEND_SCRAM="$2" \
    sh environments/kind/data/run-bootstrap.sh >"$work/out" 2>&1 || rc=$?
  calls="$(wc -l <"$work/log" | tr -d ' ')"
}

status=0
run valid "$good"
if [ "$rc" -eq 0 ] && grep -qx psql "$work/log"; then
  echo "ok   valid: 종료 0, DB 호출 ${calls}회"
else
  echo "FAIL valid: 종료 ${rc}, 호출 ${calls}"; cat "$work/out"; status=1
fi

cr="$(printf '\r')"
bad_cases=(
  "empty::"
  "plaintext::${plain}"
  "prefix-only::SCRAM-SHA-256\$"
  "valid+LF+plain::${good}
${plain}"
  "LF+valid::
${good}"
  "valid+LF::${good}
"
  "valid+CR::${good}${cr}"
  "valid+CRLF+plain::${good}${cr}
${plain}"
  "iterations-0000::SCRAM-SHA-256\$0000:${salt}\$${stored}:${server}"
  "iterations-4095::SCRAM-SHA-256\$4095:${salt}\$${stored}:${server}"
  "iterations-40960::SCRAM-SHA-256\$40960:${salt}\$${stored}:${server}"
  "salt-A::SCRAM-SHA-256\$4096:A\$${stored}:${server}"
  "salt-15bytes::SCRAM-SHA-256\$4096:$(b64 000102030405060708090a0b0c0d0e)\$${stored}:${server}"
  "salt-noncanonical::SCRAM-SHA-256\$4096:${salt:0:21}B==\$${stored}:${server}"
  "salt-badchar::SCRAM-SHA-256\$4096:${salt:0:21}!==\$${stored}:${server}"
  "stored-31bytes::SCRAM-SHA-256\$4096:${salt}\$$(b64 "$(printf '%062d' 0)"):${server}"
  "no-key-colon::SCRAM-SHA-256\$4096:${salt}\$${stored}${server}"
  "extra-field::${good}:${server}"
  "extra-dollar::SCRAM-SHA-256\$4096:${salt}\$\$${stored}:${server}"
  "command-text::\$(printf EVALUATED)"
)
for c in "${bad_cases[@]}"; do
  name="${c%%::*}"; value="${c#*::}"
  run "$name" "$value"
  if [ "$rc" -ne 0 ] && [ "$calls" -eq 0 ] && ! grep -qF "$plain" "$work/out" && ! grep -q EVALUATED "$work/out"; then
    echo "ok   ${name}: 종료 ${rc}, DB 호출 0회"
  else
    echo "FAIL ${name}: 종료 ${rc}, DB 호출 ${calls}회"; status=1
  fi
done

# 변수마다: 없음(unset)·빈 값·원문. 다른 5개는 정상.
vars=(AUTH_DB_APP_SCRAM CONTENT_DB_APP_SCRAM CONTENT_DB_RECOMMEND_SCRAM CONTENT_DB_INGEST_SCRAM CHAT_DB_APP_SCRAM OPS_DB_APP_SCRAM)
for v in "${vars[@]}"; do
  for kind in unset empty plaintext; do
    case "$kind" in
      unset) extra=(-u "$v") ;;
      empty) extra=("$v=") ;;
      plaintext) extra=("$v=$plain") ;;
    esac
    # run의 3번째 인자부터는 env에 그대로 붙는다(-u는 env 옵션이라 앞에 둔다).
    : >"$work/log"; rc=0
    env -i PATH="$work/bin:/usr/bin:/bin" FAKE_LOG="$work/log" BOOTSTRAP_DIR="$work/bootstrap" \
      AUTH_DB_APP_SCRAM="$good2" CONTENT_DB_APP_SCRAM="$good2" CONTENT_DB_INGEST_SCRAM="$good2" \
      CHAT_DB_APP_SCRAM="$good2" OPS_DB_APP_SCRAM="$good2" CONTENT_DB_RECOMMEND_SCRAM="$good" \
      env "${extra[@]}" sh environments/kind/data/run-bootstrap.sh >"$work/out" 2>&1 || rc=$?
    calls="$(wc -l <"$work/log" | tr -d ' ')"
    if [ "$rc" -ne 0 ] && [ "$calls" -eq 0 ] && ! grep -qF "$plain" "$work/out" && grep -q "^$v:" "$work/out"; then
      echo "ok   ${v} ${kind}: 종료 ${rc}, DB 호출 0회"
    else
      echo "FAIL ${v} ${kind}: 종료 ${rc}, DB 호출 ${calls}회"; status=1
    fi
  done
done

# SQL이 6개 해시를 모두 읽는지(변수 이름 오타로 빈 값이 들어가지 않게)
for v in "${vars[@]}"; do
  if grep -Eq "^[\\]getenv [a-z_]+ ${v}\$" environments/kind/data/db-bootstrap.sql; then
    echo "ok   db-bootstrap.sql이 ${v}를 읽음"
  else
    echo "FAIL db-bootstrap.sql에 \\getenv ... ${v}가 없음"; status=1
  fi
done
exit "$status"
