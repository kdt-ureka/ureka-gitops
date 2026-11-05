provider "aws" {
  region = var.aws_region

  # 다른 AWS 계정(예: 이전 프로젝트 프로필)으로 실수로 실행되는 것을 막는다.
  # 계정 ID는 커밋하지 않는 terraform.tfvars나 TF_VAR_allowed_account_ids로 넣는다.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Stack     = "shared-ecr"
      Source    = "kdt-ureka/ureka-gitops"
    }
  }
}
