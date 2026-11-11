#!/usr/bin/env bash
# scripts/kind/p11-check.sh 회귀 시험. 클러스터 없이 가짜 kubectl로 돈다(CI Helm 워크플로와 로컬에서 같이 쓴다).
#
# 1) baseline: 모든 단계가 정상인 모습을 흉내 내면 종료 코드 0이어야 한다(시험 장치 자체가 맞는지 확인).
# 2) 그 정상 결과에서 한 가지씩만 바꾼 경우는 모두 실패(0이 아님)여야 한다.
set -euo pipefail
cd "$(dirname "$0")/.."

fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

# p11-check.sh의 필수 체크 ID 목록을 그대로 가져온다(목록이 바뀌어도 시험이 따라간다).
ids="$(sed -n '/^required=(/,/^)/p' scripts/kind/p11-check.sh | grep -v '^required=(\|^)' | tr -s ' \n' ' ')"
export FAKE_IDS="$ids"

cat >"$fake/kubectl" <<'SH'
#!/usr/bin/env bash
# 진짜 kubectl처럼 exec -i일 때만 표준 입력을 읽는다.
case " $* " in *" -i "*) cat >/dev/null 2>&1 || true ;; esac
mode="${FAKE_MODE:-baseline}"
args=" $* "
emit() { # 접두사(A|B|C|D 또는 M|X)에 맞는 ID를 PASS로 낸다. M06b는 EXCEPTION.
  for id in $FAKE_IDS; do
    [ "$mode" = drop_one_id ] && [ "$id" = C07 ] && continue                 # 필수 ID 하나만 빠짐
    if [ "$mode" = other_exception ] && [ "$id" = M01 ]; then                 # M06b가 아닌 EXCEPTION
      [[ "$1" == *M* ]] && echo "psql:<stdin>:1: NOTICE:  P11 EXCEPTION M01 예외"; continue
    fi
    case "$id" in
      M06b) [[ "$1" == *M* ]] && echo "psql:<stdin>:1: NOTICE:  P11 EXCEPTION M06b 예외" ;;
      [$1]*) echo "psql:<stdin>:1: NOTICE:  P11 PASS $id 정상" ;;
    esac
  done
}
case "$args" in *" get secret "*) printf 'dGVzdA=='; exit 0 ;; esac
[ "$mode" = exec_fail ] && { echo 'error: pods "postgres-0" not found' >&2; exit 1; }
[ "$mode" = silent_ok ] && exit 0

# sh -c '...' _ <login> <target> ... 형태에서 접속 대상 DB를 꺼낸다.
target=""; prev2=""; prev1=""
for a in "$@"; do [ "$prev2" = "_" ] && target="$a"; prev2="$prev1"; prev1="$a"; done
# 위 반복은 "_ 다음다음" 값을 잡는다.

case "$args" in
  *"select count(*)"*)
    [ "$mode" = count_text ] && { echo "abc"; exit 0; }
    echo 0; exit 0 ;;
  *"searchable_count"*)   # 1부
    emit ABCD
    [ "$mode" = part1_fail ] && { echo "psql:<stdin>:99: ERROR:  syntax error" >&2; exit 3; }
    exit 0 ;;
  *" -U postgres "*)      # 2부
    emit M
    [ "$mode" = part2_fail ] && exit 3
    exit 0 ;;
  *"select current_user"*)
    case "$mode" in
      self_rc_fail)   echo content_db_recommend; echo "psql: error: server closed the connection" >&2; exit 2 ;;
      self_rc_fail_quiet) echo content_db_recommend; exit 2 ;;   # 표준 오류 없이 이름만 찍고 비정상 종료
      self_wrong_user) echo someone_else; exit 0 ;;
    esac
    echo content_db_recommend; exit 0 ;;
  *"select 1"*)
    case "$mode" in
      cross_allowed) [ "$target" = auth_db ] && { echo 1; exit 0; } ;;
      cross_wrong_db) [ "$target" = auth_db ] && {
        printf 'psql: error: connection to server failed: FATAL:  permission denied for database "content_db"\nDETAIL:  User does not have CONNECT privilege.\n' >&2; exit 2; } ;;
      cross_other_error) [ "$target" = auth_db ] && { echo "psql: error: connection refused" >&2; exit 2; } ;;
      cross_no_connect_detail) [ "$target" = auth_db ] && {
        printf 'psql: error: FATAL:  permission denied for database "auth_db"\n' >&2; exit 2; } ;;
    esac
    printf 'psql: error: connection to server failed: FATAL:  permission denied for database "%s"\nDETAIL:  User does not have CONNECT privilege.\n' "$target" >&2
    exit 2 ;;
esac
exit 0
SH
chmod +x "$fake/kubectl"

run() { FAKE_MODE="$1" PATH="$fake:$PATH" bash scripts/kind/p11-check.sh </dev/null >"$fake/out.$1" 2>&1; }

status=0
if run baseline; then
  echo "ok   baseline: 정상 흉내 → 성공(0)"
else
  echo "FAIL baseline: 정상 흉내인데 실패. 시험 장치나 러너가 틀렸다"; tail -5 "$fake/out.baseline"; status=1
fi

for mode in exec_fail silent_ok count_text part1_fail part2_fail self_rc_fail self_rc_fail_quiet self_wrong_user \
            cross_allowed cross_wrong_db cross_other_error cross_no_connect_detail drop_one_id other_exception; do
  if run "$mode"; then
    echo "FAIL ${mode}: 성공(0)으로 끝났다"; status=1
  else
    echo "ok   ${mode}: 실패로 끝남"
  fi
done

if KUBE_CONTEXT=arn:aws:eks:example FAKE_MODE=baseline PATH="$fake:$PATH" bash scripts/kind/p11-check.sh </dev/null >/dev/null 2>&1; then
  echo "FAIL non-kind context: kind가 아닌 컨텍스트에서 실행됐다"; status=1
else
  echo "ok   non-kind context: 거부"
fi
exit "$status"
