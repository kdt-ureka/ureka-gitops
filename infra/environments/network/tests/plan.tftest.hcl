# AWS 자격 없이 실행한다: terraform test (mock provider, plan만)
# 계정 ID는 테스트용 123456789012만 쓴다.
mock_provider "aws" {}

variables {
  allowed_account_ids = ["123456789012"]
}

run "address_layout" {
  command = plan

  assert {
    condition = output.subnet_cidrs == {
      public  = { "ap-northeast-2a" = "10.0.0.0/24", "ap-northeast-2c" = "10.0.1.0/24" }
      private = { "ap-northeast-2a" = "10.0.16.0/20", "ap-northeast-2c" = "10.0.32.0/20" }
    }
    error_message = "Subnet layout must be public /24 x2 and private /20 x2 in 2a and 2c."
  }
}

run "rejects_bad_account_id" {
  command = plan

  variables {
    allowed_account_ids = ["not-an-account"]
  }

  expect_failures = [var.allowed_account_ids]
}
