# Ureka 서비스 이미지 저장소(ECR)와 GitHub Actions 게시 Role.
# dev·prod가 같은 digest를 쓰므로 환경별이 아니라 계정에 한 벌만 둔다.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

module "service_ecr" {
  source   = "../../modules/service_ecr"
  for_each = var.services

  project_name    = var.project_name
  service_name    = each.key
  max_image_count = var.max_image_count
}

module "ecr_publisher" {
  source   = "../../modules/github_ecr_publisher"
  for_each = var.services

  project_name             = var.project_name
  service_name             = each.key
  github_oidc_provider_arn = local.github_oidc_provider_arn
  github_organization      = var.github_organization
  github_repository        = each.value.github_repository
  github_branch            = var.github_branch
  ecr_repository_arn       = module.service_ecr[each.key].repository_arn
}
