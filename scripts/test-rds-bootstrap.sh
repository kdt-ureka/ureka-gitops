#!/usr/bin/env bash
# scripts/ec2/rds-bootstrap.sh 회귀 시험. 가짜 kubectl·aws·flock·id로 돈다(클러스터·AWS 없음, CI Helm 워크플로와 로컬).
# - 성공·Job 실패·시간 초과·aws 실패 모두: 임시 Secret rds-master가 마지막에 없다. 끝나지 않은 Job은 지운다.
# - Secret 삭제가 실패하면 경고하고 실패로 끝난다(성공으로 숨기지 않는다).
# - 다른 실행이 잠금을 쥐고 있으면 아무것도 만들지 않는다. 이전 Job·Secret을 못 지우면 새 Secret을 만들지 않는다.
# - 비밀번호·ARN은 어느 경우에도 kubectl·aws 인자와 출력(stdout·stderr)에 없다. Job의 PGHOST는 RDS 엔드포인트로 바뀐다.
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
args=()
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in --context|-n) skip=1 ;; --request-timeout=*) ;; *) args+=("$a") ;; esac
done
set -- "${args[@]}"
nf() { echo "Error from server (NotFound): $1 \"$2\" not found" >&2; exit 1; }
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
        *succeeded*) [ "${FAKE_MODE:-}" = job_ok ] || [ "${FAKE_MODE:-}" = secret_delete_fails ] && echo -n 1 ;;
        *failed*) [ "${FAKE_MODE:-}" = job_failed ] && echo -n 1 ;;
      esac
      exit 0
    fi
    [ -f "$st/job" ] && { echo "job.batch/db-bootstrap-rds"; exit 0; }; nf jobs db-bootstrap-rds ;;
  "get pod") exit 0 ;;
  "wait --for=delete") exit 0 ;;
  "delete job") [ "${FAKE_MODE:-}" = old_job_stuck ] && exit 1; rm -f "$st/job"; exit 0 ;;
  "delete secret")
    if [ "${FAKE_MODE:-}" = secret_delete_fails ] && [ -f "$st/job_ran" ]; then exit 1; fi
    if [ "${FAKE_MODE:-}" = old_secret_stuck ]; then exit 1; fi
    rm -f "$st/secret"; exit 0 ;;
  "create secret")
    touch "$st/secret"
    for a in "$@"; do case "$a" in --from-file=*) f="${a#*=}"; f="${f#*=}"; cat "$f" >>"$st/secret_values" ;; esac; done
    exit 0 ;;
  "create configmap") echo "kind: ConfigMap"; exit 0 ;;
  "apply -f")
    body="$(cat)"
    if printf '%s' "$body" | grep -q 'kind: Job'; then printf '%s' "$body" >"$st/job.yaml"; touch "$st/job" "$st/job_ran"; fi
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

run() { # 모드, [기존 Secret 있음 1] → rc, 출력 $t/out
  rm -rf "$t/state"; mkdir -p "$t/state"; : >"$t/log"
  [ "${2:-0}" = 1 ] && touch "$t/state/secret"
  printf 'AWS_REGION=ap-northeast-2\n' >"$t/etc/registry.env"
  printf 'RDS_MASTER_SECRET_ARN=%s\nRDS_ENDPOINT=%s\n' "$FAKE_ARN" "$FAKE_HOST" >"$t/etc/rds.env"
  rc=0
  FAKE_MODE="$1" FAKE_LOG="$t/log" FAKE_STATE="$t/state" PATH="$t/bin:$PATH" \
    UREKA_ETC_DIR="$t/etc" UREKA_LOCK_FILE="$t/lock" RDS_BOOTSTRAP_WAIT_SECONDS="${WAIT:-10}" \
    bash scripts/ec2/rds-bootstrap.sh </dev/null >"$t/out" 2>&1 || rc=$?
}
reached_job() { # 이름: 앞 단계에서 엉뚱하게 끝나지 않고 Job까지 갔는지(실패 시나리오가 우연히 통과하지 않게)
  if [ -f "$t/state/job_ran" ]; then ok "$1: Job까지 실행됨"; else fail "$1: Job 전에 끝났다"; tail -3 "$t/out"; fi
}
no_leak() { # 이름
  if grep -qF -e "$FAKE_PW" -e "$FAKE_ARN" -e "123456789012" "$t/out" "$t/log"; then fail "$1: 비밀번호·ARN이 출력이나 명령 인자에 나왔다"; else ok "$1: 비밀번호·ARN 무노출(출력·인자)"; fi
}
secret_gone() { # 이름
  if [ -f "$t/state/secret" ]; then fail "$1: rds-master가 남았다"; else ok "$1: rds-master 없음"; fi
}
expect_rc() { # 이름 기대(0|nonzero|숫자)
  case "$2" in
    0) [ "$rc" = 0 ] && ok "$1: 종료 0" || { fail "$1: 종료 ${rc}(기대 0)"; tail -5 "$t/out"; } ;;
    nonzero) [ "$rc" != 0 ] && ok "$1: 종료 ${rc}" || fail "$1: 성공으로 끝났다" ;;
    *) [ "$rc" = "$2" ] && ok "$1: 종료 ${rc}" || { fail "$1: 종료 ${rc}(기대 $2)"; tail -5 "$t/out"; } ;;
  esac
}

run job_ok
reached_job "성공"; expect_rc "성공" 0; secret_gone "성공"; no_leak "성공"
if [ -f "$t/state/secret_values" ] && grep -qF "$FAKE_PW" "$t/state/secret_values"; then ok "성공: Secret에는 파일로 비밀번호가 들어갔다"; else fail "성공: Secret 값이 비었다"; fi
if grep -q "value: ${FAKE_HOST}" "$t/state/job.yaml" && ! grep -q 'RDS_ENDPOINT' "$t/state/job.yaml"; then ok "성공: Job PGHOST = RDS 엔드포인트"; else fail "성공: Job PGHOST가 바뀌지 않았다"; fi
[ -f "$t/state/job" ] && ok "성공: 끝난 Job은 로그 확인용으로 남긴다" || fail "성공: 끝난 Job을 지웠다"

run job_failed
reached_job "Job 실패"; expect_rc "Job 실패" nonzero; secret_gone "Job 실패"; no_leak "Job 실패"
[ -f "$t/state/job" ] && fail "Job 실패: Job이 남았다" || ok "Job 실패: Job·Pod 삭제"

WAIT=0 run job_pending
reached_job "시간 초과"; expect_rc "시간 초과" nonzero; secret_gone "시간 초과"; no_leak "시간 초과"
[ -f "$t/state/job" ] && fail "시간 초과: Job이 남았다" || ok "시간 초과: Job·Pod 삭제"

run secret_delete_fails
reached_job "Secret 삭제 실패"; expect_rc "Secret 삭제 실패" 3
grep -q 'rds-master를 지우지 못했습니다' "$t/out" && ok "Secret 삭제 실패: 경고" || fail "Secret 삭제 실패: 경고 없음"
no_leak "Secret 삭제 실패"

run aws_fail
grep -q '^AWS ' "$t/log" && ok "aws 실패: aws까지 실행됨" || fail "aws 실패: aws 전에 끝났다"
expect_rc "aws 실패" nonzero; secret_gone "aws 실패"; no_leak "aws 실패"
grep -q 'AccessDenied' "$t/out" && ok "aws 실패: 오류 종류만 보여 준다" || fail "aws 실패: 오류 종류가 없다"

run lock_busy
expect_rc "다른 실행 중" nonzero
grep -q 'create secret' "$t/log" && fail "다른 실행 중: Secret을 만들었다" || ok "다른 실행 중: 아무것도 만들지 않음"

run old_secret_stuck 1
expect_rc "이전 Secret 못 지움" nonzero
grep -q 'create secret' "$t/log" && fail "이전 Secret 못 지움: 새 Secret을 만들었다" || ok "이전 Secret 못 지움: 새로 만들지 않음"
grep -q 'AWS ' "$t/log" && fail "이전 Secret 못 지움: 마스터 비밀을 읽었다" || ok "이전 Secret 못 지움: 마스터 비밀을 읽지 않음"

exit "$status"
