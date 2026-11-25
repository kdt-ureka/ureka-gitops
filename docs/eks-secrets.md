# EKS 비밀값: Secrets Manager → ESO, 최소 IRSA (#63)

이 문서는 CN 담당이 교차 검토 뒤 실행할 절차다. 초안 작성 때 AWS 조회·apply·클러스터 변경은 하지 않았다(prod 시드·bootstrap 도구 포함).
AWS 변경(Terraform apply, 비밀 생성)은 교차 검토와 파트장 승인 뒤 파트장이 직접 한다.

## 한눈에

```
EC2 dev k3s Secret ──(1회 복사, EC2 서버 안)──▶ Secrets Manager ureka/eks/dev/app, ureka/eks/dev/chat-ai
                                                   │ GetSecretValue (ureka/eks/dev/* 만)
                                     IRSA 역할 ureka-eks-eso-dev ◀── dev:ureka-secrets-reader 토큰(ESO만 발급)
                                                   │
                          ESO(external-secrets 네임스페이스, AWS 권한 없음) → dev의 기존 이름 Secret 8개
prod도 같은 구조(ureka/eks/prod/*, ureka-eks-eso-prod, prod:ureka-secrets-reader). 값은 새로 만든다(seed_prod_secrets.py).
```

- **dev 원본 = EC2 dev 값의 복사본(방식 A).** EKS dev는 EC2 dev와 같은 RDS dev DB·계정을 쓰므로 DB 비밀번호가 같아야 한다.
  EC2 쪽 값은 읽기만 하고 새로 만들거나 덮어쓰지 않는다. **교체할 때는 EC2와 EKS dev를 같이 바꾼다**(아래 '값 교체').
- **prod 원본 = 새 값.** 같은 RDS 안의 prod 전용 논리 DB·계정 비밀번호와 prod 전용 JWT 키·내부 토큰. dev와 공유하지 않는다.
- RDS 마스터 비밀은 ESO가 읽지 않는다. bootstrap 때만 쓴다.

## Secrets Manager 구조

환경마다 리더 역할이 하나라서 서비스별로 나눠도 권한 차이가 없다. 비용만 늘어나므로 **환경별 묶음**으로 둔다.

| 비밀 이름 | 내용(JSON 속성) | 만드는 곳 |
|---|---|---|
| `ureka/eks/dev/app` | 아래 12개 | `scripts/ec2/copy_eks_dev_secrets.py`(EC2 값 복사) |
| `ureka/eks/dev/chat-ai` | `AI_MODE`, `AI_API_KEY` | 같은 스크립트(필수: EC2에 `ureka-chat-ai`가 없으면 복사 전체를 멈춤) |
| `ureka/eks/prod/app` | 아래 12개(새 값) | `scripts/eks/seed_prod_secrets.py`(아래 'prod 순서') |
| `ureka/eks/prod/ses-smtp` | `MAIL_USERNAME`, `MAIL_PASSWORD` → Secret `ureka-auth-mail` | `scripts/ses/create-smtp-secret.py`(gitops#91, `docs/ses.md`). prod만 연결 |
| `ureka/eks/prod/chat-ai` | 위와 같음 | prod용 키가 정해지면(아직 끔) |

비용: 비밀 5개 × $0.40/월 = 약 $2/월, API 호출은 1시간 새로 고침 기준 월 $0.1 미만(가정, 계산기로 재확인).
Gemini 키는 교체 담당·주기가 달라 따로 둔다. 기존 `ureka/dev/chat-ai`(EC2 원본)는 그대로 둔다.

`app` 묶음 속성 → 만들어지는 Secret(이름·키는 `create-secrets.sh`와 같아 앱 values의 `secretKeyRef`를 바꾸지 않는다):

| 속성 | Secret/키 |
|---|---|
| `AUTH_DB_PASSWORD` | `ureka-auth-secrets/DB_PASSWORD` |
| `CONTENT_DB_PASSWORD` | `ureka-content-secrets/DB_PASSWORD` |
| `CHAT_DB_PASSWORD` | `ureka-chat-secrets/DB_PASSWORD` |
| `OPS_DB_PASSWORD` | `ureka-ops-secrets/DB_PASSWORD` |
| `RECOMMEND_DB_USERNAME`, `RECOMMEND_DB_PASSWORD` | `ureka-recommend-db/DB_USERNAME`, `DB_PASSWORD` |
| `INGEST_DB_USERNAME`, `INGEST_DB_PASSWORD` | `ureka-ingest-db/DB_USERNAME`, `DB_PASSWORD` |
| `JWT_PRIVATE_KEY`, `EMAIL_CODE_SECRET` | `ureka-auth-secrets`의 같은 이름 키 |
| `JWT_PUBLIC_KEY` | auth·content·chat·ops Secret의 `JWT_PUBLIC_KEY` |
| `INTERNAL_SERVICE_TOKEN` | auth·content·chat·recommend Secret의 `INTERNAL_SERVICE_TOKEN` |

표의 원본은 `charts/ureka-eks-secrets/values.yaml`의 `bundles`다. 복사 스크립트의 표와 같은지 `tests/eks/test_copy_eks_dev_secrets.py`가,
앱이 읽는 모든 `secretKeyRef`를 만드는지 `scripts/test-eks-secrets.sh`가 확인한다.
만들지 않는 것: `postgres-admin`(kind 전용), `db-accounts`·`db-accounts-chat-ops`(bootstrap용 해시), `rds-master`.
prod bootstrap의 임시 Secret(`db-bootstrap-prod-master`·`db-bootstrap-prod-accounts`)은 도구가 만들고 실행 뒤 지운다(ESO와 무관).

## 권한 경계

| 주체 | 받는 권한 | 코드 |
|---|---|---|
| ESO 컨트롤러 | AWS 권한 없음. 토큰 발급은 dev·prod의 `ureka-secrets-reader` 두 개만(Role `resourceNames`). 차트 기본의 클러스터 전체 `serviceaccounts/token` 권한은 끔 | `argocd/eks/external-secrets-app.yaml`, `charts/ureka-eks-secrets/templates/reader.yaml` |
| `dev:ureka-secrets-reader` | `ureka-eks-eso-dev`: `secretsmanager:GetSecretValue`, `ureka/eks/dev/*`만 | `infra/environments/eks/secrets.tf` |
| `prod:ureka-secrets-reader` | `ureka-eks-eso-prod`: 같은 동작, `ureka/eks/prod/*`만 | 같은 파일 |
| EC2 dev 호스트 역할 | 복사하는 동안만 `ureka/eks/dev/*`에 Create·Describe·Put·TagResource(읽기 없음) | `infra/environments/data/eks_secret_copy.tf` |

- IRSA 신뢰 조건은 `StringEquals`로 `sub=system:serviceaccount:<env>:ureka-secrets-reader`, `aud=sts.amazonaws.com`만 받는다.
  리소스는 마지막 `/`까지 고정해 `ureka/eks/dev/*`가 prod나 `ureka/eks/devx…`와 겹치지 않는다. 기본 KMS 키(aws/secretsmanager)라 kms 권한은 없다.
- **dev에서 prod 비밀을 읽을 수 없다.** 네임스페이스 `SecretStore`는 자기 네임스페이스의 리더 계정만 쓴다.
  어느 네임스페이스에서나 리더를 빌려 쓸 수 있는 `ClusterSecretStore`·`ClusterExternalSecret`, 그리고 `ClusterGenerator`·`ClusterPushSecret`·`PushSecret`은
  CRD도 만들지 않고 처리도 끈다. 등록 도구는 이 중 `ClusterSecretStore`·`ClusterExternalSecret` CRD가 클러스터에 있으면 멈춘다(나머지는 검사하지 않는다).
- **다른 Pod가 리더 권한을 쓸 수 없다.** 차트의 ValidatingAdmissionPolicy가 (1) 그 네임스페이스에서 리더 계정으로 Pod를 만들거나
  (2) ESO 컨트롤러가 아닌 주체가 리더 토큰(TokenRequest)을 받는 것을 거부한다. 리더 계정은 토큰 자동 마운트도 끈다.
  앱 Pod의 서비스계정 토큰은 신뢰 조건의 sub가 달라 역할을 맡을 수 없다. 노드 IMDS는 hop limit 1이라 일반 Pod가 노드 역할을 쓰지 못한다(#42).
- ESO 컨트롤러도 리더 두 개 말고 다른 서비스계정 토큰은 발급할 수 없다(Role·RoleBinding, 렌더 검사가 규칙 1개·이름 고정을 확인).
- 기본 `edit`·`admin` 역할에 ESO 쓰기 권한이 합쳐지지 않게 했다(`rbac.aggregateToEdit/Admin: false`, `view`만 합침).
  그래서 dev 편집자도 SecretStore·ExternalSecret을 만들 수 없다. 남는 위험: dev Secret을 직접 읽을 수 있는 사람은 dev 비밀을 본다.
  prod에 사람이 직접 쓰지 못하게 하는 RBAC는 #62가 정한다. 정책은 apiserver가 평가하므로 VAP를 지울 수 있는 클러스터 관리자는 예외다.
- chat의 SQS IRSA(보내기·받기만)는 큐가 생기는 #53에서 같은 방식(서비스계정 sub 고정, 큐 ARN 고정)으로 추가한다. 이번 범위에 없다.

## dev 복사 (EC2 → Secrets Manager, CN 실행)

선행: 이 PR 병합, EC2 dev·k3s가 켜져 있고 서비스 Secret이 정상(앱 Healthy). EKS는 꺼져 있어도 된다.

1. 내 PC에서 data 스택의 비공개 tfvars에 `eks_dev_secret_copy_enabled = true`를 넣고 plan을 검토한다.
   **변경은 `aws_iam_role_policy.ec2_copy_eks_dev_secrets` 생성 1개뿐이어야 한다**(RDS·SG 변경 없음). 파트장이 apply한다.
   `ureka-chat-ai`는 필수다(EKS dev는 chat-ai 묶음을 항상 연결한다). EC2에 없으면 먼저 `sudo bash scripts/ec2/up.sh --chat-ai`로 만든다.
2. EC2 서버(SSM 셸)에서 저장소를 최신 main으로 맞춘 뒤 검사만 한다. 값은 출력되지 않는다.

   ```sh
   sudo python3 scripts/ec2/copy_eks_dev_secrets.py check
   ```

   모든 Secret을 읽어 키가 다 있는지, 같은 속성(JWT 공개키·내부 토큰)이 Secret마다 같은지, 계정 이름이 맞는지 보고
   원격 비밀이 있는지 확인한다. 하나라도 틀리면 AWS에 아무것도 쓰지 않는다.
3. 복사한다. 두 묶음 중 하나라도 이미 있으면 아무것도 쓰지 않고 멈춘다.

   ```sh
   sudo python3 scripts/ec2/copy_eks_dev_secrets.py copy
   ```

4. 바로 1번 값을 `false`로 되돌려 plan(정책 삭제 1개)→apply한다. 복사 권한을 켜 둔 채로 두지 않는다.
5. 내 PC에서 값 없이 존재만 확인한다: `aws secretsmanager describe-secret --secret-id ureka/eks/dev/app --profile ureka-admin --query '{Name:Name,Tags:Tags}'`.
   `get-secret-value`로 값을 열어 보지 않는다.

값은 서버의 0700 임시 폴더 파일을 `file://`로 aws CLI에 넘긴 뒤 바로 지운다. SIGKILL·서버 종료 때는 `/tmp/eks-dev-copy-*`가 남을 수 있으니
다음 접속에서 지운다. aws 오류 원문에는 ARN(계정 ID)이 들어 있어 예외 이름만 보여 준다.

### 부분 실패 복구

두 묶음은 별도 API 호출이라 원자적이지 않다. `app`을 쓴 뒤 `chat-ai` 쓰기가 실패하면 스크립트는 이미 쓴 묶음과 못 쓴 묶음의 **이름만** 알리고 멈춘다.
이때 일반 `copy` 재시도는 `app`이 이미 있어 멈춘다(덮어쓰기 방지).

1. 임시 쓰기 권한은 켜 둔 채 원인(예외 이름, 네트워크, 권한)을 확인한다. 오늘 안에 재개하지 않으면 바로 권한을 끈다(1번 값 `false` → apply).
2. 값 없이 상태를 확인한다. 내 PC에서 `aws secretsmanager describe-secret --secret-id ureka/eks/dev/<묶음> --profile ureka-admin --query '{Name:Name,Versions:VersionIdsToStages,Deleted:DeletedDate}'`.
   `app`은 버전 1개(AWSCURRENT), `chat-ai`는 없음(ResourceNotFound)이어야 이 복구에 해당한다. 서버에서 `check`가 통과해야 한다(EC2 원본이 그 사이 바뀌지 않음).
3. 위 조건이 맞을 때만 같은 원본으로 `sudo python3 scripts/ec2/copy_eks_dev_secrets.py copy --update-existing`를 실행한다.
   `app`에는 같은 내용의 새 버전이 붙고(이전 버전은 AWSPREVIOUS) `chat-ai`가 생긴다. 다른 상태면 멈추고 교차 검토를 받는다.
4. 1번 값을 `false`로 되돌려 apply하고, EKS가 켜져 있으면 아래 '연결 순서' 4번의 Ready 확인을 다시 한다.

이 경로(두 번째 쓰기 실패 → 일반 재시도 거부 → `--update-existing` 재개)는 `tests/eks/test_copy_eks_dev_secrets.py`가 시험한다.

### 값 교체

EC2 dev 값을 바꾸면(EC2 교체·재생성) EKS dev도 같이 맞춘다: 1번 → `copy --update-existing`(새 버전, 이전 값은 AWSPREVIOUS로 남음) → 4번.
ESO는 1시간마다 다시 읽는다. 앱 Pod는 시작할 때만 env를 읽으므로 EKS dev 앱을 재시작한다.
DB 비밀번호만 따로 바꾸는 절차는 없다(EC2 `create-secrets.sh`도 교체를 제공하지 않는다). 순서가 어긋나면 한쪽 환경이 DB 인증에 실패한다.

## EKS 연결 순서 (EKS 켠 뒤, CN 실행)

1. EKS Terraform apply(이 PR로 리더 역할 2개 추가. 비용 없음). plan에서 IAM role·inline policy 각 2개 생성만 늘었는지 본다.
2. Argo CD 설치(#43 도구) → `kubectl --context ureka-eks apply -f argocd/eks/external-secrets-app.yaml` → Argo CD에서 Sync.
   `external-secrets` Pod 3개 Ready, 네임스페이스 restricted 경고 없음을 확인한다.
3. #62로 `dev` 네임스페이스가 생긴 뒤 등록한다. 승인 계정 ID는 명령 인자가 아니라 환경 변수 `UREKA_EXPECTED_ACCOUNT_ID`로만 받는다
   (승인된 로컬 설정에서 셸에 읽어 둔다). 도구가 STS 계정과 따로 비교하고 kubectl 표준 입력으로만 넘긴다.
   조회가 실패하면 원문은 로컬 `.local/eks/last-error.log`(0600)에만 남는다. 공유하지 않는다.
   check의 server dry-run은 Application 한 개만 검사한다. 자식 자원(VAP CEL, ESO webhook, 동기화)은 4·5번에서 확인한다.

   ```sh
   python3 scripts/eks/register_secrets_app.py check --env dev --profile ureka-admin
   python3 scripts/eks/register_secrets_app.py apply --env dev --confirm-env dev --profile ureka-admin
   ```

4. 확인(값 없이): `kubectl --context ureka-eks -n dev get secretstore,externalsecret`에서 SecretStore `Valid`, ExternalSecret 8개 모두 `SecretSynced`/Ready,
   `get secret`에 8개 이름이 있는지. 이것이 ESO의 정상 토큰 발급·IRSA 성공의 증거다.
5. 권한 시험(#63 완료 기준 "다른 Pod가 못 쓰는지"). **각 거부는 비교 요청이 같은 주체·환경에서 성공하는지 먼저 보고**, 거부 메시지가
   해당 정책 이름을 포함하는지까지 확인한다(다른 원인의 실패를 통과로 적지 않는다). 토큰은 어디에도 출력하지 않는다.
   - Pod: 아래 시험 Pod는 restricted를 충족한다. 먼저 기본 계정으로 성공(비교), 다음 리더 계정으로 `ureka-secrets-reader-pods-dev` 거부를 본다.

     ```sh
     probe() { # 서비스계정 이름
       kubectl --context ureka-eks -n dev run probe --image=busybox:1.37 --restart=Never --dry-run=server -o name \
         --overrides='{"spec":{"serviceAccountName":"'"$1"'","automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"probe","image":"busybox:1.37","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
     }
     probe default                                   # 비교: pod/probe (dry-run 성공)
     probe ureka-secrets-reader 2>&1 | grep -o 'ureka-secrets-reader-pods-dev.*'   # 거부: 정책 이름과 메시지
     ```

   - 토큰: 비교로 일반 계정 토큰 발급이 되는지 보고(출력 버림), 리더 계정은 `ureka-secrets-reader-token-dev` 거부 메시지를 본다.
     비교가 실패하면(사람 권한에 `serviceaccounts/token` 없음) 이 시험은 "RBAC에서 먼저 막힘"으로 적고, VAP 확인은 권한 있는 CN 역할로 다시 한다.

     ```sh
     kubectl --context ureka-eks -n dev create token default --duration=10m >/dev/null && echo '비교: 발급 가능'
     kubectl --context ureka-eks -n dev create token ureka-secrets-reader --duration=10m 2>&1 >/dev/null | grep -o 'ureka-secrets-reader-token-dev.*'
     ```

   - 앱 서비스계정 토큰으로 역할 맡기 → `AccessDenied`(신뢰 조건 불일치). 방법은 #43 앱 배포 뒤 임시 Pod로 시험하고, 토큰은 출력하지 않는다.
   - dev SecretStore로 `ureka/eks/prod/app`을 가리키는 임시 ExternalSecret → 상태 메시지에 `AccessDenied`, 같은 형식의 dev 경로 ExternalSecret은 Ready(비교). 확인 뒤 둘 다 삭제.
6. prod는 아래 'prod 순서'를 따른다(시드·DB bootstrap 뒤 `--env prod`로 3~5번). 시드 전에는 등록하지 않는다.
   prod Application은 **자동 Sync가 없다.** 등록 뒤에도 main에 병합된 변경(SecretStore·리더 정책·속성 매핑)은 CN이 Argo CD diff를 확인하고 손으로 Sync해야 반영된다.
   dev는 자동 Sync(selfHeal)다. Secrets Manager 값의 1시간 갱신은 ESO 동작이라 Sync와 별개다.

Application은 prune을 끈다. `ExternalSecret`이 지워지면 소유한 Secret도 지워져 앱이 내려가기 때문이다(Git에서 빠져도 자동 삭제는 없지만,
누가 ExternalSecret을 직접 지우면 Secret도 지워질 수 있다). 묶음을 없애는 변경은 병합 뒤 CN이 해당 자원만 확인하고 지운다.
원격 비밀이 사라지면 마지막 Secret 값은 남는다(`deletionPolicy: Retain`).

## prod 순서 (시드 → DB bootstrap → 비밀 앱 → 앱, CN 실행)

같은 RDS 인스턴스 안에 prod 전용 논리 DB·계정을 만들고, 그 비밀번호를 prod 전용 비밀 묶음에 둔다. dev와 데이터·계정·값을 공유하지 않는다.
**prod 비밀·DB가 없으면 prod 앱은 뜨지 않는다**(DB 인증 실패). 아래 순서를 지킨다. 각 단계는 교차 검토·파트장 승인 뒤 파트장이 실행한다.

| 구분 | dev(지금) | prod(새로) |
|---|---|---|
| DB | `auth_db`, `chat_db`, `content_db`, `ops_db` | `auth_db_prod`, `chat_db_prod`, `content_db_prod`, `ops_db_prod` |
| 로그인 계정 | `<db>_app`, `content_db_recommend`, `content_db_ingest` | `<db>_prod_app`, `content_db_prod_recommend`, `content_db_prod_ingest` |
| NOLOGIN 역할 | `content_db_recommend_search`, `content_db_ingest_writer`, `content_db_rag_search_definer`(V14) | `content_db_prod_recommend_search`, `content_db_prod_ingest_writer`, `content_db_prod_rag_search_definer`(V14) |

- 이름 규칙은 `<DB 이름>_<용도>`다. `environments/kind/data/db-bootstrap.sql`이 psql 변수 `db_suffix`(빈 값 또는 `_prod`)로 이름을 만든다.
  dev(kind·EC2·EKS dev)는 지금과 같은 이름이고(변수 없이 실행해도 같다), 다른 값은 아무것도 만들지 않고 멈춘다.
  content 마이그레이션(V12·V14)이 역할 이름을 `current_database()`로 만들어 검색 함수 역할도 앱 수정 없이 `content_db_prod_*`가 된다.
- 권한 구조는 dev와 같다: 각 prod DB의 PUBLIC CONNECT 회수, 검색·적재 계정은 NOLOGIN 역할 상속(INHERIT, SET 끔)으로만 권한을 받는다.
  dev 계정은 prod DB에, prod 계정은 dev DB에 접속하지 못하고 dev·prod 역할 사이 멤버십도 없다
  (`scripts/test-db-bootstrap-sql.sh`가 같은 서버에 두 벌을 만들어 슈퍼유저·RDS 마스터 흉내 두 경우 모두 확인).
- prod 앱 values(#43)는 DB URL·사용자 이름만 prod 이름으로 덮어쓴다. Secret 이름·키는 dev와 같다.
- content prod 데이터는 재적재 또는 dev 복사 중 별도 결정(ingest 담당과). 이 절차는 빈 DB·계정까지만이다.

### 0. 선행

- #62(prod 네임스페이스, Pod Security restricted)·#63(이 문서)·이 PR 병합. SES 비밀(`ureka/eks/prod/ses-smtp`, `docs/ses.md` 3번).
- 운영 PC: AWS SSO `ureka-admin` 로그인, `UREKA_EXPECTED_ACCOUNT_ID`를 화면에 보이지 않게 읽어 둠(`scripts/eks/README.md` '준비'),
  `infra/environments/data`를 `backend.hcl`로 init(도구가 `terraform output`으로 마스터 비밀 ARN·엔드포인트를 읽는다).
- 2번부터: EKS가 켜져 있고(#42), data 스택 RDS SG가 **지금 EKS 노드 SG**에서 5432를 허용(EKS를 새로 만들면 data 재plan에서 SG 규칙만 바뀌는지 확인),
  RDS `available`. Job 이미지는 Docker Hub에서 NAT로 받는다.

### 1. 시드: `ureka/eks/prod/app` 만들기 (EKS 불필요)

```sh
python3 scripts/eks/seed_prod_secrets.py check  --profile ureka-admin
python3 scripts/eks/seed_prod_secrets.py create --profile ureka-admin --confirm-env prod
```

- AWS CLI history(`cli_history=enabled`)면 멈춤(요청·응답 본문이 로컬 기록에 남는다) → 승인 계정(STS) 확인 → 이미 있으면(삭제 예약 포함) 멈춤 → 비밀번호 6개·`EMAIL_CODE_SECRET`·`INTERNAL_SERVICE_TOKEN`은
  `secretsmanager get-random-password`(영문·숫자 64자), JWT 키 쌍(RSA 2048)은 0700 임시 폴더에서 openssl로 만들고 바로 지움
  → 묶음 JSON을 aws 표준 입력으로만 `create-secret`(이번 실행 표시로 무작위 `ClientRequestToken`을 붙인다). 값은 화면·명령 인자·Git·로그에 없다. 계정 이름 2개는 `content_db_prod_recommend`·`content_db_prod_ingest`.
- 확인(값 없이): `aws secretsmanager describe-secret --secret-id ureka/eks/prod/app --profile ureka-admin --query '{Name:Name,Versions:VersionIdsToStages,Deleted:DeletedDate}'`
  → 버전 1개(AWSCURRENT). `get-secret-value`로 열어 보지 않는다.
- SES·Gemini 값은 이 묶음에 없다(별도 비밀). 덮어쓰기·교체 기능은 없다(아래 'prod 값 교체').

#### prod 시드 실패 복구

- "만들어지지 않았습니다": 아무것도 생기지 않았다. 원인(예외 이름·SSO 만료·권한)을 고친 뒤 그대로 다시 실행한다.
- 응답만 잃었는데 저장된 버전 ID가 이번 실행의 토큰이면 도구가 확인하고 성공으로 끝낸다("참고: 생성 응답은 잃었지만 …").
- "이번 실행의 버전이 아닙니다": 동시에 다른 실행이 만든 것이다. 비밀은 한 번에 한 JSON으로만 들어가므로 값끼리는 맞다.
  누가 실행했는지 확인하고, 위 확인 명령으로 버전 1개면 **그대로 쓴다**(이번 실행 값은 메모리에서 버렸다).
- "확인하지 못했습니다": SSO를 다시 로그인하고 위 확인 명령으로 상태를 본 뒤 위 두 경우 중 하나로 처리한다.
- 시드를 버리고 새로 만들어야 할 때(예: 형식 오류를 발견)는 **2번 DB bootstrap 전에만** 지운다:
  `aws secretsmanager delete-secret --secret-id ureka/eks/prod/app --force-delete-without-recovery --profile ureka-admin` → 다시 1번.
  bootstrap 뒤에 지우면 DB 비밀번호와 어긋난다(그때는 2번을 다시 실행해 새 해시를 넣는다. bootstrap은 매번 해시를 다시 넣는다).

### 2. prod DB bootstrap (EKS 켠 뒤)

```sh
python3 scripts/eks/bootstrap_prod_db.py check --profile ureka-admin
python3 scripts/eks/bootstrap_prod_db.py apply --profile ureka-admin --confirm-env prod
```

- check: CLI history 꺼짐·승인 계정·ACTIVE EKS·kubectl 컨텍스트 `ureka-eks`·prod 네임스페이스 restricted·data output 형식·prod 묶음(속성·계정 이름·비밀번호 겹침) 확인, 마스터 비밀은 apply와 같은 입력 경로로 `describe-secret`만 해 존재·RDS 소유를 본다(값은 읽지 않음). 변경 없음.
- apply: **클러스터 실행 잠금**(prod Lease `db-bootstrap-prod-lock`, create라 동시에 하나만 성공) → 잠금 안에서 이전 실행 잔여물 삭제 확인
  → RDS 마스터 비밀 읽기(ARN은 0600 임시 파일 `--cli-input-json file://`로만, 호출 뒤 바로 삭제. aws CLI v2는 `file:///dev/stdin`을 이 옵션에서 읽지 못한다) → prod 네임스페이스에 임시
  `db-bootstrap-prod-accounts`(SCRAM 해시 6개)·ConfigMap·`db-bootstrap-prod-master` → Job `db-bootstrap-prod`(`environments/eks/prod/db-bootstrap/job.yaml`,
  restricted 충족, `DB_SUFFIX=_prod`) → 완료 대기(최대 10분) → 로그 요약(확인 줄·오류 줄만, 해시는 가림)
  → **성공·실패·Ctrl+C·SIGTERM 모두** 이번 실행 표시(`ureka.io/bootstrap-run` 라벨)가 붙은 Job·Pod·Secret 2개·ConfigMap만 삭제·없어졌는지 확인
  (정리 중에는 Ctrl+C·SIGTERM을 무시) → 잠금 해제. 비밀번호 원문은 DB 서버로 가지 않는다(해시만).
- 종료 코드: 0 성공, 1 실패(정리 완료), **3 정리 실패**(마스터 비밀번호가 클러스터에 남았을 수 있음. CREATE 거부·시간 초과·중단 같은 다른 오류와 겹쳐도 3), 130 중단(정리 완료).
- 성공 출력: `check environment suffix _prod, content db content_db_prod`, `check vector …`, `정리 확인: … 없음`.
- 종료 코드 3("경고: 지우지 못한 자원"): 마스터 비밀번호가 클러스터에 남았을 수 있다. 출력된 자원을 바로 지우고
  `kubectl --context ureka-eks -n prod get job,pod,secret,configmap | grep db-bootstrap-prod`가 비었는지 본다.
  SIGKILL·PC 종료·클러스터 불통으로 도구가 정리하지 못했을 때도 같은 명령으로 확인한다(다음 apply가 잠금을 잡은 뒤 먼저 지운다).
- 여러 번 실행해도 같은 상태가 된다(비밀번호 해시는 매번 다시 넣는다). dev DB·계정은 건드리지 않는다(postgres·template1 CONNECT 회수는 공통).
- **동시 실행·잠금**: 다른 실행이 잠금을 갖고 있으면 아무것도 지우지 않고 멈춘다(다른 PC·셸에서 겹쳐 실행해도 상대 Job·Secret을 지우지 않는다).
  도구가 SIGKILL 등으로 잠금을 남겼다면 `kubectl --context ureka-eks -n prod get lease db-bootstrap-prod-lock -o yaml`로 시각을 보고,
  그 실행이 끝났음을 확인한 뒤 **30분이 지난 경우에만** `apply … --recover-stale-lock`으로 넘겨받는다(읽은 resourceVersion으로 교체해, 두 복구가 겹쳐도 하나만 성공).
  그 뒤 시작 정리가 남은 Job·Secret을 지운다. 잠금 해제만 실패하면 경고하고 종료 코드 1(다음 실행이 멈추므로 위 명령으로 확인).
- 임시 마스터 Secret의 접근 통제는 prod RBAC(#62: 사람은 조회만, Secret·로그·exec 없음)에 기댄다. prod에 Pod 템플릿·Secret 쓰기 권한을 주는 변경은 이 Secret 접근 범위도 함께 검토한다.
- 환경 경계 시험은 정상 bootstrap 경로의 결과다. 다른 주체가 미리 만든 prod 역할·교차 GRANT를 지우지는 않는다(역할은 인스턴스 전체 공유,
  content 앱 계정은 CREATEROLE). 실제 RDS 첫 적용 전에 `_prod` 역할이 이미 있는지, 멤버십이 예상과 같은지 확인한다.
- 마스터 비밀은 이 도구를 실행하는 CN SSO만 읽는다. ESO 리더 역할(`ureka/eks/prod/*`)에는 RDS 관리 비밀(`rds!…`)이 들어가지 않는다.

### 3. prod 비밀 앱 등록·수동 Sync

위 'EKS 연결 순서' 3번을 `--env prod`로 한다(`check` → `apply --confirm-env prod`). prod는 자동 Sync가 없으므로 등록 뒤 Argo CD에서 **diff를 보고 손으로 Sync**한다.

수동 Sync 전 확인 포인트(`ureka-eks-secrets-prod` diff):
- 자원은 16개뿐: ServiceAccount `ureka-secrets-reader`, SecretStore `ureka-aws-secrets`, Role·RoleBinding `ureka-secrets-reader-token`,
  ValidatingAdmissionPolicy·Binding 각 2개(`…-pods-prod`, `…-token-prod`), ExternalSecret 8개(서비스 7개 + `ureka-auth-mail`).
- ExternalSecret의 원격 키는 모두 `ureka/eks/prod/app` 또는 `ureka/eks/prod/ses-smtp`다(`ureka/eks/dev/` 없음).
- 리더 ServiceAccount의 역할 ARN 끝이 `role/ureka-eks-eso-prod`다. 삭제(prune) 표시가 없다(prune 꺼짐).
- 처음이 아닌 Sync(main 변경 반영)는 바뀐 항목이 그 PR의 의도와 같은지 본다. 속성 매핑이 바뀌면 앱 재시작이 필요할 수 있다.

Sync 뒤(값 없이): `kubectl --context ureka-eks -n prod get secretstore,externalsecret`에서 SecretStore `Valid`, ExternalSecret 8개 `SecretSynced`,
`get secret`에 같은 이름 8개. `ureka-auth-mail`만 실패하면 SES 비밀이 아직 없는 것이다. **지금은** auth가 이 Secret을 참조하지 않아 앱 기동에 영향이 없지만,
아래 'prod 메일'의 #43 후속으로 auth가 필수(optional 아님) `secretKeyRef`로 참조하면 Secret이 없을 때 auth Pod가 뜨지 않는다(CreateContainerConfigError).
그래서 순서는 **SES 비밀 생성(`docs/ses.md` 3번) → 이 3번에서 `ureka-auth-mail` SecretSynced 확인 → auth가 참조하는 values 병합 → 4번 prod 앱 Sync**다.
권한 시험은 위 5번을 prod로 한다(정책 이름 `…-prod`).

### 4. prod 앱 Sync (#43)

비밀 8개가 생긴 뒤 prod 업무 앱을 수동 Sync한다. auth·content·ops는 기동할 때 Flyway가 스키마를 만들고, chat은 마이그레이션 Job이 만든다.
DB 인증 실패(`password authentication failed for user "…_prod_app"`)면 2번을 다시 실행한다(같은 묶음 값으로 해시를 다시 넣음).

### prod 메일(SES)

ExternalSecret `ureka-auth-mail`(키 `MAIL_USERNAME`·`MAIL_PASSWORD`)은 prod만 만든다. **auth가 이 Secret을 읽으려면 #43 쪽 values 변경이 더 필요하다**:
`MAIL_USERNAME`·`MAIL_PASSWORD`(이 Secret 참조)·`MAIL_FROM`은 base env에 없어 지금 차트의 `envOverrides`로 넣을 수 없다.
`MAIL_HOST`·`MAIL_PORT`·`MAIL_SMTP_AUTH`·`MAIL_STARTTLS`는 base에 있어 prod `envOverrides`로 바꾼다(값은 `docs/ses.md` 5번).
base에 추가하면 EC2 dev auth가 새 Pod 스펙으로 카나리 배포(50%에서 멈춤)되므로, prod values에서만 env를 더하는 방법을 #43에서 정한다.
그 values를 병합·Sync하기 전에 `ureka-auth-mail`이 SecretSynced여야 한다(위 3번 순서). 필수 참조라 Secret이 없으면 auth Pod가 시작하지 않는다.
#49 NetworkPolicy가 prod에 들어가면 auth → SES SMTP(587) egress와 bootstrap Job → RDS(5432) egress를 허용 목록에 넣는다.

### prod 값 교체

이 PR은 교체 도구를 만들지 않는다. DB 비밀번호 교체 순서(설계만): 묶음에 새 버전(`put-secret-value`, 이전 값은 AWSPREVIOUS) → 2번 bootstrap(새 해시)
→ ESO 새로 고침 → prod 앱 재시작. 2번과 앱 재시작 사이에는 기존 연결만 살아 있고 새 연결은 실패한다. JWT 키 교체는 모든 로그인 토큰을 끊는다.

## Turnstile 끄기와 복구 (prod auth 봇 확인, auth#44)

prod auth는 `TURNSTILE_ENABLED=true`이고 비밀키(`ureka-auth-turnstile`의 `TURNSTILE_SECRET_KEY`)를 **필수 참조**로 읽는다. 비밀 묶음 `turnstile`의 원격 비밀 `ureka/eks/prod/turnstile`은 JSON이 아니라 **값 하나**라서 속성 이름을 비워 두고(`wholeValueAllowed`에 적은 항목만 허용) 전체 값을 읽는다.

켜는 순서: 병합 → prod 비밀 앱 수동 Sync(`ureka-auth-turnstile` SecretSynced) → prod auth 수동 Sync(카나리 정지) → **새 카나리 Pod**로 확인(새 비회원 발급 201, 인증 메일 202와 실제 수신, 토큰 없이 호출하면 400, 공급자·키 문제는 503) → 승격 → 모든 Pod가 ON인지 확인. 카나리 중에는 OFF Pod도 요청을 받으므로 공개 보호가 끝난 것으로 보지 않는다.

| 상황 | 복구 |
|---|---|
| 설정 실수(비밀키 값·호스트 불일치)인데 Secret·키는 **있음** | `environments/eks/prod/ureka-auth.yaml`의 `TURNSTILE_ENABLED`를 `"false"`로 되돌리고 auth 앱을 Sync한다. 고친 뒤 다시 켠다 |
| Secret·키가 **없음**(ExternalSecret 실패 등) | `false` 한 줄만으로는 복구되지 않는다. 필수 참조(`requiredSecretEnv`)가 남아 새 Pod가 시작하지 못한다. 이 변경(PR)을 되돌리거나 `TURNSTILE_SECRET_KEY`를 `requiredSecretEnv`에서 빼고 `false`로 한다. 메일 자격(`MAIL_USERNAME`·`MAIL_PASSWORD`) 필수 지정은 유지한다 |
| 운영 중 Cloudflare 장애(503) | 기본은 503 유지. 끄려면 CN이 판단하고 공개 입구 제한 같은 다른 막기를 먼저 건다(`07-봇확인-Turnstile.md` 8-2) |

끄는 순간 비회원 발급과 인증 메일이 **확인 없이 열린다**. 끈 시각, 이유, 다시 켠 뒤 확인한 결과를 기록한다. 비밀키를 바꾸면 ESO 동기화 뒤 auth Pod를 교체하고 새 Pod로 다시 확인한다(Secret 갱신만으로는 실행 중인 Pod의 환경 변수가 바뀌지 않는다). 값은 로그·화면·리뷰에 출력하지 않는다.

## 로컬 검증 (AWS·클러스터 불필요)

```sh
terraform -chdir=infra/environments/eks test
terraform -chdir=infra/environments/data test
python3 -m unittest discover -s tests/eks      # 복사·시드·bootstrap 도구(가짜 aws·kubectl)
bash scripts/test-eks-secrets.sh
bash scripts/test-run-bootstrap.sh            # DB_SUFFIX 검사 포함
bash scripts/test-db-bootstrap-sql.sh         # Docker: dev·prod 두 벌, 환경 경계
bash scripts/check-forbidden-files.sh
```

## 아직 확인하지 않은 것

- 실제 AWS에서 리더 역할 맡기·경로 밖 거부, EC2 역할의 복사 권한(특히 기본 KMS 키로 `CreateSecret`이 kms 권한 없이 되는지)
- ESO 2.15.0과 EKS 1.37 실제 동작·Pod Security restricted·webhook 포트(10250, control plane → 노드 SG 1025–65535 허용 범위)
- VAP의 TokenRequest 거부가 실제 apiserver에서 동작하는지(위 5번 시험)
- ESO 컨트롤러 egress(Secrets Manager·STS, NAT 경유)는 #49 NetworkPolicy에서 허용 목록에 넣는다
- ESO 차트 이미지 취약점 검사, 실제 메모리 사용량
- prod 시드: `create-secret --secret-string file:///dev/stdin`은 운영 PC aws CLI v2에서 동작 확인(11/23). `--cli-input-json`은 같은 방식이 안 되어 임시 파일로 바꿨다
- prod bootstrap: 실제 RDS(마스터는 슈퍼유저 아님)에서 `_prod` 두 번째 벌 생성, prod 네임스페이스 restricted에서 Job 실행, 노드 → RDS 5432,
  RDS의 `postgres` DB CONNECT 회수 여부(dev와 같은 한계), prod 앱 Flyway가 `content_db_prod_*` 역할을 만드는지
- auth가 `ureka-auth-mail`을 실제로 읽는 연결(#43 후속)과 SES 발송
