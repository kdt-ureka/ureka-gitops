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

locals {
  # 태그 없는 이미지만 7일 뒤 정리한다.
  # 태그 붙은 이미지를 개수로 지우는 규칙은 두지 않는다: 배포 중이거나 롤백용으로 남긴 digest까지
  # 지울 수 있기 때문이다(IMMUTABLE·force_delete로는 막지 못함). 보존 구조는 infra/README.md 후속 작업 참고.
  lifecycle_policy = {
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
    ]
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy     = jsonencode(local.lifecycle_policy)
}
