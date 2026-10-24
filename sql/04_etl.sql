-- =====================================================================
-- 04_etl.sql : ETL procedure that normalises the staging data into the 3NF schema
-- =====================================================================
SET DEFINE OFF

CREATE OR REPLACE PROCEDURE sp_load_from_staging IS
  v_ref DATE := fn_ref_date;
  v_n   NUMBER;
BEGIN
  -- lookup tables --------------------------------------------------------
  INSERT INTO contract_types (contract_type_id, contract_name, term_months)
  SELECT ROW_NUMBER() OVER (ORDER BY t), c, t
    FROM (SELECT contract AS c,
                 CASE contract WHEN 'Month-to-month' THEN 1 WHEN 'One year' THEN 12 ELSE 24 END AS t
            FROM stg_telco GROUP BY contract);
  DBMS_OUTPUT.PUT_LINE('contract_types : ' || SQL%ROWCOUNT);

  INSERT INTO payment_methods (payment_method_id, method_name, is_automatic)
  SELECT ROW_NUMBER() OVER (ORDER BY payment_method), payment_method,
         CASE WHEN payment_method LIKE '%(automatic)' THEN 'Y' ELSE 'N' END
    FROM stg_telco GROUP BY payment_method;
  DBMS_OUTPUT.PUT_LINE('payment_methods: ' || SQL%ROWCOUNT);

  INSERT INTO plans (plan_name, internet_service, phone_service, base_price)
  SELECT CASE WHEN phone_service = 'Yes' AND internet_service <> 'No' THEN internet_service || ' + Phone'
              WHEN phone_service = 'Yes' THEN 'Phone Only'
              ELSE internet_service || ' Only' END,
         internet_service,
         CASE phone_service WHEN 'Yes' THEN 'Y' ELSE 'N' END,
         MIN(fn_to_num(monthly_charges))
    FROM stg_telco GROUP BY internet_service, phone_service;
  DBMS_OUTPUT.PUT_LINE('plans          : ' || SQL%ROWCOUNT);

  INSERT INTO services (service_id, service_name, service_category) VALUES (1, 'Multiple Lines',    'PHONE');
  INSERT INTO services (service_id, service_name, service_category) VALUES (2, 'Online Security',   'SECURITY');
  INSERT INTO services (service_id, service_name, service_category) VALUES (3, 'Online Backup',     'SECURITY');
  INSERT INTO services (service_id, service_name, service_category) VALUES (4, 'Device Protection', 'SECURITY');
  INSERT INTO services (service_id, service_name, service_category) VALUES (5, 'Tech Support',      'SUPPORT');
  INSERT INTO services (service_id, service_name, service_category) VALUES (6, 'Streaming TV',      'STREAMING');
  INSERT INTO services (service_id, service_name, service_category) VALUES (7, 'Streaming Movies',  'STREAMING');

  -- customers ------------------------------------------------------------
  INSERT INTO customers (customer_id, full_name, email, gender, senior_citizen, has_partner,
                         has_dependents, signup_date, status)
  SELECT customer_id, full_name, LOWER(email), gender,
         CASE senior_citizen WHEN '1' THEN 'Y' ELSE 'N' END,
         CASE partner WHEN 'Yes' THEN 'Y' ELSE 'N' END,
         CASE dependents WHEN 'Yes' THEN 'Y' ELSE 'N' END,
         ADD_MONTHS(v_ref, -TO_NUMBER(tenure)),
         CASE churn WHEN 'Yes' THEN 'CHURNED' ELSE 'ACTIVE' END
    FROM stg_telco;
  DBMS_OUTPUT.PUT_LINE('customers      : ' || SQL%ROWCOUNT);

  -- subscriptions --------------------------------------------------------
  INSERT INTO subscriptions (customer_id, plan_id, contract_type_id, payment_method_id, paperless_billing,
                             start_date, end_date, monthly_charge, status, cancel_reason)
  SELECT s.customer_id, p.plan_id, ct.contract_type_id, pm.payment_method_id,
         CASE s.paperless_billing WHEN 'Yes' THEN 'Y' ELSE 'N' END,
         ADD_MONTHS(v_ref, -TO_NUMBER(s.tenure)),
         CASE s.churn WHEN 'Yes' THEN v_ref END,
         fn_to_num(s.monthly_charges),
         CASE s.churn WHEN 'Yes' THEN 'CANCELLED' ELSE 'ACTIVE' END,
         CASE s.churn WHEN 'Yes' THEN 'Churned (as recorded in source dataset)' END
    FROM stg_telco s
    JOIN plans p            ON p.internet_service = s.internet_service
                           AND p.phone_service = CASE s.phone_service WHEN 'Yes' THEN 'Y' ELSE 'N' END
    JOIN contract_types ct  ON ct.contract_name = s.contract
    JOIN payment_methods pm ON pm.method_name = s.payment_method;
  DBMS_OUTPUT.PUT_LINE('subscriptions  : ' || SQL%ROWCOUNT);

  -- add-on services (M:N) ------------------------------------------------
  INSERT INTO subscription_services (subscription_id, service_id, added_on)
  SELECT sub.subscription_id, sv.service_id, sub.start_date
    FROM stg_telco s
    JOIN subscriptions sub ON sub.customer_id = s.customer_id
    JOIN services sv ON (sv.service_name = 'Multiple Lines'    AND s.multiple_lines   = 'Yes')
                     OR (sv.service_name = 'Online Security'   AND s.online_security  = 'Yes')
                     OR (sv.service_name = 'Online Backup'     AND s.online_backup    = 'Yes')
                     OR (sv.service_name = 'Device Protection' AND s.device_protection = 'Yes')
                     OR (sv.service_name = 'Tech Support'      AND s.tech_support     = 'Yes')
                     OR (sv.service_name = 'Streaming TV'      AND s.streaming_tv     = 'Yes')
                     OR (sv.service_name = 'Streaming Movies'  AND s.streaming_movies = 'Yes');
  DBMS_OUTPUT.PUT_LINE('sub_services   : ' || SQL%ROWCOUNT);

  -- billing history for the last (up to) 6 months of every subscription ---
  INSERT INTO billing_records (subscription_id, bill_month, amount, status, due_date, paid_date)
  SELECT x.subscription_id, x.bm, x.monthly_charge, x.st, LAST_DAY(x.bm),
         CASE WHEN x.st = 'PAID' THEN x.bm + MOD(ORA_HASH(x.customer_id || TO_CHAR(x.bm, 'MMYYYY')), 25) END
    FROM (SELECT sub.subscription_id, sub.customer_id, sub.monthly_charge, m.bm,
                 CASE WHEN m.bm < TRUNC(v_ref, 'MM') THEN 'PAID'
                      WHEN sub.status = 'CANCELLED' AND MOD(ORA_HASH(sub.customer_id), 4) = 0 THEN 'OVERDUE'
                      ELSE 'PENDING' END AS st
            FROM subscriptions sub
            CROSS JOIN (SELECT ADD_MONTHS(TRUNC(v_ref, 'MM'), 1 - LEVEL) AS bm
                          FROM dual CONNECT BY LEVEL <= 6) m
           WHERE m.bm >  TRUNC(sub.start_date, 'MM')
             AND m.bm <= TRUNC(NVL(sub.end_date, v_ref), 'MM')) x;
  DBMS_OUTPUT.PUT_LINE('billing_records: ' || SQL%ROWCOUNT);

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END sp_load_from_staging;
/
SHOW ERRORS

SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC sp_load_from_staging

PROMPT Gathering optimizer statistics...
EXEC DBMS_STATS.GATHER_SCHEMA_STATS(ownname => USER, cascade => TRUE)
