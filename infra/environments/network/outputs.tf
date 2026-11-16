output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs by AZ."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs by AZ."
  value       = module.network.private_subnet_ids
}

output "subnet_cidrs" {
  description = "Subnet CIDRs by tier and AZ."
  value       = module.network.subnet_cidrs
}
