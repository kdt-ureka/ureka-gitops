terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69.0"
    }
  }

  # 원격 state: S3 + S3 네이티브 잠금(use_lockfile, DynamoDB 없음).
  # 버킷 이름 등 실제 값은 커밋하지 않는 backend.hcl로 넣는다:
  #   terraform init -backend-config=backend.hcl
  # 버킷 만드는 방법: infra/bootstrap/README.md
  backend "s3" {}
}
