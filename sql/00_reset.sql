-- =====================================================================
-- 00_reset.sql : drops everything the project created earlier, so that
-- the build can be repeated from a clean state (run first by run_all.sql)
-- =====================================================================
SET DEFINE OFF
BEGIN
  FOR o IN (SELECT object_name, object_type FROM user_objects
             WHERE object_type IN ('VIEW', 'PACKAGE', 'PROCEDURE', 'FUNCTION', 'TRIGGER')) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP ' || o.object_type || ' "' || o.object_name || '"';
    EXCEPTION WHEN OTHERS THEN NULL;   -- already gone (for example a trigger dropped with its table)
    END;
  END LOOP;
  FOR t IN (SELECT table_name FROM user_tables) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE "' || t.table_name || '" CASCADE CONSTRAINTS PURGE';
  END LOOP;
  FOR s IN (SELECT sequence_name FROM user_sequences WHERE sequence_name NOT LIKE 'ISEQ$$%') LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE "' || s.sequence_name || '"';
  END LOOP;
END;
/
