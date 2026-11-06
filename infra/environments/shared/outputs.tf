# 서비스 레포 Actions Variables에 넣을 값. 계정 ID가 들어 있으니 PR·문서에 그대로 붙이지 않는다.
output "publishers" {
  description = "Per service: ECR repository URL, publisher role ARN and trusted OIDC subject."
  value = {
    for key, svc in var.services : key => {
      github_repository   = svc.github_repository
      ecr_repository_url  = module.service_ecr[key].repository_url
      publisher_role_arn  = module.ecr_publisher[key].role_arn
      github_oidc_subject = module.ecr_publisher[key].github_oidc_subject
    }
  }
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN trusted by the publisher roles."
  value       = local.github_oidc_provider_arn
}
