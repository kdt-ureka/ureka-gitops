-- Exact inventory prevents new tables silently entering or being omitted from the copy.
DO $$
DECLARE actual text[]; expected text[]; latest text;
BEGIN
 SELECT array_agg(n.nspname||'.'||c.relname ORDER BY n.nspname,c.relname) INTO actual
 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('catalog','rag','ingest') AND c.relkind IN ('r','p');
 SELECT array_agg(name ORDER BY name) INTO expected FROM copy_policy;
 IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'copy inventory mismatch'; END IF;
 SELECT version INTO latest FROM catalog.flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1;
 IF latest IS NULL OR latest !~ '^[0-9]+$' THEN RAISE EXCEPTION 'Flyway version missing'; END IF;
 IF latest::int NOT BETWEEN 18 AND 20 OR EXISTS(SELECT 1 FROM catalog.flyway_schema_history WHERE NOT success) THEN
   RAISE EXCEPTION 'unreviewed or failed Flyway migration';
 END IF;
END $$;
-- Ignore environment-specific install user/time and seed creation timestamps only.
CREATE TEMP TABLE seed_fingerprints(name text, signature text);
DO $$
DECLARE r record; hash text;
BEGIN
 FOR r IN SELECT name FROM copy_policy WHERE mode='seed' ORDER BY name LOOP
  EXECUTE format('SELECT md5(coalesce(string_agg(row::text, chr(10) ORDER BY row::text), '''')) FROM
    (SELECT to_jsonb(t)-''created_at''-''updated_at'' AS row FROM %s t) s', r.name) INTO hash;
  INSERT INTO seed_fingerprints VALUES(r.name, hash);
 END LOOP;
END $$;
SELECT md5(jsonb_build_object(
 'flyway', (SELECT jsonb_agg(jsonb_build_array(installed_rank,version,type,checksum,success) ORDER BY installed_rank) FROM catalog.flyway_schema_history),
 'seeds', (SELECT jsonb_agg(jsonb_build_array(name,signature) ORDER BY name) FROM seed_fingerprints),
 'columns', (SELECT jsonb_agg(jsonb_build_array(n.nspname,c.relname,a.attname,pg_catalog.format_type(a.atttypid,a.atttypmod),a.attnotnull,a.attgenerated,a.attidentity) ORDER BY n.nspname,c.relname,a.attnum)
 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid
 WHERE n.nspname||'.'||c.relname IN (SELECT name FROM copy_policy) AND a.attnum>0 AND NOT a.attisdropped)
)::text);
