# EKS 비밀값: Secrets Manager → ESO, 최소 IRSA (#63)

이 문서는 CN 담당이 교차 검토 뒤 실행할 절차다. 초안 작성 때 AWS 조회·apply·클러스터 변경은 하지 않았다.
AWS 변경(Terraform apply, 비밀 생성)은 교차 검토와 파트장 승인 뒤 파트장이 직접 한다.

## 한눈에

```
EC2 dev k3s Secret ──(1회 복사, EC2 서버 안)──▶ Secrets Manager ureka/eks/dev/app, ureka/eks/dev/chat-ai
                                                   │ GetSecretValue (ureka/eks/dev/* 만)
                                     IRSA 역할 ureka-eks-eso-dev ◀── dev:ureka-secrets-reader 토큰(ESO만 발급)
                                                   │
                          ESO(external-secrets 네임스페이스, AWS 권한 없음) → dev의 기존 이름 Secret 8개
prod도 같은 구조(ureka/eks/prod/*, ureka-eks-eso-prod, prod:ureka-secrets-reader). 값은 새로 만든다(후속 PR).
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
| `ureka/eks/dev/chat-ai` | `AI_MODE`, `AI_API_KEY` | 같은 스크립트(EC2에 `ureka-chat-ai`가 있을 때만) |
| `ureka/eks/prod/app` | 아래 12개(새 값) | 후속 PR 시드 절차 |
| `ureka/eks/prod/chat-ai` | 위와 같음 | prod용 키가 정해지면(아직 끔) |

비용: 비밀 4개 × $0.40/월 = 약 $1.6/월, API 호출은 1시간 새로 고침 기준 월 $0.1 미만(가정, 계산기로 재확인).
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

## 권한 경계

| 주체 | 받는 권한 | 코드 |
|---|---|---|
| ESO 컨트롤러 | AWS 권한 없음. `serviceaccounts/token` 발급(차트 기본 RBAC) | `argocd/eks/external-secrets-app.yaml` |
| `dev:ureka-secrets-reader` | `ureka-eks-eso-dev`: `secretsmanager:GetSecretValue`, `ureka/eks/dev/*`만 | `infra/environments/eks/secrets.tf` |
| `prod:ureka-secrets-reader` | `ureka-eks-eso-prod`: 같은 동작, `ureka/eks/prod/*`만 | 같은 파일 |
| EC2 dev 호스트 역할 | 복사하는 동안만 `ureka/eks/dev/*`에 Create·Describe·Put·TagResource(읽기 없음) | `infra/environments/data/eks_secret_copy.tf` |

- IRSA 신뢰 조건은 `StringEquals`로 `sub=system:serviceaccount:<env>:ureka-secrets-reader`, `aud=sts.amazonaws.com`만 받는다.
  리소스는 마지막 `/`까지 고정해 `ureka/eks/dev/*`가 prod나 `ureka/eks/devx…`와 겹치지 않는다. 기본 KMS 키(aws/secretsmanager)라 kms 권한은 없다.
- **dev에서 prod 비밀을 읽을 수 없다.** 네임스페이스 `SecretStore`는 자기 네임스페이스의 리더 계정만 쓴다.
  어느 네임스페이스에서나 리더를 빌려 쓸 수 있는 `ClusterSecretStore`·`ClusterExternalSecret`·`PushSecret`은 CRD도 만들지 않고 처리도 끈다.
  등록 도구는 이 CRD가 있으면 멈춘다.
- **다른 Pod가 리더 권한을 쓸 수 없다.** 차트의 ValidatingAdmissionPolicy가 (1) 그 네임스페이스에서 리더 계정으로 Pod를 만들거나
  (2) ESO 컨트롤러가 아닌 주체가 리더 토큰(TokenRequest)을 받는 것을 거부한다. 리더 계정은 토큰 자동 마운트도 끈다.
  앱 Pod의 서비스계정 토큰은 신뢰 조건의 sub가 달라 역할을 맡을 수 없다. 노드 IMDS는 hop limit 1이라 일반 Pod가 노드 역할을 쓰지 못한다(#42).
- 남는 위험: dev에 Secret 읽기·`ExternalSecret` 생성 권한이 있는 사람은 dev 비밀을 볼 수 있다(ESO의 edit/view ClusterRole이 기본 admin/edit에 합쳐진다).
  prod에 사람이 직접 쓰지 못하게 하는 RBAC는 #62가 정한다. 정책은 apiserver가 평가하므로 VAP를 지울 수 있는 클러스터 관리자는 예외다.
- chat의 SQS IRSA(보내기·받기만)는 큐가 생기는 #53에서 같은 방식(서비스계정 sub 고정, 큐 ARN 고정)으로 추가한다. 이번 범위에 없다.

## dev 복사 (EC2 → Secrets Manager, CN 실행)

선행: 이 PR 병합, EC2 dev·k3s가 켜져 있고 서비스 Secret이 정상(앱 Healthy). EKS는 꺼져 있어도 된다.

1. 내 PC에서 data 스택의 비공개 tfvars에 `eks_dev_secret_copy_enabled = true`를 넣고 plan을 검토한다.
   **변경은 `aws_iam_role_policy.ec2_copy_eks_dev_secrets` 생성 1개뿐이어야 한다**(RDS·SG 변경 없음). 파트장이 apply한다.
2. EC2 서버(SSM 셸)에서 저장소를 최신 main으로 맞춘 뒤 검사만 한다. 값은 출력되지 않는다.

   ```sh
   sudo python3 scripts/ec2/copy_eks_dev_secrets.py check
   ```

   모든 Secret을 읽어 키가 다 있는지, 같은 속성(JWT 공개키·내부 토큰)이 Secret마다 같은지, 계정 이름이 맞는지 보고
   원격 비밀이 있는지 확인한다. 하나라도 틀리면 AWS에 아무것도 쓰지 않는다.
3. 복사한다. 이미 있는 비밀은 바꾸지 않고 멈춘다(부분 쓰기 없음).

   ```sh
   sudo python3 scripts/ec2/copy_eks_dev_secrets.py copy
   ```

4. 바로 1번 값을 `false`로 되돌려 plan(정책 삭제 1개)→apply한다. 복사 권한을 켜 둔 채로 두지 않는다.
5. 내 PC에서 값 없이 존재만 확인한다: `aws secretsmanager describe-secret --secret-id ureka/eks/dev/app --profile ureka-admin --query '{Name:Name,Tags:Tags}'`.
   `get-secret-value`로 값을 열어 보지 않는다.

값은 서버의 0700 임시 폴더 파일을 `file://`로 aws CLI에 넘긴 뒤 바로 지운다. SIGKILL·서버 종료 때는 `/tmp/eks-dev-copy-*`가 남을 수 있으니
다음 접속에서 지운다. aws 오류 원문에는 ARN(계정 ID)이 들어 있어 예외 이름만 보여 준다.

### 값 교체

EC2 dev 값을 바꾸면(EC2 교체·재생성) EKS dev도 같이 맞춘다: 1번 → `copy --update-existing`(새 버전, 이전 값은 AWSPREVIOUS로 남음) → 4번.
ESO는 1시간마다 다시 읽는다. 앱 Pod는 시작할 때만 env를 읽으므로 EKS dev 앱을 재시작한다.
DB 비밀번호만 따로 바꾸는 절차는 없다(EC2 `create-secrets.sh`도 교체를 제공하지 않는다). 순서가 어긋나면 한쪽 환경이 DB 인증에 실패한다.

## EKS 연결 순서 (EKS 켠 뒤, CN 실행)

1. EKS Terraform apply(이 PR로 리더 역할 2개 추가. 비용 없음). plan에서 IAM role·inline policy 각 2개 생성만 늘었는지 본다.
2. Argo CD 설치(#43 도구) → `kubectl --context ureka-eks apply -f argocd/eks/external-secrets-app.yaml` → Argo CD에서 Sync.
   `external-secrets` Pod 3개 Ready, 네임스페이스 restricted 경고 없음을 확인한다.
3. #62로 `dev` 네임스페이스가 생긴 뒤 등록한다. 계정 ID는 승인된 로컬 설정의 `UREKA_EXPECTED_ACCOUNT_ID`에서 읽고 kubectl 표준 입력으로만 넘긴다.

   ```sh
   python3 scripts/eks/register_secrets_app.py check --env dev \
     --profile ureka-admin --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID"
   python3 scripts/eks/register_secrets_app.py apply --env dev --confirm-env dev \
     --profile ureka-admin --expected-account-id "$UREKA_EXPECTED_ACCOUNT_ID"
   ```

4. 확인(값 없이): `kubectl --context ureka-eks -n dev get externalsecret,secretstore`가 모두 Ready/Valid, `get secret`에 8개 이름이 있는지.
5. 권한 시험(#63 완료 기준 "다른 Pod가 못 쓰는지"). 결과는 거부 메시지만 기록한다.
   - 리더 계정으로 Pod 생성 → 거부: `kubectl --context ureka-eks -n dev run probe --image=busybox --restart=Never --overrides='{"spec":{"serviceAccountName":"ureka-secrets-reader"}}' --dry-run=server`
   - 사람 권한으로 리더 토큰 요청 → 거부(토큰은 화면에 내지 않는다): `kubectl --context ureka-eks -n dev create token ureka-secrets-reader >/dev/null 2>&1 && echo '실패: 발급됨' || echo '거부됨'`
   - 앱 서비스계정 토큰으로 역할 맡기 → `AccessDenied`(신뢰 조건 불일치). 방법은 #43 앱 배포 뒤 임시 Pod로 시험하고, 토큰은 출력하지 않는다.
   - dev SecretStore로 `ureka/eks/prod/app`을 가리키는 임시 ExternalSecret → `AccessDenied`로 동기화 실패, 확인 뒤 삭제.
6. prod는 prod 시드(후속 PR) 뒤 `--env prod`로 같은 순서를 밟는다. 시드 전에는 등록하지 않는다.

Application은 prune을 끈다. `ExternalSecret`이 지워지면 소유한 Secret도 지워져 앱이 내려가기 때문이다. 묶음을 없애는 변경은 병합 뒤 CN이 해당 자원만 확인하고 지운다.
원격 비밀이 사라지면 마지막 Secret 값은 남는다(`deletionPolicy: Retain`).

## prod DB·계정 생성 설계 (후속 PR, 실행은 CN이 교차 검토 뒤)

같은 RDS 인스턴스 안에 prod 전용 논리 DB와 계정을 만든다. dev와 데이터·계정을 공유하지 않는다. RDS 추가 비용은 없다.

| 구분 | dev(지금) | prod(새로) |
|---|---|---|
| DB | `auth_db`, `chat_db`, `content_db`, `ops_db` | `auth_db_prod`, `chat_db_prod`, `content_db_prod`, `ops_db_prod` |
| 로그인 계정 | `<db>_app`, `content_db_recommend`, `content_db_ingest` | `<db>_prod_app`, `content_db_prod_recommend`, `content_db_prod_ingest` |
| NOLOGIN 역할 | `content_db_recommend_search`, `content_db_ingest_writer` | `content_db_prod_recommend_search`, `content_db_prod_ingest_writer` |

- 이름 규칙은 `<DB 이름>_<용도>`다. content 마이그레이션(V12·V14)이 역할 이름을 `current_database()`로 만들기 때문에
  DB 이름만 바꾸면 검색 함수 소유·호출 역할도 앱 수정 없이 `content_db_prod_*`로 생긴다. 각 prod DB에서 PUBLIC CONNECT를 회수하고
  dev 계정은 prod DB에, prod 계정은 dev DB에 CONNECT가 없어야 한다(확인 쿼리를 같이 만든다).
- prod 앱 values(#43)는 DB URL·사용자 이름만 prod 이름으로 덮어쓴다. Secret 이름·키는 dev와 같다.
- 비밀번호·토큰은 **Secrets Manager `get-random-password`가 만든다.** JWT 키 쌍만 운영 PC의 0700 임시 폴더에서 openssl로 만든다.
  값은 화면·명령 인자·Git·채팅에 싣지 않고, `ureka/eks/prod/app`이 이미 있으면 멈춘다(덮어쓰기 없음).
- 계정 생성: 지금 `db-bootstrap.sql`을 DB·역할 이름 매개변수(접미사 `_prod`)를 받게 고치고, kind 시험(`scripts/test-db-bootstrap-sql.sh`)에
  dev·prod 두 벌을 같은 서버에 만드는 경우와 서로 CONNECT가 없는 경우를 더한다.
  실행은 `rds-bootstrap.sh`와 같은 흐름이다: 운영 PC가 `ureka/eks/prod/app`의 비밀번호로 **SCRAM 해시만** 계산 → EKS의 임시 bootstrap 네임스페이스에
  해시 Secret과 RDS 마스터 임시 Secret → Job 실행 → 성공·실패와 관계없이 마스터 Secret·Job을 지우고 사라졌는지 확인.
  비밀번호 원문은 DB 서버로 보내지 않는다. 마스터 비밀 읽기는 CN SSO에서만, ESO 리더에는 주지 않는다.
- content prod 데이터는 재적재 또는 dev 복사 중 별도 결정(ingest 담당과). 이 절차는 빈 DB·계정까지만이다.
- 후속 PR 범위: prod 시드 스크립트·시험, bootstrap SQL 매개변수화·시험, 실행 스크립트·시험, 이 절 갱신.

## 로컬 검증 (AWS·클러스터 불필요)

```sh
terraform -chdir=infra/environments/eks test
terraform -chdir=infra/environments/data test
python3 -m unittest discover -s tests/eks
bash scripts/test-eks-secrets.sh
bash scripts/check-forbidden-files.sh
```

## 아직 확인하지 않은 것

- 실제 AWS에서 리더 역할 맡기·경로 밖 거부, EC2 역할의 복사 권한(특히 기본 KMS 키로 `CreateSecret`이 kms 권한 없이 되는지)
- ESO 2.15.0과 EKS 1.37 실제 동작·Pod Security restricted·webhook 포트(10250, control plane → 노드 SG 1025–65535 허용 범위)
- VAP의 TokenRequest 거부가 실제 apiserver에서 동작하는지(위 5번 시험)
- ESO 컨트롤러 egress(Secrets Manager·STS, NAT 경유)는 #49 NetworkPolicy에서 허용 목록에 넣는다
- ESO 차트 이미지 취약점 검사, 실제 메모리 사용량
