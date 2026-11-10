# kind dev DB·비밀값과 DB 계정 구조

kind dev에 PostgreSQL 18 + pgvector, Redis, 비밀값 Secret을 붙이고 auth·content를 Argo CD로 배포한다. 운영(RDS·EKS)에 그대로 옮기는 것은 **DB 계정·권한 절차**뿐이고, 매니페스트와 비밀값 방식은 kind 전용이다.

## 1. 구성

| 무엇 | 어디 | Argo CD Application |
|---|---|---|
| PostgreSQL 18 + pgvector 0.8.7 (StatefulSet, PVC 2Gi) | `environments/kind/data/postgres.yaml` | `ureka-dev-data-kind` |
| Redis 8.8 (저장 안 함) | `environments/kind/data/redis.yaml` | 〃 |
| DB·계정 생성 Job (PostSync, 멱등) | `environments/kind/data/db-bootstrap-job.yaml` + `db-bootstrap.sql` | 〃 |
| auth (auth_db) | `environments/kind/ureka-auth.yaml` | `ureka-auth-kind` |
| content (content_db) | `environments/kind/ureka-content.yaml` | `ureka-content-kind` |
| 비밀값 Secret | Git에 없음. `scripts/kind/create-secrets.sh` | (Argo CD가 관리하지 않음) |

이미지는 모두 digest로 고정한다(`scripts/check-charts.sh`가 chart와 kustomize 양쪽을 검사). PSA restricted 그대로(비root uid 999, 읽기 전용 루트 FS, capability 제거, seccomp).

## 2. 처음 띄우는 순서

```bash
scripts/kind/up.sh
kubectl apply -f argocd/kind/ureka-dev-namespace.yaml   # dev 네임스페이스
scripts/kind/create-secrets.sh                           # Secret 4개(값은 이 PC에서 생성, 출력 안 함)
scripts/kind/sync-ecr-image.sh auth <커밋 SHA>
scripts/kind/sync-ecr-image.sh content <커밋 SHA>
kubectl apply -f argocd/kind/                            # data → (Job이 계정 생성) → auth·content
scripts/kind/p11-check.sh                                # V14가 content main에 들어간 뒤
```

Secret보다 Application을 먼저 적용해도 망가지지 않는다. Pod가 Secret을 찾을 때까지 기다리고, Job은 재시도한다.

## 3. 비밀값 방식 (결정 필요: 송준혁)

| 안 | 내용 | 장점 | 단점 |
|---|---|---|---|
| **A. 생성 스크립트 (이 PR)** | `create-secrets.sh`가 kind 안에서 Secret을 만든다. 값은 Git·파일에 없다 | 추가 컨트롤러 없음. 클러스터마다 값이 달라 유출 범위가 그 PC로 한정. 팀원이 각자 kind를 띄워도 그대로 동작 | Secret이 Git 밖이라 Argo CD가 상태를 모른다. 클러스터를 지우면 값도 사라진다(로컬 dev라 문제없음) |
| B. Sealed Secrets | 암호화한 Secret을 Git에 커밋 | Git으로 전부 관리 | 컨트롤러 키가 클러스터마다 달라 **팀원 kind마다 다시 봉인**해야 한다. PUBLIC 저장소에 암호문이 쌓인다 |
| C. ESO + 로컬 백엔드 | 운영과 같은 ESO, 저장소만 로컬(예: Kubernetes provider) | 운영(EKS: Secrets Manager → ESO)과 같은 모양 | kind에 컨트롤러·CRD 추가, 결국 원본 Secret은 A처럼 만들어야 한다 |

추천은 **A**. kind는 S6~S7 임시 환경이고, 운영은 이미 Secrets Manager → ESO로 정해져 있다. ESO 경로 검증은 EKS(S8)에서 한다. 바꾸게 되면 앱 values의 `secretKeyRef` 이름만 맞추면 된다.

`create-secrets.sh --rotate`: 모든 값을 새로 만들고 postgres 슈퍼유저 비밀번호를 바꾼 뒤, data Application을 다시 동기화해 Job이 계정 비밀번호를 맞추게 하고 auth·content를 재시작한다.

## 4. DB 계정 구조 (운영 RDS에도 같은 절차)

ERD v1.1의 "서비스별 논리 DB, 계정 공유 없음"을 따른다. 역할은 DB 클러스터 전역이라 이름에 DB를 붙인다(content V12·V14와 같은 규칙).

| 계정/역할 | LOGIN | 속성 | 하는 일 | 누가 만드나 |
|---|---|---|---|---|
| `auth_db_app` | O | 없음 | auth_db 소유자. auth 앱 + Flyway | 관리자(`db-bootstrap.sql`) |
| `content_db_app` | O | **CREATEROLE만** (슈퍼유저 아님) | content_db 소유자. content 앱 + Flyway V1~ | 관리자 |
| `content_db_recommend` | O | 없음, 읽기 전용 기본·`statement_timeout 5s` | recommend 검색 접속 계정 | 관리자 |
| `content_db_ingest` | O | 없음 | ingest 적재 접속 계정 | 관리자 |
| `content_db_recommend_search` | X | | 검색 함수 EXECUTE만 (V14가 권한 부여) | 관리자가 먼저 생성, 권한은 Flyway |
| `content_db_ingest_writer` | X | | 적재 권한 (V12가 권한 부여) | 관리자가 먼저 생성, 권한은 Flyway |
| `content_db_rag_search_definer` | X | | 검색 함수 소유자 (SECURITY DEFINER) | Flyway V14 |

- 로그인 계정은 역할을 **INHERIT로만** 받는다(`SET FALSE`). `SET ROLE`로 역할을 바꿀 수 없다.
- 호출·적재 역할을 관리자가 먼저 만드는 이유: PostgreSQL 16+는 역할을 만든 CREATEROLE 계정에 그 역할의 ADMIN OPTION을 남긴다. Flyway(앱 계정)가 만들면 앱 계정이 검색·적재 권한을 스스로 자기나 다른 계정에 부여할 수 있다. 관리자가 만들면 그 경로가 없다. V12·V14는 "이미 있으면 재사용"이라 그대로 동작한다.
- 함수 소유 역할(definer)은 V14가 만들어야 한다(소유권 이전에 ADMIN OPTION이 필요). 그래서 `content_db_app`에 definer의 ADMIN OPTION 한 행이 남는다(SET·INHERIT 없음, P11 M06에 표시). 앱 계정과 마이그레이션 계정을 나누면 없앨 수 있다(후속 5장).
- `REVOKE ALL ON DATABASE ... FROM PUBLIC`: 서비스 계정은 자기 DB에만 접속한다(관리용 `postgres` DB도 회수).
- vector 확장은 신뢰 확장이 아니라 관리자가 `catalog` 스키마에 미리 설치하고 스키마 소유권을 `content_db_app`에 넘긴다. RDS는 `rds_superuser`(마스터 계정)가 설치한다.

## 5. 검증 기록 (2026-11-10, 이 PR 브랜치, 검증 동안 Application이 PR 브랜치를 봄)

kind v1.36.1 노드, Argo CD v3.6.0, PostgreSQL 18.6, pgvector 0.8.7.

| 항목 | 결과 |
|---|---|
| data Application 첫 동기화 → postgres·redis Ready, Job 완료 | 약 50초 |
| 부트스트랩 SQL 변경 push → Argo CD 자동 동기화 → Job 재실행(멱등) | 2분 5초(폴링, 수동 refresh 없음) |
| auth `sha-29ddad5` / content `sha-9b4b54d` Application 적용 → Synced/Healthy | 51초, 재시작 0 |
| digest | ECR 복사 digest = 각 CI artifact `image-ref.json` digest |
| `/readyz`·`/healthz` (클러스터 안에서) | auth 200/200, content 200/200 |
| Flyway | auth V1~V5 `auth_db_app`, content V1~V13 `content_db_app`(슈퍼유저 아님) 성공 |
| 서비스 간 | auth 게스트 토큰 발급 201 → content 검색 200, 위조 토큰 401(JWT 공개키 공유 확인) |
| selfHeal | content `replicas 2`로 손으로 변경 → 1초 안에 1로 복귀 |

### V14 비슈퍼유저 적용 (content#30 미병합 → 별도 DB로 미리 확인)

content main 이미지는 아직 V13까지다. content#30 브랜치(`eb6966a`)의 V1~V14 파일을 Flyway CLI 11.7.2(Spring Boot 3.5.16과 같은 계열)로 kind PostgreSQL의 임시 DB `content_v14`에 적용했다. 계정 구조는 4장과 같게 만들었다(`content_v14_app` = CREATEROLE, 슈퍼유저 아님).

- 결과: **V1~V14 14개 성공**, 0.44초. V6은 `vector already exists, skipping`(관리자가 미리 설치).
- Flyway 경고: "PostgreSQL 18.6은 이 Flyway 버전에서 시험되지 않음(최신 지원 17)". 앱(Spring Boot)도 같은 경고가 난다. 동작에는 문제없었고, Flyway 업그레이드 때 다시 본다.
- 확인 후 임시 DB·역할은 지웠다.

### P11 부정 시험 (초안) — `scripts/kind/p11-check.sh`

위 `content_v14`에서 recommend 로그인 계정(`content_v14_recommend`)으로 실행: **PASS 44 / FAIL 0**.

| 구분 | 시험 | 결과 |
|---|---|---|
| A 연결 기본값 | 읽기 전용 트랜잭션, statement_timeout 상한 | PASS 2 |
| B 허용 실행 | 계약 형식 최소 입력 → 정상 응답(`status`·`items`…), 잘못된 입력 → 22023 | PASS 2 |
| C 거절(기본) | 원본·기준·이력·적재 표 SELECT 7개, 읽기 전용 INSERT, 다른 DEFINER 함수 2개, SET ROLE 4개 | PASS 14 (42501/25006) |
| D 거절(READ WRITE로 바꿔도) | INSERT·UPDATE·DELETE·TRUNCATE 6개, CREATE TABLE(catalog·rag·public·TEMP)·SCHEMA, 함수 교체·SECURITY INVOKER 변경 | PASS 13 (42501) |
| M 카탈로그 | 함수 소유자 = definer(NOLOGIN·특수 속성 없음), SECURITY DEFINER, `search_path=pg_catalog, pg_temp`, **PUBLIC EXECUTE 없음**, EXECUTE 보유 = 호출 역할+소유자뿐, definer를 SET/INHERIT로 쓰는 계정 없음, definer 쓰기·CREATE 없음, 호출 역할·로그인 계정 표 권한 0, 로그인 계정이 실행 가능한 DEFINER 함수 = 검색 함수 하나, 멤버십·속성, 다른 DB CONNECT 없음 | PASS 12 (+INFO: definer SELECT 가능 표 11개) |
| X 다른 DB | auth_db 접속 거절 | PASS 1 |

시험이 찾은 것: 처음 실행에서 M12 FAIL(관리용 `postgres` DB에 PUBLIC CONNECT가 기본으로 열려 있음) → `db-bootstrap.sql`에 회수 추가 → 재실행 통과.

**남은 것**: content#30 병합 → 새 content 이미지 values PR → `scripts/kind/p11-check.sh`(content_db)로 같은 시험을 실제 배포 DB에서 다시 기록한다. G1(S7) 근거로 쓸 결과는 그 실행이다.

## 6. 후속 (이 PR 범위 밖)

- **마이그레이션 계정과 앱 계정 분리**: 지금 content 앱은 기동 때 Flyway를 CREATEROLE 계정으로 돌린다. 운영에서는 Flyway를 배포 Job(마이그레이션 계정)으로 빼고 앱은 DML만 있는 계정으로 접속하는 것이 맞다. 앱 코드(`spring.flyway.enabled`) 변경이 필요해 content 담당(AI팀)과 협의.
- recommend를 실제 모드로 kind에 붙일 때 `content_db_recommend` 자격을 쓰는 Secret 추가(`ureka-recommend-secrets`).
- ingest Job/CronJob이 `content_db_ingest`를 쓰도록 연결.
- auth 메일: kind에 메일 서버가 없다(Mailpit 추가 여부). 가입 인증 메일만 실패하고 기동·`/readyz`와는 무관.
- Redis 인증·네트워크 제한: 앱 설정에 Redis 비밀번호 항목이 없다. NetworkPolicy(DB·Redis는 해당 서비스 Pod만)는 EKS에서.
- Flyway가 PostgreSQL 18을 정식 지원하는 버전으로 올리기(앱 의존성).
