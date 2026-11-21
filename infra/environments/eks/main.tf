# Direct AWS resources: small destroyable stack, explicit IAM/SG/lifecycle ownership.
# Discover network by the same tags as ec2; do not read another stack's state.
data "aws_vpc" "shared" {
  tags = { Project = var.project_name, Stack = "network" }
}
data "aws_subnet" "private" {
  for_each          = toset(var.availability_zones)
  vpc_id            = data.aws_vpc.shared.id
  availability_zone = each.value
  tags              = { Project = var.project_name, Stack = "network", Tier = "private" }
}
data "aws_subnet" "nat" {
  vpc_id            = data.aws_vpc.shared.id
  availability_zone = var.availability_zones[0]
  tags              = { Project = var.project_name, Stack = "network", Tier = "public" }
}
data "aws_route_table" "private" {
  vpc_id = data.aws_vpc.shared.id
  tags   = { Project = var.project_name, Stack = "network", Tier = "private" }
}
locals {
  name = "${var.project_name}-eks"
}
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat" }
}
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.aws_subnet.nat.id
  tags          = { Name = "${local.name}-nat" }
}
# network must first stop managing inline route=[]; this is the sole default-route owner.
resource "aws_route" "private_internet" {
  route_table_id         = data.aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 7
}
resource "aws_eks_cluster" "this" {
  name                          = local.name
  role_arn                      = aws_iam_role.cluster.arn
  version                       = var.kubernetes_version
  deletion_protection           = false
  bootstrap_self_managed_addons = false
  enabled_cluster_log_types     = ["audit"]
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  upgrade_policy {
    support_type = "STANDARD"
  }
  vpc_config {
    subnet_ids              = [for az in var.availability_zones : data.aws_subnet.private[az].id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_public_access_cidrs
  }
  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
}
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_role_arn
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
# Read-only team access belongs to #62. No placeholder principal receives permission here.
resource "aws_security_group" "nodes" {
  name        = "${local.name}-nodes"
  description = "Private EKS nodes; no Internet ingress, intra-cluster traffic only"
  vpc_id      = data.aws_vpc.shared.id
  tags        = { Name = "${local.name}-nodes" }
}
resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "Node and VPC CNI Pod communication; #49 applies NetworkPolicy"
}
resource "aws_vpc_security_group_ingress_rule" "control_to_nodes" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 1025
  to_port                      = 65535
  description                  = "Kubelet and admission webhooks from control plane"
}
resource "aws_vpc_security_group_ingress_rule" "control_https_to_nodes" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
resource "aws_vpc_security_group_ingress_rule" "nodes_to_api" {
  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
# General Internet egress is needed for Gemini/TMDB and image downloads.
# Workload egress restrictions are enforced by #49 NetworkPolicy, not this shared node SG.
resource "aws_vpc_security_group_egress_rule" "nodes" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_launch_template" "nodes" {
  name_prefix            = "${local.name}-"
  vpc_security_group_ids = [aws_security_group.nodes.id]
  update_default_version = true
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      encrypted             = true
      delete_on_termination = true
    }
  }
}
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-general"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = [for az in var.availability_zones : data.aws_subnet.private[az].id]
  instance_types  = ["t3.large"]
  capacity_type   = "ON_DEMAND"
  ami_type        = "AL2023_x86_64_STANDARD"
  version         = var.kubernetes_version
  release_version = var.ami_release_version
  scaling_config {
    min_size     = 2
    max_size     = 3
    desired_size = var.desired_nodes
  }
  update_config { max_unavailable = 1 }
  launch_template {
    id      = aws_launch_template.nodes.id
    version = tostring(aws_launch_template.nodes.latest_version)
  }
  depends_on = [
    aws_route.private_internet, aws_iam_role_policy_attachment.nodes,
    aws_eks_addon.cni, aws_vpc_security_group_ingress_rule.nodes_self,
    aws_vpc_security_group_ingress_rule.control_to_nodes,
    aws_vpc_security_group_ingress_rule.control_https_to_nodes,
    aws_vpc_security_group_ingress_rule.nodes_to_api,
    aws_vpc_security_group_egress_rule.nodes,
  ]
}
