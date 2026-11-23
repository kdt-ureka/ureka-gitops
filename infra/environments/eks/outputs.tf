output "cluster_name" {
  value = aws_eks_cluster.this.name
}
output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}
output "node_security_group_id" {
  description = "Pass to data stack eks_node_security_group_ids after EKS apply; remove there before EKS destroy."
  value       = aws_security_group.nodes.id
}
output "oidc_issuer_url" {
  description = "IRSA trust issuer. #63 adds only the ESO reader roles (secrets.tf)."
  value       = aws_iam_openid_connect_provider.this.url
}
output "kubeconfig_hint" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name} --profile ureka-admin --alias ${aws_eks_cluster.this.name}"
}
output "eso_reader_role_names" {
  description = "#63 ESO reader IRSA role names per environment (ARN = account ID + this name; keep the ARN out of Git)."
  value       = { for env, role in aws_iam_role.eso_reader : env => role.name }
}
