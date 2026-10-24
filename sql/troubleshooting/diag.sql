SET LINESIZE 220 PAGESIZE 200 LONG 2000
COLUMN name FORMAT A12
COLUMN username FORMAT A25
COLUMN common FORMAT A6
COLUMN sqltext FORMAT A150
COLUMN message FORMAT A150
COLUMN action FORMAT A150
PROMPT == root: users named LOGIN
SELECT username, common, con_id FROM cdb_users WHERE username = 'LOGIN' OR username LIKE 'C##%';
PROMPT == violations
SELECT name, status, message, action FROM pdb_plug_in_violations WHERE status <> 'RESOLVED';
PROMPT == pending sync statements
SELECT con_uid, opcode, replace(substr(sqltext,1,150),chr(10),' ') sqltext FROM pdb_sync$ WHERE sqltext LIKE '%LOGIN%';
EXIT
