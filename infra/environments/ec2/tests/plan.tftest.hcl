# AWS 자격 없이 실행한다: terraform test (mock provider, plan만)
# 계정 ID는 테스트용 123456789012만 쓴다.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-northeast-2"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      id                = "subnet-0123456789abcdef0"
      availability_zone = "ap-northeast-2a"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }
}

variables {
  allowed_account_ids = ["123456789012"]
}

# VPC·서브넷 태그 조회는 실제 AWS에서만 의미가 있어 plan(교차 검토)으로 확인한다.
run "registry_and_pull_scope" {
  command = plan

  assert {
    condition     = local.ecr_registry == "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com"
    error_message = "Registry host must come from the running account and region."
  }

  assert {
    condition     = length(local.ecr_repository_arns) == 7 && contains(local.ecr_repository_arns, "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/auth")
    error_message = "Pull access must cover exactly the seven service repositories."
  }
}

run "rejects_bad_account_id" {
  command = plan

  variables {
    allowed_account_ids = ["not-an-account"]
  }

  expect_failures = [var.allowed_account_ids]
}
