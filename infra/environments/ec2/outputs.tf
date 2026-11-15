output "instance_id" {
  description = "EC2 instance ID. Not secret, but keep it out of public issues together with the account ID."
  value       = module.k3s_host.instance_id
}

output "security_group_id" {
  description = "Host security group (the RDS PR adds egress 5432 to the RDS security group)."
  value       = module.k3s_host.security_group_id
}

output "port_forward_document_name" {
  description = "SSM document for port 80 only."
  value       = module.k3s_host.port_forward_document_name
}

output "connect_hint" {
  description = "How CN connects (shell) and how the web UI is reached (port 80 only)."
  value       = <<-EOT
    셸(CN):      aws ssm start-session --target ${module.k3s_host.instance_id}
    화면(80번):  aws ssm start-session --target ${module.k3s_host.instance_id} --document-name ${module.k3s_host.port_forward_document_name} --parameters localPortNumber=8080
                 → http://localhost:8080
  EOT
}
