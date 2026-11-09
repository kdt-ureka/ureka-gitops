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

override_resource {
  target          = module.service_ecr["ingest"].aws_ecr_repository.this
  override_during = plan
  values = {
    arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/ingest"
    repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ureka/ingest"
  }
}

override_resource {
  target          = module.ecr_publisher["ingest"].aws_iam_role.publisher
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/ureka-ingest-ecr-publisher"
  }
}

variables {
  allowed_account_ids = ["123456789012"]
}

run "one_repository_and_role_per_service" {
  command = plan

  assert {
    condition     = length(module.service_ecr) == 7 && length(module.ecr_publisher) == 7
    error_message = "Expected one ECR repository and one publisher role for each of the 7 services."
  }

  assert {
    condition     = toset(keys(module.service_ecr)) == toset(["auth", "chat", "content", "ops", "recommend", "frontend", "ingest"])
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
          "token.actions.githubusercontent.com:sub" = "repo:kdt-ureka@342343039/${var.services[k].github_repository}@${var.services[k].github_repository_id}:ref:refs/heads/main"
        }
      }
    ])
    error_message = "Trust conditions must be exactly aud=sts.amazonaws.com and sub=repo:kdt-ureka@<org_id>/<repo>@<repo_id>:ref:refs/heads/main."
  }

  assert {
    condition     = module.ecr_publisher["chat"].github_oidc_subject == "repo:kdt-ureka@342343039/ureka-chat@1443842466:ref:refs/heads/main"
    error_message = "chat role must trust only kdt-ureka/ureka-chat on main."
  }

  # ingest는 EKS Job/CronJob 워커. 다른 서비스와 같은 규칙을 따르는지 값으로 고정해 확인한다.
  assert {
    condition = (
      module.ecr_publisher["ingest"].github_oidc_subject == "repo:kdt-ureka@342343039/ureka-ingest@1447881588:ref:refs/heads/main" &&
      module.ecr_publisher["ingest"].trust_policy.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:kdt-ureka@342343039/ureka-ingest@1447881588:ref:refs/heads/main"
    )
    error_message = "ingest role must trust only kdt-ureka/ureka-ingest on main."
  }
}

run "auth_subject_matches_real_github_token" {
  command = plan

  # 2026-11-08 auth main CI에서 GitHub가 실제로 보낸 sub 값(kdt-ureka/ureka-auth#8 실패 원인).
  assert {
    condition     = module.ecr_publisher["auth"].github_oidc_subject == "repo:kdt-ureka@342343039/ureka-auth@1443841620:ref:refs/heads/main"
    error_message = "auth role must trust the immutable subject GitHub actually issues."
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

  # 서비스마다 저장소 ARN이 달라야 한다(override가 겹치면 위 검사가 의미 없어진다).
  assert {
    condition     = length(toset([for k, m in module.service_ecr : m.repository_arn])) == 7
    error_message = "Each service must have a unique ECR repository ARN."
  }

  assert {
    condition     = module.ecr_publisher["ingest"].ecr_push_policy.Statement[1].Resource == "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/ingest"
    error_message = "ingest role must push only to ureka/ingest."
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

  # 규칙은 정확히 하나: 태그 없는 이미지를 push 후 7일 지나면 삭제. 태그 붙은 이미지를 지우는 규칙은 없다(배포·롤백 digest 보호).
  assert {
    condition = alltrue([
      for k, m in module.service_ecr :
      length(m.security_settings.lifecycle_policy.rules) == 1 &&
      m.security_settings.lifecycle_policy.rules[0].rulePriority == 1 &&
      m.security_settings.lifecycle_policy.rules[0].selection.tagStatus == "untagged" &&
      m.security_settings.lifecycle_policy.rules[0].selection.countType == "sinceImagePushed" &&
      m.security_settings.lifecycle_policy.rules[0].selection.countUnit == "days" &&
      m.security_settings.lifecycle_policy.rules[0].selection.countNumber == 7 &&
      length(keys(m.security_settings.lifecycle_policy.rules[0].selection)) == 4 &&
      m.security_settings.lifecycle_policy.rules[0].action == { type = "expire" }
    ])
    error_message = "Lifecycle policy must be exactly one rule: expire untagged images 7 days after push."
  }
}

run "rejects_wildcard_branch" {
  command = plan

  variables {
    github_branch = "*"
  }

  expect_failures = [var.github_branch]
}

run "rejects_non_integer_repository_id" {
  command = plan

  variables {
    services = {
      auth = { github_repository = "ureka-auth", github_repository_id = 1.5 }
    }
  }

  expect_failures = [var.services]
}

run "rejects_duplicate_repository_id" {
  command = plan

  variables {
    services = {
      auth = { github_repository = "ureka-auth", github_repository_id = 1443841620 }
      chat = { github_repository = "ureka-chat", github_repository_id = 1443841620 }
    }
  }

  expect_failures = [var.services]
}

run "rejects_invalid_organization_id" {
  command = plan

  variables {
    github_organization_id = 0
  }

  expect_failures = [var.github_organization_id]
}
