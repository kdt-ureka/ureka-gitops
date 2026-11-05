output "role_arn" {
  description = "Role ARN for aws-actions/configure-aws-credentials."
  value       = aws_iam_role.publisher.arn
}

output "role_name" {
  description = "Publisher IAM role name."
  value       = aws_iam_role.publisher.name
}

output "github_oidc_subject" {
  description = "Exact OIDC subject the role trusts."
  value       = local.github_oidc_subject
}

output "trust_policy" {
  description = "Role trust policy document (for review and tests)."
  value       = local.trust_policy
}

output "ecr_push_policy" {
  description = "Inline push policy document (for review and tests)."
  value       = local.ecr_push_policy
}
