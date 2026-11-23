-- replica bypasses FK and ordinary triggers: validate FK anti-joins before COMMIT.
DO $$
DECLARE fk record; join_terms text; nonnull_terms text; invalid boolean;
BEGIN
 FOR fk IN SELECT c.* FROM pg_catalog.pg_constraint c WHERE c.contype='f'
 AND c.conrelid IN (SELECT name::regclass FROM copy_policy WHERE mode='copy') LOOP
  IF fk.confmatchtype <> 's' THEN RAISE EXCEPTION 'unsupported FK match type'; END IF;
  SELECT string_agg(format('child.%I=parent.%I',a.attname,b.attname),' AND ' ORDER BY x.i),
         string_agg(format('child.%I IS NOT NULL',a.attname),' AND ' ORDER BY x.i)
  INTO join_terms,nonnull_terms
  FROM generate_subscripts(fk.conkey,1) x(i)
  JOIN pg_catalog.pg_attribute a ON a.attrelid=fk.conrelid AND a.attnum=fk.conkey[x.i]
  JOIN pg_catalog.pg_attribute b ON b.attrelid=fk.confrelid AND b.attnum=fk.confkey[x.i];
  EXECUTE format('SELECT EXISTS(SELECT 1 FROM %s child WHERE %s AND NOT EXISTS(SELECT 1 FROM %s parent WHERE %s))',
                 fk.conrelid::regclass,nonnull_terms,fk.confrelid::regclass,join_terms) INTO invalid;
  IF invalid THEN RAISE EXCEPTION 'copied foreign key mismatch'; END IF;
 END LOOP;
 IF EXISTS(SELECT d.content_id FROM rag.content_embeddings e JOIN rag.content_search_documents d USING(document_id)
           WHERE e.is_active GROUP BY d.content_id HAVING count(*)>1) THEN
  RAISE EXCEPTION 'more than one active embedding per content';
 END IF;
END $$;
