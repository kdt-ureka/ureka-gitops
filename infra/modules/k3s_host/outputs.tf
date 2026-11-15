output "instance_id" {
  description = "EC2 instance ID (SSM target)."
  value       = aws_instance.host.id
}

output "security_group_id" {
  description = "Host security group. The RDS PR adds one egress rule to the RDS security group on 5432."
  value       = aws_security_group.host.id
}

output "role_name" {
  description = "Host IAM role name."
  value       = aws_iam_role.host.name
}

output "port_forward_document_name" {
  description = "SSM session document that forwards only to host port 80."
  value       = aws_ssm_document.port_forward_http.name
}

output "availability_zone" {
  description = "AZ of the host."
  value       = aws_instance.host.availability_zone
}
