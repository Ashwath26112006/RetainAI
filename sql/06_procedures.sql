-- =====================================================================
-- 06_procedures.sql : stored procedures (business operations)
-- =====================================================================
SET DEFINE OFF

-- (Re)computes risk score, band and segment of ONE customer
CREATE OR REPLACE PROCEDURE sp_score_customer (p_customer_id IN VARCHAR2) IS
  v_score NUMBER;
BEGIN
  v_score := fn_churn_risk_score(p_customer_id);
  IF v_score IS NULL THEN
    RETURN;
  END IF;
  MERGE INTO churn_scores t
  USING (SELECT p_customer_id AS cid FROM dual) s
     ON (t.customer_id = s.cid)
   WHEN MATCHED THEN UPDATE SET
        t.rule_score = v_score,
        t.risk_band  = fn_risk_band(v_score),
        t.segment    = fn_segment(p_customer_id, v_score),
        t.scored_at  = SYSDATE
   WHEN NOT MATCHED THEN INSERT (customer_id, rule_score, risk_band, segment, scored_at)
        VALUES (p_customer_id, v_score, fn_risk_band(v_score), fn_segment(p_customer_id, v_score), SYSDATE);
END sp_score_customer;
/

-- Scores every customer using an EXPLICIT cursor (row-by-row processing, periodic commit)
CREATE OR REPLACE PROCEDURE sp_score_all_customers (p_scored OUT NUMBER) IS
  CURSOR c_cust IS SELECT customer_id FROM customers ORDER BY customer_id;
  v_id customers.customer_id%TYPE;
BEGIN
  p_scored := 0;
  OPEN c_cust;
  LOOP
    FETCH c_cust INTO v_id;
    EXIT WHEN c_cust%NOTFOUND;
    sp_score_customer(v_id);
    p_scored := p_scored + 1;
    IF MOD(p_scored, 1000) = 0 THEN
      COMMIT;
    END IF;
  END LOOP;
  CLOSE c_cust;
  COMMIT;
END sp_score_all_customers;
/

-- Registers a new customer together with a first subscription and optional add-on services
CREATE OR REPLACE PROCEDURE sp_add_customer (
  p_full_name        IN  VARCHAR2,
  p_email            IN  VARCHAR2,
  p_gender           IN  VARCHAR2,
  p_senior           IN  CHAR,
  p_partner          IN  CHAR,
  p_dependents       IN  CHAR,
  p_plan_id          IN  NUMBER,
  p_contract_type_id IN  NUMBER,
  p_payment_method_id IN NUMBER,
  p_paperless        IN  CHAR,
  p_monthly_charge   IN  NUMBER,
  p_services         IN  VARCHAR2,          -- comma separated service ids, e.g. '2,5'
  p_customer_id      OUT VARCHAR2,
  p_subscription_id  OUT NUMBER) IS
  v_price   plans.base_price%TYPE;
  v_i       PLS_INTEGER := 1;
  v_tok     VARCHAR2(10);
BEGIN
  SELECT base_price INTO v_price FROM plans WHERE plan_id = p_plan_id;

  p_customer_id := 'RA-' || LPAD(seq_customer.NEXTVAL, 6, '0');
  INSERT INTO customers (customer_id, full_name, email, gender, senior_citizen, has_partner,
                         has_dependents, signup_date, status)
  VALUES (p_customer_id, p_full_name, p_email, p_gender, p_senior, p_partner, p_dependents,
          fn_ref_date, 'ACTIVE');

  INSERT INTO subscriptions (customer_id, plan_id, contract_type_id, payment_method_id,
                             paperless_billing, start_date, monthly_charge, status)
  VALUES (p_customer_id, p_plan_id, p_contract_type_id, p_payment_method_id,
          p_paperless, fn_ref_date, NVL(p_monthly_charge, v_price), 'ACTIVE')
  RETURNING subscription_id INTO p_subscription_id;

  LOOP
    v_tok := TRIM(REGEXP_SUBSTR(p_services, '[^,]+', 1, v_i));
    EXIT WHEN v_tok IS NULL;
    INSERT INTO subscription_services (subscription_id, service_id, added_on)
    VALUES (p_subscription_id, TO_NUMBER(v_tok), fn_ref_date);
    v_i := v_i + 1;
  END LOOP;

  sp_score_customer(p_customer_id);
  COMMIT;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    ROLLBACK;
    RAISE_APPLICATION_ERROR(-20001, 'Unknown plan id ' || p_plan_id);
  WHEN DUP_VAL_ON_INDEX THEN
    ROLLBACK;
    RAISE_APPLICATION_ERROR(-20002, 'E-mail address is already registered');
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_add_customer;
/

-- Cancels a subscription (the AFTER UPDATE trigger marks the customer CHURNED and queues a win-back action)
CREATE OR REPLACE PROCEDURE sp_cancel_subscription (p_subscription_id IN NUMBER, p_reason IN VARCHAR2) IS
  v_customer subscriptions.customer_id%TYPE;
BEGIN
  UPDATE subscriptions
     SET status = 'CANCELLED', end_date = fn_ref_date, cancel_reason = p_reason
   WHERE subscription_id = p_subscription_id AND status <> 'CANCELLED'
  RETURNING customer_id INTO v_customer;

  IF SQL%ROWCOUNT = 0 THEN
    RAISE_APPLICATION_ERROR(-20003, 'Subscription not found or already cancelled');
  END IF;
  sp_score_customer(v_customer);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_cancel_subscription;
/

-- Re-activates a cancelled subscription (win-back)
CREATE OR REPLACE PROCEDURE sp_reactivate_subscription (p_subscription_id IN NUMBER) IS
  v_customer subscriptions.customer_id%TYPE;
BEGIN
  UPDATE subscriptions
     SET status = 'ACTIVE', end_date = NULL, cancel_reason = NULL
   WHERE subscription_id = p_subscription_id AND status = 'CANCELLED'
  RETURNING customer_id INTO v_customer;

  IF SQL%ROWCOUNT = 0 THEN
    RAISE_APPLICATION_ERROR(-20006, 'Subscription not found or not cancelled');
  END IF;
  sp_score_customer(v_customer);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_reactivate_subscription;
/

-- Monthly billing run : one bill per ACTIVE subscription that has no bill for the month yet
CREATE OR REPLACE PROCEDURE sp_generate_bills (p_bill_month IN DATE, p_created OUT NUMBER) IS
  v_month DATE := TRUNC(NVL(p_bill_month, fn_ref_date), 'MM');
BEGIN
  INSERT INTO billing_records (subscription_id, bill_month, amount, status, due_date)
  SELECT s.subscription_id, v_month, s.monthly_charge, 'PENDING', LAST_DAY(v_month)
    FROM subscriptions s
   WHERE s.status = 'ACTIVE'
     AND TRUNC(s.start_date, 'MM') < v_month
     AND NOT EXISTS (SELECT 1 FROM billing_records b
                      WHERE b.subscription_id = s.subscription_id AND b.bill_month = v_month);
  p_created := SQL%ROWCOUNT;       -- implicit cursor attribute
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_generate_bills;
/

-- Registers a payment
CREATE OR REPLACE PROCEDURE sp_record_payment (p_bill_id IN NUMBER, p_paid_date IN DATE DEFAULT NULL) IS
BEGIN
  UPDATE billing_records
     SET status = 'PAID', paid_date = NVL(p_paid_date, fn_ref_date)
   WHERE bill_id = p_bill_id AND status <> 'PAID';
  IF SQL%ROWCOUNT = 0 THEN
    RAISE_APPLICATION_ERROR(-20004, 'Bill not found or already paid');
  END IF;
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_record_payment;
/

-- Flags every unpaid bill whose due date has passed
CREATE OR REPLACE PROCEDURE sp_mark_overdue_bills (p_updated OUT NUMBER) IS
BEGIN
  UPDATE billing_records SET status = 'OVERDUE'
   WHERE status = 'PENDING' AND due_date < fn_ref_date;
  p_updated := SQL%ROWCOUNT;
  COMMIT;
END sp_mark_overdue_bills;
/

-- Support tickets
CREATE OR REPLACE PROCEDURE sp_open_ticket (
  p_customer_id IN VARCHAR2, p_category IN VARCHAR2, p_priority IN VARCHAR2,
  p_subject IN VARCHAR2, p_ticket_id OUT NUMBER) IS
BEGIN
  INSERT INTO support_tickets (customer_id, category, priority, status, subject, assigned_to, opened_at)
  VALUES (p_customer_id, p_category, p_priority, 'OPEN', p_subject, 'Support Desk', fn_ref_date)
  RETURNING ticket_id INTO p_ticket_id;
  sp_score_customer(p_customer_id);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_open_ticket;
/

CREATE OR REPLACE PROCEDURE sp_close_ticket (p_ticket_id IN NUMBER, p_resolution IN VARCHAR2) IS
  v_customer support_tickets.customer_id%TYPE;
BEGIN
  UPDATE support_tickets
     SET status = 'CLOSED', resolution = p_resolution
   WHERE ticket_id = p_ticket_id AND status IN ('OPEN','IN_PROGRESS','RESOLVED')
  RETURNING customer_id INTO v_customer;
  IF SQL%ROWCOUNT = 0 THEN
    RAISE_APPLICATION_ERROR(-20007, 'Ticket not found or already closed');
  END IF;
  sp_score_customer(v_customer);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_close_ticket;
/

-- Retention campaigns -------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_create_campaign (
  p_name IN VARCHAR2, p_segment IN VARCHAR2, p_offer IN VARCHAR2, p_discount IN NUMBER,
  p_start IN DATE, p_end IN DATE, p_campaign_id OUT NUMBER) IS
BEGIN
  INSERT INTO retention_campaigns (campaign_name, target_segment, offer, discount_pct, start_date, end_date, status)
  VALUES (p_name, p_segment, p_offer, NVL(p_discount, 0), p_start, p_end, 'ACTIVE')
  RETURNING campaign_id INTO p_campaign_id;
  COMMIT;
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN
    ROLLBACK;
    RAISE_APPLICATION_ERROR(-20008, 'A campaign with this name already exists');
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_create_campaign;
/

-- Creates one retention action for every ACTIVE, HIGH-risk customer of the target segment (PARAMETERIZED cursor)
CREATE OR REPLACE PROCEDURE sp_plan_retention (p_campaign_id IN NUMBER, p_created OUT NUMBER) IS
  v_segment retention_campaigns.target_segment%TYPE;
  v_disc    retention_campaigns.discount_pct%TYPE;
  v_offer   retention_campaigns.offer%TYPE;
  v_start   retention_campaigns.start_date%TYPE;
  CURSOR c_targets (cp_segment VARCHAR2, cp_campaign NUMBER) IS
    SELECT cs.customer_id
      FROM churn_scores cs
      JOIN customers c ON c.customer_id = cs.customer_id
     WHERE c.status = 'ACTIVE'
       AND cs.risk_band = 'HIGH'
       AND (cp_segment = 'ANY' OR cs.segment = cp_segment)
       AND NOT EXISTS (SELECT 1 FROM retention_actions ra
                        WHERE ra.customer_id = cs.customer_id AND ra.campaign_id = cp_campaign);
BEGIN
  p_created := 0;
  SELECT target_segment, discount_pct, offer, start_date
    INTO v_segment, v_disc, v_offer, v_start
    FROM retention_campaigns WHERE campaign_id = p_campaign_id;

  FOR r IN c_targets(v_segment, p_campaign_id) LOOP
    INSERT INTO retention_actions (customer_id, campaign_id, action_type, action_date, outcome, notes)
    VALUES (r.customer_id, p_campaign_id,
            CASE WHEN v_disc > 0 THEN 'DISCOUNT' ELSE 'EMAIL' END,
            GREATEST(fn_ref_date, v_start), 'PENDING', v_offer);
    p_created := p_created + 1;
  END LOOP;
  COMMIT;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    ROLLBACK;
    RAISE_APPLICATION_ERROR(-20009, 'Campaign not found');
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_plan_retention;
/

-- Records the customer's answer; an accepted discount is applied exactly once, an accepted win-back re-activates the subscription
CREATE OR REPLACE PROCEDURE sp_record_outcome (p_action_id IN NUMBER, p_outcome IN VARCHAR2, p_notes IN VARCHAR2 DEFAULT NULL) IS
  v_old      retention_actions.outcome%TYPE;
  v_type     retention_actions.action_type%TYPE;
  v_customer retention_actions.customer_id%TYPE;
  v_campaign retention_actions.campaign_id%TYPE;
  v_disc     NUMBER := 0;
  v_sub      subscriptions.subscription_id%TYPE;
BEGIN
  SELECT outcome, action_type, customer_id, campaign_id
    INTO v_old, v_type, v_customer, v_campaign
    FROM retention_actions WHERE action_id = p_action_id FOR UPDATE;

  UPDATE retention_actions
     SET outcome = p_outcome, notes = NVL(p_notes, notes)
   WHERE action_id = p_action_id;

  IF p_outcome = 'ACCEPTED' AND v_old <> 'ACCEPTED' THEN
    IF v_type = 'DISCOUNT' AND v_campaign IS NOT NULL THEN
      SELECT discount_pct INTO v_disc FROM retention_campaigns WHERE campaign_id = v_campaign;
      UPDATE subscriptions
         SET monthly_charge = ROUND(monthly_charge * (1 - v_disc / 100), 2)
       WHERE customer_id = v_customer AND status = 'ACTIVE';
    ELSIF v_type = 'WIN_BACK' THEN
      SELECT subscription_id INTO v_sub
        FROM subscriptions
       WHERE customer_id = v_customer AND status = 'CANCELLED'
       ORDER BY end_date DESC, subscription_id DESC
       FETCH FIRST 1 ROW ONLY;
      UPDATE subscriptions SET status = 'ACTIVE', end_date = NULL, cancel_reason = NULL
       WHERE subscription_id = v_sub;
    END IF;
  END IF;
  sp_score_customer(v_customer);
  COMMIT;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    ROLLBACK;
    RAISE_APPLICATION_ERROR(-20011, 'Action not found or nothing to reactivate');
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_record_outcome;
/

-- ML integration -------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_save_ml_score (p_customer_id IN VARCHAR2, p_probability IN NUMBER, p_model IN VARCHAR2) IS
BEGIN
  UPDATE churn_scores SET ml_probability = p_probability, ml_model = p_model
   WHERE customer_id = p_customer_id;
  IF SQL%ROWCOUNT = 0 THEN
    RAISE_APPLICATION_ERROR(-20005, 'Customer ' || p_customer_id || ' has not been scored yet');
  END IF;
END sp_save_ml_score;
/

CREATE OR REPLACE PROCEDURE sp_log_ml_run (
  p_model IN VARCHAR2, p_train IN NUMBER, p_test IN NUMBER, p_acc IN NUMBER,
  p_prec IN NUMBER, p_rec IN NUMBER, p_f1 IN NUMBER, p_auc IN NUMBER, p_details IN VARCHAR2) IS
BEGIN
  INSERT INTO ml_model_runs (model_name, n_train, n_test, accuracy, precision_, recall, f1, roc_auc, details)
  VALUES (p_model, p_train, p_test, p_acc, p_prec, p_rec, p_f1, p_auc, SUBSTR(p_details, 1, 1000));
  COMMIT;
END sp_log_ml_run;
/

CREATE OR REPLACE PROCEDURE sp_set_reference_date (p_date IN DATE) IS
BEGIN
  UPDATE app_config SET config_value = TO_CHAR(p_date, 'YYYY-MM-DD') WHERE config_key = 'REFERENCE_DATE';
  COMMIT;
END sp_set_reference_date;
/

-- Synthetic seed data: support tickets and retention campaigns -------------------
CREATE OR REPLACE PROCEDURE sp_seed_support_tickets (p_created OUT NUMBER) IS
  v_ref DATE := fn_ref_date;
BEGIN
  INSERT INTO support_tickets (customer_id, category, priority, status, subject, resolution,
                               assigned_to, opened_at, closed_at)
  SELECT q.customer_id, q.category, q.priority, q.status,
         CASE q.category
           WHEN 'BILLING'      THEN 'Question about latest invoice'
           WHEN 'TECHNICAL'    THEN 'Connection drops / slow speed'
           WHEN 'SERVICE'      THEN 'Request to change add-on services'
           WHEN 'CANCELLATION' THEN 'Customer asks about cancelling the contract'
           ELSE 'General enquiry' END,
         CASE WHEN q.status IN ('RESOLVED','CLOSED') THEN 'Resolved by support agent' END,
         'Agent-' || TO_CHAR(MOD(q.h, 8) + 1),
         q.opened_at,
         CASE WHEN q.status IN ('RESOLVED','CLOSED') THEN LEAST(v_ref, q.opened_at + MOD(q.h, 9) + 1) END
    FROM (SELECT c.customer_id,
                 ORA_HASH(c.customer_id || t.k) AS h,
                 CASE WHEN MOD(ORA_HASH(c.customer_id || 'cat' || t.k), 100) < 30 THEN 'BILLING'
                      WHEN MOD(ORA_HASH(c.customer_id || 'cat' || t.k), 100) < 60 THEN 'TECHNICAL'
                      WHEN MOD(ORA_HASH(c.customer_id || 'cat' || t.k), 100) < 78 THEN 'SERVICE'
                      WHEN MOD(ORA_HASH(c.customer_id || 'cat' || t.k), 100) < 92 THEN 'CANCELLATION'
                      ELSE 'OTHER' END AS category,
                 CASE MOD(ORA_HASH(c.customer_id || 'pri' || t.k), 10)
                      WHEN 0 THEN 'URGENT' WHEN 1 THEN 'HIGH' WHEN 2 THEN 'HIGH'
                      WHEN 3 THEN 'LOW' WHEN 4 THEN 'LOW' ELSE 'MEDIUM' END AS priority,
                 CASE WHEN MOD(ORA_HASH(c.customer_id || 'sta' || t.k), 100) < 25 THEN 'OPEN'
                      WHEN MOD(ORA_HASH(c.customer_id || 'sta' || t.k), 100) < 35 THEN 'IN_PROGRESS'
                      WHEN MOD(ORA_HASH(c.customer_id || 'sta' || t.k), 100) < 50 THEN 'RESOLVED'
                      ELSE 'CLOSED' END AS status,
                 GREATEST(c.signup_date, v_ref - MOD(ORA_HASH(c.customer_id || 'dat' || t.k), 150)) AS opened_at
            FROM customers c
            CROSS JOIN (SELECT LEVEL AS k FROM dual CONNECT BY LEVEL <= 3) t
           WHERE MOD(ORA_HASH(c.customer_id || 'sel' || t.k), 100) <
                 CASE c.status WHEN 'CHURNED' THEN 40 ELSE 18 END) q;
  p_created := SQL%ROWCOUNT;
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_seed_support_tickets;
/

CREATE OR REPLACE PROCEDURE sp_seed_campaigns IS
  v_ref DATE := fn_ref_date;
BEGIN
  INSERT INTO retention_campaigns (campaign_name, target_segment, offer, discount_pct, start_date, end_date, status)
  VALUES ('Contract Upgrade Offer', 'At Risk', 'Switch to a 1-year contract and get 15% off', 15, v_ref, v_ref + 60, 'ACTIVE');
  INSERT INTO retention_campaigns (campaign_name, target_segment, offer, discount_pct, start_date, end_date, status)
  VALUES ('New Customer Welcome Call', 'New', 'Onboarding call and free Tech Support for 3 months', 0, v_ref, v_ref + 45, 'ACTIVE');
  INSERT INTO retention_campaigns (campaign_name, target_segment, offer, discount_pct, start_date, end_date, status)
  VALUES ('Auto-Pay Incentive', 'ANY', 'Move to automatic payment and save 5%', 5, v_ref, v_ref + 90, 'ACTIVE');
  INSERT INTO retention_campaigns (campaign_name, target_segment, offer, discount_pct, start_date, end_date, status)
  VALUES ('Loyalty Thank-You', 'Loyal', 'Free streaming add-on for 2 months', 0, v_ref, v_ref + 30, 'PLANNED');
  COMMIT;
END sp_seed_campaigns;
/
SELECT object_name, status FROM user_objects WHERE object_type = 'PROCEDURE' ORDER BY object_name;
