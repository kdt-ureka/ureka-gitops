#!/usr/bin/env bash
# 유출 검사가 실제로 잡는지 확인하는 자체 테스트. 실제 계정 ID는 쓰지 않는다.
# 가짜 ID는 실행할 때 만들어서 저장소에 12자리 숫자를 남기지 않는다.
# 사용: scripts/test-leak-checks.sh [gitleaks 바이너리 경로]  (경로가 없으면 Gitleaks 검사는 건너뛴다)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check="$repo_root/scripts/check-forbidden-files.sh"
gitleaks_bin="${1:-}"
fake="$(printf '9%.0s' {1..12})"
fake2="$(printf '8%.0s' {1..12})"
test_id="123456789012"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

new_repo() {
  local dir="$work/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name leak-test
  echo "$dir"
}

# expect <name> <want: pass|fail> <marker> <command...>
# fail을 기대할 때는 종료 코드만 보지 않고, 출력에 marker(탐지 메시지 또는 Gitleaks 규칙 ID)가 모두 있어야 성공으로 본다.
# 설정 오류·실행 오류로 실패한 경우를 탐지로 착각하지 않기 위해서다. marker는 공백으로 여러 개를 줄 수 있다.
expect() {
  local name="$1" want="$2" markers="$3"; shift 3
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  local got=pass; [ "$rc" -ne 0 ] && got=fail
  if [ "$got" != "$want" ]; then
    echo "FAIL ${name}: expected ${want}, got ${got} (exit ${rc})"; fail=1; return
  fi
  if printf '%s' "$out" | grep -q -e "$fake" -e "$fake2"; then
    echo "FAIL ${name}: output contains the detected value"; fail=1; return
  fi
  if [ "$want" = fail ]; then
    local m
    for m in $markers; do
      if ! printf '%s\n' "$out" | grep -qF -- "$m"; then
        echo "FAIL ${name}: failed without expected detection '${m}' (exit ${rc})"; fail=1; return
      fi
    done
  fi
  echo "ok   ${name}"
}

script_mark="[account-id]"   # check-forbidden-files.sh 탐지 메시지의 고정 표식

# 1. 예시 ID와 가짜 ID가 같은 줄에 섞여 있으면 실패해야 한다.
d="$(new_repo mixed)"
printf 'allowed_account_ids = ["%s", "%s"]\n' "$test_id" "$fake" > "$d/a.tfvars.example"
git -C "$d" add -A
expect "script: mixed line fails" fail "$script_mark" bash -c "cd '$d' && bash '$check'"

# 2. 예시 ID만 있으면 통과해야 한다.
d="$(new_repo only-test)"
printf 'allowed_account_ids = ["%s", "000000000000"]\n' "$test_id" > "$d/a.tfvars.example"
git -C "$d" add -A
expect "script: test IDs only pass" pass "" bash -c "cd '$d' && bash '$check'"

# 3. 쉼표로 붙은 두 ID도 각각 본다(두 번째가 가짜).
d="$(new_repo adjacent)"
printf '%s,%s\n' "$test_id" "$fake" > "$d/ids.txt"
git -C "$d" add -A
expect "script: adjacent IDs fail" fail "$script_mark" bash -c "cd '$d' && bash '$check'"

if [ -n "$gitleaks_bin" ]; then
  cfg="$repo_root/.gitleaks.toml"
  # 탐지 결과를 JSON 보고서로 받아 규칙 ID만 출력한다(값은 --redact로 가려지고 출력하지도 않는다).
  # 보고서가 없으면(설정 오류 등) 규칙 ID가 출력되지 않으므로 expect가 실패로 처리한다.
  gl() {
    local report rc=0
    report="$(mktemp "$work/report.XXXXXX")"
    "$gitleaks_bin" git "$1" --config "$cfg" --redact --no-banner --exit-code 1 --log-level error \
      --report-format json --report-path "$report" >/dev/null 2>&1 || rc=$?
    if [ -s "$report" ]; then jq -r '.[].RuleID' "$report" | sort -u; fi
    return "$rc"
  }

  # 4. 중간 커밋에 넣었다가 지운 일반 계정 ID도 이력 검사에서 잡아야 한다.
  d="$(new_repo history)"
  printf 'owner_id = %s\n' "$fake" > "$d/notes.txt"
  git -C "$d" add -A && git -C "$d" commit -qm add
  printf 'owner_id = <ACCOUNT_ID>\n' > "$d/notes.txt"
  git -C "$d" commit -qam remove
  expect "gitleaks: removed plain ID in history fails" fail "aws-account-id" gl "$d"

  # 5. ARN·ECR 호스트 형식.
  d="$(new_repo arn)"
  printf 'role = "arn:aws:iam::%s:role/x"\nhost = "%s.dkr.ecr.ap-northeast-2.amazonaws.com"\n' "$fake" "$fake2" > "$d/main.tf"
  git -C "$d" add -A && git -C "$d" commit -qm arn
  expect "gitleaks: ARN and ECR host fail" fail "aws-arn-with-account-id aws-ecr-registry-host" gl "$d"

  # 6. 예시 ID에 쉼표로 바로 붙인 ID를 넣었다가 지운 이력도 잡아야 한다(구분자 소비로 놓치지 않는지).
  d="$(new_repo gl-adjacent)"
  printf 'ids = %s,%s\n' "$test_id" "$fake" > "$d/ids.txt"
  git -C "$d" add -A && git -C "$d" commit -qm add
  printf 'ids = %s\n' "$test_id" > "$d/ids.txt"
  git -C "$d" commit -qam remove
  expect "gitleaks: adjacent ID removed in history fails" fail "aws-account-id" gl "$d"

  # 7. 예시 ID만 있는 이력은 통과해야 한다(13자리 이상 숫자, 문자가 섞인 해시도 통과).
  d="$(new_repo gl-clean)"
  printf 'ts = %s1\nsha = 551f6fc8%sabc\n' "$test_id" "$test_id" > "$d/other.txt"
  git -C "$d" add -A && git -C "$d" commit -qm other
  printf 'role = "arn:aws:iam::%s:role/x"\nids = ["%s", "000000000000"]\n' "$test_id" "$test_id" > "$d/main.tf"
  git -C "$d" add -A && git -C "$d" commit -qm clean
  expect "gitleaks: test IDs only pass" pass "" gl "$d"
else
  echo "skip gitleaks cases (binary not given)"
fi

exit "$fail"
