-- P11(함수 역할/배포) 2부: 관리자 계정으로 시스템 카탈로그를 읽어 함수 소유자·search_path·PUBLIC 권한과
-- 역할 구성을 확인한다. 아무것도 바꾸지 않는다. 결과는 'P11 PASS' / 'P11 FAIL' 줄로 낸다.
-- 1부(p11-recommend-login.sql) 뒤에 실행하면, 1부의 GRANT 시도 등이 상태를 바꾸지 않았는지도 같이 본다.
\set ON_ERROR_STOP on
\set VERBOSITY terse

DO $$
DECLARE
    db          TEXT := current_database();
    definer     TEXT := current_database() || '_rag_search_definer';
    caller      TEXT := current_database() || '_recommend_search';
    login       TEXT := current_database() || '_recommend';
    fn          OID  := to_regprocedure('rag.search_contents_v1(catalog.vector, jsonb)');
    f           RECORD;
    n           BIGINT;
    i           INT;
    names       TEXT;

BEGIN
    IF fn IS NULL THEN
        RAISE WARNING 'P11 FAIL M00 rag.search_contents_v1(catalog.vector, jsonb)가 없음(V14 미적용)';
        RETURN;
    END IF;

    SELECT p.prosecdef, p.proconfig, r.rolname AS owner, r.rolcanlogin, r.rolsuper, r.rolcreaterole, r.rolcreatedb, r.rolbypassrls
    INTO f FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.oid = fn;

    -- M1 소유자
    IF f.owner = definer AND NOT f.rolcanlogin AND NOT f.rolsuper AND NOT f.rolcreaterole AND NOT f.rolcreatedb AND NOT f.rolbypassrls THEN
        RAISE NOTICE 'P11 PASS M01 함수 소유자 = % (NOLOGIN, 특수 속성 없음)', f.owner;
    ELSE
        RAISE WARNING 'P11 FAIL M01 함수 소유자 % (login=% super=% createrole=%)', f.owner, f.rolcanlogin, f.rolsuper, f.rolcreaterole;
    END IF;

    -- M2 SECURITY DEFINER + search_path 고정
    IF f.prosecdef THEN
        RAISE NOTICE 'P11 PASS M02 SECURITY DEFINER';
    ELSE
        RAISE WARNING 'P11 FAIL M02 SECURITY DEFINER 아님';
    END IF;
    IF f.proconfig = ARRAY['search_path=pg_catalog, pg_temp'] THEN
        RAISE NOTICE 'P11 PASS M03 search_path 고정 %', f.proconfig;
    ELSE
        RAISE WARNING 'P11 FAIL M03 search_path 설정 %', f.proconfig;
    END IF;

    -- M4 PUBLIC EXECUTE 없음, EXECUTE 받은 역할 = 소유자 + 호출 역할뿐
    SELECT count(*) INTO n FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = fn AND a.grantee = 0;
    IF (SELECT proacl FROM pg_proc WHERE oid = fn) IS NOT NULL AND n = 0 THEN
        RAISE NOTICE 'P11 PASS M04 PUBLIC EXECUTE 없음';
    ELSE
        RAISE WARNING 'P11 FAIL M04 PUBLIC EXECUTE 있음(proacl NULL이면 기본값=PUBLIC 허용)';
    END IF;
    SELECT string_agg(r.rolname || CASE WHEN a.is_grantable THEN '(grant)' ELSE '' END, ',' ORDER BY r.rolname) INTO names
    FROM pg_proc p, aclexplode(p.proacl) a JOIN pg_roles r ON r.oid = a.grantee
    WHERE p.oid = fn AND a.privilege_type = 'EXECUTE';
    IF names = (SELECT string_agg(x, ',' ORDER BY x) FROM unnest(ARRAY[caller, definer]) x) THEN
        RAISE NOTICE 'P11 PASS M05 EXECUTE 보유 = %', names;
    ELSE
        RAISE WARNING 'P11 FAIL M05 EXECUTE 보유 = % (기대: %, %)', names, caller, definer;
    END IF;

    -- M6 함수 소유 역할 멤버십.
    -- a) SET/INHERIT로 이 역할의 권한을 쓸 수 있는 계정이 없어야 한다.
    -- b) ADMIN OPTION 보유자: V14를 실행한 마이그레이션 계정(<DB>_app)이 PostgreSQL 16+ 규칙상 갖는다. 이 계정은
    --    나중에 자기나 다른 계정에 이 역할을 부여할 수 있다 → 위험을 숨기지 않고 EXCEPTION으로 표시한다.
    --    kind 개인 환경의 임시 예외(docs/kind-db-secrets.md 4장). 공유·운영 전에 마이그레이션·앱 계정 분리로 없앤다.
    --    <DB>_app 말고 다른 보유자가 있으면 FAIL이다.
    SELECT count(*) INTO n FROM pg_auth_members WHERE roleid = definer::regrole AND (inherit_option OR set_option);
    IF n = 0 THEN
        RAISE NOTICE 'P11 PASS M06a % 를 SET/INHERIT로 쓰는 계정 없음', definer;
    ELSE
        RAISE WARNING 'P11 FAIL M06a % 멤버십(SET/INHERIT) %건', definer, n;
    END IF;
    SELECT string_agg(m.rolname, ',' ORDER BY m.rolname) INTO names FROM pg_auth_members a JOIN pg_roles m ON m.oid = a.member
    WHERE a.roleid = definer::regrole AND a.admin_option;
    IF names IS NULL THEN
        RAISE NOTICE 'P11 PASS M06b % 의 ADMIN OPTION 보유자 없음', definer;
    ELSIF names = db || '_app' THEN
        RAISE NOTICE 'P11 EXCEPTION M06b % 의 ADMIN OPTION 보유자 = % (마이그레이션 계정이 재부여 가능, kind 임시 예외)', definer, names;
    ELSE
        RAISE WARNING 'P11 FAIL M06b % 의 ADMIN OPTION 보유자 = %', definer, names;
    END IF;

    -- M7 함수 소유 역할: 쓰기·스키마 CREATE 없음
    SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
    WHERE s.nspname IN ('catalog', 'rag', 'ingest', 'public') AND c.relkind IN ('r', 'p', 'v', 'm')
      AND (has_table_privilege(definer, c.oid, 'INSERT') OR has_table_privilege(definer, c.oid, 'UPDATE')
        OR has_table_privilege(definer, c.oid, 'DELETE') OR has_table_privilege(definer, c.oid, 'TRUNCATE'));
    IF n = 0 AND NOT has_schema_privilege(definer, 'catalog', 'CREATE') AND NOT has_schema_privilege(definer, 'rag', 'CREATE')
       AND NOT has_schema_privilege(definer, 'public', 'CREATE') THEN
        RAISE NOTICE 'P11 PASS M07 함수 소유 역할: 표 쓰기 0, 스키마 CREATE 없음';
    ELSE
        RAISE WARNING 'P11 FAIL M07 함수 소유 역할 쓰기 가능 표 %개 또는 스키마 CREATE 보유', n;
    END IF;
    -- M8 함수 소유 역할 SELECT 허용 목록 = V14가 준 표뿐(ureka-content V14 "1) 함수 소유자")
    SELECT string_agg(s.nspname || '.' || c.relname, ',' ORDER BY s.nspname, c.relname) INTO names FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
    WHERE s.nspname NOT IN ('pg_catalog', 'information_schema') AND s.nspname NOT LIKE 'pg_toast%'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_table_privilege(definer, c.oid, 'SELECT');
    IF names = 'catalog.content_genres,catalog.content_ott_availability,catalog.contents,catalog.genres,catalog.mapping_versions,'
            || 'catalog.ott_providers,catalog.preference_option_genres,catalog.preference_options,'
            || 'rag.content_embeddings,rag.content_search_documents,rag.rerank_policies' THEN
        RAISE NOTICE 'P11 PASS M08 함수 소유 역할 SELECT = 허용 목록 11개와 같음';
    ELSE
        RAISE WARNING 'P11 FAIL M08 함수 소유 역할 SELECT 가능 표가 허용 목록과 다름: %', names;
    END IF;

    -- M9 호출 역할·로그인 계정: 표 권한 0
    FOR i IN 1..2 LOOP
        names := (ARRAY[caller, login])[i];
        SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
        WHERE s.nspname NOT IN ('pg_catalog', 'information_schema') AND s.nspname NOT LIKE 'pg_toast%'
          AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
          AND (has_table_privilege(names, c.oid, 'SELECT') OR has_table_privilege(names, c.oid, 'INSERT')
            OR has_table_privilege(names, c.oid, 'UPDATE') OR has_table_privilege(names, c.oid, 'DELETE'));
        IF n = 0 THEN
            RAISE NOTICE 'P11 PASS M09% % 표 권한 0 (사용자 스키마 전체)', (ARRAY['a', 'b'])[i], names;
        ELSE
            RAISE WARNING 'P11 FAIL M09% % 표 권한 %개', (ARRAY['a', 'b'])[i], names, n;
        END IF;
    END LOOP;

    -- M10 로그인 계정이 실행할 수 있는 SECURITY DEFINER 함수 = 검색 함수 하나
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO names
    FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE p.prosecdef AND s.nspname NOT IN ('pg_catalog', 'information_schema')
      AND has_function_privilege(login, p.oid, 'EXECUTE');
    IF names = fn::regprocedure::text THEN
        RAISE NOTICE 'P11 PASS M10 로그인 계정이 실행 가능한 SECURITY DEFINER 함수 = %', names;
    ELSE
        RAISE WARNING 'P11 FAIL M10 로그인 계정이 실행 가능한 SECURITY DEFINER 함수 = %', names;
    END IF;

    -- M11 로그인 계정 속성과 멤버십
    SELECT string_agg(r.rolname || '(inherit=' || a.inherit_option || ',set=' || a.set_option || ',admin=' || a.admin_option || ')', ',') INTO names
    FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid WHERE a.member = login::regrole;
    IF names = caller || '(inherit=true,set=false,admin=false)'
       AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = login AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls OR rolreplication)) THEN
        RAISE NOTICE 'P11 PASS M11 로그인 계정 멤버십 = % , 특수 속성 없음', names;
    ELSE
        RAISE WARNING 'P11 FAIL M11 로그인 계정 멤버십 = % 또는 특수 속성 보유', names;
    END IF;

    -- M12 다른 DB에 접속 권한 없음(PUBLIC CONNECT 회수)
    SELECT string_agg(d.datname, ',') INTO names FROM pg_database d
    WHERE d.datname <> db AND d.datallowconn AND has_database_privilege(login, d.oid, 'CONNECT');
    IF names IS NULL THEN
        RAISE NOTICE 'P11 PASS M12 로그인 계정이 접속 가능한 다른 DB 없음(postgres·template1 포함, template0은 원래 접속 불가)';
    ELSE
        RAISE WARNING 'P11 FAIL M12 로그인 계정이 CONNECT 가능한 다른 DB: %', names;
    END IF;

    -- M13 로그인 계정 스키마 권한: 어느 스키마에도 CREATE 없음, ingest 스키마 USAGE 없음
    SELECT string_agg(s.nspname, ',' ORDER BY s.nspname) INTO names FROM pg_namespace s
    WHERE s.nspname NOT LIKE 'pg_%' AND s.nspname <> 'information_schema' AND has_schema_privilege(login, s.oid, 'CREATE');
    IF names IS NULL AND NOT has_schema_privilege(login, 'ingest', 'USAGE') THEN
        RAISE NOTICE 'P11 PASS M13 로그인 계정: 스키마 CREATE 없음, ingest USAGE 없음';
    ELSE
        RAISE WARNING 'P11 FAIL M13 로그인 계정 스키마 CREATE: %, ingest USAGE: %', names, has_schema_privilege(login, 'ingest', 'USAGE');
    END IF;
END $$;
