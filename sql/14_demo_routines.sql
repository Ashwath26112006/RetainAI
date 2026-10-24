-- =====================================================================
-- 14_demo_routines.sql : visible demonstration of functions, procedures and triggers
-- (a demo customer is created and removed again; audit rows are kept)
-- =====================================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 170
SET PAGESIZE 60
SET FEEDBACK ON
COLUMN customer_id FORMAT A12
COLUMN segment FORMAT A10
COLUMN band FORMAT A8
COLUMN table_name FORMAT A16
COLUMN operation FORMAT A12
COLUMN record_key FORMAT A10
COLUMN old_value FORMAT A44
COLUMN new_value FORMAT A44
COLUMN notes FORMAT A52
COLUMN action_type FORMAT A10
COLUMN email FORMAT A40
COLUMN full_name FORMAT A18
VARIABLE cid VARCHAR2(20)
VARIABLE sid NUMBER
VARIABLE n NUMBER
VARIABLE bill NUMBER
VARIABLE tid NUMBER

PROMPT === F1. Functions applied to sample customers ===
SELECT customer_id, fn_tenure_months(customer_id) AS tenure_mo, fn_churn_risk_score(customer_id) AS risk_score,
       fn_risk_band(fn_churn_risk_score(customer_id)) AS band, fn_segment(customer_id) AS segment,
       fn_lifetime_value(customer_id) AS lifetime_value
  FROM customers
 WHERE customer_id IN ('7590-VHVEG','5575-GNVDE','3668-QPYBK','7795-CFOCW','9237-HQITU','9305-CDSKC')
 ORDER BY customer_id;

PROMPT === P1. sp_add_customer : register a customer (name and e-mail are normalised by trigger trg_customers_bi) ===
EXEC sp_add_customer('demo customer one', '  Demo.One@RetainAI-Demo.Example ', 'Female', 'N', 'Y', 'N', 2, 1, 1, 'Y', NULL, '2,5', :cid, :sid)
PRINT cid sid
SELECT customer_id, full_name, email, status, signup_date FROM customers WHERE customer_id = :cid;
SELECT customer_id, rule_score, risk_band, segment FROM churn_scores WHERE customer_id = :cid;

PROMPT === P2. sp_generate_bills / sp_record_payment ===
EXEC sp_generate_bills(DATE '2026-10-01', :n)
PRINT n
BEGIN
  SELECT bill_id INTO :bill FROM billing_records WHERE subscription_id = :sid AND bill_month = DATE '2026-10-01';
END;
/
PRINT bill
EXEC sp_record_payment(:bill)
SELECT bill_id, TO_CHAR(bill_month,'Mon-YYYY') AS bill_month, amount, status, paid_date FROM billing_records WHERE bill_id = :bill;

PROMPT === P3. sp_open_ticket : urgent cancellation request ===
EXEC sp_open_ticket(:cid, 'CANCELLATION', 'URGENT', 'Wants to cancel (demo)', :tid)
PRINT tid

PROMPT === T1. Trigger trg_tickets_ai created a retention CALL automatically ===
SELECT action_id, action_type, outcome, notes FROM retention_actions WHERE customer_id = :cid ORDER BY action_id;

PROMPT === P4. sp_cancel_subscription -> triggers trg_subscriptions_status / trg_subscriptions_audit ===
EXEC sp_cancel_subscription(:sid, 'Moving abroad (demo)')
SELECT customer_id, status FROM customers WHERE customer_id = :cid;
SELECT customer_id, rule_score, risk_band, segment FROM churn_scores WHERE customer_id = :cid;
SELECT action_id, action_type, outcome, notes FROM retention_actions WHERE customer_id = :cid ORDER BY action_id;

PROMPT === T2. Audit trail written by the triggers ===
SELECT audit_id, table_name, operation, record_key, old_value, new_value FROM audit_log
 WHERE record_key = TO_CHAR(:sid) OR operation = 'BULK_INSERT' ORDER BY audit_id;

PROMPT === T3. Business rules enforced by triggers and constraints (errors are expected) ===
PROMPT -- delete a customer
DELETE FROM customers WHERE customer_id = :cid;
PROMPT -- re-open a paid bill
UPDATE billing_records SET status = 'PENDING' WHERE bill_id = :bill;
PROMPT -- invalid e-mail
INSERT INTO customers (customer_id, full_name, email, gender, signup_date) VALUES ('X-1', 'No At', 'noatsign', 'Male', NULL);
PROMPT -- negative monthly charge
INSERT INTO subscriptions (customer_id, plan_id, contract_type_id, payment_method_id, start_date, monthly_charge, status)
VALUES ('7590-VHVEG', 1, 1, 1, DATE '2026-09-30', -5, 'SUSPENDED');
PROMPT -- cancel an already cancelled subscription
EXEC sp_cancel_subscription(:sid, 'again')
ROLLBACK;

PROMPT === Clean-up of demo data ===
DELETE FROM retention_actions WHERE customer_id = :cid;
DELETE FROM churn_scores WHERE customer_id = :cid;
DELETE FROM subscription_services WHERE subscription_id = :sid;
DELETE FROM billing_records WHERE bill_month = DATE '2026-10-01';
DELETE FROM subscriptions WHERE customer_id = :cid;
DELETE FROM support_tickets WHERE customer_id = :cid;
ALTER TRIGGER trg_customers_bd DISABLE;
DELETE FROM customers WHERE customer_id = :cid;
ALTER TRIGGER trg_customers_bd ENABLE;
COMMIT;
