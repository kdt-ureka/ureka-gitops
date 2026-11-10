# ureka-gitops

Ureka AWS·EKS 인프라 및 Argo CD 배포 설정

이 저장소는 PUBLIC이다. 계정 ID, 이메일, Role ARN, ECR 주소, 버킷 이름, 비밀값, 토큰은 커밋하지 않는다(`<ACCOUNT_ID>`처럼 가린다).

## 구성

| 경로 | 내용 |
|---|---|
| `infra/` | AWS 인프라 Terraform (ECR, GitHub OIDC 게시 Role) |
| `charts/ureka-backend/` | 백엔드 공통 Helm chart (Deployment, Service). Java·Python 서비스 공용 |
| `environments/kind/` | kind(로컬) dev values. 서비스마다 파일 하나 + `namespace/` |
| `argocd/kind/` | kind dev용 Argo CD Application (main 자동 동기화) |
| `kind/`, `scripts/kind/` | kind 클러스터·로컬 레지스트리 준비, ECR 이미지 복사 |
| `environments/kind/data/` | kind dev PostgreSQL(pgvector)·Redis·DB 계정 생성 Job (kustomize) |
| `tests/db/` | DB 권한 시험(P11 검색 함수 역할) |
| `docs/kind-deploy-rollback.md` | 배포·롤백 절차 |
| `docs/kind-db-secrets.md` | kind DB·비밀값 방식, DB 계정 구조, P11 기록 |

## kind dev 환경

S6~S7 dev는 노트북 kind 클러스터 + Argo CD다. 이미지는 CI가 ECR에 게시한 것을 digest 그대로 kind 로컬 레지스트리(`localhost:5001`)에 복사해 쓴다. 클러스터와 이 저장소에는 AWS 자격 증명을 두지 않는다.

### 1. 조회 전용 SSO 프로필 추가 (처음 한 번)

ECR에서 받기만 하므로 관리자 프로필이 아니라 **ReadOnlyAccess 권한 세트** 프로필을 쓴다(push 권한 없음).

```bash
aws configure sso --profile ureka-readonly
```

물어보는 값:

| 항목 | 입력 |
|---|---|
| SSO session name | `ureka` (이미 있으면 같은 이름 선택) |
| SSO start URL | `<IAM Identity Center 시작 URL>` (팀 비공개 기록 참고) |
| SSO region | `ap-northeast-2` |
| SSO registration scopes | 기본값(`sso:account:access`) |
| 계정 선택 | `ureka` 계정 |
| 역할(권한 세트) 선택 | `ReadOnlyAccess` |
| Default client Region | `ap-northeast-2` |
| CLI default output format | `json` |

확인(계정 ID가 출력되므로 공유할 때 가린다):

```bash
aws sso login --profile ureka-readonly
aws sts get-caller-identity --profile ureka-readonly --query Arn --output text
```

### 2. 클러스터 준비

```bash
scripts/kind/up.sh   # kind 'ureka' + 로컬 레지스트리 + Argo CD v3.6.0. 여러 번 실행해도 된다
```

### 3. 비밀값 → 이미지 복사 → Application 적용

```bash
kubectl apply -f argocd/kind/ureka-dev-namespace.yaml
scripts/kind/create-secrets.sh   # 로컬 전용 Secret(DB·JWT·내부 토큰). 값은 Git에 없고 출력하지 않는다
scripts/kind/sync-ecr-image.sh recommend <ureka-recommend main 커밋 SHA 40자>
scripts/kind/sync-ecr-image.sh auth <ureka-auth main 커밋 SHA 40자>
scripts/kind/sync-ecr-image.sh content <ureka-content main 커밋 SHA 40자>
kubectl apply -f argocd/kind/
```

Argo CD로 배포하는 것: 데이터 계층(PostgreSQL 18 + pgvector, Redis, DB 계정 생성 Job), recommend(MOCK_MODE), auth, content. chat·ops는 다음 PR. DB 계정 구조와 비밀값 방식은 [docs/kind-db-secrets.md](docs/kind-db-secrets.md).

출력된 digest는 해당 CI 실행의 artifact `image-ref.json` digest와 같아야 한다. 이후 배포·롤백은 [docs/kind-deploy-rollback.md](docs/kind-deploy-rollback.md).

### 로컬 검사

```bash
scripts/check-charts.sh          # helm lint + 렌더링 + data kustomize 렌더링 + 이미지 digest 고정 확인 (CI Helm 워크플로와 같음)
scripts/kind/p11-check.sh        # (kind 실행 중) P11 검색 함수 역할 부정 시험
scripts/check-forbidden-files.sh # 커밋 금지 파일·계정 ID (CI Security 워크플로와 같음)
```
