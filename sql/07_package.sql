-- =====================================================================
-- 07_package.sql : PKG_RETAINAI - analytics API used by the dashboard and reports
-- =====================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pkg_retainai AS
  -- scalar KPIs
  FUNCTION churn_rate (p_contract_name IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;
  FUNCTION monthly_recurring_revenue RETURN NUMBER;
  FUNCTION revenue_at_risk RETURN NUMBER;
  FUNCTION customers_in_band (p_band IN VARCHAR2) RETURN NUMBER;

  -- result sets (REF CURSORs) for the front end
  PROCEDURE dashboard_kpis   (p_result OUT SYS_REFCURSOR);
  PROCEDURE segment_report   (p_result OUT SYS_REFCURSOR);
  PROCEDURE churn_breakdown  (p_dimension IN VARCHAR2, p_result OUT SYS_REFCURSOR);
  PROCEDURE high_risk_report (p_limit IN NUMBER, p_result OUT SYS_REFCURSOR);

  -- batch refresh of all scores / segments
  PROCEDURE refresh_analytics (p_scored OUT NUMBER);
END pkg_retainai;
/

CREATE OR REPLACE PACKAGE BODY pkg_retainai AS

  FUNCTION churn_rate (p_contract_name IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    v_total   NUMBER;
    v_churned NUMBER;
  BEGIN
    SELECT COUNT(*), COUNT(CASE WHEN customer_status = 'CHURNED' THEN 1 END)
      INTO v_total, v_churned
      FROM v_customer_current
     WHERE p_contract_name IS NULL OR contract_name = p_contract_name;
    IF v_total = 0 THEN
      RETURN 0;
    END IF;
    RETURN ROUND(100 * v_churned / v_total, 2);
  END churn_rate;

  FUNCTION monthly_recurring_revenue RETURN NUMBER IS
    v_mrr NUMBER;
  BEGIN
    SELECT NVL(SUM(monthly_charge), 0) INTO v_mrr FROM subscriptions WHERE status = 'ACTIVE';
    RETURN v_mrr;
  END monthly_recurring_revenue;

  FUNCTION revenue_at_risk RETURN NUMBER IS
    v_amt NUMBER;
  BEGIN
    SELECT NVL(SUM(s.monthly_charge), 0)
      INTO v_amt
      FROM subscriptions s
      JOIN churn_scores cs ON cs.customer_id = s.customer_id
     WHERE s.status = 'ACTIVE' AND cs.risk_band = 'HIGH';
    RETURN v_amt;
  END revenue_at_risk;

  FUNCTION customers_in_band (p_band IN VARCHAR2) RETURN NUMBER IS
    v_cnt NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_cnt
      FROM churn_scores cs JOIN customers c ON c.customer_id = cs.customer_id
     WHERE cs.risk_band = UPPER(p_band) AND c.status = 'ACTIVE';
    RETURN v_cnt;
  END customers_in_band;

  PROCEDURE dashboard_kpis (p_result OUT SYS_REFCURSOR) IS
  BEGIN
    OPEN p_result FOR
      SELECT (SELECT COUNT(*) FROM customers)                                   AS total_customers,
             (SELECT COUNT(*) FROM customers WHERE status = 'ACTIVE')           AS active_customers,
             (SELECT COUNT(*) FROM customers WHERE status = 'CHURNED')          AS churned_customers,
             pkg_retainai.churn_rate(NULL)                                      AS churn_rate_pct,
             pkg_retainai.monthly_recurring_revenue                             AS mrr,
             pkg_retainai.revenue_at_risk                                       AS revenue_at_risk,
             pkg_retainai.customers_in_band('HIGH')                             AS high_risk_customers,
             (SELECT COUNT(*) FROM support_tickets WHERE status IN ('OPEN','IN_PROGRESS')) AS open_tickets,
             (SELECT NVL(SUM(amount), 0) FROM billing_records WHERE status = 'OVERDUE')    AS overdue_amount,
             (SELECT ROUND(AVG(tenure_months), 1) FROM v_customer_current WHERE customer_status = 'ACTIVE') AS avg_tenure_months
        FROM dual;
  END dashboard_kpis;

  PROCEDURE segment_report (p_result OUT SYS_REFCURSOR) IS
  BEGIN
    OPEN p_result FOR
      SELECT segment, customers, active_customers, avg_monthly_charge, monthly_revenue, avg_risk_score
        FROM v_segment_summary
       ORDER BY monthly_revenue DESC;
  END segment_report;

  PROCEDURE churn_breakdown (p_dimension IN VARCHAR2, p_result OUT SYS_REFCURSOR) IS
  BEGIN
    IF UPPER(p_dimension) NOT IN ('CONTRACT','PAYMENT','INTERNET','TENURE_BAND','SENIOR') THEN
      RAISE_APPLICATION_ERROR(-20010, 'Unknown dimension: ' || p_dimension);
    END IF;
    OPEN p_result FOR
      SELECT dimension_value, customers, churned, churn_rate_pct
        FROM v_churn_by_dimension
       WHERE dimension = UPPER(p_dimension)
       ORDER BY dimension_value;
  END churn_breakdown;

  PROCEDURE high_risk_report (p_limit IN NUMBER, p_result OUT SYS_REFCURSOR) IS
  BEGIN
    OPEN p_result FOR
      SELECT * FROM (
        SELECT v.customer_id, v.full_name, v.contract_name, v.payment_method, v.tenure_months,
               v.monthly_charge, cs.rule_score, cs.risk_band, cs.segment, cs.ml_probability,
               RANK() OVER (ORDER BY cs.rule_score DESC, v.monthly_charge DESC) AS priority_rank
          FROM v_customer_current v
          JOIN churn_scores cs ON cs.customer_id = v.customer_id
         WHERE v.customer_status = 'ACTIVE' AND cs.risk_band = 'HIGH')
       WHERE priority_rank <= NVL(p_limit, 25)
       ORDER BY priority_rank, customer_id;
  END high_risk_report;

  PROCEDURE refresh_analytics (p_scored OUT NUMBER) IS
  BEGIN
    sp_score_all_customers(p_scored);
  END refresh_analytics;

END pkg_retainai;
/
SHOW ERRORS PACKAGE BODY pkg_retainai
