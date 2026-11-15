output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC IPv4 CIDR."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs by AZ."
  value       = { for k, s in aws_subnet.public : s.availability_zone => s.id }
}

output "private_subnet_ids" {
  description = "Private subnet IDs by AZ."
  value       = { for k, s in aws_subnet.private : s.availability_zone => s.id }
}

output "subnet_cidrs" {
  description = "Subnet CIDRs by tier and AZ (known at plan time)."
  value = {
    public  = { for k, s in aws_subnet.public : s.availability_zone => s.cidr_block }
    private = { for k, s in aws_subnet.private : s.availability_zone => s.cidr_block }
  }
}
