# infra

Ureka AWS 인프라 Terraform.

| 경로 | 내용 |
|---|---|
| `modules/service_ecr` | 서비스 하나의 ECR 저장소 (태그 변경 불가, push 시 기본 스캔, 수명 주기 정책) |
| `modules/github_ecr_publisher` | GitHub Actions OIDC로 받는 서비스별 ECR push 전용 IAM Role |
| `environments/shared` | 계정에 한 벌만 두는 자원: GitHub OIDC provider, 서비스 6개 ECR·게시 Role |

## 보안 기준

- 장기 Access Key를 쓰지 않는다. CI는 OIDC 단기 자격만 받는다.
- Role 신뢰 조건은 `aud = sts.amazonaws.com`, `sub = repo:kdt-ureka/<레포>:ref:refs/heads/main` (StringEquals, 와일드카드 없음).
- 권한은 `ecr:GetAuthorizationToken`(리소스 제한 불가)만 `*`, 나머지 push·digest 조회는 해당 서비스 저장소 ARN 하나로 제한한다. pull 권한은 없다.
- 이 저장소는 PUBLIC이다. 계정 ID는 `terraform.tfvars`(커밋 금지)나 `TF_VAR_allowed_account_ids`로만 넣는다.
- `allowed_account_ids`로 다른 계정 프로필로 실행하는 실수를 막는다.

## 실행 (plan)

```bash
cd infra/environments/shared
cp terraform.tfvars.example terraform.tfvars   # 계정 ID 입력
export AWS_PROFILE=ureka-admin                  # aws sso login --profile ureka-admin
terraform init
terraform plan
```

apply는 IAM·OIDC 보안 검토와 CN 팀장 승인 뒤에만 한다. 원격 state(S3)는 아직 없다: 위치를 정하기 전에는 apply하지 않는다.

## 비용

ECR 저장 용량(GB·월)과 데이터 전송만 과금된다. 시간당 과금 자원은 없다. IAM·OIDC provider는 무료.

## 테스트

```bash
terraform test   # AWS 자격 불필요 (mock provider)
```
