-- =====================================================================
-- 09_seed_ops.sql : operational sample data (support tickets, campaigns, retention actions) + first scoring run
-- NOTE: the Telco dataset has no ticket / campaign information, so these records are SIMULATED
--       (deterministic, hash-based) to exercise the operational modules.
-- =====================================================================
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

EXEC sp_seed_campaigns

DECLARE
  v_n NUMBER;
BEGIN
  sp_seed_support_tickets(v_n);
  DBMS_OUTPUT.PUT_LINE('support tickets seeded : ' || v_n);
  sp_score_all_customers(v_n);
  DBMS_OUTPUT.PUT_LINE('customers scored       : ' || v_n);
END;
/

DECLARE
  v_n NUMBER;
BEGIN
  FOR c IN (SELECT campaign_id, campaign_name FROM retention_campaigns WHERE status = 'ACTIVE' ORDER BY campaign_id) LOOP
    sp_plan_retention(c.campaign_id, v_n);
    DBMS_OUTPUT.PUT_LINE(RPAD(c.campaign_name, 28) || ' -> ' || v_n || ' retention actions planned');
  END LOOP;
END;
/

-- simulated customer responses for ~70% of campaign actions
DECLARE
  v_done NUMBER := 0;
  v_out  VARCHAR2(12);
  v_pct  NUMBER;
BEGIN
  FOR a IN (SELECT action_id FROM retention_actions WHERE campaign_id IS NOT NULL ORDER BY action_id) LOOP
    v_pct := MOD(DBMS_UTILITY.GET_HASH_VALUE('resp' || a.action_id, 0, 1073741824), 100);
    v_out := CASE WHEN v_pct < 30 THEN 'ACCEPTED' WHEN v_pct < 55 THEN 'DECLINED'
                  WHEN v_pct < 70 THEN 'NO_RESPONSE' END;
    IF v_out IS NOT NULL THEN
      sp_record_outcome(a.action_id, v_out, 'Simulated response (demo data)');
      v_done := v_done + 1;
    END IF;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('simulated outcomes recorded: ' || v_done);
END;
/
