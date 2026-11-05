terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69.0"
    }
  }

  # 원격 state(S3 + use_lockfile)는 버킷 위치를 정한 뒤 붙인다.
  # 그 전까지는 local state로 plan만 실행하고 apply하지 않는다.
}
