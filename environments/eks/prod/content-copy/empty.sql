DO $$
DECLARE r record; occupied boolean;
BEGIN
 FOR r IN SELECT name FROM copy_policy WHERE mode='copy' ORDER BY name LOOP
  EXECUTE format('SELECT EXISTS(SELECT 1 FROM %s)',r.name) INTO occupied;
  IF occupied THEN RAISE EXCEPTION 'destination copy table is not empty'; END IF;
 END LOOP;
END $$;
