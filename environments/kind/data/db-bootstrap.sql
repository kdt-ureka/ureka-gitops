-- 서비스 DB·로그인 계정 생성 절차 (kind dev). 여러 번 실행해도 같은 상태가 된다.
--
-- 누가 실행하나: DB 관리자 계정(kind는 postgres 슈퍼유저, RDS는 마스터 계정=rds_superuser).
--   kind에서는 db-bootstrap Job이 Argo CD 동기화 뒤(PostSync)에 자동으로 돌린다.
-- 비밀번호: 이 파일에 없다. psql \getenv로 환경 변수에서 읽는다(Secret db-accounts, scripts/kind/create-secrets.sh).
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
--   (Flyway가 만드는 NOLOGIN 역할)
--     content_db_rag_search_definer  검색 함수 소유자. 어떤 LOGIN 계정에도 주지 않는다(V14).
--
-- 호출·적재 역할(content_db_recommend_search, content_db_ingest_writer)은 여기서 관리자 계정이 먼저 NOLOGIN으로 만든다.
-- V12·V14는 "이미 있으면 재사용"하므로 그대로 동작하고, 객체 권한(GRANT EXECUTE 등)은 Flyway가 준다.
-- 이렇게 하면 content_db_app(마이그레이션 계정)이 이 두 역할의 ADMIN OPTION을 갖지 않아,
-- 앱 계정이 스스로 검색·적재 역할을 자기나 다른 계정에 부여할 수 없다. 멤버십 부여는 관리자만 한다.
--
-- 운영(RDS) 차이: vector 확장은 rds_superuser가 설치할 수 있다(kind는 슈퍼유저가 미리 설치하는 것으로 흉내 낸다).
\set ON_ERROR_STOP on

\getenv auth_app_pw AUTH_DB_APP_PASSWORD
\getenv content_app_pw CONTENT_DB_APP_PASSWORD
\getenv content_recommend_pw CONTENT_DB_RECOMMEND_PASSWORD
\getenv content_ingest_pw CONTENT_DB_INGEST_PASSWORD

SELECT CASE WHEN :'auth_app_pw' = '' OR :'content_app_pw' = '' OR :'content_recommend_pw' = '' OR :'content_ingest_pw' = ''
            THEN 1/0 END AS "비밀번호 환경 변수가 비어 있으면 0으로 나누기 오류로 멈춘다";

-- 1) 로그인 계정 ---------------------------------------------------------------
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['auth_db_app', 'content_db_app', 'content_db_recommend', 'content_db_ingest']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec

-- 속성을 매번 다시 맞춘다(손으로 바꾼 권한이 남지 않게).
ALTER ROLE auth_db_app          LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'auth_app_pw';
ALTER ROLE content_db_app       LOGIN NOSUPERUSER NOCREATEDB CREATEROLE   NOREPLICATION NOBYPASSRLS PASSWORD :'content_app_pw';
ALTER ROLE content_db_recommend LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'content_recommend_pw';
ALTER ROLE content_db_ingest    LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'content_ingest_pw';

-- 2) 호출·적재 역할(NOLOGIN)과 멤버십 ------------------------------------------
SELECT format('CREATE ROLE %I NOLOGIN', r) FROM unnest(ARRAY['content_db_recommend_search', 'content_db_ingest_writer']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
ALTER ROLE content_db_recommend_search NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE content_db_ingest_writer    NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

-- SET은 끈다: 로그인 계정이 SET ROLE로 역할을 바꿀 필요가 없다(권한은 INHERIT로만 쓴다).
GRANT content_db_recommend_search TO content_db_recommend WITH INHERIT TRUE, SET FALSE;
GRANT content_db_ingest_writer    TO content_db_ingest    WITH INHERIT TRUE, SET FALSE;

-- 검색 계정 연결 기본값: 읽기 전용 트랜잭션, 실행 시간 상한.
-- recommend는 연결마다 남은 예산으로 더 짧은 statement_timeout을 건다. 이 값은 그 설정이 없는 경로의 상한이다.
ALTER ROLE content_db_recommend SET default_transaction_read_only = on;
ALTER ROLE content_db_recommend SET statement_timeout = '5s';
ALTER ROLE content_db_recommend SET idle_in_transaction_session_timeout = '10s';

-- 3) 데이터베이스 ----------------------------------------------------------------
SELECT 'CREATE DATABASE auth_db OWNER auth_db_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'auth_db') \gexec
SELECT 'CREATE DATABASE content_db OWNER content_db_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'content_db') \gexec
ALTER DATABASE auth_db OWNER TO auth_db_app;
ALTER DATABASE content_db OWNER TO content_db_app;

-- 새 DB는 PUBLIC에 CONNECT가 열려 있다. 서비스 DB끼리 접속하지 못하게 닫고 필요한 역할에만 준다.
REVOKE ALL ON DATABASE auth_db, content_db FROM PUBLIC;
GRANT CONNECT ON DATABASE content_db TO content_db_recommend_search, content_db_ingest_writer;

-- 4) content_db: vector 확장 미리 설치 ------------------------------------------
-- pgvector는 신뢰(trusted) 확장이 아니라 슈퍼유저만 설치할 수 있다. Flyway V6의 CREATE EXTENSION IF NOT EXISTS는
-- 이미 설치돼 있으면 권한 검사 없이 넘어간다. 설치 스키마는 Flyway 기본 스키마와 같은 catalog
-- (ureka-content V6·V14 주석, NonSuperuserMigrationTest와 같은 순서).
\connect content_db
CREATE SCHEMA IF NOT EXISTS catalog;
CREATE EXTENSION IF NOT EXISTS vector SCHEMA catalog;
ALTER SCHEMA catalog OWNER TO content_db_app;
