# Terraform state 버킷 부트스트랩

`infra/environments/*`의 원격 state를 담을 S3 버킷을 **한 번만** 만든다. Terraform 자체 state를 담을 곳이 아직 없으므로 이 버킷만 AWS CLI로 만든다.

- 이 문서는 절차만 적는다. 실행은 CN 팀장이 직접 한다.
- 비용: S3 저장 용량·요청만 과금(state 파일은 수 KB). 시간당 과금 없음.
- 잠금은 S3 네이티브 잠금(`use_lockfile = true`, Terraform 1.10+). DynamoDB 테이블은 만들지 않는다.

## 설정

| 항목 | 값 |
|---|---|
| 이름 | `ureka-tfstate-<무작위 8자리 hex>` — **계정 ID를 넣지 않는다** |
| 리전 | ap-northeast-2 |
| 공개 차단 | 4개 항목 모두 켬 |
| 객체 소유권 | BucketOwnerEnforced (ACL 비활성) |
| 버전 관리 | 켬 (state 복구용) |
| 암호화 | SSE-S3 (AES256), bucket key |
| 버킷 정책 | TLS가 아닌 요청 거부 |
| 수명 주기 | 이전 버전 90일 후 삭제(최신 이전 버전 10개는 유지), 미완료 멀티파트 7일 후 삭제 |
| 잠금 | `use_lockfile = true` (state 옆 `.tflock` 객체, DynamoDB 없음) |
| 접근 | 최소 권한: 아래 "접근 권한" 참고. CI(GitHub Actions) Role에는 state 권한을 주지 않는다 |

## 명령 (bash/zsh)

```bash
# 0) 계정 확인: Ureka SSO 프로필만 쓴다. TravelPlanner 프로필(default, kdt-travel-*) 금지.
aws sso login --profile ureka-admin
export AWS_PROFILE=ureka-admin AWS_REGION=ap-northeast-2
aws sts get-caller-identity --query Arn --output text   # AWSReservedSSO_AdministratorAccess_... 인지 확인

# 1) 이름 정하기 (한 번만. 정한 이름은 팀 비공개 공간에 기록)
BUCKET="ureka-tfstate-$(openssl rand -hex 4)"
echo "$BUCKET"

# 2) 버킷 생성
aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# 3) 공개 차단 + 객체 소유권
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

# 4) 버전 관리 + 기본 암호화(SSE-S3)
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# 5) TLS 아닌 요청 거부
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"DenyInsecureTransport\",
    \"Effect\": \"Deny\",
    \"Principal\": \"*\",
    \"Action\": \"s3:*\",
    \"Resource\": [\"arn:aws:s3:::${BUCKET}\", \"arn:aws:s3:::${BUCKET}/*\"],
    \"Condition\": {\"Bool\": {\"aws:SecureTransport\": \"false\"}}
  }]
}"

# 6) 이전 버전·미완료 업로드 정리
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [{
    "ID": "expire-old-state-versions",
    "Status": "Enabled",
    "Filter": {},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 90, "NewerNoncurrentVersions": 10},
    "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
  }]
}'

# 7) 태그
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=Project,Value=ureka},{Key=ManagedBy,Value=aws-cli-bootstrap},{Key=Purpose,Value=terraform-state}]'
```

## 확인

```bash
aws s3api get-public-access-block --bucket "$BUCKET"        # 4개 모두 true
aws s3api get-bucket-versioning --bucket "$BUCKET"          # Status: Enabled
aws s3api get-bucket-encryption --bucket "$BUCKET"          # AES256
aws s3api get-bucket-ownership-controls --bucket "$BUCKET"  # BucketOwnerEnforced
aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text
```

## 접근 권한 (최소 권한)

- 지금 state에 접근하는 주체는 사람의 SSO 세션(`ureka-admin`)뿐이다. ECR 게시 Role 등 CI Role에는 S3 권한이 없다.
- 공개 차단 + TLS 강제 버킷 정책으로 외부·평문 접근을 막는다.
- 나중에 plan 전용 권한 세트나 CI plan Role을 만들 때는 이 버킷·키에만 아래 권한을 준다(`<BUCKET>`은 실제 이름으로).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListStateKeys",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<BUCKET>",
      "Condition": {"StringLike": {"s3:prefix": ["shared/ecr/*"]}}
    },
    {
      "Sid": "ReadWriteStateAndLock",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::<BUCKET>/shared/ecr/terraform.tfstate",
        "arn:aws:s3:::<BUCKET>/shared/ecr/terraform.tfstate.tflock"
      ]
    },
    {
      "Sid": "ReleaseLock",
      "Effect": "Allow",
      "Action": "s3:DeleteObject",
      "Resource": "arn:aws:s3:::<BUCKET>/shared/ecr/terraform.tfstate.tflock"
    }
  ]
}
```

plan만 하는 주체라도 잠금 파일을 쓰고 지우므로 `.tflock`에 Put·Delete가 필요하다. state 자체의 삭제 권한(`s3:DeleteObject` on `terraform.tfstate`)과 버킷 설정 변경 권한은 주지 않는다.

## 다음

`infra/environments/shared/backend.hcl.example`을 `backend.hcl`로 복사하고 `bucket`에 위 이름을 넣는다. 이후 순서는 `infra/README.md`.

## 되돌리기

state가 들어가기 전이라면 `aws s3api delete-bucket --bucket "$BUCKET"`. state가 들어간 뒤에는 지우지 않는다(버전 관리된 객체를 모두 지워야 삭제된다).
