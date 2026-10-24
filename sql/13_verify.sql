-- =====================================================================
-- 13_verify.sql : proof that the objects exist, are VALID and hold the expected data
-- =====================================================================
SET DEFINE OFF
SET LINESIZE 150
SET PAGESIZE 100
SET FEEDBACK ON
COLUMN object_name FORMAT A32
COLUMN object_type FORMAT A16
COLUMN table_name FORMAT A24
COLUMN constraint_name FORMAT A26
COLUMN column_name FORMAT A22

PROMPT === V1. Row counts of all tables ===
SELECT 'APP_CONFIG' AS table_name, COUNT(*) AS row_count FROM app_config UNION ALL
SELECT 'STG_TELCO', COUNT(*) FROM stg_telco UNION ALL
SELECT 'CONTRACT_TYPES', COUNT(*) FROM contract_types UNION ALL
SELECT 'PAYMENT_METHODS', COUNT(*) FROM payment_methods UNION ALL
SELECT 'PLANS', COUNT(*) FROM plans UNION ALL
SELECT 'SERVICES', COUNT(*) FROM services UNION ALL
SELECT 'CUSTOMERS', COUNT(*) FROM customers UNION ALL
SELECT 'SUBSCRIPTIONS', COUNT(*) FROM subscriptions UNION ALL
SELECT 'SUBSCRIPTION_SERVICES', COUNT(*) FROM subscription_services UNION ALL
SELECT 'BILLING_RECORDS', COUNT(*) FROM billing_records UNION ALL
SELECT 'SUPPORT_TICKETS', COUNT(*) FROM support_tickets UNION ALL
SELECT 'RETENTION_CAMPAIGNS', COUNT(*) FROM retention_campaigns UNION ALL
SELECT 'RETENTION_ACTIONS', COUNT(*) FROM retention_actions UNION ALL
SELECT 'CHURN_SCORES', COUNT(*) FROM churn_scores UNION ALL
SELECT 'AUDIT_LOG', COUNT(*) FROM audit_log;

PROMPT === V2. Schema objects by type and status ===
SELECT object_type, status, COUNT(*) AS objects FROM user_objects
 WHERE object_type IN ('TABLE','VIEW','FUNCTION','PROCEDURE','PACKAGE','PACKAGE BODY','TRIGGER','SEQUENCE','INDEX')
 GROUP BY object_type, status ORDER BY object_type;

PROMPT === V3. Invalid objects / compilation errors (expected: no rows selected) ===
SELECT object_name, object_type, status FROM user_objects WHERE status <> 'VALID';
SELECT name, type, line, text FROM user_errors ORDER BY name, sequence;

PROMPT === V4. Stored functions, procedures, packages and triggers ===
SELECT object_name, object_type, status FROM user_objects
 WHERE object_type IN ('FUNCTION','PROCEDURE','PACKAGE','TRIGGER') ORDER BY object_type, object_name;

PROMPT === V5. Integrity constraints (P = primary key, R = foreign key, U = unique, C = check) ===
SELECT constraint_type, COUNT(*) AS total FROM user_constraints
 WHERE generated = 'USER NAME'
 GROUP BY constraint_type ORDER BY constraint_type;

PROMPT === V6. Table structures ===
DESC customers
DESC subscriptions
DESC billing_records
DESC support_tickets
DESC churn_scores

PROMPT === V7. Source data check : staged rows vs loaded customers / churn totals ===
SELECT (SELECT COUNT(*) FROM stg_telco) AS staged_rows,
       (SELECT COUNT(*) FROM customers) AS customers,
       (SELECT COUNT(*) FROM stg_telco WHERE churn = 'Yes') AS churn_in_source,
       (SELECT COUNT(*) FROM customers WHERE status = 'CHURNED') AS churned_loaded
  FROM dual;
