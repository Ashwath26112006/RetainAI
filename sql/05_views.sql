-- =====================================================================
-- 05_views.sql : analytical views used by the package, reports and the web application
-- =====================================================================
SET DEFINE OFF

-- One row per customer with the CURRENT (most recent) subscription and its descriptors
CREATE OR REPLACE VIEW v_customer_current AS
SELECT c.customer_id, c.full_name, c.email, c.gender, c.senior_citizen, c.has_partner, c.has_dependents,
       c.signup_date, c.status AS customer_status,
       s.subscription_id, s.status AS subscription_status, s.start_date, s.end_date,
       s.monthly_charge, s.paperless_billing,
       p.plan_id, p.plan_name, p.internet_service, p.phone_service,
       ct.contract_type_id, ct.contract_name, ct.term_months,
       pm.payment_method_id, pm.method_name AS payment_method, pm.is_automatic,
       ROUND(MONTHS_BETWEEN(NVL(s.end_date, fn_ref_date), s.start_date)) AS tenure_months
  FROM customers c
  JOIN (SELECT sub.*,
               ROW_NUMBER() OVER (PARTITION BY sub.customer_id
                                  ORDER BY sub.start_date DESC, sub.subscription_id DESC) AS rn
          FROM subscriptions sub) s
       ON s.customer_id = c.customer_id AND s.rn = 1
  JOIN plans p            ON p.plan_id = s.plan_id
  JOIN contract_types ct  ON ct.contract_type_id = s.contract_type_id
  JOIN payment_methods pm ON pm.payment_method_id = s.payment_method_id;

-- Customer 360 : current subscription + scores + operational counters
CREATE OR REPLACE VIEW v_customer_360 AS
SELECT v.*, cs.rule_score, cs.risk_band, cs.segment, cs.ml_probability, cs.ml_model, cs.scored_at,
       (SELECT COUNT(*) FROM support_tickets t WHERE t.customer_id = v.customer_id) AS ticket_count,
       (SELECT COUNT(*) FROM support_tickets t WHERE t.customer_id = v.customer_id
                AND t.status IN ('OPEN','IN_PROGRESS')) AS open_tickets,
       (SELECT COUNT(*) FROM subscription_services ss WHERE ss.subscription_id = v.subscription_id) AS addon_count
  FROM v_customer_current v
  LEFT JOIN churn_scores cs ON cs.customer_id = v.customer_id;

-- Churn rate by business dimension
CREATE OR REPLACE VIEW v_churn_by_dimension AS
WITH base AS (
  SELECT customer_status, contract_name, payment_method, internet_service,
         CASE WHEN tenure_months <= 12 THEN '0-12 months'
              WHEN tenure_months <= 24 THEN '13-24 months'
              WHEN tenure_months <= 48 THEN '25-48 months'
              ELSE '49+ months' END AS tenure_band,
         CASE senior_citizen WHEN 'Y' THEN 'Senior citizen' ELSE 'Non-senior' END AS senior_group
    FROM v_customer_current)
SELECT 'CONTRACT' AS dimension, contract_name AS dimension_value, COUNT(*) AS customers,
       SUM(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END) AS churned,
       ROUND(100 * AVG(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END), 2) AS churn_rate_pct
  FROM base GROUP BY contract_name
UNION ALL
SELECT 'PAYMENT', payment_method, COUNT(*),
       SUM(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END),
       ROUND(100 * AVG(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END), 2)
  FROM base GROUP BY payment_method
UNION ALL
SELECT 'INTERNET', internet_service, COUNT(*),
       SUM(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END),
       ROUND(100 * AVG(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END), 2)
  FROM base GROUP BY internet_service
UNION ALL
SELECT 'TENURE_BAND', tenure_band, COUNT(*),
       SUM(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END),
       ROUND(100 * AVG(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END), 2)
  FROM base GROUP BY tenure_band
UNION ALL
SELECT 'SENIOR', senior_group, COUNT(*),
       SUM(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END),
       ROUND(100 * AVG(CASE WHEN customer_status = 'CHURNED' THEN 1 ELSE 0 END), 2)
  FROM base GROUP BY senior_group;

-- Customer segmentation summary
CREATE OR REPLACE VIEW v_segment_summary AS
SELECT cs.segment,
       COUNT(*) AS customers,
       SUM(CASE WHEN v.customer_status = 'ACTIVE' THEN 1 ELSE 0 END) AS active_customers,
       ROUND(AVG(v.monthly_charge), 2) AS avg_monthly_charge,
       ROUND(SUM(CASE WHEN v.customer_status = 'ACTIVE' THEN v.monthly_charge ELSE 0 END), 2) AS monthly_revenue,
       ROUND(AVG(cs.rule_score), 1) AS avg_risk_score
  FROM churn_scores cs
  JOIN v_customer_current v ON v.customer_id = cs.customer_id
 GROUP BY cs.segment;

-- Validation of the rule-based score: observed churn per risk band
CREATE OR REPLACE VIEW v_risk_distribution AS
SELECT cs.risk_band,
       COUNT(*) AS customers,
       SUM(CASE WHEN c.status = 'CHURNED' THEN 1 ELSE 0 END) AS churned,
       ROUND(100 * AVG(CASE WHEN c.status = 'CHURNED' THEN 1 ELSE 0 END), 2) AS observed_churn_pct,
       ROUND(AVG(cs.rule_score), 1) AS avg_score
  FROM churn_scores cs JOIN customers c ON c.customer_id = cs.customer_id
 GROUP BY cs.risk_band;

-- Billing by month
CREATE OR REPLACE VIEW v_monthly_revenue AS
SELECT bill_month,
       COUNT(*) AS bills,
       SUM(amount) AS billed_amount,
       SUM(CASE WHEN status = 'PAID' THEN amount ELSE 0 END) AS paid_amount,
       SUM(CASE WHEN status = 'PENDING' THEN amount ELSE 0 END) AS pending_amount,
       SUM(CASE WHEN status = 'OVERDUE' THEN amount ELSE 0 END) AS overdue_amount
  FROM billing_records
 GROUP BY bill_month;

-- Ticket statistics
CREATE OR REPLACE VIEW v_ticket_summary AS
SELECT category,
       COUNT(*) AS total,
       SUM(CASE WHEN status IN ('OPEN','IN_PROGRESS') THEN 1 ELSE 0 END) AS open_tickets,
       ROUND(AVG(closed_at - opened_at), 1) AS avg_days_to_close
  FROM support_tickets
 GROUP BY category;

-- Campaign effectiveness
CREATE OR REPLACE VIEW v_campaign_effectiveness AS
SELECT rc.campaign_id, rc.campaign_name, rc.target_segment, rc.discount_pct, rc.status,
       COUNT(ra.action_id) AS actions,
       SUM(CASE WHEN ra.outcome = 'ACCEPTED' THEN 1 ELSE 0 END) AS accepted,
       SUM(CASE WHEN ra.outcome = 'DECLINED' THEN 1 ELSE 0 END) AS declined,
       SUM(CASE WHEN ra.outcome = 'NO_RESPONSE' THEN 1 ELSE 0 END) AS no_response,
       SUM(CASE WHEN ra.outcome = 'PENDING' THEN 1 ELSE 0 END) AS pending,
       CASE WHEN COUNT(ra.action_id) = 0 THEN 0
            ELSE ROUND(100 * SUM(CASE WHEN ra.outcome = 'ACCEPTED' THEN 1 ELSE 0 END) / COUNT(ra.action_id), 1)
       END AS acceptance_pct
  FROM retention_campaigns rc
  LEFT JOIN retention_actions ra ON ra.campaign_id = rc.campaign_id
 GROUP BY rc.campaign_id, rc.campaign_name, rc.target_segment, rc.discount_pct, rc.status;
