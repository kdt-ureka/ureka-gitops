# infra

Ureka AWS 인프라 Terraform.

| 경로 | 내용 |
|---|---|
| `modules/service_ecr` | 서비스 하나의 ECR 저장소 (태그 변경 불가, push 시 기본 스캔, 수명 주기 정책) |
| `modules/github_ecr_publisher` | GitHub Actions OIDC로 받는 서비스별 ECR push 전용 IAM Role |
| `bootstrap` | 원격 state S3 버킷을 만드는 절차(문서만) |
| `environments/shared` | 계정에 한 벌만 두는 자원: GitHub OIDC provider, 서비스 6개 ECR·게시 Role |

## 보안 기준

- 장기 Access Key를 쓰지 않는다. CI는 OIDC 단기 자격만 받는다. 사람은 IAM Identity Center(SSO) 프로필 `ureka-admin`만 쓴다.
- Role 신뢰 조건은 `aud = sts.amazonaws.com`, `sub = repo:kdt-ureka/<레포>:ref:refs/heads/main` (StringEquals, 와일드카드 없음).
- 권한은 `ecr:GetAuthorizationToken`(리소스 제한 불가)만 `*`, 나머지 push·digest 조회는 해당 서비스 저장소 ARN 하나로 제한한다. pull 권한은 없다.

## 계정 ID 다루는 규칙

이 저장소는 **PUBLIC**이다.

- 계정 ID, 이메일, 실제 Role ARN·ECR URL은 코드·커밋·PR·이슈에 쓰지 않는다. 필요하면 `<ACCOUNT_ID>`로 가린다.
- 계정 ID는 커밋하지 않는 `terraform.tfvars`나 환경 변수 `TF_VAR_allowed_account_ids`로만 넣는다.
- 원격 state 설정은 커밋하지 않는 `backend.hcl`로 넣는다. 버킷 이름은 무작위 접미사를 쓰고 계정 ID를 넣지 않는다.
- `allowed_account_ids`로 다른 계정 프로필(이전 프로젝트 등)로 실행하는 실수를 막는다.
- `terraform plan` 출력에는 계정 ID가 나온다. PR·문서에 붙일 때는 가린다.
- CI `Security` 워크플로가 막는 것: `*.tfvars`(예시 제외), `*.tfstate*`, `*.tfplan`, `.terraform/`, `backend.hcl`, kubeconfig, `.env` 추적, 12자리 숫자(테스트용 `123456789012`·`000000000000` 제외), Gitleaks 비밀 탐지.

## 실행 순서

| 단계 | 누가 | 내용 |
|---|---|---|
| 1. 부트스트랩 | CN 팀장 | state 버킷을 한 번만 만든다: [`bootstrap/README.md`](bootstrap/README.md) |
| 2. backend 설정 | 실행자 | `backend.hcl.example` → `backend.hcl`, `terraform.tfvars.example` → `terraform.tfvars` (둘 다 커밋 금지) |
| 3. init | 실행자 | `terraform init -backend-config=backend.hcl` |
| 4. plan | 실행자 | `terraform plan -out=tfplan` → 계정 ID를 가린 결과를 PR에 공유 |
| 5. 승인 | Codex 보안 검토 + CN 팀장 | IAM·OIDC 변경은 둘 다 필요 |
| 6. apply | CN 팀장(또는 승인받은 실행자) | 승인받은 그 plan 파일로: `terraform apply tfplan` |
| 7. 기록 | 실행자 | output 값을 서비스 레포 Actions Variables에 등록, PR에 결과(계정 ID 가림) 기록 |

```bash
cd infra/environments/shared
aws sso login --profile ureka-admin
export AWS_PROFILE=ureka-admin
cp backend.hcl.example backend.hcl                 # bucket 이름 입력
cp terraform.tfvars.example terraform.tfvars       # 계정 ID 입력
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
# 승인 후에만
terraform apply tfplan
```

PR CI는 AWS 자격 없이 `terraform init -backend=false`로 형식·문법·정책 테스트만 한다. plan·apply는 CI에서 하지 않는다.

## 비용

ECR 저장 용량(GB·월)과 데이터 전송만 과금된다. 시간당 과금 자원은 없다. IAM·OIDC provider는 무료.

## 테스트

```bash
terraform test   # AWS 자격 불필요 (mock provider)
```
