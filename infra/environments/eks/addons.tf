# Install CNI before nodes so they never start with the unconfigured default CNI.
resource "aws_eks_addon" "cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = var.addon_versions.vpc-cni
  service_account_role_arn    = aws_iam_role.addon["cni"].arn
  configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_iam_role_policy_attachment.addon]
}
resource "aws_eks_addon" "runtime" {
  for_each                    = toset(["coredns", "kube-proxy", "aws-ebs-csi-driver"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = var.addon_versions[each.value]
  service_account_role_arn    = each.value == "aws-ebs-csi-driver" ? aws_iam_role.addon["ebs"].arn : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_eks_node_group.this, aws_iam_role_policy_attachment.addon]
}
