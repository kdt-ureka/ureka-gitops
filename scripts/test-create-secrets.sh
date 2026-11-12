#!/usr/bin/env bash
# scripts/kind/create-secrets.sh 회귀 시험. 클러스터 없이 가짜 kubectl로 돈다(CI Helm 워크플로와 로컬에서 같이 쓴다).
# - 조회가 NotFound가 아닌 오류(Forbidden·연결 실패)면 Secret을 하나도 만들지 않고 실패해야 한다.
# - 이미 있는 Secret은 덮어쓰지 않는다(전부 있으면 아무것도 안 함, 묶음 하나라도 일부만 있으면 실패).
# - 모두 없을 때만 9개(기본 6 + chat·ops 3)를 create로 만든다(apply 아님).
# - 기본 6개가 있고 chat·ops 3개가 없으면 3개만 추가한다. 이때 JWT 공개키·내부 토큰은 ureka-auth-secrets 값을 그대로 쓴다.
# - 각 Secret의 키 목록이 정해진 그대로다(chat·ops에 JWT 개인키·AI 키가 들어가지 않는다).
# - --chat-ai: 표준 입력의 키로 ureka-chat-ai(AI_MODE=gemini, AI_API_KEY) 하나만 만든다. 키는 argv·출력에 나오지 않는다.
#   이미 있음·빈 값·형식 아님·조회 오류면 만들지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."

fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

BASE="postgres-admin db-accounts ureka-auth-secrets ureka-content-secrets ureka-recommend-db ureka-ingest-db"
CHAT_OPS="db-accounts-chat-ops ureka-chat-secrets ureka-ops-secrets"
# 가짜 클러스터의 ureka-auth-secrets 값(추가 경로에서 복사돼야 하는 값)
export FAKE_PUB="fake-public-key-$(openssl rand -hex 8)"
export FAKE_INTERNAL="fake-internal-token-$(openssl rand -hex 8)"

cat >"$fake/kubectl" <<'SH'
#!/usr/bin/env bash
mode="${FAKE_MODE:-}"
log="${FAKE_LOG:?}"
args=" $* "
echo "ARGV $*" >>"$log"
nf() { echo "Error from server (NotFound): $1 \"$2\" not found" >&2; exit 1; }
forbid() { echo "Error from server (Forbidden): $1 \"$2\" is forbidden: User cannot get resource" >&2; exit 1; }
arg_after() { # 단어 → 그 다음 인자
  local prev=""
  for a in "$@"; do
    [ "$prev" = "$want" ] && { echo "$a"; return; }
    prev="$a"
  done
}
sha() { shasum -a 256 "$1" | cut -c1-16; }
case "$args" in
  *" get namespace "*)
    [ "$mode" = ns_forbidden ] && forbid namespaces dev
    exit 0 ;;
  *" get "*"go-template="*)
    want=secret name="$(arg_after "$@")"
    echo "READ $name" >>"$log"
    case "$args" in
      *JWT_PUBLIC_KEY*) v="$FAKE_PUB" ;;
      *INTERNAL_SERVICE_TOKEN*) v="$FAKE_INTERNAL" ;;
      *) v="" ;;
    esac
    [ "$mode" = auth_key_empty ] && v=""
    printf '%s' "$v" | base64; exit 0 ;;
  *" get "*" secret "*)
    want=secret name="$(arg_after "$@")"
    case "$mode" in
      secret_forbidden) forbid secrets "$name" ;;
      conn_refused) echo "The connection to the server 127.0.0.1:6443 was refused" >&2; exit 1 ;;
    esac
    case " ${FAKE_EXISTING:-} " in *" $name "*) exit 0 ;; esac
    nf secrets "$name" ;;
  *" get "*" pvc "*)
    case "$mode" in
      pvc_forbidden) forbid persistentvolumeclaims data-postgres-0 ;;
      pvc_exists) exit 0 ;;
    esac
    nf persistentvolumeclaims data-postgres-0 ;;
  *" create secret generic "*"--dry-run=client"*)
    want=generic name="$(arg_after "$@")"
    keys=""
    for a in "$@"; do
      case "$a" in --from-file=*) kv="${a#--from-file=}"; keys="$keys ${kv%%=*}"
        echo "KEY $name ${kv%%=*} $(sha "${kv#*=}")" >>"$log" ;; esac
    done
    echo "GEN $name$keys" >>"$log"
    echo "apiVersion: v1"; echo "kind: Secret"; exit 0 ;;
  *" label "*"--local"*)
    cat; exit 0 ;;
  *" create -f - "*)
    cat >/dev/null
    # 확인과 생성 사이에 누가 같은 이름을 만든 경우: 세 번째 create에서 AlreadyExists
    if { [ "$mode" = already_exists_on_create ] && [ "$(grep -c '^CREATE' "$log")" -eq 2 ]; } || [ "$mode" = already_exists_on_create_first ]; then
      echo 'Error from server (AlreadyExists): secrets "x" already exists' >&2; exit 1
    fi
    echo CREATE >>"$log"; exit 0 ;;
  *" apply "*)
    echo APPLY >>"$log"; exit 0 ;;
esac
echo "가짜 kubectl: 처리하지 않은 호출 $*" >&2
exit 1
SH
chmod +x "$fake/kubectl"

status=0
run() { # 모드, 이미 있는 Secret 목록 → rc, creates
  : >"$fake/log"
  rc=0
  FAKE_MODE="$1" FAKE_EXISTING="$2" FAKE_LOG="$fake/log" PATH="$fake:$PATH" \
    bash scripts/kind/create-secrets.sh </dev/null >"$fake/out" 2>&1 || rc=$?
  creates="$(grep -c '^CREATE' "$fake/log" || true)"
}
check() { # 이름, 모드, 이미 있는 Secret, 기대 종료(0|nonzero), 기대 create 수
  local name="$1" want_rc="$4" want_creates="$5"
  run "$2" "$3"
  if grep -q APPLY "$fake/log"; then echo "FAIL ${name}: apply를 썼다(덮어쓸 수 있음)"; status=1; return 1; fi
  if grep -qF -e "$FAKE_PUB" -e "$FAKE_INTERNAL" "$fake/out"; then echo "FAIL ${name}: 값이 출력에 나왔다"; status=1; return 1; fi
  if { [ "$want_rc" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$want_rc" = nonzero ] && [ "$rc" -eq 0 ]; } || [ "$creates" -ne "$want_creates" ]; then
    echo "FAIL ${name}: 종료 ${rc}(기대 ${want_rc}), create ${creates}개(기대 ${want_creates})"; tail -3 "$fake/out"; status=1; return 1
  fi
  echo "ok   ${name}: 종료 ${rc}, create ${creates}개"
}
gen_keys() { sed -n "s/^GEN $1 //p" "$fake/log"; }
key_sha() { awk -v n="$1" -v k="$2" '$1=="KEY" && $2==n && $3==k {print $4}' "$fake/log"; }
str_sha() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }
expect_eq() { # 설명, 실제, 기대
  if [ "$2" = "$3" ] && [ -n "$2" ]; then echo "ok   $1"; else echo "FAIL $1: '$2' != '$3'"; status=1; fi
}
expect_keys() { # Secret 이름, 기대 키 목록
  expect_eq "  ${1} 키" "$(gen_keys "$1")" "$2"
}

# 1) 처음 만들기: 9개, 각 Secret 키 목록, 서비스끼리 같은 값·다른 값
if check "none_exist" "" "" 0 9; then
  expect_eq "  만든 순서" "$(sed -n 's/^GEN \([^ ]*\).*/\1/p' "$fake/log" | tr '\n' ' ')" "$BASE $CHAT_OPS "
  expect_keys db-accounts "AUTH_DB_APP_SCRAM CONTENT_DB_APP_SCRAM CONTENT_DB_RECOMMEND_SCRAM CONTENT_DB_INGEST_SCRAM"
  expect_keys db-accounts-chat-ops "CHAT_DB_APP_SCRAM OPS_DB_APP_SCRAM"
  expect_keys ureka-chat-secrets "DB_PASSWORD JWT_PUBLIC_KEY INTERNAL_SERVICE_TOKEN"
  expect_keys ureka-ops-secrets "DB_PASSWORD JWT_PUBLIC_KEY"
  expect_eq "  chat JWT 공개키 = auth" "$(key_sha ureka-chat-secrets JWT_PUBLIC_KEY)" "$(key_sha ureka-auth-secrets JWT_PUBLIC_KEY)"
  expect_eq "  ops JWT 공개키 = auth" "$(key_sha ureka-ops-secrets JWT_PUBLIC_KEY)" "$(key_sha ureka-auth-secrets JWT_PUBLIC_KEY)"
  expect_eq "  chat 내부 토큰 = auth" "$(key_sha ureka-chat-secrets INTERNAL_SERVICE_TOKEN)" "$(key_sha ureka-auth-secrets INTERNAL_SERVICE_TOKEN)"
  n="$(awk '$1=="KEY" && $3=="DB_PASSWORD" {print $4}' "$fake/log" | sort -u | wc -l | tr -d ' ')"
  expect_eq "  DB 비밀번호 6개 모두 다름" "$n" 6
  expect_eq "  기존 값 읽지 않음" "$(grep -c '^READ' "$fake/log" || true)" 0
fi

# 2) 추가: 기본 6개만 있음(DB 볼륨도 있음) → chat·ops 3개만, 값은 auth에서 복사
if check "add_chat_ops" pvc_exists "$BASE" 0 3; then
  expect_eq "  만든 것" "$(sed -n 's/^GEN \([^ ]*\).*/\1/p' "$fake/log" | tr '\n' ' ')" "$CHAT_OPS "
  expect_keys ureka-chat-secrets "DB_PASSWORD JWT_PUBLIC_KEY INTERNAL_SERVICE_TOKEN"
  expect_keys ureka-ops-secrets "DB_PASSWORD JWT_PUBLIC_KEY"
  expect_eq "  chat JWT 공개키 = 기존 auth 값" "$(key_sha ureka-chat-secrets JWT_PUBLIC_KEY)" "$(str_sha "$FAKE_PUB")"
  expect_eq "  ops JWT 공개키 = 기존 auth 값" "$(key_sha ureka-ops-secrets JWT_PUBLIC_KEY)" "$(str_sha "$FAKE_PUB")"
  expect_eq "  chat 내부 토큰 = 기존 auth 값" "$(key_sha ureka-chat-secrets INTERNAL_SERVICE_TOKEN)" "$(str_sha "$FAKE_INTERNAL")"
  expect_eq "  읽은 Secret은 ureka-auth-secrets뿐" "$(sed -n 's/^READ //p' "$fake/log" | sort -u)" ureka-auth-secrets
fi
check "add: auth 값이 비어 있음"     auth_key_empty "$BASE" nonzero 0 || true
check "all_exist"                    ""  "$BASE $CHAT_OPS" 0 0 || true
check "base partial"                 ""  "postgres-admin" nonzero 0 || true
check "base partial + chat·ops 전부" ""  "postgres-admin $CHAT_OPS" nonzero 0 || true
check "chat·ops partial"             ""  "$BASE ureka-chat-secrets" nonzero 0 || true
check "chat·ops만 있음"              ""  "$CHAT_OPS" nonzero 0 || true
check "pvc_exists(처음)"             pvc_exists "" nonzero 0 || true
check "secret_forbidden"             secret_forbidden "" nonzero 0 || true
check "secret_forbidden(추가)"       secret_forbidden "$BASE" nonzero 0 || true
check "pvc_forbidden"                pvc_forbidden "" nonzero 0 || true
check "ns_forbidden"                 ns_forbidden "" nonzero 0 || true
check "conn_refused"                 conn_refused "" nonzero 0 || true
# 중간 실패: 앞의 2개는 남고 스크립트는 실패로 끝난다(덮어쓰지 않음). 다음 실행은 '일부만 있음'으로 멈춘다.
check "already_exists_on_create"     already_exists_on_create "" nonzero 2 || true
check "already_exists_on_create(추가)" already_exists_on_create "$BASE" nonzero 2 || true

# --chat-ai (선택 AI 키). 키는 표준 입력으로만 들어간다.
# 제공자 키 모양(AIza…)을 피한 합성 값. 비밀 탐지 규칙에 걸리지 않게 한다.
export FAKE_AI_KEY="ReviewOnlyChatAi$(openssl rand -hex 16)"
check_ai() { # 이름, 모드, 이미 있는 Secret, 표준 입력 내용, 기대 종료, 기대 create 수
  local name="$1" input="$4" want_rc="$5" want_creates="$6"
  : >"$fake/log"
  rc=0
  : >"$fake/xtrace"
  # CHECK_BASH: 셸 추적을 켠 실행(bash -x 등)도 같은 검사를 받게 한다. fd 3은 BASH_XTRACEFD 시험용 추적 파일.
  printf '%s' "$input" | FAKE_MODE="$2" FAKE_EXISTING="$3" FAKE_LOG="$fake/log" PATH="$fake:$PATH" \
    ${CHECK_ENV:-} ${CHECK_BASH:-bash} scripts/kind/create-secrets.sh --chat-ai >"$fake/out" 2>&1 3>"$fake/xtrace" || rc=$?
  cat "$fake/xtrace" >>"$fake/out"
  creates="$(grep -c '^CREATE' "$fake/log" || true)"
  if grep -q APPLY "$fake/log"; then echo "FAIL ${name}: apply를 썼다"; status=1; return 1; fi
  if grep -qF -e "$FAKE_AI_KEY" "$fake/out"; then echo "FAIL ${name}: 키가 출력에 나왔다"; status=1; return 1; fi
  if grep '^ARGV' "$fake/log" | grep -qF -e "$FAKE_AI_KEY"; then echo "FAIL ${name}: 키가 kubectl 인자에 실렸다"; status=1; return 1; fi
  if { [ "$want_rc" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$want_rc" = nonzero ] && [ "$rc" -eq 0 ]; } || [ "$creates" -ne "$want_creates" ]; then
    echo "FAIL ${name}: 종료 ${rc}(기대 ${want_rc}), create ${creates}개(기대 ${want_creates})"; tail -3 "$fake/out"; status=1; return 1
  fi
  echo "ok   ${name}: 종료 ${rc}, create ${creates}개"
}
if check_ai "chat-ai: 새로 만들기" "" "$BASE $CHAT_OPS" "$FAKE_AI_KEY" 0 1; then
  expect_eq "  만든 것" "$(sed -n 's/^GEN \([^ ]*\).*/\1/p' "$fake/log")" ureka-chat-ai
  expect_keys ureka-chat-ai "AI_MODE AI_API_KEY"
  expect_eq "  AI_MODE = gemini" "$(key_sha ureka-chat-ai AI_MODE)" "$(str_sha gemini)"
  expect_eq "  AI_API_KEY = 입력값(줄바꿈 없음)" "$(key_sha ureka-chat-ai AI_API_KEY)" "$(str_sha "$FAKE_AI_KEY")"
  expect_eq "  기존 값 읽지 않음" "$(grep -c '^READ' "$fake/log" || true)" 0
fi
if check_ai "chat-ai: 끝에 줄바꿈" "" "" "$FAKE_AI_KEY"$'\n' 0 1; then
  expect_eq "  AI_API_KEY = 줄바꿈 뺀 값" "$(key_sha ureka-chat-ai AI_API_KEY)" "$(str_sha "$FAKE_AI_KEY")"
fi
check_ai "chat-ai: 이미 있음"        ""  "ureka-chat-ai" "$FAKE_AI_KEY" nonzero 0 || true
check_ai "chat-ai: 빈 입력"          ""  "" "" nonzero 0 || true
check_ai "chat-ai: 공백 섞임"        ""  "" "AIza fake key with spaces 123" nonzero 0 || true
check_ai "chat-ai: 따옴표 섞임"      ""  "" "\"${FAKE_AI_KEY}\"" nonzero 0 || true
check_ai "chat-ai: 너무 짧음"        ""  "" "AIzaShort" nonzero 0 || true
check_ai "chat-ai: 너무 긺(257자)"   ""  "" "$(printf 'a%.0s' $(seq 257))" nonzero 0 || true
check_ai "chat-ai: 두 줄"            ""  "" "${FAKE_AI_KEY}"$'\n'"second" nonzero 0 || true
check_ai "chat-ai: CRLF"             ""  "" "${FAKE_AI_KEY}"$'\r\n' nonzero 0 || true
# 끝에 붙은 빈 줄은 명령 치환이 모두 지우므로 받는다(내용 있는 두 번째 줄만 거부).
if check_ai "chat-ai: 끝 빈 줄 여러 개" "" "" "${FAKE_AI_KEY}"$'\n\n\n' 0 1; then
  expect_eq "  AI_API_KEY = 끝 줄바꿈 뺀 값" "$(key_sha ureka-chat-ai AI_API_KEY)" "$(str_sha "$FAKE_AI_KEY")"
fi
check_ai "chat-ai: secret_forbidden" secret_forbidden "" "$FAKE_AI_KEY" nonzero 0 || true
check_ai "chat-ai: ns_forbidden"     ns_forbidden "" "$FAKE_AI_KEY" nonzero 0 || true
check_ai "chat-ai: 생성 중 AlreadyExists" already_exists_on_create_first "" "$FAKE_AI_KEY" nonzero 0 || true
# 셸 추적을 켜고 실행해도 키가 출력(stderr 포함)·추적 파일·kubectl 인자에 나오지 않아야 한다.
CHECK_BASH="bash -x" check_ai "chat-ai: bash -x 성공"   "" "" "$FAKE_AI_KEY" 0 1 || true
CHECK_BASH="bash -x" check_ai "chat-ai: bash -x 형식 오류" "" "" "${FAKE_AI_KEY} x" nonzero 0 || true
CHECK_ENV="env SHELLOPTS=xtrace" check_ai "chat-ai: SHELLOPTS=xtrace" "" "" "$FAKE_AI_KEY" 0 1 || true
CHECK_ENV="env BASH_XTRACEFD=3" CHECK_BASH="bash -x" check_ai "chat-ai: BASH_XTRACEFD=3" "" "" "$FAKE_AI_KEY" 0 1 || true
CHECK_BASH="bash -x" check_ai "chat-ai: bash -x 이미 있음" "" "ureka-chat-ai" "$FAKE_AI_KEY" nonzero 0 || true

: >"$fake/log"
rc=0; FAKE_LOG="$fake/log" PATH="$fake:$PATH" bash scripts/kind/create-secrets.sh --unknown </dev/null >/dev/null 2>&1 || rc=$?
expect_eq "알 수 없는 인자 → 종료 2, 호출 없음" "${rc}:$(grep -c '^ARGV' "$fake/log" || true)" "2:0"
: >"$fake/log"
if printf '%s' "$FAKE_AI_KEY" | KUBE_CONTEXT=arn:aws:eks:example FAKE_LOG="$fake/log" PATH="$fake:$PATH" bash scripts/kind/create-secrets.sh --chat-ai >/dev/null 2>&1; then
  echo "FAIL non-kind context(--chat-ai): 실행됐다"; status=1
else
  echo "ok   non-kind context(--chat-ai): 거부"
fi

: >"$fake/log"
if KUBE_CONTEXT=arn:aws:eks:example FAKE_LOG="$fake/log" PATH="$fake:$PATH" bash scripts/kind/create-secrets.sh </dev/null >/dev/null 2>&1; then
  echo "FAIL non-kind context: 실행됐다"; status=1
else
  echo "ok   non-kind context: 거부"
fi
exit "$status"
