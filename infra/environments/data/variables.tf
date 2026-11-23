variable "aws_region" {
  type        = string
  description = "AWS region."
  default     = "ap-northeast-2"
}

variable "allowed_account_ids" {
  type        = list(string)
  description = "The only AWS account IDs Terraform may operate on. Keep out of Git."

  validation {
    condition     = length(var.allowed_account_ids) > 0 && alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "allowed_account_ids must list at least one 12-digit AWS account ID."
  }
}

variable "project_name" {
  type        = string
  description = "Project identifier used for names and tags."
  default     = "ureka"
}

variable "engine_version" {
  type        = string
  description = "PostgreSQL major version. AWS picks the default minor; minor upgrades apply in the maintenance window."
  default     = "18"

  validation {
    condition     = can(regex("^[0-9]+$", var.engine_version))
    error_message = "engine_version must be a major version only (for example 18), so the minor can move without plan drift."
  }
}

variable "instance_class" {
  type        = string
  description = "RDS instance class. db.t4g.micro for dev; db.t4g.small if memory runs short."
  default     = "db.t4g.micro"

  validation {
    condition     = contains(["db.t4g.micro", "db.t4g.small"], var.instance_class)
    error_message = "instance_class must be db.t4g.micro or db.t4g.small (sizes reviewed for this project)."
  }
}

variable "allocated_storage_gib" {
  type        = number
  description = "gp3 storage size."
  default     = 20

  validation {
    condition     = var.allocated_storage_gib >= 20 && var.allocated_storage_gib <= 100
    error_message = "allocated_storage_gib must be between 20 and 100."
  }
}

variable "availability_zone" {
  type        = string
  description = "Single-AZ placement. Same AZ as the EC2 host to avoid cross-AZ transfer."
  default     = "ap-northeast-2a"
}

variable "backup_retention_days" {
  type        = number
  description = "Automated backup retention. At least 1 (0 would disable backups)."
  default     = 1

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 7
    error_message = "backup_retention_days must be 1-7 for dev."
  }
}

variable "deletion_protection" {
  type        = bool
  description = "Keep on. Turning it off is a reviewed change before any destroy/replace."
  default     = true
}

variable "eks_node_security_group_ids" {
  type        = set(string)
  default     = []
  description = "Optional EKS node SGs. Set after EKS apply; clear and apply before EKS destroy. Same VPC only."
  validation {
    condition     = length(var.eks_node_security_group_ids) <= 1 && alltrue([for id in var.eks_node_security_group_ids : can(regex("^sg-[0-9a-f]+$", id))])
    error_message = "Supply zero or one reviewed EKS node security group ID."
  }
}

variable "eks_dev_secret_copy_enabled" {
  type        = bool
  default     = false
  description = "#63: temporarily let the EC2 dev host write ureka/eks/dev/* (copy script only). Turn on, copy, turn off; never read."
}
