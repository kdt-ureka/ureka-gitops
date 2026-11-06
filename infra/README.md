# infra

Ureka AWS 인프라 Terraform.

| 경로 | 내용 |
|---|---|
| `modules/service_ecr` | 서비스 하나의 ECR 저장소 (태그 변경 불가, push 시 기본 스캔, 태그 없는 이미지만 7일 후 정리) |
| `modules/github_ecr_publisher` | GitHub Actions OIDC로 받는 서비스별 ECR push 전용 IAM Role |
| `bootstrap` | 원격 state S3 버킷을 만드는 절차(문서만) |
| `environments/shared` | 계정에 한 벌만 두는 자원: GitHub OIDC provider, 서비스 7개(auth, chat, content, ops, recommend, frontend, ingest) ECR·게시 Role |

## 보안 기준

- 장기 Access Key를 쓰지 않는다. CI는 OIDC 단기 자격만 받는다. 사람은 IAM Identity Center(SSO) 프로필 `ureka-admin`만 쓴다.
- Role 신뢰 조건은 `aud = sts.amazonaws.com`, `sub = repo:kdt-ureka/<레포>:ref:refs/heads/main` (StringEquals, 와일드카드 없음).
- 권한은 `ecr:GetAuthorizationToken`(리소스 제한 불가)만 `*`, 나머지 push·digest 조회는 해당 서비스 저장소 ARN 하나로 제한한다. pull 권한은 없다.

## 남은 위험: main에서 실행되는 모든 워크플로가 게시 Role을 받을 수 있다 (MVP에서 수용)

- 신뢰 조건은 레포와 `refs/heads/main`만 본다. 이벤트 종류(push·workflow_dispatch 등)와 워크플로 파일은 구분하지 않는다.
- 서비스 레포는 Free 플랜 private이라 main 브랜치 보호를 켤 수 없다. 레포 쓰기 권한이 있는 사람은 main에 직접 push하거나, 워크플로 파일을 바꿔 main에서 실행해 이 Role을 받을 수 있다.
- 받을 수 있는 권한은 해당 서비스 ECR 저장소 하나에 이미지를 push하는 것뿐이다(pull·삭제·다른 저장소·state 접근 없음). 태그 변경 불가라 기존 태그를 덮어쓰지는 못한다. 다만 임의 이미지를 새 태그로 올릴 수는 있다.
- 배포에 쓰이는 이미지는 GitOps 저장소(`ureka-gitops`)의 digest로만 바뀐다. `ureka-gitops` main은 보호되어 있다(PR 필수, 승인 1명, 새 커밋 시 승인 무효, 대화 해결 필수, force push·삭제 금지). 다만 관리자 우회는 막혀 있지 않고(`enforce_admins` 꺼짐) 필수 상태 검사도 없다. 배포 도구(Argo CD 등)가 아직 없어서, "GitOps digest로만 배포된다"는 배포 구성이 생긴 뒤 다시 확인해야 하는 목표다. 지금은 임의로 올린 이미지가 GitOps PR 없이 배포될 경로는 없지만, 관리자는 리뷰 없이 GitOps main을 바꿀 수 있다.
- 팀 규칙으로 보완한다.
  - 서비스 레포 main에 직접 push하지 않는다. 모든 변경은 PR → 승인 1명 → Squash 병합.
  - `.github/workflows/` 변경 PR은 CN 승인을 받는다.
  - GitOps PR에서 digest를 바꿀 때 그 digest가 해당 커밋의 CI 실행(Step Summary·`image-ref` artifact)에서 나온 것인지 확인한다.
- 선택지(구현하지 않음): 서비스 레포 OIDC subject 템플릿에 `job_workflow_ref`를 넣으면(`include_claim_keys: [repo, context, job_workflow_ref]`) 신뢰 조건을 `.github/workflows/ci.yml@refs/heads/main` 하나로 좁힐 수 있다. 레포 설정 변경과 sub 형식 변경이 함께 필요하다.

## 계정 ID 다루는 규칙

이 저장소는 **PUBLIC**이다.

- 계정 ID, 이메일, 실제 Role ARN·ECR URL은 코드·커밋·PR·이슈에 쓰지 않는다. 필요하면 `<ACCOUNT_ID>`로 가린다.
- 계정 ID는 커밋하지 않는 `terraform.tfvars`나 환경 변수 `TF_VAR_allowed_account_ids`로만 넣는다.
- 원격 state 설정은 커밋하지 않는 `backend.hcl`로 넣는다. 버킷 이름은 무작위 접미사를 쓰고 계정 ID를 넣지 않는다.
- `allowed_account_ids`로 다른 계정 프로필(이전 프로젝트 등)로 실행하는 실수를 막는다.
- `terraform plan` 출력에는 계정 ID가 나온다. PR·문서에 붙일 때는 가린다.
- CI `Security` 워크플로가 막는 것: `*.tfvars`(예시 제외), `*.tfstate*`, `*.tfplan`, `.terraform/`, `backend.hcl`, kubeconfig, `.env` 추적, 12자리 숫자(현재 트리, 일치 항목마다 테스트용 `123456789012`·`000000000000`만 제외), Gitleaks(커밋 이력 전체: 기본 비밀 규칙, 계정 ID가 든 ARN·ECR 호스트, 일반 12자리 계정 ID). 탐지해도 로그에는 파일·줄만 남기고 값은 출력하지 않는다. `scripts/test-leak-checks.sh`가 가짜 ID로 이 검사들이 실제로 잡는지 CI에서 확인한다.

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

## 후속 작업: 배포·롤백 이미지 보존 구조

지금 ECR 수명 주기 규칙은 **태그 없는 이미지 7일 후 삭제** 하나뿐이다. 태그 붙은 이미지를 개수로 지우는 규칙은 배포 중이거나 롤백용 digest까지 지울 수 있어서 넣지 않았다. 그래서 `sha-<commit>` 이미지는 계속 쌓인다(저장 비용만 증가).

정리 규칙을 넣으려면 먼저 보존 대상을 표시하는 구조가 필요하다. 설계 후보:

1. 승격 태그: dev·prod에 배포하거나 롤백 후보로 남길 digest에 `deployed-<env>-<날짜>` 같은 추가 태그를 붙인다(태그 변경 불가라도 같은 digest에 새 태그 추가는 가능). 게시 Role이 아닌 배포·승격 주체가 붙인다.
2. 수명 주기: `tagPrefixList = ["sha-"]`인 이미지만 "N일 지난 것" 또는 "최신 N개 초과"로 삭제하고, `deployed-` 접두 이미지는 규칙 대상에서 뺀다. ECR 규칙은 이미지에 붙은 태그 중 하나라도 맞으면 대상이 될 수 있으므로, 보존 태그가 있는 이미지가 지워지지 않는지 규칙 우선순위와 함께 검증한다.
3. GitOps 저장소에 있는 digest 목록과 ECR 이미지를 비교해 지워질 대상에 배포 중 digest가 없는지 확인하는 점검을 둔다.

담당·시점은 CN에서 정한다(C3·C5와 함께).

## 비용

ECR 저장 용량(GB·월)과 데이터 전송만 과금된다. 시간당 과금 자원은 없다. IAM·OIDC provider는 무료.

## 테스트

```bash
terraform test   # AWS 자격 불필요 (mock provider)
```
