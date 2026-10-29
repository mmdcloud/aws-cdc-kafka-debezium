CREATE TABLE IF NOT EXISTS public.heartbeat (id INT PRIMARY KEY, ts TIMESTAMPTZ);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'debezium_pub') THEN
    CREATE PUBLICATION debezium_pub FOR ALL TABLES;
  END IF;
END
$$;