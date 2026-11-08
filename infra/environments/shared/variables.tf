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

variable "github_organization_id" {
  type        = number
  description = "Immutable numeric ID of the GitHub organization (gh api orgs/<org> --jq .id)."
  default     = 342343039

  validation {
    condition     = var.github_organization_id > 0 && floor(var.github_organization_id) == var.github_organization_id
    error_message = "github_organization_id must be a positive integer."
  }
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
  type = map(object({
    github_repository    = string
    github_repository_id = number
  }))
  description = "Service key => GitHub repository name and immutable numeric ID (gh api repos/<org>/<repo> --jq .id). Each gets one ECR repository and one publisher role."
  default = {
    auth      = { github_repository = "ureka-auth", github_repository_id = 1443841620 }
    chat      = { github_repository = "ureka-chat", github_repository_id = 1443842466 }
    content   = { github_repository = "ureka-content", github_repository_id = 1443843348 }
    ops       = { github_repository = "ureka-ops", github_repository_id = 1443844291 }
    recommend = { github_repository = "ureka-recommend", github_repository_id = 1443843923 }
    frontend  = { github_repository = "ureka-frontend", github_repository_id = 1443844833 }
    ingest    = { github_repository = "ureka-ingest", github_repository_id = 1447881588 }
  }

  validation {
    condition = alltrue([
      for svc in values(var.services) :
      svc.github_repository_id > 0 && floor(svc.github_repository_id) == svc.github_repository_id
    ])
    error_message = "Each github_repository_id must be a positive integer."
  }

  validation {
    condition     = length(distinct([for svc in values(var.services) : svc.github_repository_id])) == length(var.services)
    error_message = "github_repository_id values must be unique."
  }
}

variable "create_github_oidc_provider" {
  type        = bool
  description = "Create the account-level GitHub OIDC provider. Set false if it already exists (one per account)."
  default     = true
}
