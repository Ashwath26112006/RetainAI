-- =====================================================================
-- 10_cursors_demo.sql : implicit, explicit, parameterized, BULK COLLECT and REF cursors
-- =====================================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 160
SET PAGESIZE 100
SET FEEDBACK ON

PROMPT ======================================================================
PROMPT Demo 1 : IMPLICIT cursor - SQL%FOUND / SQL%ROWCOUNT (transaction rolled back)
PROMPT ======================================================================
BEGIN
  UPDATE billing_records SET status = status WHERE status = 'PENDING';
  IF SQL%FOUND THEN
    DBMS_OUTPUT.PUT_LINE('PENDING bills touched by the UPDATE : ' || SQL%ROWCOUNT);
  ELSE
    DBMS_OUTPUT.PUT_LINE('No PENDING bills found');
  END IF;
  ROLLBACK;
END;
/

PROMPT ======================================================================
PROMPT Demo 2 : EXPLICIT cursor - OPEN / FETCH / %NOTFOUND / %ROWCOUNT / CLOSE
PROMPT          Top-5 revenue-at-risk customers (active, HIGH risk)
PROMPT ======================================================================
DECLARE
  CURSOR c_top IS
    SELECT v.customer_id, v.full_name, cs.rule_score, v.monthly_charge
      FROM v_customer_current v
      JOIN churn_scores cs ON cs.customer_id = v.customer_id
     WHERE v.customer_status = 'ACTIVE' AND cs.risk_band = 'HIGH'
     ORDER BY v.monthly_charge DESC, v.customer_id
     FETCH FIRST 5 ROWS ONLY;
  r c_top%ROWTYPE;
BEGIN
  OPEN c_top;
  LOOP
    FETCH c_top INTO r;
    EXIT WHEN c_top%NOTFOUND;
    DBMS_OUTPUT.PUT_LINE(c_top%ROWCOUNT || '. ' || RPAD(r.customer_id, 12) || RPAD(r.full_name, 22)
                         || ' score=' || LPAD(r.rule_score, 3) || '  monthly=' || TO_CHAR(r.monthly_charge, '999.99'));
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('rows fetched: ' || c_top%ROWCOUNT || ', cursor open? ' ||
                       CASE WHEN c_top%ISOPEN THEN 'yes' ELSE 'no' END);
  CLOSE c_top;
END;
/

PROMPT ======================================================================
PROMPT Demo 3 : PARAMETERIZED cursors in nested FOR loops
PROMPT          Three highest-risk active customers of every contract type
PROMPT ======================================================================
DECLARE
  CURSOR c_contract IS SELECT contract_name FROM contract_types ORDER BY term_months;
  CURSOR c_cust (p_contract VARCHAR2, p_n NUMBER) IS
    SELECT v.customer_id, v.full_name, cs.rule_score
      FROM v_customer_current v JOIN churn_scores cs ON cs.customer_id = v.customer_id
     WHERE v.contract_name = p_contract AND v.customer_status = 'ACTIVE'
     ORDER BY cs.rule_score DESC, v.customer_id
     FETCH FIRST p_n ROWS ONLY;
BEGIN
  FOR k IN c_contract LOOP
    DBMS_OUTPUT.PUT_LINE('--- ' || k.contract_name);
    FOR r IN c_cust(k.contract_name, 3) LOOP
      DBMS_OUTPUT.PUT_LINE('    ' || RPAD(r.customer_id, 12) || RPAD(r.full_name, 22) || ' score=' || r.rule_score);
    END LOOP;
  END LOOP;
END;
/

PROMPT ======================================================================
PROMPT Demo 4 : BULK COLLECT ... LIMIT - revenue at risk, cross-checked with PKG_RETAINAI
PROMPT ======================================================================
DECLARE
  CURSOR c_risk IS
    SELECT s.monthly_charge
      FROM subscriptions s JOIN churn_scores cs ON cs.customer_id = s.customer_id
     WHERE s.status = 'ACTIVE' AND cs.risk_band = 'HIGH';
  TYPE t_amt IS TABLE OF subscriptions.monthly_charge%TYPE;
  v_amt   t_amt;
  v_sum   NUMBER := 0;
  v_cnt   NUMBER := 0;
  v_batch NUMBER := 0;
BEGIN
  OPEN c_risk;
  LOOP
    FETCH c_risk BULK COLLECT INTO v_amt LIMIT 500;
    EXIT WHEN v_amt.COUNT = 0;
    v_batch := v_batch + 1;
    FOR i IN 1 .. v_amt.COUNT LOOP
      v_sum := v_sum + v_amt(i);
    END LOOP;
    v_cnt := v_cnt + v_amt.COUNT;
  END LOOP;
  CLOSE c_risk;
  DBMS_OUTPUT.PUT_LINE('batches of <=500 rows : ' || v_batch);
  DBMS_OUTPUT.PUT_LINE('HIGH-risk active subs : ' || v_cnt);
  DBMS_OUTPUT.PUT_LINE('revenue at risk (cursor)   : ' || TO_CHAR(v_sum, '999,999.99'));
  DBMS_OUTPUT.PUT_LINE('revenue at risk (package)  : ' || TO_CHAR(pkg_retainai.revenue_at_risk, '999,999.99'));
END;
/

PROMPT ======================================================================
PROMPT Demo 5 : REF CURSOR returned by a package procedure (segment report)
PROMPT ======================================================================
DECLARE
  v_rc       SYS_REFCURSOR;
  v_segment  VARCHAR2(20);
  v_cust     NUMBER;
  v_active   NUMBER;
  v_avg      NUMBER;
  v_rev      NUMBER;
  v_score    NUMBER;
BEGIN
  pkg_retainai.segment_report(v_rc);
  DBMS_OUTPUT.PUT_LINE(RPAD('SEGMENT', 12) || LPAD('CUSTOMERS', 10) || LPAD('ACTIVE', 8) || LPAD('AVG CHARGE', 12) || LPAD('MRR', 12) || LPAD('AVG RISK', 10));
  LOOP
    FETCH v_rc INTO v_segment, v_cust, v_active, v_avg, v_rev, v_score;
    EXIT WHEN v_rc%NOTFOUND;
    DBMS_OUTPUT.PUT_LINE(RPAD(v_segment, 12) || LPAD(v_cust, 10) || LPAD(v_active, 8)
                         || LPAD(TO_CHAR(v_avg, '990.00'), 12) || LPAD(TO_CHAR(v_rev, '999,990.00'), 12) || LPAD(v_score, 10));
  END LOOP;
  CLOSE v_rc;
END;
/

PROMPT ======================================================================
PROMPT Demo 6 : REF CURSOR printed from SQL*Plus (dashboard KPIs)
PROMPT ======================================================================
VARIABLE rc REFCURSOR
EXEC pkg_retainai.dashboard_kpis(:rc)
SET LINESIZE 250
PRINT rc
SET LINESIZE 160
