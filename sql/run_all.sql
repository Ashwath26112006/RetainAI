-- Master build script. Run from the project root as RETAINAI:
--   sqlplus retainai/RetainAI2026@localhost:1521/XEPDB1 @sql\run_all.sql
SET ECHO OFF
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 160
SET PAGESIZE 100
SET SQLBLANKLINES ON
WHENEVER SQLERROR CONTINUE

PROMPT ##### 00_reset.sql (removes objects from an earlier build)
@sql\00_reset.sql
PROMPT ##### 01_schema.sql
@sql\01_schema.sql
PROMPT ##### 02_load_staging.sql (7043 INSERT statements, output suppressed)
@sql\02_load_staging.sql
PROMPT ##### 03_functions.sql
@sql\03_functions.sql
PROMPT ##### 04_etl.sql
@sql\04_etl.sql
PROMPT ##### 05_views.sql
@sql\05_views.sql
PROMPT ##### 06_procedures.sql
@sql\06_procedures.sql
PROMPT ##### 07_package.sql
@sql\07_package.sql
PROMPT ##### 08_triggers.sql
@sql\08_triggers.sql
PROMPT ##### 09_seed_ops.sql
@sql\09_seed_ops.sql

@sql\13_verify.sql
@sql\10_cursors_demo.sql
@sql\11_reports.sql
@sql\14_demo_routines.sql
@sql\12_tests.sql
EXIT
