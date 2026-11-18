#!/usr/bin/env bash
# scripts/ec2/rds-bootstrap.sh 회귀 시험. 가짜 kubectl·aws·flock·id로 돈다(클러스터·AWS 없음, CI Helm 워크플로와 로컬).
# 가짜 클러스터는 상태 파일로 Job·Pod·Secret을 흉내 낸다(Job을 지우면 Pod도 지워진다, pod_stuck이면 Pod가 남는다).
# - 성공·Job 실패·시간 초과·aws 실패 모두: 임시 Secret rds-master가 마지막에 없다. 끝나지 않은 Job·Pod는 지운다.
# - Secret 삭제 실패, Pod 잔존, Pod 조회 실패는 경고하고 실패로 끝난다(성공으로 숨기지 않는다).
# - 시작할 때 이전 Job·Pod·Secret을 지우지 못하거나 Pod 조회가 실패하면 마스터 비밀을 읽지 않고 아무것도 만들지 않는다.
# - 다른 실행이 잠금을 쥐고 있으면 아무것도 만들지 않는다.
# - 비밀번호·ARN은 어느 경우에도 kubectl·aws 인자와 출력(stdout·stderr)에 없다. Job의 PGHOST는 RDS 엔드포인트로 바뀐다.
# 한계: 실제 flock 경쟁, INT/TERM 전달, 실제 k3s API 동작은 이 시험이 보지 않는다.
# 판정 함수(has·no_leak 등)는 check를 거쳐 간접 호출된다.
# shellcheck disable=SC2329
set -euo pipefail
cd "$(dirname "$0")/.."

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/etc" "$t/state"

FAKE_ARN="arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds!db-0000-review-only-AbCdEf"
FAKE_PW="ReviewOnlyMasterPw$(openssl rand -hex 8)"
FAKE_HOST="ureka-dev.abcdefghijkl.ap-northeast-2.rds.amazonaws.com"
export FAKE_ARN FAKE_PW

cat >"$t/bin/id" <<'SH'
#!/bin/sh
[ "$1" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
cat >"$t/bin/flock" <<'SH'
#!/bin/sh
[ "${FAKE_MODE:-}" = lock_busy ] && exit 1
exit 0
SH
cat >"$t/bin/aws" <<'SH'
#!/usr/bin/env bash
echo "AWS $*" >>"$FAKE_LOG"
if [ "${FAKE_MODE:-}" = aws_fail ]; then
  echo "An error occurred (AccessDeniedException) when calling the GetSecretValue operation: User is not authorized to access ${FAKE_ARN}" >&2
  exit 254
fi
# --cli-input-json file://... 안의 SecretId가 맞는지 본다
f=""; for a in "$@"; do case "$a" in file://*) f="${a#file://}" ;; esac; done
python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["SecretId"] == sys.argv[2]' "$f" "$FAKE_ARN" || { echo "bad input" >&2; exit 1; }
printf '{"username":"ureka_admin","password":"%s"}\n' "$FAKE_PW"
SH
cat >"$t/bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo "KUBECTL $*" >>"$FAKE_LOG"
st="$FAKE_STATE"
mode="${FAKE_MODE:-}"
args=()
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in --context|-n) skip=1 ;; --request-timeout=*) ;; *) args+=("$a") ;; esac
done
set -- "${args[@]}"
nf() { echo "Error from server (NotFound): $1 \"$2\" not found" >&2; exit 1; }
pod_query_broken() { [ "$mode" = pod_query_fails ] || { [ "$mode" = job_failed_pod_query_fails ] && [ -f "$st/job_ran" ]; }; }
case "$1 $2" in
  "get secret")
    case "$3" in
      db-accounts|db-accounts-chat-ops) exit 0 ;;
      rds-master) [ -f "$st/secret" ] && { echo "secret/rds-master"; exit 0; }; nf secrets rds-master ;;
    esac ;;
  "get job")
    if [ "$4" = "-o" ] && [[ "$5" == jsonpath=* ]]; then
      [ -f "$st/job" ] || exit 1
      case "$5" in
        *succeeded*) case "$mode" in job_ok|secret_delete_fails) echo -n 1 ;; esac ;;
        *failed*) case "$mode" in job_failed*) echo -n 1 ;; esac ;;
      esac
      exit 0
    fi
    [ -f "$st/job" ] && { echo "job.batch/db-bootstrap-rds"; exit 0; }; nf jobs db-bootstrap-rds ;;
  "get pod")
    pod_query_broken && { echo "The connection to the server 127.0.0.1:6443 was refused" >&2; exit 1; }
    [ -f "$st/pod" ] && echo "pod/db-bootstrap-rds-abcde"
    exit 0 ;;
  "wait --for=delete")
    pod_query_broken && exit 1
    [ -f "$st/pod" ] && exit 1
    exit 0 ;;
  "delete job")
    [ "$mode" = old_job_stuck ] && exit 1
    rm -f "$st/job"
    case "$mode" in pod_stuck|job_failed_pod_stuck) ;; *) rm -f "$st/pod" ;; esac
    exit 0 ;;
  "delete secret")
    if [ "$mode" = secret_delete_fails ] && [ -f "$st/job_ran" ]; then exit 1; fi
    if [ "$mode" = old_secret_stuck ]; then exit 1; fi
    rm -f "$st/secret"; exit 0 ;;
  "create secret")
    touch "$st/secret"
    for a in "$@"; do case "$a" in --from-file=*) f="${a#*=}"; f="${f#*=}"; cat "$f" >>"$st/secret_values" ;; esac; done
    exit 0 ;;
  "create configmap") echo "kind: ConfigMap"; exit 0 ;;
  "apply -f")
    body="$(cat)"
    if printf '%s' "$body" | grep -q 'kind: Job'; then printf '%s' "$body" >"$st/job.yaml"; touch "$st/job" "$st/pod" "$st/job_ran"; fi
    exit 0 ;;
  "logs job/db-bootstrap-rds") echo "db-bootstrap 완료"; exit 0 ;;
esac
echo "가짜 kubectl: 처리하지 않은 호출 $*" >&2
exit 1
SH
chmod +x "$t/bin/"*

status=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; status=1; }
check() { # 이름, 명령...: 명령이 성공하면 ok
  local name="$1"; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

run() { # 모드, [미리 둘 상태 파일들: secret job pod]
  local mode="$1"; shift
  rm -rf "$t/state"; mkdir -p "$t/state"; : >"$t/log"
  local f; for f in "$@"; do touch "$t/state/$f"; done
  printf 'AWS_REGION=ap-northeast-2\n' >"$t/etc/registry.env"
  printf 'RDS_MASTER_SECRET_ARN=%s\nRDS_ENDPOINT=%s\n' "$FAKE_ARN" "$FAKE_HOST" >"$t/etc/rds.env"
  rc=0
  FAKE_MODE="$mode" FAKE_LOG="$t/log" FAKE_STATE="$t/state" PATH="$t/bin:$PATH" \
    UREKA_ETC_DIR="$t/etc" UREKA_LOCK_FILE="$t/lock" RDS_BOOTSTRAP_WAIT_SECONDS="${WAIT:-10}" \
    bash scripts/ec2/rds-bootstrap.sh </dev/null >"$t/out" 2>&1 || rc=$?
}
has() { [ -f "$t/state/$1" ]; }
hasnt() { [ ! -f "$t/state/$1" ]; }
out_has() { grep -q "$1" "$t/out"; }
log_hasnt() { ! grep -q "$1" "$t/log"; }
no_leak() { ! grep -qF -e "$FAKE_PW" -e "$FAKE_ARN" -e "123456789012" "$t/out" "$t/log"; }
rc_is() { [ "$rc" = "$1" ]; }
rc_nonzero() { [ "$rc" != 0 ]; }
show() { tail -3 "$t/out"; }

# 1) 성공
run job_ok
check "성공: Job까지 실행됨" has job_ran
check "성공: 종료 0" rc_is 0 || show
check "성공: rds-master 없음" hasnt secret
check "성공: 비밀번호·ARN 무노출(출력·인자)" no_leak
check "성공: Secret에는 파일로 비밀번호가 들어갔다" grep -qF "$FAKE_PW" "$t/state/secret_values"
check "성공: Job PGHOST = RDS 엔드포인트" grep -q "value: ${FAKE_HOST}" "$t/state/job.yaml"
check "성공: 자리표시(RDS_ENDPOINT)가 남지 않음" bash -c "! grep -q RDS_ENDPOINT '$t/state/job.yaml'"
check "성공: 끝난 Job은 로그 확인용으로 남긴다" has job

# 2) Job 실패·시간 초과: Job·Pod·Secret 모두 지운다
for m in job_failed job_pending; do
  if [ "$m" = job_pending ]; then WAIT=0 run "$m"; label="시간 초과"; else run "$m"; label="Job 실패"; fi
  check "${label}: Job까지 실행됨" has job_ran
  check "${label}: 실패 종료" rc_nonzero
  check "${label}: rds-master 없음" hasnt secret
  check "${label}: Job 없음" hasnt job
  check "${label}: Pod 없음" hasnt pod
  check "${label}: 비밀번호·ARN 무노출" no_leak
done

# 3) 정리 실패는 숨기지 않는다
run secret_delete_fails
check "Secret 삭제 실패: Job까지 실행됨" has job_ran
check "Secret 삭제 실패: 종료 3" rc_is 3 || show
check "Secret 삭제 실패: 경고" out_has 'rds-master를 지우지 못했습니다'
check "Secret 삭제 실패: 비밀번호·ARN 무노출" no_leak

run job_failed_pod_stuck
check "Pod 잔존(실패 뒤): Job까지 실행됨" has job_ran
check "Pod 잔존(실패 뒤): 실패 종료" rc_nonzero
check "Pod 잔존(실패 뒤): 경고" out_has 'Pod가 남아 있습니다'
check "Pod 잔존(실패 뒤): rds-master 없음" hasnt secret

run job_failed_pod_query_fails
check "Pod 조회 실패(실패 뒤): Job까지 실행됨" has job_ran
check "Pod 조회 실패(실패 뒤): 실패 종료" rc_nonzero
check "Pod 조회 실패(실패 뒤): 경고" out_has '확인하지 못했습니다'
check "Pod 조회 실패(실패 뒤): rds-master 없음" hasnt secret

# 4) aws 실패
run aws_fail
check "aws 실패: aws까지 실행됨" grep -q '^AWS ' "$t/log"
check "aws 실패: 실패 종료" rc_nonzero
check "aws 실패: rds-master 없음" hasnt secret
check "aws 실패: 비밀번호·ARN 무노출" no_leak
check "aws 실패: 오류 종류만 보여 준다" out_has 'AccessDenied'

# 5) 시작 단계: 이전 것을 확인하지 못하면 마스터 비밀을 읽지 않고 아무것도 만들지 않는다
start_refuses() { # 이름 기대메시지 모드 [상태 파일들]
  local label="$1" msg="$2"; shift 2
  run "$@"
  check "${label}: 실패 종료" rc_nonzero
  check "${label}: 그 이유로 멈춤(${msg})" out_has "$msg"
  check "${label}: 마스터 비밀을 읽지 않음" log_hasnt '^AWS '
  check "${label}: 새 Secret을 만들지 않음" log_hasnt 'create secret'
  check "${label}: Job을 만들지 않음" hasnt job_ran
}
start_refuses "다른 실행 중" '다른 rds-bootstrap이 실행 중' lock_busy
start_refuses "이전 Secret 못 지움" '이전 Secret rds-master를 지우지 못했습니다' old_secret_stuck secret
start_refuses "이전 Job 못 지움" '이전 Job db-bootstrap-rds을(를) 지우지 못했습니다' old_job_stuck job pod
start_refuses "이전 Pod 잔존" '이전 bootstrap Pod가 남아 있습니다' pod_stuck job pod
start_refuses "Pod 조회 실패(시작)" '이전 bootstrap Pod를 조회하지 못했습니다' pod_query_fails

# 6) 처음 입력(rds.env 없음, 비TTY): 붙여넣기 표시(ESC[200~·ESC[201~)·CR·공백이 섞여도 받고, 틀린 값은 원인만 알린다
first_input() { # 모드, 입력 문자열 → rds.env 없이 실행
  rm -rf "$t/state"; mkdir -p "$t/state"; : >"$t/log"
  printf 'AWS_REGION=ap-northeast-2\n' >"$t/etc/registry.env"; rm -f "$t/etc/rds.env"
  rc=0
  printf '%b' "$2" | FAKE_MODE="$1" FAKE_LOG="$t/log" FAKE_STATE="$t/state" PATH="$t/bin:$PATH" \
    UREKA_ETC_DIR="$t/etc" UREKA_LOCK_FILE="$t/lock" RDS_BOOTSTRAP_WAIT_SECONDS=10 \
    bash scripts/ec2/rds-bootstrap.sh >"$t/out" 2>&1 || rc=$?
}
saved_ok() { grep -qxF "RDS_MASTER_SECRET_ARN=${FAKE_ARN}" "$t/etc/rds.env" && grep -qxF "RDS_ENDPOINT=${FAKE_HOST}" "$t/etc/rds.env"; }
first_input job_ok "\e[200~${FAKE_ARN}\e[201~\r\n  ${FAKE_HOST} \r\n"
check "붙여넣기 표시·CR·공백: 받아들임" rc_is 0 || show
check "붙여넣기 표시·CR·공백: 깨끗한 값으로 저장" saved_ok
check "붙여넣기 표시·CR·공백: 무노출" no_leak
first_input job_ok "cd ~/ureka-gitops && git log\n${FAKE_HOST}\n"
check "잘못 붙여 넣은 명령어: 실패 종료" rc_nonzero
check "잘못 붙여 넣은 명령어: 원인 안내" out_has 'arn:aws:secretsmanager:로 시작하지 않음'
check "잘못 붙여 넣은 명령어: 저장하지 않음" test ! -f "$t/etc/rds.env"
check "잘못 붙여 넣은 명령어: 마스터 비밀을 읽지 않음" log_hasnt '^AWS '
first_input job_ok "\n${FAKE_HOST}\n"
check "빈 입력: 원인 안내" out_has '비어 있음'

exit "$status"
