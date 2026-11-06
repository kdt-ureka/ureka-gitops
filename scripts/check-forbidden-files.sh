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

# 12자리 숫자 = AWS 계정 ID 후보(ARN 안의 계정 ID 포함: arn:aws:iam::<12자리>:...).
# 일치 항목 하나하나를 보고, 정확히 테스트·예시 값(123456789012, 000000000000)인 것만 제외한다.
# 같은 줄에 예시 값이 있어도 다른 12자리 숫자는 잡는다. provider lock 해시 파일은 제외한다.
# PUBLIC 로그에 값이 다시 남지 않도록 파일·줄 번호만 출력하고 숫자와 원문은 출력하지 않는다.
# 이 검사는 현재 트리만 본다. 커밋 이력 전체는 Gitleaks 규칙 aws-account-id가 본다.
id_hits=0
while IFS= read -r -d '' f; do
  case "$f" in
    *.terraform.lock.hcl) continue ;;
  esac
  [ -f "$f" ] || continue
  # 바이너리 파일은 건너뛴다(git grep -I와 같은 동작).
  if perl -e 'exit(-B $ARGV[0] ? 0 : 1)' -- "$f"; then continue; fi
  lines="$(perl -ne '
    while (/(?<![0-9A-Za-z])([0-9]{12})(?![0-9A-Za-z])/g) {
      next if $1 eq "123456789012" || $1 eq "000000000000";
      print "$.\n";
      last;
    }
  ' -- "$f")" || { echo "::error::검사 실패: ${f}"; exit 1; }
  if [ -n "$lines" ]; then
    while IFS= read -r n; do
      echo "::error file=${f},line=${n}::AWS 계정 ID로 보이는 12자리 숫자 (값은 출력하지 않음)"
    done <<< "$lines"
    id_hits=1
  fi
done < <(git ls-files -z)
if [ "$id_hits" -ne 0 ]; then
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "금지 파일·계정 ID 없음"
fi
exit "$status"
