# AWS 자격 없이 실행한다: terraform test (mock provider, plan만)
mock_provider "aws" {
  override_during = plan

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }
  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/mock"
      repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mock"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
}

variables {
  allowed_account_ids = ["123456789012"]
}

run "one_repository_and_role_per_service" {
  command = plan

  assert {
    condition     = length(module.service_ecr) == 6 && length(module.ecr_publisher) == 6
    error_message = "Expected one ECR repository and one publisher role for each of the 6 services."
  }

  assert {
    condition     = module.ecr_publisher["auth"].github_oidc_subject == "repo:kdt-ureka/ureka-auth:ref:refs/heads/main"
    error_message = "auth role must trust only kdt-ureka/ureka-auth on main."
  }

  assert {
    condition     = alltrue([for k, m in module.ecr_publisher : !strcontains(m.github_oidc_subject, "*")])
    error_message = "OIDC subjects must not contain wildcards."
  }

  assert {
    condition     = module.ecr_publisher["auth"].trust_policy.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "Trust policy must pin the OIDC audience to sts.amazonaws.com."
  }

  assert {
    condition     = length(module.ecr_publisher["auth"].trust_policy.Statement) == 1 && !contains(keys(module.ecr_publisher["auth"].trust_policy.Statement[0].Condition), "StringLike")
    error_message = "Trust policy must have one statement and no StringLike conditions."
  }

  # Resource "*"는 GetAuthorizationToken 하나에만 허용한다.
  assert {
    condition = alltrue([
      for m in values(module.ecr_publisher) : alltrue([
        for st in m.ecr_push_policy.Statement : st.Resource != "*" || st.Action == "ecr:GetAuthorizationToken"
      ])
    ])
    error_message = "Only ecr:GetAuthorizationToken may use Resource \"*\"."
  }

  assert {
    condition = alltrue([
      for m in values(module.ecr_publisher) : alltrue([
        for st in m.ecr_push_policy.Statement : !contains(flatten([st.Action]), "ecr:*") && !contains(flatten([st.Action]), "ecr:BatchGetImage")
      ])
    ])
    error_message = "Push policy must not grant ecr:* or pull permissions."
  }
}

run "rejects_wildcard_branch" {
  command = plan

  variables {
    github_branch = "*"
  }

  expect_failures = [var.github_branch]
}
