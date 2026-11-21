variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}
variable "allowed_account_ids" {
  type      = list(string)
  sensitive = true
  validation {
    condition     = length(var.allowed_account_ids) > 0 && alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "Supply the approved account IDs in private tfvars."
  }
}
variable "project_name" {
  type    = string
  default = "ureka"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,24}$", var.project_name))
    error_message = "Use a short lowercase project name."
  }
}
variable "availability_zones" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2c"]
  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "Exactly two different AZs are required; NAT uses the first."
  }
}
variable "kubernetes_version" {
  type    = string
  default = "1.37"
  validation {
    condition     = var.kubernetes_version == "1.37"
    error_message = "This draft reviews 1.37 only; review code and add-on compatibility before changing."
  }
}
variable "admin_role_arn" {
  type        = string
  sensitive   = true
  description = "IAM role ARN of the CN SSO role, not an STS assumed-role session ARN. Keep out of Git."
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.admin_role_arn))
    error_message = "Supply an IAM role ARN (SSO path included) in private tfvars."
  }
}
variable "admin_public_access_cidrs" {
  type        = list(string)
  sensitive   = true
  description = "Current administrator public IPv4 /32s. No world-open fallback."
  validation {
    condition     = length(var.admin_public_access_cidrs) > 0 && alltrue([for c in var.admin_public_access_cidrs : can(cidrnetmask(c)) && endswith(c, "/32")])
    error_message = "Supply at least one valid IPv4 /32."
  }
}
variable "desired_nodes" {
  type    = number
  default = 2
  validation {
    condition     = contains([2, 3], var.desired_nodes)
    error_message = "Choose two or three on-demand nodes. No autoscaler is installed."
  }
}
variable "addon_versions" {
  type = object({
    vpc-cni            = string
    coredns            = string
    kube-proxy         = string
    aws-ebs-csi-driver = string
  })
  description = "Exact 1.37-compatible EKS build versions, checked by CN before plan; no automatic latest drift."
  validation {
    condition     = alltrue([for v in values(var.addon_versions) : can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", v))])
    error_message = "Set all four exact EKS build versions, e.g. vX.Y.Z-eksbuild.N."
  }
}
variable "ami_release_version" {
  type        = string
  description = "Exact EKS AL2023 x86_64 standard AMI release compatible with 1.37; CN checks availability."
  validation {
    condition     = can(regex("^1\\.37\\.[0-9]+-[0-9]{8}$", var.ami_release_version))
    error_message = "Pin a 1.37 patch/date AMI release (1.37.P-YYYYMMDD)."
  }
}
