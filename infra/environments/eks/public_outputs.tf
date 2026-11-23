# 공개 입구 출력. ARN에는 계정 ID가 있어 화면 공유·Git에 붙이지 않는다.
# Argo 등록 스크립트(scripts/eks/register_public_apps.py)는 이 출력이 아니라 고정 이름으로 AWS에서 직접 조회한다.
output "public_web_acl_name" {
  value = var.public_enabled ? aws_wafv2_web_acl.public[0].name : null
}
output "lbc_role_name" {
  value = var.public_enabled ? aws_iam_role.lbc[0].name : null
}
output "public_hosts" {
  value = sort(tolist(local.public_hosts))
}
