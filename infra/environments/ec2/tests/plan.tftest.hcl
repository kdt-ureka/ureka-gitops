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
      cidr_block        = "10.0.16.0/20"
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
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
    condition = toset(local.ecr_repository_arns) == toset([
      for s in ["auth", "chat", "content", "ops", "recommend", "frontend", "ingest"] :
      "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/${s}"
    ]) && length(local.ecr_repository_arns) == 7
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

run "db_egress_only_to_private_subnets" {
  command = plan

  override_data {
    target = data.aws_subnet.private["subnet-0aaaaaaaaaaaaaaaa"]
    values = { cidr_block = "10.0.16.0/20" }
  }

  override_data {
    target = data.aws_subnet.private["subnet-0bbbbbbbbbbbbbbbb"]
    values = { cidr_block = "10.0.32.0/20" }
  }

  assert {
    condition     = local.private_subnet_cidrs == tolist(["10.0.16.0/20", "10.0.32.0/20"])
    error_message = "EC2 database egress must target exactly the private subnet CIDRs."
  }
}

# ingest CSV 버킷: 공개 차단·SSE-S3·버전 관리, 호스트 역할은 prefix 읽기만.
run "ingest_bucket_private_and_read_only" {
  command = plan

  override_resource {
    target          = aws_s3_bucket.ingest
    override_during = plan
    values = {
      id     = "ureka-dev-ingest-test"
      bucket = "ureka-dev-ingest-test"
      arn    = "arn:aws:s3:::ureka-dev-ingest-test"
    }
  }

  override_resource {
    target          = module.k3s_host.aws_iam_role.host
    override_during = plan
    values          = { name = "ureka-dev-k3s-host" }
  }

  assert {
    condition     = aws_s3_bucket.ingest.bucket_prefix == "ureka-dev-ingest-" && aws_s3_bucket.ingest.force_destroy == false
    error_message = "Bucket name must come from bucket_prefix (no real name in Git) and must not be force-destroyed."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.ingest.block_public_acls,
      aws_s3_bucket_public_access_block.ingest.ignore_public_acls,
      aws_s3_bucket_public_access_block.ingest.block_public_policy,
      aws_s3_bucket_public_access_block.ingest.restrict_public_buckets,
    ])
    error_message = "All four public access blocks must be on."
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.ingest.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled (BucketOwnerEnforced)."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.ingest.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Default encryption must be SSE-S3."
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.ingest.versioning_configuration).status == "Enabled"
    error_message = "Versioning must be enabled."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.ingest.rule).noncurrent_version_expiration).noncurrent_days == 30
    error_message = "Noncurrent versions must expire after 30 days by default."
  }

  assert {
    condition     = jsondecode(aws_s3_bucket_policy.ingest.policy).Statement[0].Effect == "Deny" && jsondecode(aws_s3_bucket_policy.ingest.policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "Bucket policy must deny non-TLS requests."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.ingest_csv_read.policy).Statement : s.Action
    ])) == toset(["s3:GetObject", "s3:ListBucket"])
    error_message = "Host role may only read and list ingest CSVs (no put/delete)."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.ingest_csv_read.policy).Statement[0].Resource == "arn:aws:s3:::ureka-dev-ingest-test/ingest-csv/*"
    error_message = "GetObject must be limited to the ingest-csv/ prefix."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.ingest_csv_read.policy).Statement[1].Condition.StringLike["s3:prefix"] == ["ingest-csv/*"]
    error_message = "ListBucket must be limited to the ingest-csv/ prefix."
  }

  assert {
    condition     = aws_iam_role_policy.ingest_csv_read.role == "ureka-dev-k3s-host"
    error_message = "Read policy must attach to the host role."
  }
}

run "rejects_bad_ingest_prefix" {
  command = plan

  variables {
    ingest_csv_prefix = "../"
  }

  expect_failures = [var.ingest_csv_prefix]
}
