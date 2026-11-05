variable "project_name" {
  type        = string
  description = "Lowercase project identifier used as the ECR namespace."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "project_name must be lowercase letters, numbers and hyphens."
  }
}

variable "service_name" {
  type        = string
  description = "Lowercase service identifier (auth, chat, content, ops, recommend, frontend)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.service_name))
    error_message = "service_name must be lowercase letters, numbers and hyphens."
  }
}

variable "max_image_count" {
  type        = number
  description = "Maximum number of images kept in the repository."
  default     = 20

  validation {
    condition     = var.max_image_count >= 5 && floor(var.max_image_count) == var.max_image_count
    error_message = "max_image_count must be an integer of at least five so rollback images remain."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to ECR resources."
  default     = {}
}
