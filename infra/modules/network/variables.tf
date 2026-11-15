variable "name" {
  type        = string
  description = "Name prefix for network resources (for example ureka)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase letters, digits or hyphens (2-31 chars)."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "VPC IPv4 CIDR. Must be a /16 that does not overlap k3s defaults (10.42.0.0/16 pods, 10.43.0.0/16 services)."

  validation {
    condition = (
      can(cidrhost(var.vpc_cidr, 0)) &&
      endswith(var.vpc_cidr, "/16") &&
      !contains(["10.42.0.0/16", "10.43.0.0/16"], var.vpc_cidr)
    )
    error_message = "vpc_cidr must be a valid /16 other than 10.42.0.0/16 and 10.43.0.0/16 (k3s pod/service ranges)."
  }
}

variable "availability_zones" {
  type        = list(string)
  description = "Exactly two distinct AZs. One public and one private subnet is created in each."

  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "availability_zones must list exactly two distinct AZs."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDRs, same order as availability_zones."

  validation {
    condition     = length(var.public_subnet_cidrs) == 2 && alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "public_subnet_cidrs must list two valid CIDRs."
  }
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs, same order as availability_zones. No route to the internet."

  validation {
    condition     = length(var.private_subnet_cidrs) == 2 && alltrue([for c in var.private_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "private_subnet_cidrs must list two valid CIDRs."
  }
}
