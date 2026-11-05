# 서비스 하나의 ECR 저장소. TravelPlanner travel-gitops/infra/modules/service_ecr 기반.
# 태그 변경 불가(IMMUTABLE): 같은 sha-<commit> 태그를 다른 이미지로 덮어쓸 수 없다.
resource "aws_ecr_repository" "this" {
  name                 = "${var.project_name}/${var.service_name}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }

  # 기본 스캔(무료). 차단 기준은 CI의 Trivy(C6)와 보안 관문 G2에서 정한다.
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after seven days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest images for rollback"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
