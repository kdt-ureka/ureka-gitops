#!/usr/bin/env python3
"""Local disposable PostgreSQL integration test. Requires a content migration directory; no cloud calls.
All DBs/credentials/data are synthetic. The supplied migrations must be a reviewed checkout (V18..V20).
"""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'pgvector/pgvector:0.8.7-pg18-trixie@sha256:5895949dfcdf308eb0cd31c950c93c14895c77f33fbedfecf1fa511ab1d4bcd2'
FIXTURE = """
INSERT INTO catalog.contents(content_id,content_type,title,original_title,media_type,overview,fetched_at_utc,is_searchable,search_excluded_at)
VALUES('00000000-0000-4000-8000-00000000000a','MOVIE','synthetic','synthetic','movie','synthetic',now(),true,NULL);
INSERT INTO catalog.movie_details(content_id,media_type,runtime_minutes) VALUES('00000000-0000-4000-8000-00000000000a','movie',90);
INSERT INTO rag.content_search_documents(content_id,document_version,title_snapshot,overview_hash,content_hash,generation_status,generated_at)
VALUES('00000000-0000-4000-8000-00000000000a',1,'synthetic',repeat('a',64),repeat('b',64),'completed',now());
INSERT INTO rag.content_embeddings(document_id,embedding_model,embedding_version,input_hash,embedding,status,is_active,embedded_at)
VALUES(1,'synthetic-model',1,repeat('c',64),('['||array_to_string(array_fill(0::real,ARRAY[1024]),',')||']')::catalog.vector,'completed',true,now());
INSERT INTO ingest.ingestion_runs(source,scope,status,completed_at,item_count) VALUES('embedding','synthetic','completed',now(),1);
INSERT INTO catalog.recent_searches(recent_search_id,user_id,query,searched_at)
VALUES('00000000-0000-4000-8000-00000000000b','00000000-0000-4000-8000-00000000000c','PRIVATE_SYNTHETIC_SEARCH',now());
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--migrations', type=Path, required=True)
    args = parser.parse_args()
    files = sorted(args.migrations.glob('V*__*.sql'), key=lambda p: int(re.match(r'V(\d+)', p.name)[1]))
    if not files or not 18 <= int(re.match(r'V(\d+)', files[-1].name)[1]) <= 20:
        parser.error('reviewed V18..V20 content migration files are required')
    name = 'ureka-content-copy-test-' + uuid.uuid4().hex[:8]
    temp = Path(tempfile.mkdtemp(prefix='ureka-content-copy-test-'))
    passed = 0

    def run(*command, data=None, check=True):
        result = subprocess.run(command, input=data, text=True, capture_output=True)
        if check and result.returncode:
            # Never print SQL/data rows; diagnostics remain in the caller-owned temporary test directory.
            (temp / 'error.log').write_text(result.stdout + result.stderr)
            raise RuntimeError('local test command failed; inspect temporary test error.log locally')
        return result

    def sql(db, text):
        return run('docker', 'exec', '-i', name, 'psql', '-XqAt', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', db, data=text).stdout.strip()

    def reset():
        sql('postgres', 'DROP DATABASE IF EXISTS content_db_prod WITH (FORCE); CREATE DATABASE content_db_prod;')
        initialize('content_db_prod')

    def initialize(db):
        start = '''SET client_min_messages=warning; CREATE SCHEMA catalog; CREATE EXTENSION vector SCHEMA catalog; SET search_path=catalog,public;
CREATE TABLE catalog.flyway_schema_history(installed_rank int primary key,version text,type text,checksum int,success boolean);
'''
        for p in files:
            version = int(re.match(r'V(\d+)', p.name)[1])
            checksum = int.from_bytes(hashlib.sha256(p.read_bytes()).digest()[:4], 'big', signed=True)
            start += p.read_text() + f"\nINSERT INTO catalog.flyway_schema_history VALUES({version},'{version}','SQL',{checksum},true);\n"
        sql(db, start)

    def copy(*, expect=True, user="postgres"):
        result = run('docker', 'exec', '-u', '999:999', '-e', 'PGUSER='+user, '-e', 'PGSSLMODE=disable', name,
                     'bash', '/copy/run-copy.sh', check=False)
        if (result.returncode == 0) != expect:
            (temp / 'copy.log').write_text(result.stdout + result.stderr)
            raise RuntimeError('copy result differs from expectation; inspect temporary copy.log locally')
        if 'PRIVATE_SYNTHETIC_SEARCH' in result.stdout + result.stderr:
            raise RuntimeError('copy log leaked synthetic user data')
        return result

    def ok(label):
        nonlocal passed
        passed += 1
        print('ok', label, flush=True)

    print('Local Docker test diagnostics:', temp, flush=True)
    try:
        run('docker', 'run', '-d', '--name', name, '-e', 'POSTGRES_PASSWORD=synthetic-test-only',
            '-v', str(ROOT / 'environments/eks/prod/content-copy') + ':/copy:ro', IMAGE)
        for _ in range(60):
            if run('docker', 'exec', name, 'pg_isready', '-U', 'postgres', check=False).returncode == 0:
                break
            time.sleep(1)
        run('docker', 'exec', name, 'sh', '-c', 'mkdir -p /work; chmod 0777 /work')
        sql('postgres', 'CREATE DATABASE content_db; CREATE DATABASE content_db_prod;')
        initialize('content_db')
        initialize('content_db_prod')
        copy(expect=False)
        ok('empty source knowledge base rejected')
        sql('content_db', FIXTURE)
        result = copy()
        assert 'copy ok' in result.stdout
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents; SELECT count(*) FROM rag.content_embeddings; SELECT count(*) FROM catalog.recent_searches;') == '1\n1\n0'
        ok('actual migrations: copy preserves data/vector and excludes user history')
        assert sql('content_db_prod', 'SELECT last_value FROM rag.content_embeddings_embedding_id_seq;') == '1'
        ok('owned identity sequence copied')
        copy(expect=False)
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents') == '1'
        ok('nonempty destination rejected without overwrite')
        reset()
        sql('content_db_prod', "UPDATE catalog.flyway_schema_history SET version='17' WHERE installed_rank=(SELECT max(installed_rank) FROM catalog.flyway_schema_history)")
        copy(expect=False)
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents') == '0'
        ok('Flyway mismatch rejected before restore')
        reset()
        sql('content_db_prod', "UPDATE rag.rerank_policies SET description='synthetic drift'")
        copy(expect=False)
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents') == '0'
        ok('seed drift rejected before restore')
        reset()
        sql('content_db_prod', 'ALTER TABLE catalog.contents ADD CONSTRAINT synthetic_reject CHECK (false)')
        copy(expect=False)
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents; SELECT count(*) FROM rag.content_embeddings') == '0\n0'
        ok('COPY constraint failure rolls back every destination row')
        reset()
        sql('content_db', "SET session_replication_role=replica; UPDATE rag.content_search_documents SET content_id='00000000-0000-4000-8000-0000000000ff'; SET session_replication_role=origin;")
        copy(expect=False)
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents; SELECT count(*) FROM rag.content_search_documents') == '0\n0'
        ok('FK anti-join detects corrupt source and rolls back restore')
        sql('content_db', "SET session_replication_role=replica; UPDATE rag.content_search_documents SET content_id='00000000-0000-4000-8000-00000000000a'; SET session_replication_role=origin;")
        sql('content_db', """SET session_replication_role=replica;
INSERT INTO rag.content_search_documents(content_id,document_version,title_snapshot,overview_hash,content_hash,generation_status,generated_at)
VALUES('00000000-0000-4000-8000-00000000000a',2,'synthetic',repeat('a',64),repeat('b',64),'completed',now());
INSERT INTO rag.content_embeddings(document_id,embedding_model,embedding_version,input_hash,embedding,status,is_active,embedded_at)
VALUES(2,'synthetic-model',1,repeat('c',64),('['||array_to_string(array_fill(0::real,ARRAY[1024]),',')||']')::catalog.vector,'completed',true,now());
SET session_replication_role=origin;""")
        copy(expect=False)
        assert sql('content_db_prod', 'SELECT count(*) FROM rag.content_embeddings') == '0'
        ok('single-active-embedding invariant is checked after replica restore')
        sql('content_db', 'DELETE FROM rag.content_embeddings WHERE document_id=2; DELETE FROM rag.content_search_documents WHERE document_id=2;')
        sql('content_db', "INSERT INTO ingest.ingestion_runs(source,scope) VALUES('embedding','synthetic-running')")
        copy(expect=False)
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents') == '0'
        ok('running ingestion rejected')
        sql('content_db', "DELETE FROM ingest.ingestion_runs WHERE status='running'")
        sql('postgres', "CREATE ROLE synthetic_rds LOGIN; GRANT SET ON PARAMETER session_replication_role,log_statement,log_min_error_statement TO synthetic_rds")
        for db in ['content_db','content_db_prod']:
            sql(db, "GRANT USAGE ON SCHEMA catalog,rag,ingest TO synthetic_rds; GRANT ALL ON ALL TABLES IN SCHEMA catalog,rag,ingest TO synthetic_rds; GRANT ALL ON ALL SEQUENCES IN SCHEMA catalog,rag,ingest TO synthetic_rds")
        copy(user='synthetic_rds')
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents') == '1'
        ok('non-superuser with explicit parameter/object grants can copy')
        reset()
        sql('content_db_prod', "GRANT USAGE ON SCHEMA catalog,rag,ingest TO synthetic_rds; GRANT ALL ON ALL TABLES IN SCHEMA catalog,rag,ingest TO synthetic_rds; GRANT ALL ON ALL SEQUENCES IN SCHEMA catalog,rag,ingest TO synthetic_rds")
        sql('postgres', 'REVOKE SET ON PARAMETER session_replication_role FROM synthetic_rds')
        copy(user='synthetic_rds', expect=False)
        assert sql('content_db_prod', 'SELECT count(*) FROM catalog.contents') == '0'
        ok('missing replica SET privilege fails before data restore')
        print(f'passed {passed}, failed 0', flush=True)
    finally:
        run('docker', 'rm', '-f', name, check=False)


if __name__ == '__main__':
    main()
