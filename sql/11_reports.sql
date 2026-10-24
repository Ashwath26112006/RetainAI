-- =====================================================================
-- 11_reports.sql : analytical SQL (joins, aggregation, window functions, ROLLUP, anti-join)
-- =====================================================================
SET DEFINE OFF
SET LINESIZE 170
SET PAGESIZE 60
SET FEEDBACK ON

COLUMN contract_name   FORMAT A18
COLUMN payment_method  FORMAT A28
COLUMN dimension_value FORMAT A28
COLUMN segment         FORMAT A10
COLUMN full_name       FORMAT A22
COLUMN campaign_name   FORMAT A28
COLUMN category        FORMAT A14

PROMPT === R1. Churn rate by contract type, ranked (aggregate + RANK window function) ===
SELECT contract_name,
       COUNT(*)                                                    AS customers,
       SUM(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END) AS churned,
       ROUND(100 * AVG(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END), 2) AS churn_pct,
       RANK() OVER (ORDER BY AVG(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END) DESC) AS churn_rank
  FROM v_customer_current
 GROUP BY contract_name
 ORDER BY churn_rank;

PROMPT === R2. Churn by tenure band, payment method and internet service (view v_churn_by_dimension) ===
SELECT dimension, dimension_value, customers, churned, churn_rate_pct
  FROM v_churn_by_dimension
 WHERE dimension IN ('TENURE_BAND','PAYMENT','INTERNET')
 ORDER BY dimension, churn_rate_pct DESC;

PROMPT === R3. Validation of the rule-based risk score (observed churn per risk band) ===
SELECT risk_band, customers, churned, observed_churn_pct, avg_score
  FROM v_risk_distribution
 ORDER BY avg_score DESC;

PROMPT === R4. Customer segmentation summary ===
SELECT segment, customers, active_customers, avg_monthly_charge, monthly_revenue, avg_risk_score
  FROM v_segment_summary
 ORDER BY monthly_revenue DESC;

PROMPT === R5. Monthly billing with running total (SUM ... OVER) ===
COLUMN bill_month FORMAT A10
SELECT TO_CHAR(bill_month, 'Mon-YYYY') AS bill_month, bills, billed_amount, paid_amount, pending_amount, overdue_amount,
       SUM(billed_amount) OVER (ORDER BY bill_month) AS running_billed
  FROM v_monthly_revenue
 ORDER BY v_monthly_revenue.bill_month;

PROMPT === R6. Top-10 retention priority list (PKG_RETAINAI.HIGH_RISK_REPORT, REF CURSOR) ===
VARIABLE rc REFCURSOR
EXEC pkg_retainai.high_risk_report(10, :rc)
PRINT rc

PROMPT === R7. Does ticket volume relate to churn?  (outer join + grouping; tickets are simulated data) ===
SELECT NVL(tc.n, 0) AS tickets, COUNT(*) AS customers,
       ROUND(100 * AVG(CASE WHEN c.status = 'CHURNED' THEN 1 ELSE 0 END), 1) AS churn_pct
  FROM customers c
  LEFT JOIN (SELECT customer_id, COUNT(*) AS n FROM support_tickets GROUP BY customer_id) tc
         ON tc.customer_id = c.customer_id
 GROUP BY NVL(tc.n, 0)
 ORDER BY 1;

PROMPT === R8. Campaign effectiveness ===
SELECT campaign_name, target_segment, discount_pct, actions, accepted, declined, no_response, pending, acceptance_pct
  FROM v_campaign_effectiveness
 ORDER BY campaign_id;

PROMPT === R9. Active revenue by contract and payment method with sub-totals (ROLLUP) ===
SELECT NVL(contract_name, 'ALL CONTRACTS') AS contract_name,
       NVL(payment_method, 'ALL METHODS')  AS payment_method,
       COUNT(*) AS customers, SUM(monthly_charge) AS monthly_revenue
  FROM v_customer_current
 WHERE customer_status = 'ACTIVE'
 GROUP BY ROLLUP (contract_name, payment_method)
 ORDER BY contract_name, payment_method;

PROMPT === R10. Fiber-optic customers WITHOUT Tech Support (NOT EXISTS anti-join) - observed churn ===
SELECT COUNT(*) AS customers,
       SUM(CASE WHEN v.customer_status = 'CHURNED' THEN 1 ELSE 0 END) AS churned,
       ROUND(100 * AVG(CASE WHEN v.customer_status = 'CHURNED' THEN 1 ELSE 0 END), 2) AS churn_pct
  FROM v_customer_current v
 WHERE v.internet_service = 'Fiber optic'
   AND NOT EXISTS (SELECT 1 FROM subscription_services ss JOIN services sv ON sv.service_id = ss.service_id
                    WHERE ss.subscription_id = v.subscription_id AND sv.service_name = 'Tech Support');

PROMPT === R11. Ticket statistics by category ===
SELECT category, total, open_tickets, avg_days_to_close FROM v_ticket_summary ORDER BY total DESC;

