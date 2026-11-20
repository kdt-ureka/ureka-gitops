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
  description = "#63 IRSA trust issuer. No service workload roles are granted here."
  value       = aws_iam_openid_connect_provider.this.url
}
output "kubeconfig_hint" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name} --profile ureka-admin --alias ${aws_eks_cluster.this.name}"
}
