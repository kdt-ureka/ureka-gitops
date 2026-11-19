# ingest 적재용 CSV 보관 버킷 (이슈 #32).
# - 이름은 bucket_prefix로 AWS가 만든다. 실제 이름은 state·output에만 있고 Git에는 접두어만 남는다.
# - 올리기: CN 담당 SSO(관리자 권한)만. 이 파일은 사람 권한을 추가하지 않는다.
# - 읽기: EC2 호스트 역할이 var.ingest_csv_prefix 아래만 읽는다(쓰기·삭제 없음).
#   적재 Pod는 IMDS가 막혀(hop limit 1) 역할 자격을 못 받으므로, 받기는 호스트에서 ingest.sh fetch로 한다.

resource "aws_s3_bucket" "ingest" {
  bucket_prefix = "${var.project_name}-dev-ingest-"

  # 파일이 남아 있으면 destroy가 실패한다(실수로 원본을 지우지 않게).
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ACL을 쓰지 않는다. 모든 객체는 버킷 주인(계정) 소유.
resource "aws_s3_bucket_ownership_controls" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-S3: 공개 차단·IAM 범위가 주된 방어선이고, KMS는 키 비용·권한만 늘린다(state 버킷과 같은 방식).
resource "aws_s3_bucket_server_side_encryption_configuration" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# 같은 이름으로 다시 올려도 이전 파일을 되살릴 수 있게 한다.
resource "aws_s3_bucket_versioning" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.ingest_noncurrent_version_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.ingest]
}

# HTTPS가 아닌 요청은 거부한다.
resource "aws_s3_bucket_policy" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.ingest.arn, "${aws_s3_bucket.ingest.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  # 공개 차단이 먼저 적용된 뒤에 정책을 붙인다.
  depends_on = [aws_s3_bucket_public_access_block.ingest]
}

# EC2 호스트 역할: 적재 CSV prefix 읽기만.
resource "aws_iam_role_policy" "ingest_csv_read" {
  name = "ingest-csv-read"
  role = module.k3s_host.role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadIngestCsv"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.ingest.arn}/${var.ingest_csv_prefix}*"
      },
      {
        # 없는 파일이 403 대신 404로 보이게(원인 파악용). 목록도 prefix 아래만.
        Sid       = "ListIngestCsv"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.ingest.arn
        Condition = { StringLike = { "s3:prefix" = ["${var.ingest_csv_prefix}*"] } }
      },
    ]
  })
}
