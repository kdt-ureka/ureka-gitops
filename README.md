# ureka-gitops

Ureka AWS·EKS 인프라 및 Argo CD 배포 설정

이 저장소는 PUBLIC이다. 계정 ID, 이메일, Role ARN, ECR 주소, 버킷 이름, 비밀값, 토큰은 커밋하지 않는다(`<ACCOUNT_ID>`처럼 가린다).

## 구성

| 경로 | 내용 |
|---|---|
| `infra/` | AWS 인프라 Terraform (ECR, GitHub OIDC 게시 Role) |
| `charts/ureka-backend/` | 백엔드 공통 Helm chart (Deployment, Service, 선택: 실행 명령·Service 끄기·헬스 체크 변경·마이그레이션 Job). Java·Python 서비스 공용. 선택 칸은 `values.yaml` 주석 |
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

### 3. 비밀값 → 데이터 계층 → 이미지 복사 → 서비스 Application

```bash
kubectl apply -f argocd/kind/ureka-dev-namespace.yaml
scripts/kind/create-secrets.sh   # 로컬 전용 Secret(DB·JWT·내부 토큰)을 처음 한 번 만든다. 값은 Git에 없고 출력하지 않는다
kubectl apply -f argocd/kind/ureka-dev-data.yaml
kubectl -n dev logs job/db-bootstrap | tail -1   # "db-bootstrap 완료"를 확인한 뒤 다음으로
scripts/kind/sync-ecr-image.sh recommend <ureka-recommend main 커밋 SHA 40자>
scripts/kind/sync-ecr-image.sh auth <ureka-auth main 커밋 SHA 40자>
scripts/kind/sync-ecr-image.sh content <ureka-content main 커밋 SHA 40자>
scripts/kind/sync-ecr-image.sh chat <ureka-chat main 커밋 SHA 40자>
scripts/kind/sync-ecr-image.sh ops <ureka-ops main 커밋 SHA 40자>
scripts/kind/sync-ecr-image.sh frontend <ureka-frontend main 커밋 SHA 40자>
kubectl apply -f argocd/kind/
```

Argo CD로 배포하는 것: 데이터 계층(PostgreSQL 18 + pgvector, Redis, 메일 서버 Mailpit, DB 계정 생성 Job), recommend(MOCK_MODE), auth, content, ops, frontend, chat(api·worker·Alembic 마이그레이션 Job, AI 기본 꺼짐 — 켜기는 [docs/kind-db-secrets.md](docs/kind-db-secrets.md) "chat AI 켜기"). 가입 인증 메일은 `kubectl -n dev port-forward deploy/mailpit 8025:8025` → http://localhost:8025 에서 본다. 화면은 `kubectl -n dev port-forward svc/ureka-frontend 3000:80` → http://localhost:3000 (nginx가 `/api/*`를 각 서비스로 넘긴다). 이미 있는 kind 클러스터는 `create-secrets.sh`를 한 번 더 실행하면 chat·ops Secret만 추가된다. 비밀값 교체는 클러스터를 새로 만든다. DB 계정 구조·비밀값 방식·데이터 보존은 [docs/kind-db-secrets.md](docs/kind-db-secrets.md).

출력된 digest는 해당 CI 실행의 artifact `image-ref.json` digest와 같아야 한다. 이후 배포·롤백은 [docs/kind-deploy-rollback.md](docs/kind-deploy-rollback.md).

### 로컬 검사

```bash
scripts/check-charts.sh          # helm lint + 렌더링 + data kustomize 렌더링 + 이미지 digest 고정 확인 (CI Helm 워크플로와 같음)
scripts/test-chart-options.sh    # chart 선택 칸(command·Service 끄기·헬스 체크·마이그레이션 Job) 렌더링과 잘못된 조합 거부(클러스터 불필요, CI와 같음)
scripts/test-p11-check.sh        # P11 러너가 실행 실패를 성공으로 세지 않는지(클러스터 불필요, CI와 같음)
scripts/test-create-secrets.sh   # Secret 스크립트가 덮어쓰지 않고 조회 오류에서 멈추는지(클러스터 불필요, CI와 같음)
scripts/test-run-bootstrap.sh    # 계정 생성 Job이 잘못된 verifier에서 DB를 부르지 않는지(클러스터 불필요, CI와 같음)
scripts/kind/p11-check.sh        # (kind 실행 중) P11 검색 함수 역할 부정 시험
scripts/check-forbidden-files.sh # 커밋 금지 파일·계정 ID (CI Security 워크플로와 같음)
```
