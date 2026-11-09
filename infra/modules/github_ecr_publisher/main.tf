# GitHub Actions가 OIDC로 받는 서비스별 ECR push 전용 Role.
# TravelPlanner travel-gitops/infra/modules/github_ecr_publisher 기반. 바꾼 점:
# - 신뢰 조건: GitHub Environment 대신 main 브랜치 ref.
#   (조직이 Free 플랜이라 private 레포에서 Environments를 쓸 수 없다.)
#   sub는 TravelPlanner와 같은 GitHub "변경 불가 subject" 형식이다(조직·레포 숫자 ID 포함).
#   레포가 use_immutable_subject를 켜 두면 GitHub는 이 형식으로만 토큰을 준다.
#   숫자 ID는 재사용되지 않아, 같은 이름으로 다시 만든 레포나 조직은 이 Role을 받을 수 없다.
# - 권한: pull 권한(BatchGetImage, GetDownloadUrlForLayer)을 빼고 push와 digest 조회만 남겼다.
locals {
  github_oidc_audience = "sts.amazonaws.com"
  github_oidc_subject  = "repo:${var.github_organization}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:ref:refs/heads/${var.github_branch}"
  role_name            = "${var.project_name}-${var.service_name}-ecr-publisher"
}

locals {
  trust_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowGitHubActionsOnTrustedBranch"
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = var.github_oidc_provider_arn }
        Condition = {
          # StringLike가 아니라 StringEquals: 와일드카드 없이 레포·브랜치 하나만 허용한다.
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = local.github_oidc_audience
            "token.actions.githubusercontent.com:sub" = local.github_oidc_subject
          }
        }
      },
    ]
  }

  ecr_push_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken은 리소스 단위 제한을 지원하지 않는다.
        Sid      = "AuthenticateToEcr"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushAndDescribeServiceImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = var.ecr_repository_arn
      },
    ]
  }
}

resource "aws_iam_role" "publisher" {
  name                 = local.role_name
  description          = "GitHub Actions ${var.github_repository}@${var.github_branch} ECR publisher"
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "${local.role_name}-push"
  role   = aws_iam_role.publisher.id
  policy = jsonencode(local.ecr_push_policy)
}
