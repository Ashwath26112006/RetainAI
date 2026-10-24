"""RetainAI - Customer Retention Analytics Platform (Flask front end for the Oracle schema)."""
import csv
import datetime as dt
import io
import os
import re
import secrets
import time
from decimal import Decimal
from functools import wraps

import oracledb
from flask import (Flask, Response, flash, jsonify, redirect, render_template, request, session, url_for)
from flask.json.provider import DefaultJSONProvider

import db
from werkzeug.security import check_password_hash, generate_password_hash

ADMIN_USER = os.getenv("RETAINAI_ADMIN_USER", "admin")
ADMIN_PASS = os.getenv("RETAINAI_ADMIN_PASS", "retainai")
PER_PAGE = 20


class Provider(DefaultJSONProvider):
    @staticmethod
    def default(o):
        if isinstance(o, (dt.datetime, dt.date)):
            return o.strftime("%Y-%m-%d")
        if isinstance(o, Decimal):
            return float(o)
        return DefaultJSONProvider.default(o)


app = Flask(__name__)
app.json = Provider(app)
app.secret_key = os.getenv("RETAINAI_SECRET", "retainai-dev-secret")


# ------------------------------------------------------------------ helpers
def login_required(f):
    @wraps(f)
    def wrapper(*a, **kw):
        if not session.get("user"):
            return redirect(url_for("login", next=request.path))
        return f(*a, **kw)
    return wrapper


def ora_message(e):
    """Human readable first line of an Oracle error."""
    msg = str(e.args[0].message) if e.args and hasattr(e.args[0], "message") else str(e)
    first = msg.strip().splitlines()[0]
    return re.sub(r"^ORA-\d+:\s*", lambda m: m.group(0), first)


def run(action, ok_msg, back):
    """Execute `action()`, flash success / Oracle error, redirect to `back`."""
    try:
        res = action()
        flash(ok_msg(res) if callable(ok_msg) else ok_msg, "ok")
    except oracledb.DatabaseError as e:
        flash(ora_message(e), "err")
    return redirect(back)


@app.template_filter("money")
def money(v):
    return "-" if v is None else f"${float(v):,.2f}"


@app.template_filter("num")
def num(v):
    return "-" if v is None else f"{int(v):,}"


@app.template_filter("pct")
def pct(v, d=1):
    return "-" if v is None else f"{float(v):.{d}f}%"


@app.template_filter("dictupdate")
def dictupdate(d, extra):
    out = dict(d); out.update(extra); return out


@app.template_filter("d")
def fdate(v):
    return "" if v is None else v.strftime("%d %b %Y") if hasattr(v, "strftime") else str(v)


@app.context_processor
def inject():
    try:
        ref = db.scalar("SELECT fn_ref_date FROM dual")
    except Exception:
        ref = None
    return dict(business_date=ref, user=session.get("user"), endpoint=request.endpoint)


@app.errorhandler(oracledb.DatabaseError)
def db_error(e):
    return render_template("error.html", message=ora_message(e)), 500


# ------------------------------------------------------------------ auth
def stored_admin_hash():
    """Password hash saved by the password-recovery flow (table app_config); None = use the default password."""
    try:
        return db.scalar("SELECT config_value FROM app_config WHERE config_key = 'ADMIN_PASSWORD_HASH'")
    except oracledb.DatabaseError:
        return None


def password_ok(user, password):
    if user != ADMIN_USER:
        return False
    h = stored_admin_hash()
    return check_password_hash(h, password or "") if h else password == ADMIN_PASS


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if password_ok(request.form.get("username"), request.form.get("password")):
            session["user"] = ADMIN_USER
            return redirect(request.args.get("next") or url_for("dashboard"))
        flash("Invalid username or password", "err")
    return render_template("login.html")


# ---- password recovery -------------------------------------------------------------------------
# There is no mail server in this lab setup, so the one-time recovery code is printed in the terminal of the
# machine that runs the application (the VS Code terminal). The code is valid for 10 minutes and 5 attempts.
RESET_CODES = {}
CODE_TTL, CODE_TRIES = 600, 5


@app.route("/forgot", methods=["GET", "POST"])
def forgot():
    if request.method == "POST":
        user = (request.form.get("username") or "").strip()
        if user == ADMIN_USER:  # the same answer is shown for unknown users, so accounts cannot be probed
            code = "%06d" % secrets.randbelow(10 ** 6)
            RESET_CODES[user] = {"code": code, "exp": time.time() + CODE_TTL, "tries": 0}
            print(f"[RetainAI] Password recovery code for '{user}': {code}  (valid {CODE_TTL // 60} minutes)", flush=True)
        session["reset_user"] = user
        flash("If the account exists, a one-time recovery code has been printed in the terminal running the application.", "ok")
        return redirect(url_for("reset"))
    return render_template("forgot.html")


@app.route("/reset", methods=["GET", "POST"])
def reset():
    user = session.get("reset_user")
    if not user:
        return redirect(url_for("forgot"))
    if request.method == "POST":
        code = (request.form.get("code") or "").strip()
        pw, pw2 = request.form.get("password") or "", request.form.get("confirm") or ""
        entry = RESET_CODES.get(user)
        if not entry or entry["exp"] < time.time():
            flash("The recovery code has expired. Request a new one.", "err")
            return redirect(url_for("forgot"))
        entry["tries"] += 1
        if entry["tries"] > CODE_TRIES:
            RESET_CODES.pop(user, None)
            flash("Too many wrong attempts. Request a new code.", "err")
            return redirect(url_for("forgot"))
        if not secrets.compare_digest(code, entry["code"]):
            flash("Incorrect recovery code.", "err")
        elif len(pw) < 8:
            flash("The new password must be at least 8 characters long.", "err")
        elif pw != pw2:
            flash("The two passwords do not match.", "err")
        else:
            h = generate_password_hash(pw, method="pbkdf2:sha256")
            db.execute("MERGE INTO app_config c USING (SELECT 'ADMIN_PASSWORD_HASH' k FROM dual) s ON (c.config_key = s.k) "
                       "WHEN MATCHED THEN UPDATE SET c.config_value = :h "
                       "WHEN NOT MATCHED THEN INSERT (config_key, config_value, description) "
                       "VALUES (s.k, :h, 'Hash of the administrator password (set by password recovery)')", {"h": h})
            db.execute("INSERT INTO audit_log (table_name, operation, record_key, new_value) "
                       "VALUES ('APP_CONFIG', 'PASSWORD_RESET', 'ADMIN_PASSWORD_HASH', 'administrator password changed through recovery code')")
            RESET_CODES.pop(user, None)
            session.pop("reset_user", None)
            flash("Password updated. Sign in with your new password.", "ok")
            return redirect(url_for("login"))
    return render_template("reset.html", user=user)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ------------------------------------------------------------------ dashboard
@app.route("/")
@login_required
def dashboard():
    kpi = db.call_cursor("pkg_retainai.dashboard_kpis")[0]
    top = db.call_cursor("pkg_retainai.high_risk_report", (8,))
    return render_template("dashboard.html", k=kpi, top=top)


@app.route("/api/churn/<dim>")
@login_required
def api_churn(dim):
    return jsonify(db.call_cursor("pkg_retainai.churn_breakdown", (dim.upper(),)))


@app.route("/api/segments")
@login_required
def api_segments():
    return jsonify(db.call_cursor("pkg_retainai.segment_report"))


@app.route("/api/risk")
@login_required
def api_risk():
    return jsonify(db.query("SELECT risk_band, customers, churned, observed_churn_pct, avg_score FROM v_risk_distribution "
                            "ORDER BY avg_score"))


@app.route("/api/revenue")
@login_required
def api_revenue():
    return jsonify(db.query("SELECT TO_CHAR(bill_month,'Mon YY') AS label, billed_amount, paid_amount, pending_amount, "
                            "overdue_amount FROM v_monthly_revenue ORDER BY bill_month"))


@app.route("/api/ml_compare")
@login_required
def api_ml_compare():
    return jsonify(db.query("""SELECT risk_band, COUNT(*) AS customers,
                                      ROUND(AVG(ml_probability) * 100, 1) AS avg_ml_pct
                                 FROM churn_scores WHERE ml_probability IS NOT NULL GROUP BY risk_band"""))


# ------------------------------------------------------------------ customers
SORTS = {"risk": "rule_score DESC NULLS LAST, customer_id", "name": "full_name", "tenure": "tenure_months DESC, customer_id",
         "charge": "monthly_charge DESC, customer_id", "id": "customer_id"}


@app.route("/customers")
@login_required
def customers():
    a = request.args
    where, p = [], {}
    if a.get("q", "").strip():
        where.append("(UPPER(full_name) LIKE :q OR UPPER(customer_id) LIKE :q OR UPPER(email) LIKE :q)")
        p["q"] = "%" + a["q"].strip().upper() + "%"
    for key, col in (("status", "customer_status"), ("segment", "segment"), ("band", "risk_band"), ("contract", "contract_name")):
        if a.get(key):
            where.append(f"{col} = :{key}")
            p[key] = a[key]
    base = "FROM v_customer_360" + (" WHERE " + " AND ".join(where) if where else "")
    total = db.scalar("SELECT COUNT(*) " + base, p)
    page = max(int(a.get("page", 1) or 1), 1)
    order = SORTS.get(a.get("sort", "risk"), SORTS["risk"])
    rows = db.query("SELECT customer_id, full_name, customer_status, contract_name, internet_service, tenure_months, "
                    "monthly_charge, rule_score, risk_band, segment, ml_probability " + base +
                    f" ORDER BY {order} OFFSET :off ROWS FETCH NEXT :n ROWS ONLY",
                    {**p, "off": (page - 1) * PER_PAGE, "n": PER_PAGE})
    segs = [r["segment"] for r in db.query("SELECT DISTINCT segment FROM churn_scores ORDER BY 1")]
    contracts = [r["contract_name"] for r in db.query("SELECT contract_name FROM contract_types ORDER BY term_months")]
    return render_template("customers.html", rows=rows, total=total, page=page, pages=max((total + PER_PAGE - 1) // PER_PAGE, 1),
                           segs=segs, contracts=contracts, a=a)


@app.route("/customers/new", methods=["GET", "POST"])
@login_required
def customer_new():
    if request.method == "POST":
        f = request.form
        svc = ",".join(f.getlist("services"))
        try:
            cid, sid = db.call("sp_add_customer", (
                f["full_name"], f["email"], f["gender"], "Y" if f.get("senior") else "N",
                "Y" if f.get("partner") else "N", "Y" if f.get("dependents") else "N",
                int(f["plan_id"]), int(f["contract_type_id"]), int(f["payment_method_id"]),
                "Y" if f.get("paperless") else "N", float(f["monthly_charge"]) if f.get("monthly_charge") else None,
                svc or None), outs=(str, int))
            flash(f"Customer {cid} registered (subscription {int(sid)}) and scored.", "ok")
            return redirect(url_for("customer", cid=cid))
        except oracledb.DatabaseError as e:
            flash(ora_message(e), "err")
    return render_template("customer_new.html",
                           plans=db.query("SELECT plan_id, plan_name, base_price FROM plans ORDER BY plan_id"),
                           contracts=db.query("SELECT contract_type_id, contract_name FROM contract_types ORDER BY term_months"),
                           methods=db.query("SELECT payment_method_id, method_name FROM payment_methods ORDER BY 1"),
                           services=db.query("SELECT service_id, service_name FROM services ORDER BY 1"), f=request.form)


@app.route("/customers/<cid>")
@login_required
def customer(cid):
    c = db.one("SELECT * FROM v_customer_360 WHERE customer_id = :id", {"id": cid})
    if not c:
        flash("Customer not found", "err")
        return redirect(url_for("customers"))
    sid = c["subscription_id"]
    return render_template(
        "customer.html", c=c, ltv=db.func("fn_lifetime_value", (cid,)),
        services=db.query("SELECT sv.service_name, sv.service_category FROM subscription_services ss JOIN services sv "
                          "ON sv.service_id = ss.service_id WHERE ss.subscription_id = :s ORDER BY sv.service_id", {"s": sid}),
        bills=db.query("SELECT bill_id, bill_month, amount, status, due_date, paid_date FROM billing_records "
                       "WHERE subscription_id = :s ORDER BY bill_month DESC FETCH FIRST 12 ROWS ONLY", {"s": sid}),
        tickets=db.query("SELECT ticket_id, category, priority, status, subject, opened_at, closed_at FROM support_tickets "
                         "WHERE customer_id = :c ORDER BY opened_at DESC, ticket_id DESC", {"c": cid}),
        actions=db.query("SELECT ra.action_id, ra.action_type, ra.action_date, ra.outcome, ra.notes, rc.campaign_name "
                         "FROM retention_actions ra LEFT JOIN retention_campaigns rc ON rc.campaign_id = ra.campaign_id "
                         "WHERE ra.customer_id = :c ORDER BY ra.action_id DESC", {"c": cid}))


@app.post("/customers/<cid>/cancel")
@login_required
def customer_cancel(cid):
    sid = int(request.form["subscription_id"])
    return run(lambda: db.call("sp_cancel_subscription", (sid, request.form.get("reason") or "Not specified")),
               "Subscription cancelled - customer marked CHURNED and a win-back action was queued.",
               url_for("customer", cid=cid))


@app.post("/customers/<cid>/reactivate")
@login_required
def customer_reactivate(cid):
    sid = int(request.form["subscription_id"])
    return run(lambda: db.call("sp_reactivate_subscription", (sid,)), "Subscription re-activated.", url_for("customer", cid=cid))


@app.post("/customers/<cid>/rescore")
@login_required
def customer_rescore(cid):
    return run(lambda: db.call("sp_score_customer", (cid,)), "Risk score refreshed.", url_for("customer", cid=cid))


@app.post("/customers/<cid>/ticket")
@login_required
def customer_ticket(cid):
    f = request.form
    return run(lambda: db.call("sp_open_ticket", (cid, f["category"], f["priority"], f["subject"]), outs=(int,)),
               lambda r: f"Ticket #{int(r[0])} opened.", url_for("customer", cid=cid))


# ------------------------------------------------------------------ billing
@app.route("/billing")
@login_required
def billing():
    a = request.args
    where, p = [], {}
    if a.get("status"):
        where.append("b.status = :st"); p["st"] = a["status"]
    if a.get("month"):
        where.append("b.bill_month = TO_DATE(:m, 'YYYY-MM')"); p["m"] = a["month"]
    if a.get("q"):
        where.append("(UPPER(c.customer_id) LIKE :q OR UPPER(c.full_name) LIKE :q)"); p["q"] = "%" + a["q"].upper() + "%"
    base = ("FROM billing_records b JOIN subscriptions s ON s.subscription_id = b.subscription_id "
            "JOIN customers c ON c.customer_id = s.customer_id" + (" WHERE " + " AND ".join(where) if where else ""))
    total = db.scalar("SELECT COUNT(*) " + base, p)
    page = max(int(a.get("page", 1) or 1), 1)
    rows = db.query("SELECT b.bill_id, c.customer_id, c.full_name, b.bill_month, b.amount, b.status, b.due_date, b.paid_date "
                    + base + " ORDER BY b.bill_month DESC, b.bill_id OFFSET :off ROWS FETCH NEXT :n ROWS ONLY",
                    {**p, "off": (page - 1) * PER_PAGE, "n": PER_PAGE})
    months = db.query("SELECT TO_CHAR(bill_month,'YYYY-MM') AS ym, TO_CHAR(bill_month,'Mon YYYY') AS label, billed_amount, "
                      "paid_amount, pending_amount, overdue_amount, bills FROM v_monthly_revenue ORDER BY bill_month DESC")
    return render_template("billing.html", rows=rows, total=total, page=page, pages=max((total + PER_PAGE - 1) // PER_PAGE, 1),
                           months=months, a=a)


@app.post("/billing/run")
@login_required
def billing_run():
    month = request.form["month"] + "-01"
    return run(lambda: db.call("sp_generate_bills", (db.to_date(month),), outs=(int,)),
               lambda r: f"Billing run for {request.form['month']}: {int(r[0])} new bills created.", url_for("billing"))


@app.post("/billing/overdue")
@login_required
def billing_overdue():
    return run(lambda: db.call("sp_mark_overdue_bills", (), outs=(int,)),
               lambda r: f"{int(r[0])} bills flagged OVERDUE.", url_for("billing"))


@app.post("/billing/<int:bid>/pay")
@login_required
def billing_pay(bid):
    return run(lambda: db.call("sp_record_payment", (bid, None)), f"Payment recorded for bill #{bid}.",
               request.form.get("back") or url_for("billing"))


# ------------------------------------------------------------------ tickets
@app.route("/tickets")
@login_required
def tickets():
    a = request.args
    where, p = [], {}
    for key in ("status", "category", "priority"):
        if a.get(key):
            where.append(f"t.{key} = :{key}"); p[key] = a[key]
    base = ("FROM support_tickets t JOIN customers c ON c.customer_id = t.customer_id" +
            (" WHERE " + " AND ".join(where) if where else ""))
    total = db.scalar("SELECT COUNT(*) " + base, p)
    page = max(int(a.get("page", 1) or 1), 1)
    rows = db.query("SELECT t.ticket_id, t.customer_id, c.full_name, t.category, t.priority, t.status, t.subject, t.opened_at, "
                    "t.closed_at " + base + " ORDER BY CASE t.status WHEN 'OPEN' THEN 0 WHEN 'IN_PROGRESS' THEN 1 ELSE 2 END, "
                    "t.opened_at DESC, t.ticket_id DESC OFFSET :off ROWS FETCH NEXT :n ROWS ONLY",
                    {**p, "off": (page - 1) * PER_PAGE, "n": PER_PAGE})
    summary = db.query("SELECT category, total, open_tickets, avg_days_to_close FROM v_ticket_summary ORDER BY total DESC")
    return render_template("tickets.html", rows=rows, total=total, page=page, pages=max((total + PER_PAGE - 1) // PER_PAGE, 1),
                           summary=summary, a=a)


@app.post("/tickets/new")
@login_required
def ticket_new():
    f = request.form
    return run(lambda: db.call("sp_open_ticket", (f["customer_id"].strip(), f["category"], f["priority"], f["subject"]), outs=(int,)),
               lambda r: f"Ticket #{int(r[0])} opened.", url_for("tickets"))


@app.post("/tickets/<int:tid>/close")
@login_required
def ticket_close(tid):
    return run(lambda: db.call("sp_close_ticket", (tid, request.form.get("resolution") or "Resolved")),
               f"Ticket #{tid} closed.", request.form.get("back") or url_for("tickets"))


# ------------------------------------------------------------------ analytics
@app.route("/analytics")
@login_required
def analytics():
    seg = db.call_cursor("pkg_retainai.segment_report")
    risk = db.query("SELECT risk_band, customers, churned, observed_churn_pct, avg_score FROM v_risk_distribution ORDER BY avg_score DESC")
    return render_template("analytics.html", seg=seg, risk=risk)


# ------------------------------------------------------------------ retention
@app.route("/retention")
@login_required
def retention():
    a = request.args
    camps = db.query("SELECT * FROM v_campaign_effectiveness ORDER BY campaign_id")
    where, p = [], {}
    if a.get("campaign"):
        where.append("ra.campaign_id = :cid"); p["cid"] = int(a["campaign"])
    if a.get("outcome"):
        where.append("ra.outcome = :o"); p["o"] = a["outcome"]
    sql = ("SELECT ra.action_id, ra.customer_id, c.full_name, ra.action_type, ra.action_date, ra.outcome, ra.notes, rc.campaign_name "
           "FROM retention_actions ra JOIN customers c ON c.customer_id = ra.customer_id "
           "LEFT JOIN retention_campaigns rc ON rc.campaign_id = ra.campaign_id" +
           (" WHERE " + " AND ".join(where) if where else "") +
           " ORDER BY CASE ra.outcome WHEN 'PENDING' THEN 0 ELSE 1 END, ra.action_id DESC FETCH FIRST 30 ROWS ONLY")
    return render_template("retention.html", camps=camps, actions=db.query(sql, p), a=a,
                           segments=["ANY", "At Risk", "New", "Standard", "Loyal", "Champion"])


@app.post("/retention/campaign")
@login_required
def campaign_new():
    f = request.form
    return run(lambda: db.call("sp_create_campaign", (f["name"], f["segment"], f["offer"], float(f.get("discount") or 0),
                                                     db.to_date(f["start"]), db.to_date(f["end"]), ), outs=(int,)),
               lambda r: f"Campaign #{int(r[0])} created.", url_for("retention"))


@app.post("/retention/campaign/<int:cid>/plan")
@login_required
def campaign_plan(cid):
    return run(lambda: db.call("sp_plan_retention", (cid,), outs=(int,)),
               lambda r: f"{int(r[0])} retention actions planned for HIGH-risk active customers.", url_for("retention"))


@app.post("/retention/action/<int:aid>")
@login_required
def action_outcome(aid):
    return run(lambda: db.call("sp_record_outcome", (aid, request.form["outcome"], None)),
               f"Outcome recorded for action #{aid}.", request.form.get("back") or url_for("retention"))


# ------------------------------------------------------------------ reports
@app.route("/reports")
@login_required
def reports():
    limit = min(int(request.args.get("limit", 25) or 25), 500)
    return render_template("reports.html", limit=limit,
                           top=db.call_cursor("pkg_retainai.high_risk_report", (limit,)),
                           seg=db.call_cursor("pkg_retainai.segment_report"),
                           contract=db.call_cursor("pkg_retainai.churn_breakdown", ("CONTRACT",)),
                           tenure=db.call_cursor("pkg_retainai.churn_breakdown", ("TENURE_BAND",)),
                           k=db.call_cursor("pkg_retainai.dashboard_kpis")[0])


@app.route("/reports/high_risk.csv")
@login_required
def report_csv():
    rows = db.call_cursor("pkg_retainai.high_risk_report", (min(int(request.args.get("limit", 100) or 100), 5000),))
    buf = io.StringIO()
    w = csv.writer(buf)
    cols = ["priority_rank", "customer_id", "full_name", "contract_name", "payment_method", "tenure_months", "monthly_charge",
            "rule_score", "risk_band", "segment", "ml_probability"]
    w.writerow(cols)
    for r in rows:
        w.writerow([r.get(c) for c in cols])
    return Response(buf.getvalue(), mimetype="text/csv", headers={"Content-Disposition": "attachment; filename=retainai_high_risk.csv"})


# ------------------------------------------------------------------ machine learning
@app.route("/ml", methods=["GET", "POST"])
@login_required
def ml_page():
    import ml
    result = None
    if request.method == "POST" and request.form.get("action") == "train":
        try:
            result = ml.train_and_score()
            flash(f"Model '{result['best']}' trained; {result['scored']} customers scored and saved to CHURN_SCORES.", "ok")
        except oracledb.DatabaseError as e:
            flash(ora_message(e), "err")
        except Exception as e:  # scikit-learn / data problems
            flash(f"Training failed: {e}", "err")
    prediction = None
    if request.method == "POST" and request.form.get("action") == "predict":
        f = request.form
        prediction = ml.predict_one(dict(
            tenure_months=float(f["tenure"]), monthly_charge=float(f["charge"]), addon_count=float(f["addons"]),
            contract_name=f["contract"], internet_service=f["internet"], payment_method=f["payment"],
            paperless_billing=f.get("paperless", "N"), senior_citizen=f.get("senior", "N"),
            has_partner=f.get("partner", "N"), has_dependents=f.get("dependents", "N"), phone_service="Y"))
        if prediction is None:
            flash("Train the model first.", "err")
    runs = db.query("SELECT run_id, model_name, trained_at, n_train, n_test, accuracy, precision_ AS prec, recall, f1, roc_auc, details "
                    "FROM ml_model_runs ORDER BY run_id DESC FETCH FIRST 5 ROWS ONLY")
    contracts = [r["contract_name"] for r in db.query("SELECT contract_name FROM contract_types ORDER BY term_months")]
    methods = [r["method_name"] for r in db.query("SELECT method_name FROM payment_methods ORDER BY 1")]
    return render_template("ml.html", result=result, runs=runs, prediction=prediction, contracts=contracts, methods=methods,
                           f=request.form)


# ------------------------------------------------------------------ admin
@app.route("/admin")
@login_required
def admin():
    tables = db.query("""SELECT 'CUSTOMERS' AS name, COUNT(*) AS n FROM customers UNION ALL
                         SELECT 'SUBSCRIPTIONS', COUNT(*) FROM subscriptions UNION ALL
                         SELECT 'SUBSCRIPTION_SERVICES', COUNT(*) FROM subscription_services UNION ALL
                         SELECT 'BILLING_RECORDS', COUNT(*) FROM billing_records UNION ALL
                         SELECT 'SUPPORT_TICKETS', COUNT(*) FROM support_tickets UNION ALL
                         SELECT 'RETENTION_CAMPAIGNS', COUNT(*) FROM retention_campaigns UNION ALL
                         SELECT 'RETENTION_ACTIONS', COUNT(*) FROM retention_actions UNION ALL
                         SELECT 'CHURN_SCORES', COUNT(*) FROM churn_scores UNION ALL
                         SELECT 'AUDIT_LOG', COUNT(*) FROM audit_log""")
    objects = db.query("""SELECT object_type, COUNT(*) AS total, SUM(CASE WHEN status = 'VALID' THEN 1 ELSE 0 END) AS valid
                            FROM user_objects WHERE object_type IN ('TABLE','VIEW','FUNCTION','PROCEDURE','PACKAGE','PACKAGE BODY',
                            'TRIGGER','SEQUENCE','INDEX') GROUP BY object_type ORDER BY object_type""")
    triggers = db.query("SELECT trigger_name, triggering_event, table_name, status FROM user_triggers ORDER BY table_name, trigger_name")
    audit = db.query("SELECT audit_id, table_name, operation, record_key, old_value, new_value, changed_at FROM audit_log "
                     "ORDER BY audit_id DESC FETCH FIRST 15 ROWS ONLY")
    tests = db.query("SELECT tc_id, description, status FROM test_results ORDER BY tc_id")
    return render_template("admin.html", tables=tables, objects=objects, triggers=triggers, audit=audit, tests=tests,
                           ref=db.scalar("SELECT config_value FROM app_config WHERE config_key = 'REFERENCE_DATE'"))


@app.post("/admin/refresh")
@login_required
def admin_refresh():
    return run(lambda: db.call("pkg_retainai.refresh_analytics", (), outs=(int,)),
               lambda r: f"Analytics refreshed: {int(r[0])} customers re-scored.", url_for("admin"))


@app.post("/admin/refdate")
@login_required
def admin_refdate():
    return run(lambda: db.call("sp_set_reference_date", (db.to_date(request.form["date"]),)),
               "Business date updated.", url_for("admin"))


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.getenv("PORT", "5000")), debug=False)
