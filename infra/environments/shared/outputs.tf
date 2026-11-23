# 서비스 레포 Actions Variables에 넣을 값. 계정 ID가 들어 있으니 PR·문서에 그대로 붙이지 않는다.
output "publishers" {
  description = "Per service: ECR repository URL, publisher role ARN and trusted OIDC subject."
  value = {
    for key, svc in var.services : key => {
      github_repository    = svc.github_repository
      github_repository_id = svc.github_repository_id
      ecr_repository_url   = module.service_ecr[key].repository_url
      publisher_role_arn   = module.ecr_publisher[key].role_arn
      github_oidc_subject  = module.ecr_publisher[key].github_oidc_subject
    }
  }
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN trusted by the publisher roles."
  value       = local.github_oidc_provider_arn
}

output "ses_smtp_user_name" {
  description = "SMTP 자격을 만들 IAM 사용자 이름(scripts/ses/create-smtp-secret.py 입력)."
  value       = var.ses_enabled ? aws_iam_user.ses_smtp[0].name : null
}

output "ses_smtp_endpoint" {
  description = "auth MAIL_HOST 값."
  value       = var.ses_enabled ? "email-smtp.${var.aws_region}.amazonaws.com" : null
}
