output "endpoint" {
  description = "Private DNS name of the instance (no account ID). Written in gitops environments/ec2/dev/data as an ExternalName target."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master secret. Contains the account ID: do not paste into public issues, PRs or chat."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "RDS security group (5432 from the k3s host only)."
  value       = aws_security_group.rds.id
}
