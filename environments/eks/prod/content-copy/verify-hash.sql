-- Internal-only canonical fingerprints: never emit individual rows to logs.
CREATE TEMP TABLE verify_hashes(name text PRIMARY KEY, digest text);
DO $$
DECLARE r record; h text; seq text;
BEGIN
 FOR r IN SELECT name FROM copy_policy WHERE mode='copy' ORDER BY name LOOP
  EXECUTE format('SELECT md5(coalesce(string_agg(md5(to_jsonb(t)::text), '''' ORDER BY md5(to_jsonb(t)::text)), '''')) FROM %s t', r.name) INTO h;
  INSERT INTO verify_hashes VALUES (r.name, h);
 END LOOP;
 FOR seq IN SELECT DISTINCT pg_get_serial_sequence(name,a.attname)
 FROM copy_policy JOIN pg_attribute a ON a.attrelid=name::regclass AND a.attnum>0 AND NOT a.attisdropped
 WHERE mode='copy' AND pg_get_serial_sequence(name,a.attname) IS NOT NULL ORDER BY 1 LOOP
  EXECUTE format('SELECT md5(jsonb_build_array(last_value,is_called)::text) FROM %s', seq) INTO h;
  INSERT INTO verify_hashes VALUES (seq, h);
 END LOOP;
END $$;
SELECT md5(jsonb_agg(jsonb_build_array(name,digest) ORDER BY name)::text) FROM verify_hashes;
