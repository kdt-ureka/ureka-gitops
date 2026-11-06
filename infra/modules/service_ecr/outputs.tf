output "repository_arn" {
  description = "Service ECR repository ARN."
  value       = aws_ecr_repository.this.arn
}

output "repository_name" {
  description = "Service ECR repository name."
  value       = aws_ecr_repository.this.name
}

output "repository_url" {
  description = "Service ECR repository URL. Deployments pin the image by sha256 digest."
  value       = aws_ecr_repository.this.repository_url
}

output "security_settings" {
  description = "Repository security settings (for review and tests)."
  value = {
    image_tag_mutability = aws_ecr_repository.this.image_tag_mutability
    force_delete         = aws_ecr_repository.this.force_delete
    scan_on_push         = aws_ecr_repository.this.image_scanning_configuration[0].scan_on_push
    encryption_type      = aws_ecr_repository.this.encryption_configuration[0].encryption_type
    lifecycle_policy     = local.lifecycle_policy
  }
}
