-- Internal comparison only: one hash, no data rows or names in logs.
CREATE TEMP TABLE row_counts(name text, n bigint);
DO $$ DECLARE r record; n bigint; BEGIN
 FOR r IN SELECT name FROM copy_policy WHERE mode='copy' ORDER BY name LOOP
  EXECUTE format('SELECT count(*) FROM %s',r.name) INTO n;
  INSERT INTO row_counts VALUES(r.name,n);
 END LOOP;
END $$;
SELECT md5(jsonb_build_object(
 'tables',(SELECT jsonb_agg(jsonb_build_array(name,n) ORDER BY name) FROM row_counts),
 'contents',(SELECT jsonb_agg(to_jsonb(t) ORDER BY media_type) FROM
   (SELECT media_type,count(*) AS n,count(*) FILTER(WHERE is_searchable) AS searchable FROM catalog.contents GROUP BY media_type) t),
 'documents',(SELECT jsonb_agg(to_jsonb(t) ORDER BY generation_status) FROM
   (SELECT generation_status,count(*) AS n FROM rag.content_search_documents GROUP BY generation_status) t),
 'embeddings',(SELECT jsonb_agg(to_jsonb(t) ORDER BY embedding_model,embedding_version,document_format,status) FROM
   (SELECT embedding_model,embedding_version,document_format,status,count(*) AS n,count(*) FILTER(WHERE is_active) AS active
    FROM rag.content_embeddings GROUP BY embedding_model,embedding_version,document_format,status) t),
 'runs',(SELECT jsonb_agg(to_jsonb(t) ORDER BY run_id DESC) FROM
   (SELECT * FROM ingest.ingestion_runs ORDER BY run_id DESC LIMIT 20) t)
)::text);
