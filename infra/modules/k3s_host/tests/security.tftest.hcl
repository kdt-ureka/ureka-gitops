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

run "local_port_range_is_1024_to_65535" {
  command = plan

  assert {
    condition = alltrue([
      for p in ["1024", "8080", "65535"] :
      can(regex(jsondecode(aws_ssm_document.port_forward_http.content).parameters.localPortNumber.allowedPattern, p))
    ])
    error_message = "Local ports 1024-65535 must be accepted."
  }

  assert {
    condition = alltrue([
      for p in ["0", "80", "1023", "65536", "99999", "8080;", "80 80"] :
      !can(regex(jsondecode(aws_ssm_document.port_forward_http.content).parameters.localPortNumber.allowedPattern, p))
    ])
    error_message = "Local ports outside 1024-65535 must be rejected."
  }
}

run "user_data_keeps_safety_settings" {
  command = plan

  assert {
    condition = alltrue([
      for needle in [
        "--proto '=https' --proto-redir '=https'",
        "--max-time 300",
        "sha256sum -c -",
        "secrets-encryption: true",
        "write-kubeconfig-mode: \"0600\"",
        "INSTALL_K3S_SKIP_DOWNLOAD=true",
        "INSTALL_K3S_SKIP_SELINUX_RPM=true",
        "\"Enforcing\"",
        "apiVersion: credentialprovider.kubelet.k8s.io/v1",
        "K3S_SHA256='${var.k3s_sha256}'",
        "ECR_PROVIDER_SHA256='${var.ecr_credential_provider_sha256}'",
        "K3S_INSTALL_SHA256='${var.k3s_install_sha256}'",
      ] : strcontains(local.user_data, needle)
    ])
    error_message = "User data must keep HTTPS-only pinned downloads, checksum checks, secret encryption, private kubeconfig and the SELinux stop."
  }

  assert {
    condition     = !strcontains(local.user_data, "set -x") && !strcontains(local.user_data, "get.k3s.io")
    error_message = "User data must not trace commands or fetch the unpinned get.k3s.io script."
  }
}

run "db_egress_adds_only_5432_to_given_cidrs" {
  command = plan

  variables {
    db_egress_cidrs = ["10.0.16.0/20", "10.0.32.0/20"]
  }

  assert {
    condition     = length(aws_security_group.host.egress) == 2 && length(aws_security_group.host.ingress) == 0
    error_message = "With RDS the host has exactly two egress rules (443 and 5432) and still no ingress."
  }

  assert {
    condition = length([for e in aws_security_group.host.egress : e if
      e.protocol == "tcp" && e.from_port == 5432 && e.to_port == 5432 &&
      toset(e.cidr_blocks) == toset(["10.0.16.0/20", "10.0.32.0/20"]) &&
      length(e.ipv6_cidr_blocks) == 0 && length(e.security_groups) == 0
    ]) == 1
    error_message = "The 5432 rule must target only the given private CIDRs."
  }

  assert {
    condition     = length([for e in aws_security_group.host.egress : e if e.from_port == 443 && toset(e.cidr_blocks) == toset(["0.0.0.0/0"])]) == 1
    error_message = "The 443 rule must stay unchanged."
  }
}

run "rejects_db_egress_to_internet" {
  command = plan

  variables {
    db_egress_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.db_egress_cidrs]
}

run "rejects_wide_db_egress" {
  command = plan

  variables {
    db_egress_cidrs = ["10.0.0.0/8"]
  }

  expect_failures = [var.db_egress_cidrs]
}
