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

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR. 10.0.0.0/16 avoids k3s defaults (10.42/16, 10.43/16)."
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "Two AZs where t3, RDS and EKS are all available."
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}
