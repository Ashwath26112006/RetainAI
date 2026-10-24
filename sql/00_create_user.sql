-- Run as SYSTEM connected to the pluggable database (XEPDB1).
-- Creates (or re-creates) the RETAINAI schema owner.
SET ECHO OFF
WHENEVER SQLERROR CONTINUE
-- when run as SYS (OS authentication) switch to the pluggable database; harmless otherwise
ALTER SESSION SET CONTAINER = XEPDB1;
DROP USER retainai CASCADE;
WHENEVER SQLERROR EXIT FAILURE
CREATE USER retainai IDENTIFIED BY RetainAI2026
  DEFAULT TABLESPACE users TEMPORARY TABLESPACE temp QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE,
      CREATE PROCEDURE, CREATE TRIGGER, CREATE SYNONYM TO retainai;
-- XEPDB1 on this laptop is open in RESTRICTED mode (pending PDB sync failure ORA-65177 from an unrelated
-- common user); RESTRICTED SESSION lets the project user connect without altering that state.
GRANT RESTRICTED SESSION TO retainai;
PROMPT User RETAINAI created.
EXIT
