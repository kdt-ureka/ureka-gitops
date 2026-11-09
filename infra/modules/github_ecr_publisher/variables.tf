variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in IAM resource names."
}

variable "service_name" {
  type        = string
  description = "Service identifier used in the role name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.service_name))
    error_message = "service_name must be lowercase letters, numbers and hyphens."
  }
}

variable "github_oidc_provider_arn" {
  type        = string
  description = "Account-level GitHub Actions OIDC provider ARN."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must be the GitHub Actions OIDC provider ARN."
  }
}

variable "github_organization" {
  type        = string
  description = "GitHub organization that owns the trusted repository."

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_organization))
    error_message = "github_organization must be a valid GitHub organization name."
  }
}

variable "github_owner_id" {
  type        = number
  description = "Immutable numeric ID of the GitHub organization (part of the immutable OIDC subject)."

  validation {
    condition     = var.github_owner_id > 0 && floor(var.github_owner_id) == var.github_owner_id
    error_message = "github_owner_id must be a positive integer."
  }
}

variable "github_repository_id" {
  type        = number
  description = "Immutable numeric ID of the trusted repository (part of the immutable OIDC subject)."

  validation {
    condition     = var.github_repository_id > 0 && floor(var.github_repository_id) == var.github_repository_id
    error_message = "github_repository_id must be a positive integer."
  }
}

variable "github_repository" {
  type        = string
  description = "GitHub repository (name only) whose workflows may assume the role."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be a repository name without the owner."
  }
}

variable "github_branch" {
  type        = string
  description = "Only workflows running on this branch may assume the role."
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.github_branch)) && !strcontains(var.github_branch, "*")
    error_message = "github_branch must be a concrete branch name without wildcards."
  }
}

variable "ecr_repository_arn" {
  type        = string
  description = "ARN of the only ECR repository this role may push to."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:ecr:[a-z0-9-]+:[0-9]{12}:repository/[a-z0-9][a-z0-9._/-]*$", var.ecr_repository_arn))
    error_message = "ecr_repository_arn must be a private ECR repository ARN."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to IAM resources."
  default     = {}
}
