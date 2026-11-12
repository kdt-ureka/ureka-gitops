# kind dev DB·비밀값과 DB 계정 구조

kind dev에 PostgreSQL 18 + pgvector, Redis, 비밀값 Secret을 붙이고 auth·content를 Argo CD로 배포한다. chat·ops용 DB(`chat_db`·`ops_db`)·계정·Secret도 여기서 미리 만든다(앱 배포는 각 서비스 values·Application PR). 매니페스트와 비밀값 방식은 kind 전용이다. DB 계정·권한 절차는 운영(RDS)에서도 같은 구조를 목표로 하지만, **RDS에서 같은 SQL 순서가 되는지는 아직 검증하지 않았다**(4장 끝).

## 1. 구성

| 무엇 | 어디 | Argo CD Application |
|---|---|---|
| PostgreSQL 18 + pgvector 0.8.7 (StatefulSet, PVC 2Gi) | `environments/kind/data/postgres.yaml` | `ureka-dev-data-kind` |
| Redis 8.8 (저장 안 함) | `environments/kind/data/redis.yaml` | 〃 |
| DB·계정 생성 Job (PostSync, 멱등) | `environments/kind/data/db-bootstrap-job.yaml` + `db-bootstrap.sql` | 〃 |
| auth (auth_db) | `environments/kind/ureka-auth.yaml` | `ureka-auth-kind` |
| content (content_db) | `environments/kind/ureka-content.yaml` | `ureka-content-kind` |
| chat_db·ops_db와 계정 (앱은 아직 없음) | 같은 `db-bootstrap.sql` | 〃 |
| 비밀값 Secret 9개 (기본 6 + chat·ops 3, 3장 목록) | Git에 없음. `scripts/kind/create-secrets.sh` | (Argo CD가 관리하지 않음) |

이미지는 모두 digest로 고정한다(`scripts/check-charts.sh`가 chart와 kustomize 양쪽을 검사). PSA restricted 그대로(비root uid 999, 읽기 전용 루트 FS, capability 제거, seccomp).

## 2. 처음 띄우는 순서

Application마다 자동 동기화가 따로 돈다. **data가 끝나고 계정이 만들어진 뒤에 auth·content를 적용한다.**

```bash
scripts/kind/up.sh
kubectl apply -f argocd/kind/ureka-dev-namespace.yaml   # dev 네임스페이스
scripts/kind/create-secrets.sh                           # Secret 9개(값은 이 PC에서 생성, 출력 안 함)
kubectl apply -f argocd/kind/ureka-dev-data.yaml         # PostgreSQL·Redis + db-bootstrap Job

# data 확인: Synced/Healthy, 마지막 동기화 Succeeded, Job 로그 "db-bootstrap 완료"
kubectl -n argocd get app ureka-dev-data-kind \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}'
kubectl -n dev logs job/db-bootstrap | tail -1

scripts/kind/sync-ecr-image.sh auth <커밋 SHA>
scripts/kind/sync-ecr-image.sh content <커밋 SHA>
kubectl apply -f argocd/kind/ureka-auth.yaml -f argocd/kind/ureka-content.yaml
scripts/kind/p11-check.sh                                # V14가 content main 이미지에 들어간 뒤
```

- Secret보다 data Application을 먼저 적용하면 postgres Pod는 Secret을 기다리고, db-bootstrap Job은 재시도하다(최대 10분) 실패할 수 있다. 그러면 동기화가 Failed로 남으므로 Secret을 만든 뒤 다시 동기화한다(Argo CD UI의 Sync, 또는 `kubectl -n argocd patch app ureka-dev-data-kind --type merge -p '{"operation":{"sync":{}}}'`).
- auth·content를 계정보다 먼저 띄우면 DB 접속 실패로 재시작하다가 계정이 생기면 Ready가 된다. 망가지지는 않지만 위 순서가 확인하기 쉽다.

## 3. 비밀값 방식 (결정 필요: 송준혁)

| 안 | 내용 | 장점 | 단점 |
|---|---|---|---|
| **A. 생성 스크립트 (이 PR)** | `create-secrets.sh`가 kind 안에서 Secret을 처음 한 번 만든다. 값은 Git·영구 파일에 남기지 않는다(만들 때 권한 700 임시 파일을 쓰고 끝나면 지운다) | 추가 컨트롤러 없음. 클러스터마다 값이 달라 유출 범위가 그 PC로 한정. 팀원이 각자 kind를 띄워도 그대로 동작 | Secret이 Git 밖이라 Argo CD가 상태를 모른다. 클러스터를 지우면 값도 사라진다(로컬 dev라 문제없음) |
| B. Sealed Secrets | 암호화한 Secret을 Git에 커밋 | Git으로 전부 관리 | 컨트롤러 키가 클러스터마다 달라 **팀원 kind마다 다시 봉인**해야 한다. PUBLIC 저장소에 암호문이 쌓인다 |
| C. ESO + 로컬 백엔드 | 운영과 같은 ESO, 저장소만 로컬(예: Kubernetes provider) | 운영(EKS: Secrets Manager → ESO)과 같은 모양 | kind에 컨트롤러·CRD 추가, 결국 원본 Secret은 A처럼 만들어야 한다 |

추천은 **A**. kind는 S6~S7 임시 환경이고, 운영은 이미 Secrets Manager → ESO로 정해져 있다. ESO 경로 검증은 EKS(S8)에서 한다.

**Secret 목록 (네임스페이스 `dev`)**

| 묶음 | Secret | 키 | 쓰는 곳 |
|---|---|---|---|
| 기본 | `postgres-admin` | `POSTGRES_PASSWORD` | postgres, db-bootstrap Job |
| 〃 | `db-accounts` | `AUTH_DB_APP_SCRAM`, `CONTENT_DB_APP_SCRAM`, `CONTENT_DB_RECOMMEND_SCRAM`, `CONTENT_DB_INGEST_SCRAM` (해시만) | db-bootstrap Job |
| 〃 | `ureka-auth-secrets` | `DB_PASSWORD`, `JWT_PRIVATE_KEY`, `JWT_PUBLIC_KEY`, `EMAIL_CODE_SECRET`, `INTERNAL_SERVICE_TOKEN` | auth |
| 〃 | `ureka-content-secrets` | `DB_PASSWORD`, `JWT_PUBLIC_KEY`, `INTERNAL_SERVICE_TOKEN` | content |
| 〃 | `ureka-recommend-db` | `DB_USERNAME`, `DB_PASSWORD` | recommend 실제 모드(아직 안 씀) |
| 〃 | `ureka-ingest-db` | `DB_USERNAME`, `DB_PASSWORD` | ingest(아직 안 씀) |
| chat·ops | `db-accounts-chat-ops` | `CHAT_DB_APP_SCRAM`, `OPS_DB_APP_SCRAM` (해시만) | db-bootstrap Job |
| 〃 | `ureka-chat-secrets` | `DB_PASSWORD`(`chat_db_app`), `JWT_PUBLIC_KEY`, `INTERNAL_SERVICE_TOKEN` | chat api·worker·마이그레이션 Job |
| 〃 | `ureka-ops-secrets` | `DB_PASSWORD`(`ops_db_app`), `JWT_PUBLIC_KEY` | ops |

- 변수 이름은 각 저장소 `.env.example`과 ureka-local compose 기준이다. chat은 `DATABASE_URL` 한 줄로 받으므로 values에서 `$(DB_PASSWORD)` 참조로 조립한다(비밀번호는 16진수라 URL 인코딩이 필요 없다. `DB_PASSWORD`를 env 목록에서 `DATABASE_URL`보다 **앞에** 둬야 치환된다).
- `JWT_PUBLIC_KEY`·`INTERNAL_SERVICE_TOKEN`은 모든 서비스가 같은 값이다(auth가 서명한 토큰을 각 서비스가 검증, 내부 호출 토큰 공유). JWT 개인키는 auth만 받는다. ops는 내부 토큰을 받지 않는다(`.env.example`에 없음).
- AI 키(`AI_API_KEY`)는 위 9개에 넣지 않는다. kind chat AI는 기본 꺼짐(chat `AI_MODE` 기본값 `disabled`)이고, 켜려는 사람만 아래 선택 Secret을 만든다.

**(선택) chat AI 켜기 — `ureka-chat-ai`**

| Secret | 키 | 쓰는 곳 |
|---|---|---|
| `ureka-chat-ai` | `AI_MODE`(`gemini`), `AI_API_KEY` | chat api·worker·마이그레이션 Job(`optional: true`로 읽음) |

```bash
scripts/kind/create-secrets.sh --chat-ai        # 터미널: 키를 화면에 보이지 않게 입력
pbpaste | scripts/kind/create-secrets.sh --chat-ai   # 또는 클립보드에서 파이프
kubectl -n dev rollout restart deployment/ureka-chat deployment/ureka-chat-worker   # env는 Pod 시작 때만 읽힌다
```

- **켜고 끄는 스위치가 Secret 자체다.** chat values는 `AI_MODE`·`AI_API_KEY`를 이 Secret에서 `optional: true`로 읽고, `AI_MODE`를 값으로 쓰지 않는다. Secret이 없으면 두 env가 아예 생기지 않아 앱 기본값(꺼짐)으로 돈다. 그래서 키가 없는 팀원 kind는 그대로 동작한다. 모델 이름(`AI_*_MODEL`)·`AI_MAX_ATTEMPTS`는 비밀값이 아니라 values에 둔다.
- 키는 표준 입력으로만 받는다(터미널이면 `read -s`). 셸 내장 `printf`로 임시 디렉터리(umask 077) 파일에 쓰고 `kubectl create --from-file`로 넘긴다. 명령 인자·화면·Git에 싣지 않는다(gitops는 PUBLIC). 영문·숫자·`._-` 20~256자가 아니면(빈 값·공백·따옴표 섞임) 아무것도 만들지 않는다. 오류 메시지에도 키를 싣지 않는다.
- 이미 있으면 덮어쓰지 않는다. 키를 바꾸거나 AI를 끄려면 `kubectl -n dev delete secret ureka-chat-ai` 후 다시 만들거나(끄기는 지우기만) 위 재시작 명령. 이 Secret은 DB와 묶여 있지 않아 지우고 다시 만들어도 된다.
- 키는 **개인 Gemini 키**를 쓴다. 요금·무료 등급 한도는 키 주인 부담(팀 예산과 별개)이고, 무료 등급 입력은 Google 제품 개선에 쓰일 수 있어 **시험 문장만** 넣는다. 범위는 chat 해석·답변·페르소나(api·worker 둘 다 Gemini 호출)이고 recommend는 mock 그대로다. 공유 환경·EKS는 팀 키를 Secrets Manager → ESO로 넣는다.
- 회귀 시험(`scripts/test-create-secrets.sh`): 새로 만들기(키 목록·`AI_MODE=gemini`·입력값 일치·끝 줄바꿈 제거), 이미 있음·빈 입력·공백·따옴표·너무 짧음/긺·Forbidden·생성 중 AlreadyExists는 만들지 않음, 모든 경우 키가 출력·kubectl 인자에 없음, kind가 아닌 컨텍스트 거부.

**기존 클러스터에 chat·ops Secret 추가하기**

Secret을 두 묶음으로 나눈 이유: 기본 묶음은 PostgreSQL 슈퍼유저 비밀번호와 묶여 있어 "일부만 있음"이면 클러스터(DB 볼륨)를 새로 만들어야 한다. chat·ops 계정은 나중에 생겼고, 슈퍼유저 비밀번호와 무관해 기존 DB에 그대로 더할 수 있다. 그래서 스크립트는 묶음마다 "전부 있음/전부 없음"만 받는다.

| 기본 6개 | chat·ops 3개 | 스크립트 동작 |
|---|---|---|
| 없음 | 없음 | 처음 만들기: 9개 생성(DB 볼륨이 남아 있으면 멈춤) |
| 전부 | 없음 | **추가**: 3개만 생성. `JWT_PUBLIC_KEY`·`INTERNAL_SERVICE_TOKEN`은 `ureka-auth-secrets` 값을 그대로 복사(값은 화면·argv에 싣지 않음), DB 비밀번호 2개는 새로 생성 |
| 전부 | 전부 | 아무것도 바꾸지 않음 |
| 일부 | (무관) | 멈춤. 기존 규칙 그대로(클러스터 새로 만들기) |
| 전부 | 일부 | 멈춤. chat·ops 3개만 지우고 다시 실행하라고 안내 |
| 없음 | 일부·전부 | 멈춤. 새 기본 Secret과 JWT 공개키가 어긋나므로 chat·ops 3개를 지우고 다시 실행 |

기존 클러스터 순서: ① 이 PR이 main에 병합되기 **전에** `scripts/kind/create-secrets.sh`(추가) → ② 병합 후 data 자동 동기화(또는 수동 sync)로 db-bootstrap이 `chat_db`·`ops_db`와 계정을 만든다. 순서가 바뀌어 Secret보다 동기화가 먼저 오면, db-bootstrap Pod는 `db-accounts-chat-ops`가 없어 `CreateContainerConfigError`로 기다리다 Secret이 생기면 이어서 돈다(Job 제한 10분을 넘기면 동기화 Failed → Secret을 만든 뒤 다시 sync). 기존 auth·content Pod와 DB는 영향이 없다.

chat·ops Secret을 다시 만들면(지우고 재실행) `chat_db_app`·`ops_db_app` 비밀번호만 바뀐다. 다음 data 동기화의 db-bootstrap이 저장된 해시와 다른 것을 보고 새 해시로 바꾸고, 그 뒤 chat·ops Pod를 재시작하면 된다. 슈퍼유저·기본 묶음에는 영향이 없다.

**값이 지나가는 곳과 수명**

| 값 | 어디에 있나 | 수명 |
|---|---|---|
| 모든 원문(DB 비밀번호, JWT 키, 토큰, 슈퍼유저 비밀번호) | 스크립트 임시 디렉터리(umask 077) → `kubectl create` 표준 입력 → Secret | 임시 디렉터리는 스크립트가 끝나면 삭제. 명령 인자(argv)·화면에 싣지 않음 |
| DB 계정 비밀번호 | 원문은 앱 Secret(`ureka-*-secrets`, `ureka-*-db`)에만. Job용 `db-accounts`에는 **SCRAM-SHA-256 해시만** | DB 서버로는 원문이 가지 않는다. `ALTER ROLE ... PASSWORD '<해시>'`는 저장된 해시와 다를 때만(처음 만들 때) 나간다 |
| 슈퍼유저 비밀번호 | `postgres-admin` → postgres Pod env, db-bootstrap Job env(`PGPASSWORD`, 관리자 접속용 원문) | postgres 이미지의 initdb가 **데이터 디렉터리를 처음 만들 때만** 슈퍼유저 비밀번호로 설정한다. 그 뒤 Secret을 바꿔도 기존 DB에는 반영되지 않는다 |

verifier는 **SQL을 보내기 전에 `environments/kind/data/run-bootstrap.sh`(db-bootstrap Job 본문)가 검사**하고, 하나라도 맞지 않으면 `pg_isready`·`psql`을 부르지 않고 멈춘다(값은 출력하지 않음). 이 생성기 형식만 받는다: 줄바꿈(CR·LF) 없음, `SCRAM-SHA-256$4096:`, salt는 base64로 디코딩해 16바이트, StoredKey·ServerKey는 각각 32바이트, 셋 다 다시 인코딩하면 같은 정규형. PostgreSQL의 모든 verifier를 받으려는 검사는 아니다. 회귀 시험 `scripts/test-run-bootstrap.sh`(CI, 러너 기본 sh = dash): 정상은 psql까지 가고, 빈 값·원문·접두사만·정상+개행+원문·앞뒤 개행·CR·CRLF·반복 수 0000/4095/40960·salt 1글자/15바이트/비정규형/잘못된 문자·키 31바이트·구분자 누락/추가·명령 문자열 20경우는 DB 호출 0회로 실패한다. 보안 재검토에서 스크립트의 SCRAM 계산이 같은 비밀번호·salt의 PostgreSQL 18 libpq 결과와 일치함을 확인했다.

2026-11-10 확인(당시 구현, SQL 안에 형식 확인 SELECT가 있던 때): `log_statement=all`로 바꾸고 bootstrap을 다시 돌렸을 때 실행된 `ALTER ROLE <이름> PASSWORD` 문장 0건, 서버 로그에 비밀번호 원문 0건(4개 계정 모두 대조). 해시는 형식 확인·비교 SELECT에 나온다(원문이 무작위 256비트라 되돌릴 수 없음). 확인 후 `log_statement`를 되돌림.

**자격에 닿을 수 있는 권한**: dev 네임스페이스 Secret 조회, Secret을 붙인 Pod를 만들 수 있는 권한, postgres·Job Pod `exec`(Pod 안 소켓·127.0.0.1 접속은 이미지 기본 pg_hba상 trust)는 DB 관리자 권한과 같다고 본다. kind는 이 PC 사용자만 갖는다.

**교체(rotate)는 제공하지 않는다.** DB 계정·슈퍼유저 비밀번호·앱 재시작을 한 번에 맞추고 중간 실패를 되돌리는 절차를 검증하지 않았기 때문이다(보안 검토 2026-11-10). kind에서 값을 바꾸려면 클러스터를 새로 만든다(`kind delete cluster --name ureka` → 2장 순서). 스크립트는 Secret이 일부만 있거나, Secret 없이 DB 볼륨만 남아 있으면 멈춘다(새 슈퍼유저 비밀번호가 기존 DB에 적용되지 않으므로). 있는지 확인할 때 **`NotFound`만 '없음'으로 보고, 권한 부족(`Forbidden`)·연결 실패 등 다른 오류는 바로 멈춘다**(보이지 않는 Secret을 없다고 보고 새로 만들지 않게). Secret은 `kubectl create`로만 만들어 이미 있는 것을 덮어쓰지 않는다. kind가 아닌 컨텍스트(`kind-*`가 아님)에서는 실행하지 않는다. 회귀 시험: `scripts/test-create-secrets.sh`(CI). 생성 도중 실패(예: 확인과 생성 사이에 누가 같은 이름을 만들어 AlreadyExists)하면 앞서 만든 Secret은 남고 스크립트는 실패한다. 여러 Secret을 한 번에 만드는 원자적 생성이 아니므로, 다음 실행은 '일부만 있음'으로 멈추고 안내대로 지운 뒤 다시 만든다. chat·ops 묶음은 계정 해시(`db-accounts-chat-ops`)를 서비스 Secret보다 먼저 만든다.

## 4. DB 계정 구조

ERD v1.1의 "서비스별 논리 DB, 계정 공유 없음"을 따른다. 역할은 DB 클러스터 전역이라 이름에 DB를 붙인다(content V12·V14와 같은 규칙).

| 계정/역할 | LOGIN | 속성 | 하는 일 | 누가 만드나 |
|---|---|---|---|---|
| `auth_db_app` | O | 없음 | auth_db 소유자. auth 앱 + Flyway | 관리자(`db-bootstrap.sql`) |
| `content_db_app` | O | **CREATEROLE만** (슈퍼유저 아님) | content_db 소유자. content 앱 + Flyway V1~ | 관리자 |
| `content_db_recommend` | O | 없음, 읽기 전용 기본·`statement_timeout 5s` | recommend 검색 접속 계정 (Secret `ureka-recommend-db`) | 관리자 |
| `content_db_ingest` | O | 없음 | ingest 적재 접속 계정 (Secret `ureka-ingest-db`) | 관리자 |
| `content_db_recommend_search` | X | | 검색 함수 EXECUTE만 (V14가 권한 부여) | 관리자가 먼저 생성, 권한은 Flyway |
| `content_db_ingest_writer` | X | | 적재 권한 (V12가 권한 부여) | 관리자가 먼저 생성, 권한은 Flyway |
| `content_db_rag_search_definer` | X | | 검색 함수 소유자 (SECURITY DEFINER) | Flyway V14 |
| `chat_db_app` | O | 없음 (CREATEROLE 없음) | chat_db 소유자. chat api·worker + 마이그레이션 Job(Alembic, `chat` 스키마) (Secret `ureka-chat-secrets`) | 관리자 |
| `ops_db_app` | O | 없음 | ops_db 소유자. ops 앱 + Flyway(`ops` 스키마, `create-schemas`) (Secret `ureka-ops-secrets`) | 관리자 |

- chat에 CREATEROLE을 주지 않는 근거: chat 마이그레이션 `0001_chat_schema`·`0002_llm_metrics`는 스키마·표·함수·트리거만 만들고 역할·확장을 만들지 않는다. DB 소유자면 `chat` 스키마와 `public.alembic_version`을 만들 수 있다(PostgreSQL 15+의 `public`은 `pg_database_owner` 소유). ops도 Flyway가 `ops` 스키마만 만든다.
- chat·ops도 앱 계정 = 마이그레이션 계정이다(auth와 같다). CREATEROLE이 없어 content의 남은 위험(아래)은 해당하지 않는다. 마이그레이션·앱 계정 분리는 운영 전 과제(7장)에 같이 묶는다.

- 로그인 계정은 역할을 **INHERIT로만** 받는다(`SET FALSE`). `SET ROLE`로 역할을 바꿀 수 없다.
- 호출·적재 역할을 관리자가 먼저 만드는 이유: PostgreSQL 16+는 역할을 만든 CREATEROLE 계정에 그 역할의 ADMIN OPTION을 남긴다. 관리자가 만들면 앱 계정이 이 두 역할을 자기나 다른 계정에 부여하는 경로가 없다. V12·V14는 "이미 있으면 재사용"이라 그대로 동작한다.
- `REVOKE ALL ON DATABASE ... FROM PUBLIC`: 서비스 계정은 자기 DB에만 접속한다. 관리용 `postgres`와 `template1`도 PUBLIC CONNECT를 회수한다(`template0`은 원래 접속 불가).
- vector 확장은 신뢰 확장이 아니라 관리자가 `catalog` 스키마에 미리 설치하고 스키마 소유권을 `content_db_app`에 넘긴다.

### 남은 위험: `content_db_app`의 CREATEROLE (kind 임시 예외)

`content_db_app`은 DB 소유자이면서 CREATEROLE이 있다. 그래서 이 계정은

- 새 LOGIN 역할을 만들 수 있고,
- V14가 만든 함수 소유 역할(`content_db_rag_search_definer`)의 ADMIN OPTION을 가져, **지금 SET·INHERIT가 꺼져 있어도 나중에 그 멤버십을 자기나 새 계정에 다시 부여할 수 있다**(그러면 검색 함수 소유자 권한 = 원본 표 11개 SELECT를 쓸 수 있다).

content 앱이 기동할 때 Flyway를 이 계정으로 돌리기 때문이다(V14가 definer를 만들고 소유권을 넘기려면 CREATEROLE이 필요). P11은 이 상태를 PASS로 숨기지 않고 **M06b EXCEPTION**으로 표시하며, ADMIN OPTION 보유자가 `content_db_app` 말고 더 있으면 FAIL로 본다.

- **개인 kind**: 임시 예외로 둔다(이 PC 사용자만 접근, 테스트 데이터).
- **공유 환경·운영 전**: 마이그레이션 계정(CREATEROLE, 배포 Job에서만 사용)과 앱 계정(DML만, CREATEROLE 없음)을 나눈다. content 앱의 `spring.flyway.enabled` 변경이 필요해 content 담당(AI팀)과 협의한다(6장).

### RDS 이식 (검증 필요)

RDS 마스터 계정은 슈퍼유저가 아니라 `rds_superuser` 멤버다. 다음이 그 권한으로 되는지 RDS에서 따로 시험하기 전에는 "같은 절차"라고 단정하지 않는다: NOLOGIN 역할 선생성과 `GRANT ... WITH INHERIT TRUE, SET FALSE`, `ALTER ROLE ... PASSWORD '<SCRAM 해시>'`, `catalog` 스키마에 vector 설치 후 소유권 이전, CREATEROLE 계정의 V14 소유권 이전, `template1`·`postgres` CONNECT 회수.

## 5. 검증 기록

### chat·ops DB·계정·Secret 추가 (2026-11-12, 공통 차트 확장 브랜치, 기존 kind 클러스터)

Application은 main을 그대로 보게 두고, 브랜치의 data kustomize 결과에서 db-bootstrap Job·ConfigMap만 이름을 바꿔(`db-bootstrap-branch16`, 훅 주석 제거) 한 번 실행했다. 확인 뒤 임시 리소스는 지웠다. Argo CD 동기화로 같은 Job이 도는 것은 병합 뒤 확인한다.

| 항목 | 결과 |
|---|---|
| `create-secrets.sh` (기본 6개 있는 클러스터) | "추가" 경로: 3개 생성. 두 번째 실행 "9개 이미 있음" |
| 복사 값 일치 (SHA-256 비교, 값 미출력) | chat·ops `JWT_PUBLIC_KEY` = auth·content, chat `INTERNAL_SERVICE_TOKEN` = auth. DB 비밀번호는 서비스마다 다름 |
| db-bootstrap (브랜치 SQL, 기존 DB) | "db-bootstrap 완료". 기존 계정은 NOTICE만(변경 없음) |
| `chat_db`·`ops_db` | 소유자 `chat_db_app`·`ops_db_app`, ACL은 소유자만(PUBLIC CONNECT 없음) |
| `chat_db_app`·`ops_db_app` 속성 | LOGIN, 슈퍼유저·CREATEDB·CREATEROLE·REPLICATION·BYPASSRLS 모두 없음, 비밀번호는 SCRAM 해시 |
| Secret 비밀번호로 접속 | chat_db에 스키마·표·함수 생성, `public` 표 생성(롤백) 성공. ops_db 스키마 생성(롤백) 성공 |
| 거부 확인 | chat→auth_db·ops_db·postgres, ops→chat_db·content_db 접속 거부(`permission denied`). chat `CREATE ROLE` 거부. 틀린 비밀번호 거부 |
| 차트 선택 칸 (PSA restricted인 dev) | 시험 values 3개 server dry-run 경고 없음. recommend 이미지로 마이그레이션 Job(uid 10001, /tmp 쓰기) Completed, Service 없는 worker Deployment Running, Job Pod는 `<name>-migrate` 라벨 |
| 기존 Application | auth·content·recommend·data·namespace 모두 Synced/Healthy 유지 |

### auth·content 처음 구성 (2026-11-10, 이 PR 브랜치. 검증 동안 Application이 PR 브랜치를 봄)

kind v1.36.1 노드, Argo CD v3.6.0, PostgreSQL 18.6, pgvector 0.8.7.

### 수정본(`ba33cd9` 이후, 보안 검토 반영) — 처음 설치 순서로 다시 검증

data·auth·content Application, Deployment·StatefulSet·Service·Job·ConfigMap, Secret, PVC를 모두 지우고(recommend·dev 네임스페이스는 유지) 2장 순서대로 다시 올렸다.

| 항목 | 결과 |
|---|---|
| `create-secrets.sh` 첫 실행 / 두 번째 실행 | Secret 6개 생성 / "이미 있음, 아무것도 바꾸지 않음" (당시는 기본 묶음만) |
| data Application 적용 → Synced/Healthy, 동기화 Succeeded, Job 완료 | 21초 |
| auth·content Application 적용 → Synced/Healthy | 46초, 재시작 0 |
| DB 계정 비밀번호 | 4개 계정 모두 `rolpassword`가 스크립트가 계산한 SCRAM 해시. 앱은 원문 비밀번호로 접속 성공 |
| 다시 동기화 시 비밀번호 문장 | `log_statement=all`에서 실행된 `ALTER ROLE ... PASSWORD` 0건, 원문 0건(3장) |
| 클러스터 안 `/readyz` | auth 200, content 200. 게스트 토큰 발급 201 |

### 처음 버전(`86e211b`) 검증 (참고)

data 첫 동기화 약 50초, SQL 변경 push → 자동 동기화·Job 재실행 2분 5초(폴링, 수동 refresh 없음), auth·content Synced/Healthy 51초, Flyway auth V1~V5(`auth_db_app`)·content V1~V13(`content_db_app`) 비슈퍼유저 성공, auth 게스트 토큰 → content 검색 200·위조 토큰 401(JWT 공개키 공유), content replicas 손으로 2 → 1초 안에 1(selfHeal). digest는 ECR 복사 = CI `image-ref.json`.

### V14 비슈퍼유저 적용 (시험 당시 content#30 미병합 → 임시 DB로 미리 확인)

시험 당시(2026-11-10) content main 이미지는 V13까지였다(content#30은 그 뒤 `e58615b`로 병합, 실제 content_db 결과는 gitops#13). content#30 브랜치(`eb6966a`)의 V1~V14 파일을 Flyway CLI 11.7.2(Spring Boot 3.5.16과 같은 계열)로 kind PostgreSQL의 임시 DB `content_v14`에 적용했다. 계정 구조는 4장과 같게 만들었다(`content_v14_app` = CREATEROLE, 슈퍼유저 아님). 두 번(처음 버전·수정본 검증) 모두 **V1~V14 14개 성공**. V6은 `vector already exists, skipping`(관리자가 미리 설치). Flyway·앱 모두 "PostgreSQL 18.6은 이 Flyway 버전에서 시험되지 않음(최신 지원 17)" 경고가 난다. 확인 후 임시 DB·역할은 지웠다.

### P11 부정 시험 — `scripts/kind/p11-check.sh` (예비 결과, G1 근거 아님)

**성공 조건**: 1·2부 SQL의 psql 종료 코드 0, 관리자가 센 검색 가능 작품 수가 숫자, 필수 체크 ID 50개가 빠짐없이 PASS(알고 받아들인 예외는 M06b만 EXCEPTION 허용), FAIL 0. 접속 시험은 자기 DB 접속이 **종료 코드 0이고 출력이 정확히 로그인 계정 이름**일 때만 X00 통과, 다른 DB는 **요청한 바로 그 DB 이름의 `permission denied for database "<DB>"`와 `User does not have CONNECT privilege`가 둘 다** 나올 때만 X01·X02 통과. 하나라도 어긋나면 종료 코드 1.

수정본, 임시 DB `content_v14`(recommend 로그인 계정 `content_v14_recommend`): **PASS 49 / FAIL 0 / EXCEPTION 1(M06b) / 필수 미확인 0, 종료 코드 0.**

| 구분 | 시험 | 결과 |
|---|---|---|
| A 연결 기본값 | 읽기 전용 트랜잭션, statement_timeout 상한 | PASS 2 |
| B 허용 실행 | 계약 형식 최소 입력 → `status=OK`, `items` 배열 / 검색 가능 작품 0개 DB에서 0건 / 잘못된 입력 → 22023 | PASS 3 |
| C 거절(기본) | 원본·기준·이력·적재 표 SELECT 7개, 읽기 전용 INSERT, 다른 DEFINER 함수 2개, SET ROLE 4개 | PASS 14 (42501/25006) |
| D 거절(READ WRITE로 바꿔도) | INSERT·UPDATE·DELETE·TRUNCATE 6개, CREATE TABLE(catalog·rag·public·TEMP)·SCHEMA, 함수 교체·SECURITY INVOKER 변경 | PASS 13 (42501) |
| M 카탈로그 | 소유자 = NOLOGIN definer, SECURITY DEFINER, `search_path=pg_catalog, pg_temp`, PUBLIC EXECUTE 없음, EXECUTE 보유 = 호출 역할+소유자뿐, definer를 SET/INHERIT로 쓰는 계정 없음, definer 쓰기·CREATE 없음, **definer SELECT = 허용 목록 11개와 같음**, 호출 역할·로그인 계정 표 권한 0, 실행 가능한 DEFINER 함수 = 검색 함수 하나, 멤버십·속성, 접속 가능한 다른 DB 없음, 스키마 CREATE 없음·ingest USAGE 없음 | PASS 14 + EXCEPTION 1(M06b: definer ADMIN OPTION = `content_v14_app`, 4장) |
| X 접속 | 같은 자격으로 자기 DB 접속 성공 확인 후 auth_db·postgres 접속이 **CONNECT 권한 거절**(`permission denied for database`) | PASS 3 |

러너 자체의 회귀 확인:

- `scripts/test-p11-check.sh`(CI Helm 워크플로): 가짜 kubectl로 **모두 정상인 경우는 성공(0)**인지 먼저 보고, 거기서 한 가지씩만 바꾼 14가지(exec 실패, 아무것도 실행 안 하고 성공만 반환, 작품 수가 숫자 아님, 1부·2부 SQL 중단, 자기 DB 접속이 이름을 찍고 비정상 종료(표준 오류 있음·없음), 자기 DB 사용자 이름 다름, 다른 DB 접속 허용, 다른 DB 이름으로 거절, 권한 아닌 이유로 실패, CONNECT 설명 없는 거절, 필수 ID 하나 누락, M06b가 아닌 EXCEPTION)와 kind가 아닌 컨텍스트가 모두 실패로 끝나는지 본다. `86e211b` 러너는 exec 실패·접속 실패를, `3058b69` 러너는 작품 수 비숫자·이름 찍고 조용히 비정상 종료·다른 DB 이름 거절·CONNECT 설명 없는 거절을 성공으로 셌다(교차 검토 두 차례의 재현과 같음).
- 실제 kind: 틀린 비밀번호 → 1부·3부 SCRIPT_ERROR로 실패, 없는 Pod → 실패, V13인 content_db → 검색 함수 없음으로 FAIL 4·필수 미확인 19로 실패.
- 수정 중 찾은 것: 처음 버전은 Pod 안에서 `127.0.0.1`로 접속했는데, 이미지 기본 pg_hba가 127.0.0.1을 trust로 둬서 **비밀번호가 틀려도 접속됐다**. 지금은 Pod IP로 접속해 scram-sha-256 인증을 거친다(틀린 비밀번호로 실패 확인).

### 실제 content_db P11 (2026-11-10 06:56 UTC, content main `e58615b` = content#30 병합)

content 이미지를 `sha-e58615b`(digest `sha256:80d5a390…ef2f69` = CI `image-ref.json`)로 올린 values 변경을 Argo CD가 배포했다(52초, 재시작 0). content 앱이 기동하면서 Flyway가 **V13 → V14를 `content_db_app`(CREATEROLE만, 슈퍼유저 아님)으로 적용**했다(실제 업그레이드 경로). `/readyz` 200.

`scripts/kind/p11-check.sh`(content_db, `content_db_recommend`, Secret `ureka-recommend-db`): **PASS 49 / FAIL 0 / EXCEPTION 1(M06b: definer ADMIN OPTION = `content_db_app`) / 필수 미확인 0, 종료 코드 0.** 항목별 결과는 위 임시 DB 표와 같다. 보안 재검토 반영 러너(#12 `8d1a196`, 접속 판정 강화)로 다시 실행해도 같은 결과(종료 코드 0, X01·X02는 요청한 DB 이름과 CONNECT 설명까지 일치)였다. 틀린 비밀번호로는 실패(종료 코드 1). 호출·적재 역할(`content_db_recommend_search`, `content_db_ingest_writer`)은 관리자가 먼저 만들어 `content_db_app`에 ADMIN OPTION이 없다(M06b 대상은 definer 하나).

**G1(S7) 근거로 쓰려면 남은 것**: ~~실제 `content_db`에서 P11 실행·기록~~(위, 완료). recommend 배포에 전용 자격(`ureka-recommend-db`)이 주입되는 경로 확인. M06b 예외는 G1 판정 때 그대로 밝힌다(공유·운영 전 계정 분리). 실제 recommend 연결과 결과 검증은 그 뒤 통합 시험으로 따로 본다.

## 6. 데이터 보존과 Argo CD

- `prune: true`는 **Git에서 지운 관리 리소스**를 클러스터에서 지운다. StatefulSet의 `volumeClaimTemplates`로 생긴 PVC(`data-postgres-0`)는 Argo CD 관리 리소스가 아니고, StatefulSet의 기본 PVC 보존 정책(Retain)이라 StatefulSet이 prune·삭제돼도 남는다.
- 데이터가 사라지는 경우: PVC를 직접 지울 때, dev 네임스페이스를 지울 때(네임스페이스 Application에 `Prune=false`가 있어 Git에서 빠져도 지우지 않음), kind 클러스터를 지울 때. kind dev는 테스트 데이터만 둔다.
- 병합 뒤 main으로 되돌리는 절차: 병합 커밋이 main에 올라간 것을 확인 → `kubectl apply -f argocd/kind/`(targetRevision main) → 세 Application의 `status.sync.revision`이 병합 커밋인지, Synced/Healthy인지, Job 로그가 "db-bootstrap 완료"인지 확인. 병합 전에 main으로 돌리면 옛 auth values로 배포돼 기동에 실패한다.

## 7. 후속 (이 PR 범위 밖)

- **마이그레이션 계정과 앱 계정 분리**(공유 환경·운영 전 필수, 4장): content 앱 코드 변경이 필요해 content 담당(AI팀)과 협의. chat은 마이그레이션이 이미 별도 Job이라 계정만 나누면 된다(auth·ops는 앱 기동 Flyway).
- **RDS 이식 검증**(4장 끝).
- recommend 실제 모드로 kind에 붙일 때 values에서 `ureka-recommend-db` Secret 사용(G1 전에 주입 경로 확인).
- ingest Job/CronJob이 `ureka-ingest-db`를 쓰도록 연결.
- **Redis 접근 제한**: 앱 설정에 Redis 비밀번호 항목이 없고, ClusterIP는 Pod 간 접근을 막지 않는다. 개인 kind는 후속으로 두지만, **공유 데모 환경에서는 auth 상태가 담긴 Redis에 허가된 워크로드만 닿게** NetworkPolicy·인증을 먼저 둔다.
- **auth 메모리**: 2026-11-10 kind에서 auth Pod가 한 번 OOMKilled(종료 코드 137, chart 기본 limit 512Mi)로 재시작했다. 다시 뜬 뒤 Ready. JVM 힙·비힙 사용량을 재고 auth values의 `resources`(또는 `JAVA_TOOL_OPTIONS`)를 정한다. 근거 없이 limit만 올리지 않는다.
- auth 메일: kind에 메일 서버가 없다(Mailpit 추가 여부). 가입 인증 메일만 실패하고 기동·`/readyz`와는 무관.
- Flyway가 PostgreSQL 18을 정식 지원하는 버전으로 올리기(앱 의존성).
