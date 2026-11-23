-- Numeric-only detail. Group names are retained in the private report comparison, not logs.
SELECT 'copy contents '||CASE media_type WHEN 'movie' THEN 1 WHEN 'tv' THEN 2 ELSE 0 END||' '||count(*)||' '||count(*) FILTER(WHERE is_searchable)
FROM catalog.contents GROUP BY media_type ORDER BY media_type;
SELECT 'copy documents '||CASE generation_status WHEN 'pending' THEN 1 WHEN 'processing' THEN 2 WHEN 'completed' THEN 3 WHEN 'failed' THEN 4 WHEN 'retryable' THEN 5 WHEN 'excluded' THEN 6 ELSE 0 END||' '||count(*)
FROM rag.content_search_documents GROUP BY generation_status ORDER BY generation_status;
SELECT 'copy embeddings '||row_number() OVER(ORDER BY embedding_model,embedding_version,document_format,status)||' '||embedding_version||' '||count(*)||' '||count(*) FILTER(WHERE is_active)
FROM rag.content_embeddings GROUP BY embedding_model,embedding_version,document_format,status ORDER BY embedding_model,embedding_version,document_format,status;
SELECT 'copy runs '||run_id||' '||coalesce(item_count,-1)||' '||CASE status WHEN 'running' THEN 1 WHEN 'completed' THEN 2 WHEN 'failed' THEN 3 WHEN 'cancelled' THEN 4 ELSE 0 END||' '||is_full_snapshot::int
FROM ingest.ingestion_runs ORDER BY run_id DESC LIMIT 20;
