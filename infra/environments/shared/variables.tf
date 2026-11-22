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

variable "ses_enabled" {
  description = "prod 메일 발송용 SES 도메인 인증·DKIM·SMTP 전용 IAM 사용자를 만든다."
  type        = bool
  default     = false
}

variable "mail_domain" {
  description = "SES로 인증할 도메인(Route 53 공개 호스팅 영역이 있어야 한다)."
  type        = string
  default     = "magonjal.com"
}

variable "mail_from_address" {
  description = "auth가 보내는 발신 주소. SMTP 사용자 정책이 이 주소만 허용한다."
  type        = string
  default     = "no-reply@magonjal.com"

  validation {
    condition     = endswith(var.mail_from_address, "@${var.mail_domain}")
    error_message = "발신 주소는 인증한 도메인(mail_domain)의 주소여야 합니다."
  }
}
