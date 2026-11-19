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
  description = "Project identifier used for names, tags and ECR namespace."
  default     = "ureka"
}

variable "availability_zone" {
  type        = string
  description = "AZ of the public subnet for the host (RDS later uses both private subnets)."
  default     = "ap-northeast-2a"
}

variable "instance_type" {
  type        = string
  description = "t3.large to start; t3.xlarge if memory runs short (see modules/k3s_host)."
  default     = "t3.large"
}

variable "cpu_credits" {
  type        = string
  description = "T3 credit mode (unlimited or standard)."
  default     = "unlimited"
}

variable "services" {
  type        = list(string)
  description = "ECR repositories (<project>/<service>) the host may pull from. Same services as environments/shared."
  default     = ["auth", "chat", "content", "ops", "recommend", "frontend", "ingest"]

  validation {
    condition     = length(var.services) > 0 && alltrue([for s in var.services : can(regex("^[a-z][a-z0-9-]*$", s))])
    error_message = "services must be lowercase service names."
  }
}

variable "ingest_csv_prefix" {
  type        = string
  description = "S3 key prefix for ingest CSVs. The host role may read only under this prefix."
  default     = "ingest-csv/"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*/$", var.ingest_csv_prefix))
    error_message = "ingest_csv_prefix must be one lowercase path segment ending with '/'."
  }
}

variable "ingest_noncurrent_version_days" {
  type        = number
  description = "Days to keep replaced (noncurrent) CSV versions before S3 deletes them."
  default     = 30

  validation {
    condition     = var.ingest_noncurrent_version_days >= 1
    error_message = "ingest_noncurrent_version_days must be at least 1."
  }
}
