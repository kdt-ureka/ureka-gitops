#!/usr/bin/env bash
# Git에 추적되면 안 되는 파일과 AWS 계정 ID(12자리 숫자)를 검사한다.
# .gitignore는 실수로 `git add -f` 하거나 규칙이 빠지면 막지 못하므로 CI에서 다시 확인한다.
set -euo pipefail

forbidden_paths='(^|/)([^/]*\.tfvars(\.json)?|[^/]*\.tfstate(\.[^/]*)?|[^/]*\.tfplan(\.json)?|tfplan[^/]*|plan\.json|[^/]*\.plan\.json|plan\.out|[^/]*\.plan\.out|backend\.hcl|[^/]*\.backend\.hcl|kubeconfig[^/]*|[^/]*\.kubeconfig|\.env(\.[^/]*)?)$|(^|/)(\.terraform|\.kube)/'
allowed_paths='(\.tfvars\.example|backend\.hcl\.example|\.env\.example)$'

status=0

bad_files="$(git ls-files | grep -E "$forbidden_paths" | grep -Ev "$allowed_paths" || true)"
if [ -n "$bad_files" ]; then
  while IFS= read -r f; do
    echo "::error file=${f}::커밋 금지 파일이 추적되고 있다: ${f}"
  done <<< "$bad_files"
  status=1
fi

# 12자리 숫자 = AWS 계정 ID 후보(ARN 안의 계정 ID 포함: arn:aws:iam::<12자리>:...). 테스트·예시용 값과 provider lock 해시는 제외한다.
# git grep 종료 코드: 0 일치, 1 없음, 그 밖은 오류(오류는 통과로 처리하지 않는다).
grep_status=0
raw_hits="$(git grep -nIE '(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)' -- . ':!*.terraform.lock.hcl')" || grep_status=$?
if [ "$grep_status" -gt 1 ]; then
  echo "::error::git grep 실행 실패 (exit ${grep_status})"
  exit 1
fi
account_hits="$(printf '%s\n' "$raw_hits" | grep -Ev '(123456789012|000000000000)' | grep -v '^$' || true)"
if [ -n "$account_hits" ]; then
  while IFS= read -r hit; do
    echo "::error file=${hit%%:*}::AWS 계정 ID로 보이는 12자리 숫자: ${hit#*:}"
  done <<< "$account_hits"
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "금지 파일·계정 ID 없음"
fi
exit "$status"
