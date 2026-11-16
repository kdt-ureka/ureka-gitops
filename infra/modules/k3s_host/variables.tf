variable "name" {
  type        = string
  description = "Name prefix (for example ureka-dev)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase letters, digits or hyphens (2-31 chars)."
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC for the host security group."
}

variable "subnet_id" {
  type        = string
  description = "Public subnet for the host. Outbound only: the security group has no inbound rules."
}

variable "instance_type" {
  type        = string
  description = "EC2 size. Start with t3.large; move to t3.xlarge if node memory > 80% or OOMKilled (stop -> change -> start)."
  default     = "t3.large"

  validation {
    condition     = contains(["t3.large", "t3.xlarge"], var.instance_type)
    error_message = "instance_type must be t3.large or t3.xlarge (x86_64, sizes reviewed for this project)."
  }
}

variable "cpu_credits" {
  type        = string
  description = "T3 credit mode. unlimited keeps full speed and bills surplus credits; standard throttles to 30% when credits run out."
  default     = "unlimited"

  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits must be standard or unlimited."
  }
}

variable "root_volume_size_gib" {
  type        = number
  description = "Root gp3 size. Holds the OS, container images and the first-version in-cluster PostgreSQL."
  default     = 40

  validation {
    condition     = var.root_volume_size_gib >= 30 && var.root_volume_size_gib <= 100
    error_message = "root_volume_size_gib must be between 30 and 100."
  }
}

variable "ami_ssm_parameter" {
  type        = string
  description = "Public SSM parameter that resolves the Amazon Linux 2023 x86_64 AMI."
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "ecr_registry" {
  type        = string
  description = "ECR registry host (<account>.dkr.ecr.<region>.amazonaws.com). Written to the host for the GitOps bootstrap; never commit the real value."

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com$", var.ecr_registry))
    error_message = "ecr_registry must look like <12 digits>.dkr.ecr.<region>.amazonaws.com."
  }
}

variable "ecr_repository_arns" {
  type        = list(string)
  description = "ECR repositories the node may pull from (our service repositories only)."

  validation {
    condition     = length(var.ecr_repository_arns) > 0 && alltrue([for a in var.ecr_repository_arns : can(regex("^arn:aws:ecr:[a-z0-9-]+:[0-9]{12}:repository/[a-z0-9._/-]+$", a))])
    error_message = "ecr_repository_arns must be explicit ECR repository ARNs (no wildcards)."
  }
}

variable "k3s_version" {
  type        = string
  description = "Pinned k3s release. Keep the Kubernetes minor equal to kind (1.36)."
  default     = "v1.36.6+k3s1"

  validation {
    condition     = can(regex("^v1\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version must be an exact release like v1.36.6+k3s1."
  }
}

variable "k3s_sha256" {
  type        = string
  description = "SHA-256 of the k3s amd64 binary for k3s_version (from the release sha256sum-amd64.txt)."
  default     = "66ceb8e67edfa547195135d74783bfadc2ecc04a91059e90ae5f70a3dbc98c15"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.k3s_sha256))
    error_message = "k3s_sha256 must be a 64-char lowercase hex SHA-256."
  }
}

variable "k3s_install_sha256" {
  type        = string
  description = "SHA-256 of install.sh at the k3s_version tag."
  default     = "46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.k3s_install_sha256))
    error_message = "k3s_install_sha256 must be a 64-char lowercase hex SHA-256."
  }
}

variable "ecr_credential_provider_version" {
  type        = string
  description = "Pinned cloud-provider-aws release for ecr-credential-provider (newest with a published linux/amd64 binary)."
  default     = "v1.35.3"

  validation {
    condition     = can(regex("^v1\\.[0-9]+\\.[0-9]+$", var.ecr_credential_provider_version))
    error_message = "ecr_credential_provider_version must be an exact release like v1.35.3."
  }
}

variable "ecr_credential_provider_sha256" {
  type        = string
  description = "SHA-256 of ecr-credential-provider-linux-amd64 for ecr_credential_provider_version."
  default     = "1b07f078c8056cfea91adf6f5ba14df0dc9b908a5e8588d99df23d9e8e9a67fd"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.ecr_credential_provider_sha256))
    error_message = "ecr_credential_provider_sha256 must be a 64-char lowercase hex SHA-256."
  }
}

variable "termination_protection" {
  type        = bool
  description = "Block terminate (console/API). The host must not be recreated until secrets move to Secrets Manager."
  default     = true
}

variable "db_egress_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs the host may reach on TCP 5432 (RDS). Empty = no database egress."
  default     = []

  validation {
    condition = alltrue([for c in var.db_egress_cidrs :
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", c)) && can(cidrhost(c, 0)) && !contains(["0.0.0.0/0"], c) && tonumber(split("/", c)[1]) >= 16
    ])
    error_message = "db_egress_cidrs must be IPv4 CIDRs of /16 or narrower (never 0.0.0.0/0)."
  }
}
