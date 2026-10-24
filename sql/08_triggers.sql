-- =====================================================================
-- 08_triggers.sql : triggers enforcing business rules and writing the audit trail
-- =====================================================================
SET DEFINE OFF

-- 1. customers: id generation, normalisation, validation -------------------------
CREATE OR REPLACE TRIGGER trg_customers_bi
BEFORE INSERT ON customers
FOR EACH ROW
BEGIN
  IF :NEW.customer_id IS NULL THEN
    :NEW.customer_id := 'RA-' || LPAD(seq_customer.NEXTVAL, 6, '0');
  END IF;
  :NEW.email       := LOWER(TRIM(:NEW.email));
  :NEW.full_name   := INITCAP(TRIM(:NEW.full_name));
  :NEW.signup_date := NVL(:NEW.signup_date, fn_ref_date);
  IF INSTR(:NEW.email, '@') < 2 THEN
    RAISE_APPLICATION_ERROR(-20020, 'Invalid e-mail address: ' || :NEW.email);
  END IF;
END trg_customers_bi;
/

-- 2. customers are never deleted - they become CHURNED -----------------------------
CREATE OR REPLACE TRIGGER trg_customers_bd
BEFORE DELETE ON customers
FOR EACH ROW
BEGIN
  RAISE_APPLICATION_ERROR(-20021, 'Customers cannot be deleted; cancel the subscription instead (status CHURNED)');
END trg_customers_bd;
/

-- 3. subscriptions: audit trail of every important change ---------------------------
CREATE OR REPLACE TRIGGER trg_subscriptions_audit
AFTER INSERT OR UPDATE OR DELETE ON subscriptions
FOR EACH ROW
BEGIN
  IF INSERTING THEN
    INSERT INTO audit_log (table_name, operation, record_key, new_value)
    VALUES ('SUBSCRIPTIONS', 'INSERT', TO_CHAR(:NEW.subscription_id),
            'customer=' || :NEW.customer_id || ', charge=' || :NEW.monthly_charge || ', status=' || :NEW.status);
  ELSIF UPDATING THEN
    IF :OLD.status <> :NEW.status OR :OLD.monthly_charge <> :NEW.monthly_charge
       OR :OLD.plan_id <> :NEW.plan_id OR :OLD.contract_type_id <> :NEW.contract_type_id THEN
      INSERT INTO audit_log (table_name, operation, record_key, old_value, new_value)
      VALUES ('SUBSCRIPTIONS', 'UPDATE', TO_CHAR(:NEW.subscription_id),
              'status=' || :OLD.status || ', charge=' || :OLD.monthly_charge || ', plan=' || :OLD.plan_id,
              'status=' || :NEW.status || ', charge=' || :NEW.monthly_charge || ', plan=' || :NEW.plan_id);
    END IF;
  ELSIF DELETING THEN
    INSERT INTO audit_log (table_name, operation, record_key, old_value)
    VALUES ('SUBSCRIPTIONS', 'DELETE', TO_CHAR(:OLD.subscription_id), 'customer=' || :OLD.customer_id);
  END IF;
END trg_subscriptions_audit;
/

-- 4. subscription status change cascades to the customer + creates a win-back action ---
CREATE OR REPLACE TRIGGER trg_subscriptions_status
AFTER UPDATE OF status ON subscriptions
FOR EACH ROW
WHEN (NEW.status <> OLD.status)
BEGIN
  IF :NEW.status = 'CANCELLED' THEN
    UPDATE customers SET status = 'CHURNED' WHERE customer_id = :NEW.customer_id;
    INSERT INTO retention_actions (customer_id, campaign_id, action_type, action_date, outcome, notes)
    VALUES (:NEW.customer_id, NULL, 'WIN_BACK', fn_ref_date, 'PENDING',
            'Auto-created on cancellation: ' || :NEW.cancel_reason);
  ELSIF :NEW.status = 'ACTIVE' AND :OLD.status = 'CANCELLED' THEN
    UPDATE customers SET status = 'ACTIVE' WHERE customer_id = :NEW.customer_id;
  END IF;
END trg_subscriptions_status;
/

-- 5. billing: row-level business rules -------------------------------------------------
CREATE OR REPLACE TRIGGER trg_billing_biu
BEFORE INSERT OR UPDATE ON billing_records
FOR EACH ROW
BEGIN
  IF INSERTING THEN
    :NEW.bill_month := TRUNC(:NEW.bill_month, 'MM');
    :NEW.due_date   := NVL(:NEW.due_date, LAST_DAY(:NEW.bill_month));
  END IF;
  IF UPDATING THEN
    IF :OLD.status = 'PAID' AND :NEW.status <> 'PAID' THEN
      RAISE_APPLICATION_ERROR(-20030, 'A paid bill cannot be re-opened');
    END IF;
    IF :OLD.status = 'PAID' AND :NEW.amount <> :OLD.amount THEN
      RAISE_APPLICATION_ERROR(-20031, 'The amount of a paid bill cannot be changed');
    END IF;
  END IF;
  IF :NEW.status = 'PAID' AND :NEW.paid_date IS NULL THEN
    :NEW.paid_date := fn_ref_date;
  END IF;
  IF :NEW.status <> 'PAID' THEN
    :NEW.paid_date := NULL;
  END IF;
END trg_billing_biu;
/

-- 6. billing: COMPOUND trigger - one audit row per bulk insert statement -----------------
CREATE OR REPLACE TRIGGER trg_billing_compound
FOR INSERT ON billing_records
COMPOUND TRIGGER
  g_rows  PLS_INTEGER := 0;
  g_total NUMBER      := 0;

  AFTER EACH ROW IS
  BEGIN
    g_rows  := g_rows + 1;
    g_total := g_total + :NEW.amount;
  END AFTER EACH ROW;

  AFTER STATEMENT IS
  BEGIN
    IF g_rows > 0 THEN
      INSERT INTO audit_log (table_name, operation, record_key, new_value)
      VALUES ('BILLING_RECORDS', 'BULK_INSERT', NULL, g_rows || ' bills, total amount ' || g_total);
    END IF;
    g_rows  := 0;
    g_total := 0;
  END AFTER STATEMENT;
END trg_billing_compound;
/

-- 7. tickets: defaults, close-date handling, no re-opening --------------------------------
CREATE OR REPLACE TRIGGER trg_tickets_biu
BEFORE INSERT OR UPDATE ON support_tickets
FOR EACH ROW
BEGIN
  IF INSERTING THEN
    :NEW.opened_at := NVL(:NEW.opened_at, fn_ref_date);
  END IF;
  IF UPDATING AND :OLD.status IN ('RESOLVED','CLOSED') AND :NEW.status IN ('OPEN','IN_PROGRESS') THEN
    RAISE_APPLICATION_ERROR(-20041, 'A closed ticket cannot be re-opened; open a new ticket');
  END IF;
  IF :NEW.status IN ('RESOLVED','CLOSED') THEN
    :NEW.closed_at := NVL(:NEW.closed_at, GREATEST(fn_ref_date, :NEW.opened_at));
  ELSE
    :NEW.closed_at := NULL;
  END IF;
  IF :NEW.closed_at < :NEW.opened_at THEN
    RAISE_APPLICATION_ERROR(-20040, 'Close date cannot be earlier than the open date');
  END IF;
END trg_tickets_biu;
/

-- 8. an urgent/high cancellation ticket immediately queues a retention call ---------------
CREATE OR REPLACE TRIGGER trg_tickets_ai
AFTER INSERT ON support_tickets
FOR EACH ROW
WHEN (NEW.category = 'CANCELLATION' AND NEW.priority IN ('HIGH','URGENT'))
BEGIN
  INSERT INTO retention_actions (customer_id, campaign_id, action_type, action_date, outcome, notes)
  VALUES (:NEW.customer_id, NULL, 'CALL', :NEW.opened_at, 'PENDING',
          'Auto-created from ticket #' || :NEW.ticket_id || ' (' || :NEW.priority || ' cancellation request)');
END trg_tickets_ai;
/

-- 9. retention actions cannot be attached to a CLOSED campaign ------------------------------
CREATE OR REPLACE TRIGGER trg_actions_bi
BEFORE INSERT ON retention_actions
FOR EACH ROW
DECLARE
  v_status retention_campaigns.status%TYPE;
BEGIN
  :NEW.action_date := NVL(:NEW.action_date, fn_ref_date);
  IF :NEW.campaign_id IS NOT NULL THEN
    SELECT status INTO v_status FROM retention_campaigns WHERE campaign_id = :NEW.campaign_id;
    IF v_status = 'CLOSED' THEN
      RAISE_APPLICATION_ERROR(-20050, 'Campaign is closed; no more actions can be added');
    END IF;
  END IF;
END trg_actions_bi;
/

-- 10. movement between risk bands is audited ---------------------------------------------------
CREATE OR REPLACE TRIGGER trg_scores_band_change
AFTER UPDATE OF risk_band ON churn_scores
FOR EACH ROW
WHEN (NEW.risk_band <> OLD.risk_band)
BEGIN
  INSERT INTO audit_log (table_name, operation, record_key, old_value, new_value)
  VALUES ('CHURN_SCORES', 'BAND_CHANGE', :NEW.customer_id,
          :OLD.risk_band || ' (' || :OLD.rule_score || ')', :NEW.risk_band || ' (' || :NEW.rule_score || ')');
END trg_scores_band_change;
/
SELECT trigger_name, trigger_type, triggering_event, table_name, status FROM user_triggers ORDER BY trigger_name;
