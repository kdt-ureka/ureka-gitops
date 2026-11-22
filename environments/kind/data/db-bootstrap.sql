-- 서비스 DB·로그인 계정 생성 절차 (kind dev). 여러 번 실행해도 같은 상태가 된다.
--
-- 누가 실행하나: DB 관리자 계정.
--   kind: postgres 슈퍼유저. db-bootstrap Job이 Argo CD 동기화 뒤(PostSync)에 자동으로 돌린다.
--   EC2 dev(RDS): RDS 마스터(rds_superuser, 슈퍼유저 아님). scripts/ec2/rds-bootstrap.sh가 필요할 때만 Job으로 돌린다.
--   슈퍼유저가 아니면(PostgreSQL 16+ 규칙) 세 곳이 다르게 돈다(아래 is_superuser 분기):
--     - REPLICATION·BYPASSRLS는 바꿀 수 없어 ALTER ROLE에서 빼고, 꺼져 있는지 검사로 대신한다.
--     - pg_authid를 읽을 수 없어 저장된 해시와 비교하지 않고 매번 넣는다(같은 해시라 결과는 같다).
--     - CREATE DATABASE ... OWNER, \connect를 하려면 관리자가 앱 소유 역할의 멤버여야 해서 멤버십을 준다.
-- 비밀번호: 원문은 이 SQL에도 DB 서버에도 가지 않는다. Secret db-accounts의 SCRAM-SHA-256 해시를 \getenv로 읽어
--   저장된 값과 다를 때만 ALTER ROLE ... PASSWORD '<해시>'로 넣는다(PostgreSQL은 해시 형식을 그대로 저장한다).
--   해시는 scripts/kind/create-secrets.sh가 이 PC에서 계산한다. 다시 동기화될 때 ALTER ROLE PASSWORD는 나가지 않는다.
--   (비교 SELECT에는 해시가 실린다. 해시는 원문이 아니고 원문은 무작위 256비트라 해시로 되돌릴 수 없다.)
--
-- 계정 구조 (ERD v1.1: 서비스별 논리 DB, 서비스 간 계정 공유 없음, 역할은 클러스터 전역이라 DB 이름을 붙인다)
--
--   auth_db
--     auth_db_app              LOGIN. auth_db 소유자. auth 앱이 접속하고 Flyway(auth 스키마)를 돌린다.
--   content_db
--     content_db_app           LOGIN + CREATEROLE, 슈퍼유저 아님. content_db 소유자. content 앱이 접속하고 Flyway V1~를 돌린다.
--                              CREATEROLE은 V14가 함수 소유 전용 역할(<db>_rag_search_definer)을 만들고 소유권을 넘길 때 필요하다.
--     content_db_recommend     LOGIN. 권한은 content_db_recommend_search 역할로만 받는다(검색 함수 EXECUTE뿐).
--     content_db_ingest        LOGIN. 권한은 content_db_ingest_writer 역할로만 받는다(V12 적재 권한).
--   chat_db
--     chat_db_app              LOGIN. chat_db 소유자. chat api·worker가 접속하고 마이그레이션 Job이 Alembic(chat 스키마)을 돌린다.
--                              CREATEROLE 없음: chat 마이그레이션(0001·0002)은 스키마·테이블·함수·트리거만 만들고 역할을 만들지 않는다.
--   ops_db
--     ops_db_app               LOGIN. ops_db 소유자. ops 앱이 접속하고 Flyway(ops 스키마, create-schemas)를 돌린다.
--   (Flyway가 만드는 NOLOGIN 역할)
--     content_db_rag_search_definer  검색 함수 소유자. 어떤 LOGIN 계정에도 주지 않는다(V14).
--
-- 호출·적재 역할(content_db_recommend_search, content_db_ingest_writer)은 여기서 관리자 계정이 먼저 NOLOGIN으로 만든다.
-- V12·V14는 "이미 있으면 재사용"하므로 그대로 동작하고, 객체 권한(GRANT EXECUTE 등)은 Flyway가 준다.
-- 이렇게 하면 content_db_app(마이그레이션 계정)이 이 두 역할의 ADMIN OPTION을 갖지 않아,
-- 앱 계정이 스스로 검색·적재 역할을 자기나 다른 계정에 부여할 수 없다. 멤버십 부여는 관리자만 한다.
--
-- 운영(RDS) 차이: vector 확장은 rds_superuser가 설치할 수 있다(kind는 슈퍼유저가 미리 설치하는 것으로 흉내 낸다).
--
-- 환경 접미사(db_suffix, #63 후속): EKS prod는 같은 RDS에 별도 논리 DB·계정을 만든다. psql 변수 db_suffix로 고른다.
--   ''(기본, 없을 때도) → auth_db, auth_db_app, content_db_recommend ... (kind·EC2 dev·EKS dev, 지금과 같다)
--   '_prod'            → auth_db_prod, auth_db_prod_app, content_db_prod_recommend ... (EKS prod, scripts/eks/bootstrap_prod_db.py)
--   이름 규칙은 <DB 이름>_<용도>다. content 마이그레이션(V12·V14)도 current_database()로 같은 규칙을 쓴다.
--   다른 값은 아무것도 만들지 않고 멈춘다. 위 주석의 이름은 접미사가 빈 경우다.
--   한 번 실행은 한 환경의 DB·계정만 만들고 바꾼다(다른 환경 계정·DB는 건드리지 않는다. postgres·template1 CONNECT 회수는 공통).
\set ON_ERROR_STOP on
\if :{?db_suffix}
\else
\set db_suffix ''
\endif
SELECT format('DO $stop$ BEGIN RAISE EXCEPTION %L; END $stop$', 'db_suffix must be empty or _prod')
WHERE :'db_suffix' NOT IN ('', '_prod') \gexec

-- 이름(psql 변수). 식별자는 :"이름", 문자열은 :'이름'으로 쓴다(psql이 따옴표 처리).
\set auth_db auth_db :db_suffix
\set content_db content_db :db_suffix
\set chat_db chat_db :db_suffix
\set ops_db ops_db :db_suffix
\set auth_app :auth_db _app
\set content_app :content_db _app
\set content_recommend :content_db _recommend
\set content_ingest :content_db _ingest
\set content_recommend_search :content_db _recommend_search
\set content_ingest_writer :content_db _ingest_writer
\set chat_app :chat_db _app
\set ops_app :ops_db _app

\getenv auth_app_scram AUTH_DB_APP_SCRAM
\getenv content_app_scram CONTENT_DB_APP_SCRAM
\getenv content_recommend_scram CONTENT_DB_RECOMMEND_SCRAM
\getenv content_ingest_scram CONTENT_DB_INGEST_SCRAM
-- chat·ops는 Secret db-accounts-chat-ops에서 온다(나중에 추가된 계정이라 db-accounts와 따로 만든다, docs/kind-db-secrets.md).
\getenv chat_app_scram CHAT_DB_APP_SCRAM
\getenv ops_app_scram OPS_DB_APP_SCRAM

-- 형식 확인은 SQL을 보내기 전에 한다(run-bootstrap.sh가 verifier 전체를 검사하고, 아니면 DB에 접속하지 않고 멈춘다).
-- 이 파일을 직접 실행할 때도 run-bootstrap.sh로 실행하거나 먼저 같은 검사를 해야 한다. 여기서 검사하면 잘못 들어간 원문이 검사 쿼리에 실려 서버로 간다.

-- 실행 계정이 슈퍼유저인지(kind: t, RDS 마스터: f)
SELECT rolsuper AS is_superuser FROM pg_roles WHERE rolname = current_user \gset

-- 1) 로그인 계정 ---------------------------------------------------------------
SELECT format('CREATE ROLE %I LOGIN', r)
FROM unnest(ARRAY[:'auth_app', :'content_app', :'content_recommend', :'content_ingest', :'chat_app', :'ops_app']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec

-- 속성을 매번 다시 맞춘다(손으로 바꾼 권한이 남지 않게). 비밀번호는 아래에서 따로.
\if :is_superuser
ALTER ROLE :"auth_app"          LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE :"content_app"       LOGIN NOSUPERUSER NOCREATEDB CREATEROLE   NOREPLICATION NOBYPASSRLS;
ALTER ROLE :"content_recommend" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE :"content_ingest"    LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE :"chat_app"          LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE :"ops_app"           LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
\else
ALTER ROLE :"auth_app"          LOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE :"content_app"       LOGIN NOCREATEDB CREATEROLE;
ALTER ROLE :"content_recommend" LOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE :"content_ingest"    LOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE :"chat_app"          LOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE :"ops_app"           LOGIN NOCREATEDB NOCREATEROLE;
\endif

-- 저장된 해시와 다를 때만(처음 만들 때, Secret을 새로 만든 뒤) 바꾼다. 슈퍼유저가 아니면 비교할 수 없어 매번 넣는다.
\if :is_superuser
SELECT format('ALTER ROLE %I PASSWORD %L', v.r, v.h)
FROM (VALUES (:'auth_app', :'auth_app_scram'), (:'content_app', :'content_app_scram'),
             (:'content_recommend', :'content_recommend_scram'), (:'content_ingest', :'content_ingest_scram'),
             (:'chat_app', :'chat_app_scram'), (:'ops_app', :'ops_app_scram')) AS v(r, h)
JOIN pg_authid a ON a.rolname = v.r
WHERE a.rolpassword IS DISTINCT FROM v.h \gexec
\else
SELECT format('ALTER ROLE %I PASSWORD %L', v.r, v.h)
FROM (VALUES (:'auth_app', :'auth_app_scram'), (:'content_app', :'content_app_scram'),
             (:'content_recommend', :'content_recommend_scram'), (:'content_ingest', :'content_ingest_scram'),
             (:'chat_app', :'chat_app_scram'), (:'ops_app', :'ops_app_scram')) AS v(r, h) \gexec
\endif

-- 2) 호출·적재 역할(NOLOGIN)과 멤버십 ------------------------------------------
SELECT format('CREATE ROLE %I NOLOGIN', r) FROM unnest(ARRAY[:'content_recommend_search', :'content_ingest_writer']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
\if :is_superuser
ALTER ROLE :"content_recommend_search" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE :"content_ingest_writer"    NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
\else
ALTER ROLE :"content_recommend_search" NOLOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE :"content_ingest_writer"    NOLOGIN NOCREATEDB NOCREATEROLE;
\endif

-- 어느 경로든: 서비스 계정·역할에 SUPERUSER·REPLICATION·BYPASSRLS가 있으면 멈춘다.
-- (psql 변수는 DO 본문 안에서 치환되지 않아, 조건이 맞을 때만 오류 DO 문을 만들어 실행한다.)
SELECT format('DO $check$ BEGIN RAISE EXCEPTION %L; END $check$', 'service role has SUPERUSER, REPLICATION or BYPASSRLS')
WHERE EXISTS (SELECT 1 FROM pg_roles
              WHERE rolname IN (:'auth_app', :'content_app', :'content_recommend', :'content_ingest', :'chat_app',
                                :'ops_app', :'content_recommend_search', :'content_ingest_writer')
                AND (rolsuper OR rolreplication OR rolbypassrls)) \gexec

-- SET은 끈다: 로그인 계정이 SET ROLE로 역할을 바꿀 필요가 없다(권한은 INHERIT로만 쓴다).
GRANT :"content_recommend_search" TO :"content_recommend" WITH INHERIT TRUE, SET FALSE;
GRANT :"content_ingest_writer"    TO :"content_ingest"    WITH INHERIT TRUE, SET FALSE;

-- 검색 계정 연결 기본값: 읽기 전용 트랜잭션, 실행 시간 상한.
-- recommend는 연결마다 남은 예산으로 더 짧은 statement_timeout을 건다. 이 값은 그 설정이 없는 경로의 상한이다.
ALTER ROLE :"content_recommend" SET default_transaction_read_only = on;
ALTER ROLE :"content_recommend" SET statement_timeout = '5s';
ALTER ROLE :"content_recommend" SET idle_in_transaction_session_timeout = '10s';

-- 3) 데이터베이스 ----------------------------------------------------------------
-- 슈퍼유저가 아니면 소유자로 지정할 역할의 멤버여야 한다(CREATE DATABASE ... OWNER, ALTER DATABASE OWNER, 소유 DB 접속).
-- 관리자는 이 역할들을 만들 때 이미 ADMIN OPTION을 가지므로 새 권한이 생기는 것은 아니다.
\if :is_superuser
\else
GRANT :"auth_app", :"content_app", :"chat_app", :"ops_app" TO CURRENT_USER WITH INHERIT TRUE, SET TRUE;
\endif
SELECT format('CREATE DATABASE %I OWNER %I', v.d, v.o)
FROM (VALUES (:'auth_db', :'auth_app'), (:'content_db', :'content_app'), (:'chat_db', :'chat_app'), (:'ops_db', :'ops_app')) AS v(d, o)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = v.d) \gexec
ALTER DATABASE :"auth_db" OWNER TO :"auth_app";
ALTER DATABASE :"content_db" OWNER TO :"content_app";
ALTER DATABASE :"chat_db" OWNER TO :"chat_app";
ALTER DATABASE :"ops_db" OWNER TO :"ops_app";

-- 새 DB는 PUBLIC에 CONNECT가 열려 있다. 서비스 DB끼리(그리고 dev·prod끼리) 접속하지 못하게 닫고 필요한 역할에만 준다.
REVOKE ALL ON DATABASE :"auth_db", :"content_db", :"chat_db", :"ops_db" FROM PUBLIC;
-- 관리용 postgres DB와 template1도 서비스 계정이 접속할 이유가 없다(template0은 원래 접속 불가).
REVOKE CONNECT, TEMPORARY ON DATABASE postgres, template1 FROM PUBLIC;
GRANT CONNECT ON DATABASE :"content_db" TO :"content_recommend_search", :"content_ingest_writer";

-- 4) content_db: vector 확장 미리 설치 ------------------------------------------
-- pgvector는 신뢰(trusted) 확장이 아니라 슈퍼유저만 설치할 수 있다. Flyway V6의 CREATE EXTENSION IF NOT EXISTS는
-- 이미 설치돼 있으면 권한 검사 없이 넘어간다. 설치 스키마는 Flyway 기본 스키마와 같은 catalog
-- (ureka-content V6·V14 주석, NonSuperuserMigrationTest와 같은 순서).
\connect :content_db
CREATE SCHEMA IF NOT EXISTS catalog;
CREATE EXTENSION IF NOT EXISTS vector SCHEMA catalog;
ALTER SCHEMA catalog OWNER TO :"content_app";

-- 5) 확인 출력(비밀값 없음). Job 로그에 남는다. RDS에서는 vector 버전이 엔진 마이너에 따라 다르다.
SELECT 'check environment suffix ' || CASE WHEN :'db_suffix' = '' THEN '(none)' ELSE :'db_suffix' END
       || ', content db ' || current_database();
SELECT 'check vector ' || extversion || ' in ' || n.nspname
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector';
SELECT 'check server ' || current_setting('server_version') || ', postgres db owner ' || pg_get_userbyid(datdba)
       || ', public connect ' || has_database_privilege('public', 'postgres', 'CONNECT')
  FROM pg_database WHERE datname = 'postgres';
