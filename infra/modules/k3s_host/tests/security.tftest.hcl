# AWS 자격 없이 실행한다: terraform test (mock provider, plan만)
# 계정 ID는 테스트용 123456789012만 쓴다.
mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-northeast-2"
    }
  }
}

override_resource {
  target          = aws_security_group.host
  override_during = plan
  values = {
    id = "sg-0123456789abcdef0"
  }
}

variables {
  name         = "ureka-dev"
  vpc_id       = "vpc-0123456789abcdef0"
  subnet_id    = "subnet-0123456789abcdef0"
  ecr_registry = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com"
  ecr_repository_arns = [
    "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/auth",
    "arn:aws:ecr:ap-northeast-2:123456789012:repository/ureka/chat",
  ]
}

run "no_inbound_and_https_only_outbound" {
  command = plan

  assert {
    condition     = length(aws_security_group.host.ingress) == 0
    error_message = "Host security group must have no inbound rules."
  }

  assert {
    condition = alltrue([
      for e in aws_security_group.host.egress :
      e.protocol == "tcp" && e.from_port == 443 && e.to_port == 443 && length(e.ipv6_cidr_blocks) == 0 && tolist(e.cidr_blocks) == tolist(["0.0.0.0/0"])
    ]) && length(aws_security_group.host.egress) == 1
    error_message = "Host egress must be exactly one TCP 443 rule (IPv4 only)."
  }

  assert {
    condition     = length(aws_instance.host.vpc_security_group_ids) == 1 && contains(aws_instance.host.vpc_security_group_ids, aws_security_group.host.id)
    error_message = "The host must use only its own security group."
  }
}

run "imds_and_disk" {
  command = plan

  assert {
    condition = (
      aws_instance.host.metadata_options[0].http_tokens == "required" &&
      aws_instance.host.metadata_options[0].http_put_response_hop_limit == 1 &&
      aws_instance.host.metadata_options[0].instance_metadata_tags == "disabled"
    )
    error_message = "IMDSv2 must be required with hop limit 1 (pods cannot reach node credentials)."
  }

  assert {
    condition = (
      aws_instance.host.root_block_device[0].encrypted == true &&
      aws_instance.host.root_block_device[0].volume_type == "gp3"
    )
    error_message = "Root volume must be encrypted gp3."
  }

  assert {
    condition     = aws_instance.host.credit_specification[0].cpu_credits == "unlimited"
    error_message = "CPU credit mode must be explicit (default unlimited)."
  }

  assert {
    condition     = aws_instance.host.disable_api_termination == true && aws_instance.host.associate_public_ip_address == true
    error_message = "Termination protection on; public IP for outbound only."
  }
}

run "iam_is_pull_only" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.host.assume_role_policy).Statement[0].Principal == { Service = "ec2.amazonaws.com" }
    error_message = "Only EC2 may assume the host role."
  }

  assert {
    condition = (
      tolist(jsondecode(aws_iam_role_policy.ecr_pull.policy).Statement[0].Action) == tolist(["ecr:GetAuthorizationToken"]) &&
      jsondecode(aws_iam_role_policy.ecr_pull.policy).Statement[0].Resource == "*"
    )
    error_message = "Only ecr:GetAuthorizationToken may use Resource *."
  }

  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.ecr_pull.policy).Statement[1].Action) == toset(["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]) &&
      tolist(jsondecode(aws_iam_role_policy.ecr_pull.policy).Statement[1].Resource) == tolist(var.ecr_repository_arns)
    )
    error_message = "ECR access must be pull-only on the listed repositories."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.ecr_pull.policy).Statement) == 2
    error_message = "ECR policy must have exactly two statements."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ssm_core.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "Only the SSM core managed policy is attached."
  }
}

run "port_forward_document_is_fixed_to_80" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_ssm_document.port_forward_http.content).sessionType == "Port" &&
      jsondecode(aws_ssm_document.port_forward_http.content).properties.portNumber == "80" &&
      jsondecode(aws_ssm_document.port_forward_http.content).properties.type == "LocalPortForwarding"
    )
    error_message = "Port forwarding document must target host port 80 only."
  }

  assert {
    condition     = keys(jsondecode(aws_ssm_document.port_forward_http.content).parameters) == ["localPortNumber"]
    error_message = "Users may choose only the local port, not the destination port or host."
  }
}

run "rejects_unreviewed_instance_type" {
  command = plan

  variables {
    instance_type = "t3.2xlarge"
  }

  expect_failures = [var.instance_type]
}

run "rejects_wildcard_repository" {
  command = plan

  variables {
    ecr_repository_arns = ["arn:aws:ecr:ap-northeast-2:123456789012:repository/*"]
  }

  expect_failures = [var.ecr_repository_arns]
}

run "rejects_unpinned_k3s" {
  command = plan

  variables {
    k3s_version = "stable"
  }

  expect_failures = [var.k3s_version]
}
