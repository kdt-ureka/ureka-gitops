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

expect() { # expect <name> <want: pass|fail> <command...>
  local name="$1" want="$2"; shift 2
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  local got=pass; [ "$rc" -ne 0 ] && got=fail
  if [ "$got" != "$want" ]; then
    echo "FAIL ${name}: expected ${want}, got ${got} (exit ${rc})"; fail=1
  elif printf '%s' "$out" | grep -q -e "$fake" -e "$fake2"; then
    echo "FAIL ${name}: output contains the detected value"; fail=1
  else
    echo "ok   ${name}"
  fi
}

# 1. 예시 ID와 가짜 ID가 같은 줄에 섞여 있으면 실패해야 한다.
d="$(new_repo mixed)"
printf 'allowed_account_ids = ["%s", "%s"]\n' "$test_id" "$fake" > "$d/a.tfvars.example"
git -C "$d" add -A
expect "script: mixed line fails" fail bash -c "cd '$d' && bash '$check'"

# 2. 예시 ID만 있으면 통과해야 한다.
d="$(new_repo only-test)"
printf 'allowed_account_ids = ["%s", "000000000000"]\n' "$test_id" > "$d/a.tfvars.example"
git -C "$d" add -A
expect "script: test IDs only pass" pass bash -c "cd '$d' && bash '$check'"

# 3. 쉼표로 붙은 두 ID도 각각 본다(두 번째가 가짜).
d="$(new_repo adjacent)"
printf '%s,%s\n' "$test_id" "$fake" > "$d/ids.txt"
git -C "$d" add -A
expect "script: adjacent IDs fail" fail bash -c "cd '$d' && bash '$check'"

if [ -n "$gitleaks_bin" ]; then
  cfg="$repo_root/.gitleaks.toml"
  gl() { "$gitleaks_bin" git "$1" --config "$cfg" --redact --no-banner --exit-code 1 --log-level error; }

  # 4. 중간 커밋에 넣었다가 지운 일반 계정 ID도 이력 검사에서 잡아야 한다.
  d="$(new_repo history)"
  printf 'owner_id = %s\n' "$fake" > "$d/notes.txt"
  git -C "$d" add -A && git -C "$d" commit -qm add
  printf 'owner_id = <ACCOUNT_ID>\n' > "$d/notes.txt"
  git -C "$d" commit -qam remove
  expect "gitleaks: removed plain ID in history fails" fail gl "$d"

  # 5. ARN·ECR 호스트 형식.
  d="$(new_repo arn)"
  printf 'role = "arn:aws:iam::%s:role/x"\nhost = "%s.dkr.ecr.ap-northeast-2.amazonaws.com"\n' "$fake" "$fake2" > "$d/main.tf"
  git -C "$d" add -A && git -C "$d" commit -qm arn
  expect "gitleaks: ARN and ECR host fail" fail gl "$d"

  # 6. 예시 ID만 있는 이력은 통과해야 한다.
  d="$(new_repo gl-clean)"
  printf 'role = "arn:aws:iam::%s:role/x"\nids = ["%s", "000000000000"]\n' "$test_id" "$test_id" > "$d/main.tf"
  git -C "$d" add -A && git -C "$d" commit -qm clean
  expect "gitleaks: test IDs only pass" pass gl "$d"
else
  echo "skip gitleaks cases (binary not given)"
fi

exit "$fail"
