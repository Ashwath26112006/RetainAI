-- =====================================================================
-- 03_functions.sql : stored functions
-- =====================================================================
SET DEFINE OFF

-- Locale-independent text -> number conversion (used by the ETL)
CREATE OR REPLACE FUNCTION fn_to_num (p_text IN VARCHAR2) RETURN NUMBER DETERMINISTIC IS
BEGIN
  IF p_text IS NULL OR TRIM(p_text) IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN TO_NUMBER(TRIM(p_text), '999999999D99', 'NLS_NUMERIC_CHARACTERS=''.,''');
EXCEPTION
  WHEN VALUE_ERROR OR INVALID_NUMBER THEN
    RETURN NULL;
END fn_to_num;
/

-- Business ("today") date of the system, read from APP_CONFIG
CREATE OR REPLACE FUNCTION fn_ref_date RETURN DATE IS
  v_date DATE;
BEGIN
  SELECT TO_DATE(config_value, 'YYYY-MM-DD') INTO v_date
    FROM app_config WHERE config_key = 'REFERENCE_DATE';
  RETURN v_date;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN TRUNC(SYSDATE);
END fn_ref_date;
/

-- Tenure (whole months) of the customer's most recent subscription
CREATE OR REPLACE FUNCTION fn_tenure_months (p_customer_id IN VARCHAR2) RETURN NUMBER IS
  v_months NUMBER;
BEGIN
  SELECT ROUND(MONTHS_BETWEEN(NVL(end_date, fn_ref_date), start_date))
    INTO v_months
    FROM subscriptions
   WHERE customer_id = p_customer_id
   ORDER BY start_date DESC, subscription_id DESC
   FETCH FIRST 1 ROW ONLY;
  RETURN v_months;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 0;
END fn_tenure_months;
/

-- Estimated revenue generated so far = monthly charge x tenure
CREATE OR REPLACE FUNCTION fn_lifetime_value (p_customer_id IN VARCHAR2) RETURN NUMBER IS
  v_charge NUMBER;
BEGIN
  SELECT monthly_charge INTO v_charge
    FROM subscriptions
   WHERE customer_id = p_customer_id
   ORDER BY start_date DESC, subscription_id DESC
   FETCH FIRST 1 ROW ONLY;
  RETURN ROUND(v_charge * fn_tenure_months(p_customer_id), 2);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 0;
END fn_lifetime_value;
/

-- Maps a numeric score to a risk band
CREATE OR REPLACE FUNCTION fn_risk_band (p_score IN NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
BEGIN
  RETURN CASE
           WHEN p_score >= 60 THEN 'HIGH'
           WHEN p_score >= 35 THEN 'MEDIUM'
           ELSE 'LOW'
         END;
END fn_risk_band;
/

-- Rule-based churn-risk score (0-100) derived from the drivers found in the Telco data
CREATE OR REPLACE FUNCTION fn_churn_risk_score (p_customer_id IN VARCHAR2) RETURN NUMBER IS
  v_score     NUMBER := 0;
  v_sub_id    subscriptions.subscription_id%TYPE;
  v_charge    subscriptions.monthly_charge%TYPE;
  v_paperless subscriptions.paperless_billing%TYPE;
  v_term      contract_types.term_months%TYPE;
  v_internet  plans.internet_service%TYPE;
  v_method    payment_methods.method_name%TYPE;
  v_senior    customers.senior_citizen%TYPE;
  v_partner   customers.has_partner%TYPE;
  v_dependent customers.has_dependents%TYPE;
  v_tenure    NUMBER;
  v_cnt       NUMBER;
BEGIN
  SELECT s.subscription_id, s.monthly_charge, s.paperless_billing,
         ct.term_months, p.internet_service, pm.method_name,
         c.senior_citizen, c.has_partner, c.has_dependents
    INTO v_sub_id, v_charge, v_paperless, v_term, v_internet, v_method,
         v_senior, v_partner, v_dependent
    FROM customers c
    JOIN subscriptions s     ON s.customer_id = c.customer_id
    JOIN contract_types ct   ON ct.contract_type_id = s.contract_type_id
    JOIN plans p             ON p.plan_id = s.plan_id
    JOIN payment_methods pm  ON pm.payment_method_id = s.payment_method_id
   WHERE c.customer_id = p_customer_id
   ORDER BY s.start_date DESC, s.subscription_id DESC
   FETCH FIRST 1 ROW ONLY;

  v_tenure := fn_tenure_months(p_customer_id);

  -- contract commitment
  IF v_term = 1 THEN v_score := v_score + 30;
  ELSIF v_term = 12 THEN v_score := v_score + 10;
  END IF;

  -- customer age (newer customers churn more)
  IF v_tenure <= 6 THEN v_score := v_score + 20;
  ELSIF v_tenure <= 12 THEN v_score := v_score + 15;
  ELSIF v_tenure <= 24 THEN v_score := v_score + 8;
  ELSIF v_tenure <= 48 THEN v_score := v_score + 3;
  END IF;

  IF v_internet = 'Fiber optic' THEN v_score := v_score + 10; END IF;
  IF v_method = 'Electronic check' THEN v_score := v_score + 10; END IF;
  IF v_paperless = 'Y' THEN v_score := v_score + 3; END IF;
  IF v_charge > 70 THEN v_score := v_score + 7; END IF;
  IF v_senior = 'Y' THEN v_score := v_score + 4; END IF;
  IF v_partner = 'N' AND v_dependent = 'N' THEN v_score := v_score + 3; END IF;

  -- missing protection services for internet customers
  IF v_internet <> 'No' THEN
    SELECT COUNT(*) INTO v_cnt
      FROM subscription_services ss JOIN services sv ON sv.service_id = ss.service_id
     WHERE ss.subscription_id = v_sub_id AND sv.service_name = 'Tech Support';
    IF v_cnt = 0 THEN v_score := v_score + 8; END IF;

    SELECT COUNT(*) INTO v_cnt
      FROM subscription_services ss JOIN services sv ON sv.service_id = ss.service_id
     WHERE ss.subscription_id = v_sub_id AND sv.service_name = 'Online Security';
    IF v_cnt = 0 THEN v_score := v_score + 7; END IF;
  END IF;

  -- operational signals: unresolved high-priority tickets (max +9) and overdue bills (+5)
  SELECT COUNT(*) INTO v_cnt FROM support_tickets
   WHERE customer_id = p_customer_id AND status IN ('OPEN','IN_PROGRESS') AND priority IN ('HIGH','URGENT');
  v_score := v_score + LEAST(v_cnt * 3, 9);

  SELECT COUNT(*) INTO v_cnt FROM billing_records
   WHERE subscription_id = v_sub_id AND status = 'OVERDUE';
  IF v_cnt > 0 THEN v_score := v_score + 5; END IF;

  RETURN LEAST(v_score, 100);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN NULL;
END fn_churn_risk_score;
/

-- Customer segmentation (rule based, RFM-style)
CREATE OR REPLACE FUNCTION fn_segment (p_customer_id IN VARCHAR2, p_score IN NUMBER DEFAULT NULL) RETURN VARCHAR2 IS
  v_status  customers.status%TYPE;
  v_score   NUMBER := p_score;
  v_term    contract_types.term_months%TYPE;
  v_tenure  NUMBER;
BEGIN
  SELECT status INTO v_status FROM customers WHERE customer_id = p_customer_id;
  IF v_status = 'CHURNED' THEN
    RETURN 'Lost';
  END IF;

  v_tenure := fn_tenure_months(p_customer_id);
  IF v_score IS NULL THEN
    v_score := fn_churn_risk_score(p_customer_id);
  END IF;

  SELECT ct.term_months INTO v_term
    FROM subscriptions s JOIN contract_types ct ON ct.contract_type_id = s.contract_type_id
   WHERE s.customer_id = p_customer_id
   ORDER BY s.start_date DESC, s.subscription_id DESC
   FETCH FIRST 1 ROW ONLY;

  RETURN CASE
           WHEN v_tenure <= 6 THEN 'New'
           WHEN v_score >= 60 THEN 'At Risk'
           WHEN v_tenure >= 36 AND v_term >= 12 THEN 'Champion'
           WHEN v_tenure >= 18 THEN 'Loyal'
           ELSE 'Standard'
         END;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN NULL;
END fn_segment;
/
SELECT object_name, object_type, status FROM user_objects WHERE object_type = 'FUNCTION' ORDER BY object_name;
