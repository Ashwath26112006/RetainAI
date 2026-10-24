-- =====================================================================
-- 12_tests.sql : automated test cases (each result is stored in TEST_RESULTS)
-- Test data are created through the public API and removed again at the end;
-- the AUDIT_LOG rows written by the triggers are kept as evidence.
-- =====================================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 0
SET FEEDBACK OFF

CREATE OR REPLACE PROCEDURE sp_log_test (
  p_id IN VARCHAR2, p_desc IN VARCHAR2, p_input IN VARCHAR2,
  p_expected IN VARCHAR2, p_actual IN VARCHAR2, p_pass IN BOOLEAN) IS
  PRAGMA AUTONOMOUS_TRANSACTION;
  v_status VARCHAR2(4) := CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END;
BEGIN
  DELETE FROM test_results WHERE tc_id = p_id;
  INSERT INTO test_results (tc_id, description, input_text, expected, actual, status)
  VALUES (p_id, p_desc, SUBSTR(p_input, 1, 300), SUBSTR(p_expected, 1, 300), SUBSTR(p_actual, 1, 400),
          v_status);
  COMMIT;
END sp_log_test;
/

DELETE FROM test_results;
COMMIT;

DECLARE
  v_ref     DATE := fn_ref_date;
  v_stamp   VARCHAR2(20) := TO_CHAR(SYSDATE, 'HH24MISS');
  v_email   VARCHAR2(100) := 'TC.User.' || TO_CHAR(SYSDATE, 'HH24MISS') || '@Test.Example';
  v_cid     VARCHAR2(20);
  v_sid     NUMBER;
  v_bill    NUMBER;
  v_ticket  NUMBER;
  v_camp    NUMBER;
  v_act     NUMBER;
  v_actcust VARCHAR2(20);
  v_charge0 NUMBER;
  v_aid     NUMBER;
  v_charge1 NUMBER;
  v_charge2 NUMBER;
  v_a       VARCHAR2(400);
  v_n       NUMBER;
  v_m       NUMBER;
  v_x       NUMBER;
  v_s       VARCHAR2(100);
  v_s2      VARCHAR2(100);
  v_hi      VARCHAR2(20);
  v_lo      VARCHAR2(20);
  v_rc      SYS_REFCURSOR;
  v_ids     NUMBER;
  v_sc1     NUMBER;
  v_sc2     NUMBER;
  v_cur_cid VARCHAR2(20);
  v_cur_nm  VARCHAR2(80);
  v_cur_ct  VARCHAR2(30);
  v_cur_pm  VARCHAR2(40);
  v_cur_tn  NUMBER;
  v_cur_ch  NUMBER;
  v_cur_sc  NUMBER;
  v_cur_bd  VARCHAR2(10);
  v_cur_sg  VARCHAR2(20);
  v_cur_ml  NUMBER;
  v_cur_rk  NUMBER;
BEGIN
  ---------------------------------------------------------------- TC01
  BEGIN
    sp_add_customer('tc test user', v_email, 'Female', 'N', 'Y', 'N', 1, 1, 1, 'Y', NULL, '2,5', v_cid, v_sid);
    SELECT COUNT(*) INTO v_n FROM customers WHERE customer_id = v_cid;
    SELECT COUNT(*) INTO v_m FROM churn_scores WHERE customer_id = v_cid;
    SELECT COUNT(*) INTO v_x FROM subscription_services WHERE subscription_id = v_sid;
    v_a := 'customer rows=' || v_n || ', score rows=' || v_m || ', add-ons=' || v_x || ', id=' || v_cid;
    sp_log_test('TC01', 'Register customer + subscription + add-ons with sp_add_customer',
                'plan 1, month-to-month, e-mail mixed case, services 2,5',
                'customer rows=1, score rows=1, add-ons=2', v_a, v_n = 1 AND v_m = 1 AND v_x = 2);
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC01', 'Register customer with sp_add_customer', 'valid data', 'customer created', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC02
  BEGIN
    SELECT email || ' / ' || full_name INTO v_a FROM customers WHERE customer_id = v_cid;
    sp_log_test('TC02', 'Trigger trg_customers_bi normalises e-mail (lower case) and name (INITCAP)',
                v_email || ' / tc test user', LOWER(v_email) || ' / Tc Test User', v_a,
                v_a = LOWER(v_email) || ' / Tc Test User');
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC02', 'Trigger normalises e-mail and name', v_email, 'normalised', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC03
  BEGIN
    sp_add_customer('Duplicate Person', LOWER(v_email), 'Male', 'N', 'N', 'N', 1, 1, 1, 'N', NULL, NULL, v_s, v_x);
    v_a := 'no error';
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 80);
  END;
  sp_log_test('TC03', 'Duplicate e-mail rejected (UNIQUE constraint -> ORA-20002)', 'same e-mail again',
              'ORA-20002: E-mail address is already registered', v_a, v_a LIKE 'ORA-20002%');

  ---------------------------------------------------------------- TC04
  BEGIN
    INSERT INTO customers (customer_id, full_name, email, gender, signup_date) VALUES (NULL, 'No At', 'noatsign', 'Male', NULL);
    v_a := 'no error';
    ROLLBACK;
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 80);
  END;
  sp_log_test('TC04', 'Trigger rejects invalid e-mail address', 'email = noatsign',
              'ORA-20020: Invalid e-mail address', v_a, v_a LIKE 'ORA-20020%');

  ---------------------------------------------------------------- TC05
  BEGIN
    INSERT INTO subscriptions (customer_id, plan_id, contract_type_id, payment_method_id, start_date, monthly_charge, status)
    VALUES (v_cid, 1, 1, 1, v_ref, -5, 'SUSPENDED');
    v_a := 'no error';
    ROLLBACK;
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC05', 'CHECK constraint: negative monthly charge rejected', 'monthly_charge = -5',
              'ORA-02290: check constraint violated', v_a, v_a LIKE 'ORA-02290%');

  ---------------------------------------------------------------- TC06
  BEGIN
    INSERT INTO support_tickets (customer_id, category, priority, subject, opened_at)
    VALUES ('NO-SUCH-ID', 'BILLING', 'LOW', 'x', v_ref);
    v_a := 'no error';
    ROLLBACK;
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC06', 'FOREIGN KEY: ticket for unknown customer rejected', 'customer_id = NO-SUCH-ID',
              'ORA-02291: integrity constraint violated - parent key not found', v_a, v_a LIKE 'ORA-02291%');

  ---------------------------------------------------------------- TC07
  BEGIN
    INSERT INTO subscriptions (customer_id, plan_id, contract_type_id, payment_method_id, start_date, monthly_charge, status)
    VALUES (v_cid, 1, 1, 1, v_ref, 20, 'ACTIVE');
    v_a := 'no error';
    ROLLBACK;
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC07', 'Business rule: only one ACTIVE subscription per customer (function-based unique index)',
              'second ACTIVE subscription for ' || v_cid, 'ORA-00001: unique constraint violated', v_a, v_a LIKE 'ORA-00001%');

  ---------------------------------------------------------------- TC08
  BEGIN
    DELETE FROM customers WHERE customer_id = v_cid;
    v_a := 'no error';
    ROLLBACK;
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC08', 'Trigger trg_customers_bd blocks deletion of customers', 'DELETE FROM customers',
              'ORA-20021: Customers cannot be deleted', v_a, v_a LIKE 'ORA-20021%');

  ---------------------------------------------------------------- TC09
  BEGIN
    SELECT customer_id INTO v_hi FROM v_customer_current
     WHERE contract_name = 'Month-to-month' AND internet_service = 'Fiber optic'
       AND payment_method = 'Electronic check' AND tenure_months <= 6 AND customer_status = 'ACTIVE'
     ORDER BY customer_id FETCH FIRST 1 ROW ONLY;
    SELECT customer_id INTO v_lo FROM v_customer_current
     WHERE contract_name = 'Two year' AND internet_service = 'DSL' AND tenure_months >= 60
       AND payment_method = 'Bank transfer (automatic)' AND customer_status = 'ACTIVE'
     ORDER BY customer_id FETCH FIRST 1 ROW ONLY;
    v_sc1 := fn_churn_risk_score(v_hi);
    v_sc2 := fn_churn_risk_score(v_lo);
    sp_log_test('TC09', 'fn_churn_risk_score separates a risky profile from a loyal one',
                v_hi || ' (M2M, fiber, e-check, new) vs ' || v_lo || ' (2-yr, DSL, auto-pay, 60+ months)',
                'risky >= 60 and loyal < 35', 'risky=' || v_sc1 || ', loyal=' || v_sc2, v_sc1 >= 60 AND v_sc2 < 35);
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC09', 'fn_churn_risk_score separates risky from loyal', 'sample customers', 'risky>=60, loyal<35', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC10
  v_a := fn_risk_band(34) || '/' || fn_risk_band(35) || '/' || fn_risk_band(59) || '/' || fn_risk_band(60);
  sp_log_test('TC10', 'fn_risk_band boundary values', '34, 35, 59, 60', 'LOW/MEDIUM/MEDIUM/HIGH', v_a,
              v_a = 'LOW/MEDIUM/MEDIUM/HIGH');

  ---------------------------------------------------------------- TC11
  v_n := fn_tenure_months('5575-GNVDE');
  v_x := fn_lifetime_value('5575-GNVDE');
  sp_log_test('TC11', 'fn_tenure_months and fn_lifetime_value for a known customer', '5575-GNVDE (tenure 34, 56.95/month)',
              'tenure=34, lifetime value=1936.3', 'tenure=' || v_n || ', lifetime value=' || v_x,
              v_n = 34 AND v_x = 1936.3);

  ---------------------------------------------------------------- TC12
  BEGIN
    SELECT customer_id INTO v_s FROM customers WHERE status = 'CHURNED' ORDER BY customer_id FETCH FIRST 1 ROW ONLY;
    v_a := fn_segment(v_s);
    sp_log_test('TC12', 'fn_segment returns Lost for a churned customer', v_s, 'Lost', v_a, v_a = 'Lost');
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC12', 'fn_segment returns Lost for churned customer', 'churned customer', 'Lost', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC13  (cancel -> trigger cascade)
  BEGIN
    sp_cancel_subscription(v_sid, 'Moving abroad (test)');
    SELECT status INTO v_s FROM customers WHERE customer_id = v_cid;
    SELECT COUNT(*) INTO v_n FROM retention_actions WHERE customer_id = v_cid AND action_type = 'WIN_BACK';
    SELECT segment INTO v_s2 FROM churn_scores WHERE customer_id = v_cid;
    v_a := 'customer status=' || v_s || ', win-back actions=' || v_n || ', segment=' || v_s2;
    sp_log_test('TC13', 'sp_cancel_subscription + trigger trg_subscriptions_status cascade', 'subscription ' || v_sid,
                'customer status=CHURNED, win-back actions=1, segment=Lost', v_a,
                v_s = 'CHURNED' AND v_n = 1 AND v_s2 = 'Lost');
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC13', 'sp_cancel_subscription cascade', 'subscription ' || v_sid, 'CHURNED', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC14
  BEGIN
    sp_cancel_subscription(v_sid, 'again');
    v_a := 'no error';
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC14', 'Cancelling an already cancelled subscription raises a business error', 'subscription ' || v_sid,
              'ORA-20003: Subscription not found or already cancelled', v_a, v_a LIKE 'ORA-20003%');

  ---------------------------------------------------------------- TC15
  BEGIN
    sp_reactivate_subscription(v_sid);
    SELECT status INTO v_s FROM customers WHERE customer_id = v_cid;
    SELECT COUNT(*) INTO v_n FROM audit_log WHERE table_name = 'SUBSCRIPTIONS' AND record_key = TO_CHAR(v_sid);
    v_a := 'customer status=' || v_s || ', audit rows for subscription=' || v_n;
    sp_log_test('TC15', 'sp_reactivate_subscription (win-back) and audit trail trigger trg_subscriptions_audit',
                'subscription ' || v_sid, 'customer status=ACTIVE, audit rows=3 (insert, cancel, reactivate)', v_a,
                v_s = 'ACTIVE' AND v_n = 3);
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC15', 'sp_reactivate_subscription', 'subscription ' || v_sid, 'ACTIVE', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC16/17  (billing run)
  BEGIN
    SELECT NVL(MAX(audit_id), 0) INTO v_aid FROM audit_log;
    sp_generate_bills(DATE '2026-10-01', v_n);
    sp_generate_bills(DATE '2026-10-01', v_m);
    SELECT COUNT(*) INTO v_x FROM subscriptions WHERE status = 'ACTIVE' AND TRUNC(start_date, 'MM') < DATE '2026-10-01';
    v_a := 'first run=' || v_n || ', second run=' || v_m || ', active subscriptions=' || v_x;
    sp_log_test('TC16', 'sp_generate_bills creates one bill per active subscription and is idempotent', 'month = Oct-2026, run twice',
                'first run = number of active subscriptions, second run = 0', v_a, v_n = v_x AND v_m = 0 AND v_n > 0);
    SELECT COUNT(*) INTO v_x FROM audit_log WHERE table_name = 'BILLING_RECORDS' AND operation = 'BULK_INSERT'
       AND audit_id > v_aid AND new_value LIKE v_n || ' bills%';
    sp_log_test('TC17', 'Compound trigger writes ONE audit row for the whole bulk insert', 'bulk insert of ' || v_n || ' bills',
                'exactly 1 BULK_INSERT audit row for this statement', 'audit rows=' || v_x, v_x = 1);
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC16', 'sp_generate_bills', 'Oct-2026', 'bills created', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC18..21 (payment rules)
  BEGIN
    SELECT bill_id INTO v_bill FROM billing_records WHERE subscription_id = v_sid AND bill_month = DATE '2026-10-01';
    sp_record_payment(v_bill);
    SELECT status || ' on ' || TO_CHAR(paid_date, 'DD-Mon-YYYY') INTO v_a FROM billing_records WHERE bill_id = v_bill;
    sp_log_test('TC18', 'sp_record_payment marks the bill PAID and sets the paid date', 'bill ' || v_bill,
                'PAID on ' || TO_CHAR(v_ref, 'DD-Mon-YYYY'), v_a, v_a = 'PAID on ' || TO_CHAR(v_ref, 'DD-Mon-YYYY'));
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC18', 'sp_record_payment', 'bill', 'PAID', SQLERRM, FALSE);
  END;
  BEGIN
    UPDATE billing_records SET status = 'PENDING' WHERE bill_id = v_bill;
    v_a := 'no error';
    ROLLBACK;
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC19', 'Trigger trg_billing_biu: a paid bill cannot be re-opened', 'UPDATE status = PENDING on paid bill',
              'ORA-20030: A paid bill cannot be re-opened', v_a, v_a LIKE 'ORA-20030%');
  BEGIN
    UPDATE billing_records SET amount = amount + 1 WHERE bill_id = v_bill;
    v_a := 'no error';
    ROLLBACK;
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC20', 'Trigger trg_billing_biu: amount of a paid bill is immutable', 'UPDATE amount on paid bill',
              'ORA-20031: The amount of a paid bill cannot be changed', v_a, v_a LIKE 'ORA-20031%');
  BEGIN
    sp_record_payment(v_bill);
    v_a := 'no error';
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC21', 'Paying an already paid bill raises a business error', 'bill ' || v_bill,
              'ORA-20004: Bill not found or already paid', v_a, v_a LIKE 'ORA-20004%');

  ---------------------------------------------------------------- TC22 (overdue boundary)
  sp_mark_overdue_bills(v_n);
  sp_log_test('TC22', 'sp_mark_overdue_bills - boundary: bills due ON the business date are not overdue', 'due_date = reference date',
              'rows flagged = 0', 'rows flagged=' || v_n, v_n = 0);

  ---------------------------------------------------------------- TC23/24 (tickets)
  BEGIN
    sp_open_ticket(v_cid, 'CANCELLATION', 'URGENT', 'Wants to cancel (test)', v_ticket);
    SELECT COUNT(*) INTO v_n FROM retention_actions
     WHERE customer_id = v_cid AND action_type = 'CALL' AND notes LIKE 'Auto-created from ticket #' || v_ticket || '%';
    sp_log_test('TC23', 'Trigger trg_tickets_ai: urgent cancellation ticket queues a retention CALL', 'ticket ' || v_ticket,
                'retention call actions = 1', 'retention call actions=' || v_n, v_n = 1);
    sp_close_ticket(v_ticket, 'Offered discount, customer stays');
    SELECT status || ', closed_at=' || TO_CHAR(closed_at, 'DD-Mon-YYYY') INTO v_a FROM support_tickets WHERE ticket_id = v_ticket;
    BEGIN
      UPDATE support_tickets SET status = 'OPEN' WHERE ticket_id = v_ticket;
      v_s := 'no error';
      ROLLBACK;
    EXCEPTION WHEN OTHERS THEN
      v_s := SUBSTR(SQLERRM, 1, 70);
    END;
    sp_log_test('TC24', 'sp_close_ticket sets closed_at; trigger blocks re-opening a closed ticket', 'ticket ' || v_ticket,
                'CLOSED, closed_at=' || TO_CHAR(v_ref, 'DD-Mon-YYYY') || ' ; ORA-20041', v_a || ' ; ' || v_s,
                v_a = 'CLOSED, closed_at=' || TO_CHAR(v_ref, 'DD-Mon-YYYY') AND v_s LIKE 'ORA-20041%');
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC23', 'ticket procedures and triggers', 'ticket', 'ok', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC25..28 (package)
  BEGIN
    SELECT ROUND(100 * SUM(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END) / COUNT(*), 2)
      INTO v_x FROM v_customer_current WHERE contract_name = 'Month-to-month';
    v_n := pkg_retainai.churn_rate('Month-to-month');
    sp_log_test('TC25', 'pkg_retainai.churn_rate (month-to-month) equals an independent SQL calculation', 'Month-to-month',
                'package value = SQL value (' || v_x || ')', 'package=' || v_n || ', sql=' || v_x, v_n = v_x);
    SELECT ROUND(100 * SUM(CASE WHEN status = 'CHURNED' THEN 1 ELSE 0 END) / COUNT(*), 2) INTO v_x FROM customers;
    v_n := pkg_retainai.churn_rate;
    sp_log_test('TC26', 'pkg_retainai.churn_rate overall equals an independent SQL calculation', 'no filter',
                'package value = SQL value (' || v_x || ')', 'package=' || v_n || ', sql=' || v_x, v_n = v_x);
    SELECT SUM(monthly_charge) INTO v_x FROM subscriptions WHERE status = 'ACTIVE';
    v_n := pkg_retainai.monthly_recurring_revenue;
    v_m := pkg_retainai.revenue_at_risk;
    sp_log_test('TC27', 'pkg_retainai MRR matches SQL and 0 < revenue at risk <= MRR', 'MRR and revenue at risk',
                'MRR=' || v_x || ' ; 0 < at-risk <= MRR', 'MRR=' || v_n || ', at-risk=' || v_m,
                v_n = v_x AND v_m > 0 AND v_m <= v_n);
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC25', 'package KPI functions', 'n/a', 'values match', SQLERRM, FALSE);
  END;
  BEGIN
    pkg_retainai.churn_breakdown('COLOR', v_rc);
    v_a := 'no error';
  EXCEPTION WHEN OTHERS THEN
    v_a := SUBSTR(SQLERRM, 1, 100);
  END;
  sp_log_test('TC28', 'pkg_retainai.churn_breakdown rejects an unknown dimension', 'dimension = COLOR',
              'ORA-20010: Unknown dimension', v_a, v_a LIKE 'ORA-20010%');

  ---------------------------------------------------------------- TC29 (ref cursor)
  BEGIN
    pkg_retainai.high_risk_report(5, v_rc);
    v_n := 0; v_m := 0;
    LOOP
      FETCH v_rc INTO v_cur_cid, v_cur_nm, v_cur_ct, v_cur_pm, v_cur_tn, v_cur_ch, v_cur_sc, v_cur_bd, v_cur_sg, v_cur_ml, v_cur_rk;
      EXIT WHEN v_rc%NOTFOUND;
      v_n := v_n + 1;
      IF v_cur_bd <> 'HIGH' OR v_cur_rk > 5 THEN v_m := v_m + 1; END IF;
    END LOOP;
    CLOSE v_rc;
    sp_log_test('TC29', 'High-risk report (REF CURSOR) returns the top-ranked HIGH-risk customers only', 'limit = 5',
                'rows >= 5, all HIGH band, rank <= 5', 'rows=' || v_n || ', violations=' || v_m, v_n >= 5 AND v_m = 0);
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC29', 'high_risk_report REF CURSOR', 'limit = 5', 'rows >= 5', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC30 (explicit cursor batch scoring)
  BEGIN
    sp_score_all_customers(v_n);
    SELECT COUNT(*) INTO v_m FROM customers;
    SELECT COUNT(*) INTO v_x FROM churn_scores;
    sp_log_test('TC30', 'sp_score_all_customers (explicit cursor loop) scores every customer', 'all customers',
                'scored = customers = churn_score rows', 'scored=' || v_n || ', customers=' || v_m || ', score rows=' || v_x,
                v_n = v_m AND v_x = v_m);
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC30', 'sp_score_all_customers', 'all customers', 'all scored', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC31 (ML score storage)
  BEGIN
    sp_save_ml_score(v_cid, 0.8765, 'test-model');
    SELECT TO_CHAR(ml_probability) || ' / ' || ml_model INTO v_a FROM churn_scores WHERE customer_id = v_cid;
    BEGIN
      sp_save_ml_score('NO-SUCH-ID', 0.5, 'test-model');
      v_s := 'no error';
    EXCEPTION WHEN OTHERS THEN
      v_s := SUBSTR(SQLERRM, 1, 60);
    END;
    sp_log_test('TC31', 'sp_save_ml_score stores a model probability; unknown customer is rejected', '0.8765 for ' || v_cid,
                '.8765 / test-model ; ORA-20005', v_a || ' ; ' || v_s, v_a = '.8765 / test-model' AND v_s LIKE 'ORA-20005%');
    ROLLBACK;
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC31', 'sp_save_ml_score', 'n/a', 'stored', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- TC32..34 (retention campaign)
  BEGIN
    sp_create_campaign('TC Campaign ' || v_stamp, 'ANY', 'Test offer: 10% off', 10, v_ref, v_ref + 30, v_camp);
    SELECT COUNT(*) INTO v_x FROM churn_scores cs JOIN customers c ON c.customer_id = cs.customer_id
     WHERE c.status = 'ACTIVE' AND cs.risk_band = 'HIGH';
    sp_plan_retention(v_camp, v_n);
    sp_plan_retention(v_camp, v_m);
    sp_log_test('TC32', 'sp_plan_retention (parameterized cursor) targets every active HIGH-risk customer once',
                'campaign ' || v_camp || ', run twice', 'first run = ' || v_x || ' (all active HIGH-risk), second run = 0',
                'first=' || v_n || ', second=' || v_m, v_n = v_x AND v_m = 0 AND v_n > 0);

    SELECT action_id, customer_id INTO v_act, v_actcust FROM retention_actions
     WHERE campaign_id = v_camp ORDER BY action_id FETCH FIRST 1 ROW ONLY;
    SELECT monthly_charge INTO v_charge0 FROM subscriptions WHERE customer_id = v_actcust AND status = 'ACTIVE';
    sp_record_outcome(v_act, 'ACCEPTED');
    SELECT monthly_charge INTO v_charge1 FROM subscriptions WHERE customer_id = v_actcust AND status = 'ACTIVE';
    sp_record_outcome(v_act, 'ACCEPTED');
    SELECT monthly_charge INTO v_charge2 FROM subscriptions WHERE customer_id = v_actcust AND status = 'ACTIVE';
    sp_log_test('TC33', 'sp_record_outcome applies an accepted 10% discount exactly once', 'action ' || v_act || ' accepted twice',
                'charge ' || v_charge0 || ' -> ' || ROUND(v_charge0 * 0.9, 2) || ' -> unchanged',
                'charge ' || v_charge0 || ' -> ' || v_charge1 || ' -> ' || v_charge2,
                v_charge1 = ROUND(v_charge0 * 0.9, 2) AND v_charge2 = v_charge1);

    UPDATE retention_campaigns SET status = 'CLOSED' WHERE campaign_id = v_camp;
    BEGIN
      INSERT INTO retention_actions (customer_id, campaign_id, action_type, action_date, outcome)
      VALUES (v_cid, v_camp, 'CALL', v_ref, 'PENDING');
      v_a := 'no error';
    EXCEPTION WHEN OTHERS THEN
      v_a := SUBSTR(SQLERRM, 1, 80);
    END;
    sp_log_test('TC34', 'Trigger trg_actions_bi: no actions can be added to a CLOSED campaign', 'insert action into closed campaign',
                'ORA-20050: Campaign is closed', v_a, v_a LIKE 'ORA-20050%');
    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    sp_log_test('TC32', 'retention campaign procedures', 'n/a', 'ok', SQLERRM, FALSE);
  END;

  ---------------------------------------------------------------- clean-up of test data
  BEGIN
    -- restore the discounted customer of TC33
    IF v_actcust IS NOT NULL THEN
      UPDATE subscriptions SET monthly_charge = v_charge0 WHERE customer_id = v_actcust AND status = 'ACTIVE';
    END IF;
    DELETE FROM retention_actions WHERE campaign_id = v_camp OR customer_id = v_cid;
    DELETE FROM retention_campaigns WHERE campaign_id = v_camp;
    DELETE FROM churn_scores WHERE customer_id = v_cid;
    DELETE FROM subscription_services WHERE subscription_id = v_sid;
    DELETE FROM billing_records WHERE bill_month = DATE '2026-10-01';
    DELETE FROM subscriptions WHERE customer_id = v_cid;
    DELETE FROM support_tickets WHERE customer_id = v_cid;
    EXECUTE IMMEDIATE 'ALTER TRIGGER trg_customers_bd DISABLE';
    DELETE FROM customers WHERE customer_id = v_cid;
    EXECUTE IMMEDIATE 'ALTER TRIGGER trg_customers_bd ENABLE';
    COMMIT;
    IF v_actcust IS NOT NULL THEN
      sp_score_customer(v_actcust);
      COMMIT;
    END IF;
    DBMS_OUTPUT.PUT_LINE('Test data removed.');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Clean-up problem: ' || SQLERRM);
    BEGIN EXECUTE IMMEDIATE 'ALTER TRIGGER trg_customers_bd ENABLE'; EXCEPTION WHEN OTHERS THEN NULL; END;
  END;
END;
/

SET FEEDBACK ON
SET PAGESIZE 100
PROMPT === Automated test results (table TEST_RESULTS) ===
COLUMN tc_id FORMAT A6
COLUMN description FORMAT A70 WORD_WRAPPED
COLUMN actual FORMAT A60 WORD_WRAPPED
COLUMN status FORMAT A6
SELECT tc_id, description, actual, status FROM test_results ORDER BY tc_id;
SELECT COUNT(*) AS total_tests, SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END) AS passed,
       SUM(CASE WHEN status = 'FAIL' THEN 1 ELSE 0 END) AS failed FROM test_results;

