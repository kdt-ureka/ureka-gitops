-- P11(함수 역할/배포) 1부: recommend 검색 로그인 계정으로 접속해서 실행한다.
-- 기준: ureka-docs db/erd-v1.1/03_Phase3_구현및검증_인계.md P11
--   "임의 표/스키마/쓰기 거절, 허용 실행 정상, PUBLIC/소유자/search_path 검증"
-- 접속 계정: <DB>_recommend (LOGIN, 권한은 <DB>_recommend_search 역할로만 받는다. db-bootstrap.sql 참고)
-- 역할 이름은 current_database()에서 만든다. 결과는 'P11 PASS' / 'P11 FAIL' 줄로 낸다(scripts/kind/p11-check.sh가 센다).
-- 아무것도 바꾸지 않는다. 쓰기 시험은 거절이 기대값이고, 허용되더라도 마지막 ROLLBACK으로 되돌린다.
\set ON_ERROR_STOP on
\set VERBOSITY terse
SET client_min_messages = notice;
-- 관리자가 센 검색 가능 작품 수(p11-check.sh가 -v searchable_count로 넘긴다).
SELECT set_config('p11.searchable_count', :'searchable_count', false) \gset

-- A. 기본 연결 상태 ------------------------------------------------------------
DO $$
BEGIN
    IF current_setting('transaction_read_only') = 'on' THEN
        RAISE NOTICE 'P11 PASS A1 기본 트랜잭션이 읽기 전용';
    ELSE
        RAISE WARNING 'P11 FAIL A1 기본 트랜잭션이 읽기 전용이 아님';
    END IF;
    IF current_setting('statement_timeout') <> '0' THEN
        RAISE NOTICE 'P11 PASS A2 statement_timeout 상한 있음(%)', current_setting('statement_timeout');
    ELSE
        RAISE WARNING 'P11 FAIL A2 statement_timeout 없음';
    END IF;
END $$;

-- B. 허용 실행 정상 --------------------------------------------------------------
-- 단위 벡터(1024차원)와 계약 형식 그대로의 최소 입력. 데이터가 없어도 오류가 아니라 정상 0건이어야 한다.
DO $$
DECLARE
    v_result JSONB;
    v_spec JSONB := '{
        "contract_version": "rag-search-v1",
        "mapping_version": "genre-map-v1",
        "policy_version": "rag-rerank-v1",
        "embedding_profile": {"model": "gemini-embedding-001", "dimension": 1024, "document_format": "title_text",
                              "query_task": "RETRIEVAL_QUERY", "document_task": "RETRIEVAL_DOCUMENT"},
        "filter_groups": [], "ott_provider_ids": [], "excluded_content_ids": [],
        "region": "KR", "offer_type": "flatrate", "candidate_limit": 20, "release_date_ranges": []
    }';
BEGIN
    EXECUTE 'SELECT rag.search_contents_v1($1::catalog.vector, $2)'
        INTO v_result USING '[1' || repeat(',0', 1023) || ']', v_spec;
    IF v_result->>'status' = 'OK' AND jsonb_typeof(v_result->'items') = 'array' THEN
        RAISE NOTICE 'P11 PASS B1 검색 함수 실행 허용(status=OK, items 배열)';
    ELSE
        RAISE WARNING 'P11 FAIL B1 응답 형식이 계약과 다름: status=% items=%', v_result->>'status', jsonb_typeof(v_result->'items');
    END IF;
    -- B3: 이 시험은 DB를 바꾸지 않으므로 작품을 넣지 않는다. 검색 가능한 작품이 없는 DB(관리자 쪽에서 센다)에서는
    -- 오류가 아니라 정상 0건이어야 한다. p11.searchable_count는 scripts/kind/p11-check.sh가 넘긴다.
    IF current_setting('p11.searchable_count', true) IS NULL THEN
        RAISE WARNING 'P11 FAIL B3 p11.searchable_count가 없음(p11-check.sh로 실행할 것)';
    ELSIF current_setting('p11.searchable_count')::int = 0 THEN
        IF jsonb_array_length(v_result->'items') = 0 THEN
            RAISE NOTICE 'P11 PASS B3 검색 가능한 작품 0개인 DB에서 정상 0건';
        ELSE
            RAISE WARNING 'P11 FAIL B3 검색 가능한 작품이 없는데 %건 반환', jsonb_array_length(v_result->'items');
        END IF;
    ELSE
        RAISE NOTICE 'P11 PASS B3 검색 가능한 작품 %개, 결과 %건(후보 정확성은 P09·P12에서 본다)',
            current_setting('p11.searchable_count'), jsonb_array_length(v_result->'items');
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'P11 FAIL B1 검색 함수 실행 실패 % %', SQLSTATE, SQLERRM;
END $$;

DO $$
BEGIN
    PERFORM rag.search_contents_v1(('[1' || repeat(',0', 1023) || ']')::catalog.vector, '{}'::jsonb);
    RAISE WARNING 'P11 FAIL B2 잘못된 입력이 거절되지 않음';
EXCEPTION WHEN SQLSTATE '22023' THEN
    RAISE NOTICE 'P11 PASS B2 잘못된 입력은 22023으로 거절(함수 안 검증이 동작)';
WHEN OTHERS THEN
    RAISE WARNING 'P11 FAIL B2 잘못된 입력 SQLSTATE가 22023이 아님: % %', SQLSTATE, SQLERRM;
END $$;

-- C. 거절돼야 하는 것 -------------------------------------------------------------
-- 42501 = insufficient_privilege, 25006 = read_only_sql_transaction, 3F000/42P01/42883 = 이름조차 안 보임(이것도 거절)
-- 쓰기는 두 번 본다: 기본(읽기 전용) 트랜잭션에서 25006, READ WRITE로 바꿔도 권한으로 42501.
-- (도우미 함수를 만들 권한이 없으므로 같은 반복문을 C·D에 그대로 둔다.)
DO $$
DECLARE
    db TEXT := current_database();
    t RECORD;
BEGIN
    FOR t IN SELECT * FROM (VALUES
        ('C01 원본 표 SELECT catalog.contents',             'SELECT 1 FROM catalog.contents LIMIT 1',              '42501'),
        ('C02 원본 표 SELECT rag.content_embeddings',       'SELECT 1 FROM rag.content_embeddings LIMIT 1',        '42501'),
        ('C03 원본 표 SELECT rag.content_search_documents', 'SELECT 1 FROM rag.content_search_documents LIMIT 1',  '42501'),
        ('C04 기준 표 SELECT rag.rerank_policies',          'SELECT 1 FROM rag.rerank_policies LIMIT 1',           '42501'),
        ('C05 기준 표 SELECT catalog.preference_options',   'SELECT 1 FROM catalog.preference_options LIMIT 1',    '42501'),
        ('C06 이력 표 SELECT catalog.flyway_schema_history', 'SELECT 1 FROM catalog.flyway_schema_history LIMIT 1', '42501'),
        ('C07 적재 표 SELECT ingest.ingestion_runs',        'SELECT 1 FROM ingest.ingestion_runs LIMIT 1',         '42501'),
        ('C08 기본(읽기 전용) 트랜잭션에서 INSERT',
            $s$INSERT INTO catalog.mapping_versions VALUES ('p11', false)$s$,                                     '25006,42501'),
        ('C09 다른 SECURITY DEFINER 함수 rag.activate_embedding', 'SELECT rag.activate_embedding(1)',             '42501'),
        ('C10 다른 SECURITY DEFINER 함수 catalog.refresh_content_searchability',
            'SELECT catalog.refresh_content_searchability(gen_random_uuid())',                                     '42501'),
        ('C11 SET ROLE 호출 역할(SET 멤버십 없음)',          format('SET ROLE %I', db || '_recommend_search'),    '42501'),
        ('C12 SET ROLE 함수 소유 역할',                     format('SET ROLE %I', db || '_rag_search_definer'),  '42501'),
        ('C13 SET ROLE 적재 역할',                          format('SET ROLE %I', db || '_ingest_writer'),       '42501'),
        ('C14 SET ROLE content 앱 계정',                    format('SET ROLE %I', db || '_app'),                 '42501')
    ) v(label, stmt, want) LOOP
        BEGIN
            EXECUTE t.stmt;
            RAISE WARNING 'P11 FAIL % — 허용됨', t.label;
            RESET ROLE;
        EXCEPTION WHEN OTHERS THEN
            IF SQLSTATE = ANY (string_to_array(t.want, ',')) THEN
                RAISE NOTICE 'P11 PASS % (%)', t.label, SQLSTATE;
            ELSE
                RAISE WARNING 'P11 FAIL % — 기대 % 실제 % %', t.label, t.want, SQLSTATE, SQLERRM;
            END IF;
        END;
    END LOOP;
END $$;

-- D. READ WRITE로 바꿔도 권한으로 거절되는지 ----------------------------------------
-- default_transaction_read_only는 사용자가 스스로 끌 수 있어 보안 경계가 아니다. 권한 자체가 없어야 한다.
BEGIN TRANSACTION READ WRITE;
DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN SELECT * FROM (VALUES
        ('D01 INSERT catalog.mapping_versions', $s$INSERT INTO catalog.mapping_versions VALUES ('p11', false)$s$, '42501'),
        ('D02 UPDATE catalog.contents',             'UPDATE catalog.contents SET manual_hidden = true',      '42501'),
        ('D03 DELETE catalog.contents',             'DELETE FROM catalog.contents',                          '42501'),
        ('D04 UPDATE rag.content_embeddings 활성',  'UPDATE rag.content_embeddings SET is_active = true',    '42501'),
        ('D05 UPDATE rag.rerank_policies',          'UPDATE rag.rerank_policies SET is_active = false',      '42501'),
        ('D06 TRUNCATE rag.content_search_documents', 'TRUNCATE rag.content_search_documents',              '42501'),
        ('D07 CREATE TABLE catalog',                'CREATE TABLE catalog.p11_probe (id int)',               '42501'),
        ('D08 CREATE TABLE rag',                    'CREATE TABLE rag.p11_probe (id int)',                   '42501'),
        ('D09 CREATE TABLE public',                 'CREATE TABLE public.p11_probe (id int)',                '42501'),
        ('D10 CREATE TEMP TABLE',                   'CREATE TEMP TABLE p11_probe (id int)',                  '42501'),
        ('D11 CREATE SCHEMA',                       'CREATE SCHEMA p11_probe',                               '42501'),
        ('D12 함수 교체 CREATE OR REPLACE',
            $s$CREATE OR REPLACE FUNCTION rag.search_contents_v1(catalog.vector, jsonb) RETURNS jsonb LANGUAGE sql AS 'SELECT NULL::jsonb'$s$,
                                                                                                         '42501'),
        ('D13 함수 SECURITY INVOKER로 변경',
            'ALTER FUNCTION rag.search_contents_v1(catalog.vector, jsonb) SECURITY INVOKER',               '42501')
        -- GRANT ... TO PUBLIC은 넣지 않는다. 권한이 일부라도 있는 비소유자의 GRANT는 오류가 아니라
        -- "no privileges were granted" 경고로 끝나 허용처럼 보인다. 결과(PUBLIC EXECUTE 없음)는 2부(관리자)가 본다.
    ) v(label, stmt, want) LOOP
        BEGIN
            EXECUTE t.stmt;
            RAISE WARNING 'P11 FAIL % — 허용됨', t.label;
        EXCEPTION WHEN OTHERS THEN
            IF SQLSTATE = ANY (string_to_array(t.want, ',')) THEN
                RAISE NOTICE 'P11 PASS % (%)', t.label, SQLSTATE;
            ELSE
                RAISE WARNING 'P11 FAIL % — 기대 % 실제 % %', t.label, t.want, SQLSTATE, SQLERRM;
            END IF;
        END;
    END LOOP;
END $$;
ROLLBACK;
