# Entire file uses a mock AWS provider; command=apply changes only test memory, never AWS.
mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/TEST" }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
  mock_data "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0" }
  }
  mock_data "aws_route_table" {
    defaults = { id = "rtb-0123456789abcdef0" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      identity = [{ oidc = [{ issuer = "https://oidc.eks.ap-northeast-2.amazonaws.com/id/TEST" }] }]
    }
  }
}
variables {
  allowed_account_ids       = ["123456789012"]
  admin_role_arn            = "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_Admin_test"
  admin_public_access_cidrs = ["192.0.2.1/32"]
  # Synthetic pins exercise the contract; these do not claim AWS availability.
  ami_release_version = "1.37.0-20261120"
  addon_versions = {
    vpc-cni            = "v1.22.3-eksbuild.1"
    coredns            = "v1.13.0-eksbuild.1"
    kube-proxy         = "v1.37.0-eksbuild.1"
    aws-ebs-csi-driver = "v1.60.0-eksbuild.1"
  }
}
run "private_nodes_and_restricted_api" {
  command = apply
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access && aws_eks_cluster.this.vpc_config[0].endpoint_public_access && toset(aws_eks_cluster.this.vpc_config[0].public_access_cidrs) == toset(["192.0.2.1/32"])
    error_message = "API must have private access plus only the admin CIDR."
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && !aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions && aws_eks_access_policy_association.admin.access_scope[0].type == "cluster"
    error_message = "Only explicit access entry grants administrator access."
  }
  assert {
    condition     = aws_eks_node_group.this.capacity_type == "ON_DEMAND" && aws_eks_node_group.this.scaling_config[0].desired_size == 2 && aws_eks_node_group.this.scaling_config[0].max_size == 3 && toset(aws_eks_node_group.this.subnet_ids) == toset([for az in var.availability_zones : data.aws_subnet.private[az].id])
    error_message = "Use two private on-demand nodes, maximum three."
  }
  assert {
    condition     = aws_route.private_internet.destination_cidr_block == "0.0.0.0/0" && aws_route.private_internet.nat_gateway_id == aws_nat_gateway.this.id && aws_nat_gateway.this.subnet_id == data.aws_subnet.nat.id
    error_message = "Temporary private default route must use this stack's public NAT."
  }
  assert {
    condition     = aws_launch_template.nodes.metadata_options[0].http_tokens == "required" && aws_launch_template.nodes.metadata_options[0].http_put_response_hop_limit == 1 && one(aws_launch_template.nodes.block_device_mappings).ebs[0].encrypted && one(aws_launch_template.nodes.block_device_mappings).ebs[0].delete_on_termination
    error_message = "Require IMDSv2, prevent normal Pod IMDS access, encrypt and delete root disk."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.nodes_self.referenced_security_group_id == aws_security_group.nodes.id && aws_vpc_security_group_ingress_rule.control_to_nodes.referenced_security_group_id == aws_eks_cluster.this.vpc_config[0].cluster_security_group_id && aws_vpc_security_group_ingress_rule.control_https_to_nodes.referenced_security_group_id == aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
    error_message = "Node ingress must come exclusively from cluster/node SGs."
  }
}
run "iam_addons_logs_and_recreation" {
  command = apply
  assert {
    condition     = toset(keys(aws_iam_role_policy_attachment.nodes)) == toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"])
    error_message = "No node CNI, EBS, secrets, or SSM policy."
  }
  assert {
    condition = alltrue([for k, role in aws_iam_role.addon :
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["${local.oidc_host}:sub"] == local.addon_service_accounts[k] &&
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["${local.oidc_host}:aud"] == "sts.amazonaws.com"
    ])
    error_message = "Each IRSA trust must match the exact service account and STS audience."
  }
  assert {
    condition     = jsondecode(aws_eks_addon.cni.configuration_values).enableNetworkPolicy == "true" && aws_eks_addon.cni.service_account_role_arn == aws_iam_role.addon["cni"].arn && aws_eks_addon.runtime["aws-ebs-csi-driver"].service_account_role_arn == aws_iam_role.addon["ebs"].arn
    error_message = "Enable CNI NetworkPolicy and separate CNI/EBS IRSA."
  }
  assert {
    condition     = aws_eks_addon.cni.addon_version == var.addon_versions.vpc-cni && alltrue([for k, a in aws_eks_addon.runtime : a.addon_version == var.addon_versions[k]]) && aws_eks_node_group.this.release_version == var.ami_release_version
    error_message = "Add-on and AMI releases must remain pinned."
  }
  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD" && !aws_eks_cluster.this.deletion_protection && toset(aws_eks_cluster.this.enabled_cluster_log_types) == toset(["audit"]) && aws_cloudwatch_log_group.cluster.retention_in_days == 7
    error_message = "Use standard support, audit only, seven-day retention, no destroy protection."
  }
}
run "rejects_world_open_api" {
  command = plan
  variables { admin_public_access_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.admin_public_access_cidrs]
}
run "rejects_empty_admin_cidrs" {
  command = plan
  variables { admin_public_access_cidrs = [] }
  expect_failures = [var.admin_public_access_cidrs]
}
run "rejects_session_arn" {
  command = plan
  variables { admin_role_arn = "arn:aws:sts::123456789012:assumed-role/Admin/session" }
  expect_failures = [var.admin_role_arn]
}
run "rejects_duplicate_azs" {
  command = plan
  variables { availability_zones = ["ap-northeast-2a", "ap-northeast-2a"] }
  expect_failures = [var.availability_zones]
}
run "rejects_unbounded_nodes" {
  command = plan
  variables { desired_nodes = 4 }
  expect_failures = [var.desired_nodes]
}
run "rejects_unpinned_ami" {
  command = plan
  variables { ami_release_version = "latest" }
  expect_failures = [var.ami_release_version]
}
run "rejects_unpinned_addon" {
  command = plan
  variables {
    addon_versions = {
      vpc-cni            = "latest"
      coredns            = "v1.13.0-eksbuild.1"
      kube-proxy         = "v1.37.0-eksbuild.1"
      aws-ebs-csi-driver = "v1.60.0-eksbuild.1"
    }
  }
  expect_failures = [var.addon_versions]
}
run "rejects_bad_account" {
  command = plan
  variables { allowed_account_ids = ["invalid"] }
  expect_failures = [var.allowed_account_ids]
}
