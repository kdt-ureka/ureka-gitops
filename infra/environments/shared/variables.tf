variable "aws_region" {
  type        = string
  description = "AWS region for ECR."
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
  description = "Project identifier used for ECR namespace and IAM names."
  default     = "ureka"
}

variable "github_organization" {
  type        = string
  description = "GitHub organization that owns the service repositories."
  default     = "kdt-ureka"
}

variable "github_branch" {
  type        = string
  description = "Branch whose workflows may publish images."
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.github_branch)) && !strcontains(var.github_branch, "*")
    error_message = "github_branch must be a concrete branch name without wildcards."
  }
}

variable "services" {
  type        = map(object({ github_repository = string }))
  description = "Service key => GitHub repository. Each gets one ECR repository and one publisher role."
  default = {
    auth      = { github_repository = "ureka-auth" }
    chat      = { github_repository = "ureka-chat" }
    content   = { github_repository = "ureka-content" }
    ops       = { github_repository = "ureka-ops" }
    recommend = { github_repository = "ureka-recommend" }
    frontend  = { github_repository = "ureka-frontend" }
  }
}

variable "create_github_oidc_provider" {
  type        = bool
  description = "Create the account-level GitHub OIDC provider. Set false if it already exists (one per account)."
  default     = true
}
