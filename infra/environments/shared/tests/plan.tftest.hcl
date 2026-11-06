# AWS 자격 없이 실행한다: terraform test (mock provider, plan만)
# 계정 ID는 테스트용 123456789012만 쓴다.
mock_provider "aws" {
  override_during = plan

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }
}

# 서비스마다 다른 ECR ARN을 줘서 Role → 저장소 연결이 서비스별로 맞는지 검사한다.
override_resource {
  target          = module.service_ecr["auth"].aws_ecr_repository.this
  override_during = plan
  values = {
    arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/auth"
    repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ureka/auth"
  }
}

override_resource {
  target          = module.ecr_publisher["auth"].aws_iam_role.publisher
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/ureka-auth-ecr-publisher"
  }
}

override_resource {
  target          = module.service_ecr["chat"].aws_ecr_repository.this
  override_during = plan
  values = {
    arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/chat"
    repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ureka/chat"
  }
}

override_resource {
  target          = module.ecr_publisher["chat"].aws_iam_role.publisher
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/ureka-chat-ecr-publisher"
  }
}

override_resource {
  target          = module.service_ecr["content"].aws_ecr_repository.this
  override_during = plan
  values = {
    arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/content"
    repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ureka/content"
  }
}

override_resource {
  target          = module.ecr_publisher["content"].aws_iam_role.publisher
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/ureka-content-ecr-publisher"
  }
}

override_resource {
  target          = module.service_ecr["ops"].aws_ecr_repository.this
  override_during = plan
  values = {
    arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/ops"
    repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ureka/ops"
  }
}

override_resource {
  target          = module.ecr_publisher["ops"].aws_iam_role.publisher
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/ureka-ops-ecr-publisher"
  }
}

override_resource {
  target          = module.service_ecr["recommend"].aws_ecr_repository.this
  override_during = plan
  values = {
    arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/recommend"
    repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ureka/recommend"
  }
}

override_resource {
  target          = module.ecr_publisher["recommend"].aws_iam_role.publisher
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/ureka-recommend-ecr-publisher"
  }
}

override_resource {
  target          = module.service_ecr["frontend"].aws_ecr_repository.this
  override_during = plan
  values = {
    arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/frontend"
    repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ureka/frontend"
  }
}

override_resource {
  target          = module.ecr_publisher["frontend"].aws_iam_role.publisher
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/ureka-frontend-ecr-publisher"
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
    condition     = toset(keys(module.service_ecr)) == toset(["auth", "chat", "content", "ops", "recommend", "frontend"])
    error_message = "Unexpected service set."
  }
}

run "trust_policy_for_every_role" {
  command = plan

  assert {
    condition = alltrue([
      for k, m in module.ecr_publisher :
      length(m.trust_policy.Statement) == 1 &&
      m.trust_policy.Statement[0].Effect == "Allow" &&
      m.trust_policy.Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      m.trust_policy.Statement[0].Principal == { Federated = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
    ])
    error_message = "Every role must trust only the GitHub OIDC provider via AssumeRoleWithWebIdentity."
  }

  # 조건은 StringEquals 하나, 키는 aud·sub 둘뿐이고 값은 서비스별 정확한 레포·main.
  assert {
    condition = alltrue([
      for k, m in module.ecr_publisher :
      m.trust_policy.Statement[0].Condition == {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:kdt-ureka/${var.services[k].github_repository}:ref:refs/heads/main"
        }
      }
    ])
    error_message = "Trust conditions must be exactly aud=sts.amazonaws.com and sub=repo:kdt-ureka/<repo>:ref:refs/heads/main."
  }

  assert {
    condition     = module.ecr_publisher["chat"].github_oidc_subject == "repo:kdt-ureka/ureka-chat:ref:refs/heads/main"
    error_message = "chat role must trust only kdt-ureka/ureka-chat on main."
  }
}

run "push_policy_is_exact_and_scoped" {
  command = plan

  assert {
    condition = alltrue([
      for k, m in module.ecr_publisher :
      length(m.ecr_push_policy.Statement) == 2 &&
      m.ecr_push_policy.Statement[0].Effect == "Allow" &&
      m.ecr_push_policy.Statement[0].Action == "ecr:GetAuthorizationToken" &&
      m.ecr_push_policy.Statement[0].Resource == "*"
    ])
    error_message = "Statement 0 must be only ecr:GetAuthorizationToken on *."
  }

  # 허용 action 집합이 정확히 이 6개여야 한다(추가·누락 모두 실패).
  assert {
    condition = alltrue([
      for k, m in module.ecr_publisher :
      m.ecr_push_policy.Statement[1].Effect == "Allow" &&
      toset(m.ecr_push_policy.Statement[1].Action) == toset([
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
      ])
    ])
    error_message = "Push statement must allow exactly the six push/describe actions."
  }

  # 각 Role은 자기 서비스 저장소 하나에만 push한다.
  assert {
    condition = alltrue([
      for k, m in module.ecr_publisher :
      m.ecr_push_policy.Statement[1].Resource == "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/${k}" &&
      m.ecr_push_policy.Statement[1].Resource == module.service_ecr[k].repository_arn
    ])
    error_message = "Each role must be scoped to its own service ECR repository ARN."
  }
}

run "ecr_security_settings" {
  command = plan

  assert {
    condition = alltrue([
      for k, m in module.service_ecr :
      m.repository_name == "ureka/${k}" &&
      m.security_settings.image_tag_mutability == "IMMUTABLE" &&
      m.security_settings.force_delete == false &&
      m.security_settings.scan_on_push == true &&
      m.security_settings.encryption_type == "AES256"
    ])
    error_message = "ECR repositories must be IMMUTABLE, scan on push, AES256 and not force-deletable."
  }

  # 태그 붙은 이미지를 지우는 규칙이 없어야 한다(배포·롤백 digest 보호).
  assert {
    condition = alltrue([
      for k, m in module.service_ecr :
      length(m.security_settings.lifecycle_policy.rules) == 1 &&
      m.security_settings.lifecycle_policy.rules[0].selection.tagStatus == "untagged"
    ])
    error_message = "Lifecycle policy must only expire untagged images."
  }
}

run "rejects_wildcard_branch" {
  command = plan

  variables {
    github_branch = "*"
  }

  expect_failures = [var.github_branch]
}
