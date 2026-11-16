# AWS 자격 없이 실행한다: terraform test (mock provider, plan만)
# 계정 ID는 테스트용 123456789012만 쓴다.
mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
    }
  }

  mock_data "aws_security_group" {
    defaults = {
      id = "sg-0ec2host000000000"
    }
  }

  mock_data "aws_iam_role" {
    defaults = {
      name = "ureka-dev-k3s-host"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds!db-00000000-0000-0000-0000-000000000000-AbCdEf"
        kms_key_id    = "alias/aws/secretsmanager"
        secret_status = "active"
      }]
    }
  }
}

variables {
  allowed_account_ids = ["123456789012"]
}

run "not_public_and_private_subnets_only" {
  command = apply

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "RDS must not be publicly accessible."
  }

  assert {
    condition     = toset(aws_db_subnet_group.this.subnet_ids) == toset(["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"])
    error_message = "DB subnet group must be exactly the two private subnets."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted && aws_db_instance.this.manage_master_user_password
    error_message = "Storage must be encrypted and the master password managed by RDS in Secrets Manager."
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection && aws_db_instance.this.skip_final_snapshot == false && aws_db_instance.this.backup_retention_period >= 1
    error_message = "Deletion protection, final snapshot and automated backups must stay on."
  }

  assert {
    condition     = aws_db_instance.this.multi_az == false && aws_db_instance.this.instance_class == "db.t4g.micro"
    error_message = "Dev defaults: single AZ, db.t4g.micro."
  }

  assert {
    condition     = one([for p in aws_db_parameter_group.this.parameter : p.value if p.name == "rds.force_ssl"]) == "1"
    error_message = "TLS must be required (rds.force_ssl = 1)."
  }
}

run "only_ec2_host_on_5432_no_egress" {
  command = apply

  assert {
    condition     = length(aws_security_group.rds.ingress) == 1 && length(aws_security_group.rds.egress) == 0
    error_message = "RDS security group must have exactly one ingress rule and no egress."
  }

  assert {
    condition = alltrue([for r in aws_security_group.rds.ingress :
      r.protocol == "tcp" && r.from_port == 5432 && r.to_port == 5432 &&
      tolist(r.security_groups) == tolist(["sg-0ec2host000000000"]) &&
    length(r.cidr_blocks) == 0 && length(r.ipv6_cidr_blocks) == 0 && length(r.prefix_list_ids) == 0 && r.self == false])
    error_message = "The only ingress must be TCP 5432 from the k3s host security group (no CIDR, no self)."
  }
}

run "ec2_reads_only_the_master_secret" {
  command = apply

  assert {
    condition     = aws_iam_role_policy.ec2_read_master_secret.role == "ureka-dev-k3s-host"
    error_message = "Policy must attach to the k3s host role."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.ec2_read_master_secret.policy) == {
      Version = "2012-10-17"
      Statement = [{
        Sid      = "ReadRdsMasterSecretOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds!db-00000000-0000-0000-0000-000000000000-AbCdEf"]
      }]
    }
    error_message = "EC2 may only GetSecretValue on the one RDS master secret ARN (no List, no wildcard)."
  }
}

run "rejects_wrong_private_subnet_count" {
  command = plan

  override_data {
    target = data.aws_subnets.private
    values = {
      ids = ["subnet-0aaaaaaaaaaaaaaaa"]
    }
  }

  expect_failures = [aws_db_subnet_group.this]
}

run "rejects_minor_version_pin" {
  command = plan

  variables {
    engine_version = "18.1"
  }

  expect_failures = [var.engine_version]
}

run "rejects_unreviewed_instance_class" {
  command = plan

  variables {
    instance_class = "db.r6g.large"
  }

  expect_failures = [var.instance_class]
}

run "rejects_disabled_backups" {
  command = plan

  variables {
    backup_retention_days = 0
  }

  expect_failures = [var.backup_retention_days]
}

run "rejects_bad_account_id" {
  command = plan

  variables {
    allowed_account_ids = ["not-an-account"]
  }

  expect_failures = [var.allowed_account_ids]
}
