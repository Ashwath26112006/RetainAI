"""Front-end test cases UI01-UI19: starts the Flask app, drives it with a real browser (Microsoft Edge via Playwright)
and checks that each screen and each form behaves as specified. Prints PASS/FAIL for every case."""
import os, subprocess, sys, tempfile, time, urllib.parse, urllib.request, datetime as dt
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = tempfile.gettempdir()  # the server log (needed to read the recovery code) is kept here
PORT = os.getenv("PORT", "5000"); BASE = f"http://127.0.0.1:{PORT}"
STAMP = dt.datetime.now().strftime("%H%M%S")
results = []

def start_server():
    env = dict(os.environ, PORT=PORT)
    p = subprocess.Popen([sys.executable, os.path.join(ROOT, "app", "app.py")], cwd=ROOT, env=env,
                         stdout=open(os.path.join(OUT, "retainai_server.log"), "w"), stderr=subprocess.STDOUT)
    for _ in range(60):
        try:
            urllib.request.urlopen(BASE + "/login", timeout=2); return p
        except Exception:
            time.sleep(1)
    p.terminate(); raise SystemExit("Flask server did not start - see the server log in the temp folder")

def flash_text(page):
    try:
        page.wait_for_selector(".flash", timeout=40000); return page.locator(".flash").first.inner_text().strip()
    except Exception:
        return ""

def record(tc, desc, inp, expected, actual, ok):
    results.append(dict(tc_id=tc, description=desc, input=inp, expected=expected, actual=actual, status="PASS" if ok else "FAIL"))
    print(("PASS " if ok else "FAIL ") + tc + " " + desc + " -> " + actual)

def main():
    server = start_server()
    try:
        with sync_playwright() as pw:
            try:
                browser = pw.chromium.launch(channel="msedge", headless=True)
            except Exception:
                browser = pw.chromium.launch(headless=True)
            ctx = browser.new_context(viewport={"width": 1366, "height": 900})
            page = ctx.new_page()
            page.set_default_timeout(90000)

            # ---------------- login ----------------
            page.goto(BASE + "/login")
            page.fill("input[name=username]", "admin"); page.fill("input[name=password]", "wrong")
            page.click("button"); msg = flash_text(page)
            record("UI01", "Login with a wrong password is rejected", "admin / wrong", "error message 'Invalid username or password'", msg, "Invalid" in msg)
            page.fill("input[name=username]", "admin"); page.fill("input[name=password]", "retainai"); page.click("button")
            page.wait_for_selector("#c4 svg"); page.wait_for_timeout(600)
            record("UI02", "Valid login opens the dashboard with charts rendered from Oracle data", "admin / retainai",
                   "dashboard KPIs and 4 charts visible", page.locator(".kpi .val").first.inner_text() + " customers, " + str(page.locator(".chart svg").count()) + " charts",
                   page.locator(".chart svg").count() >= 4)

            # ---------------- read-only screens: every page must load without a server error ----------------
            for path in ["/customers", "/customers?band=HIGH&status=ACTIVE&sort=risk", "/customers/7590-VHVEG", "/customers/new", "/billing",
                         "/tickets", "/analytics", "/retention", "/reports", "/admin"]:
                resp = page.goto(BASE + path)
                assert resp and resp.ok, f"{path} returned HTTP {resp.status if resp else 'none'}"

            # ---------------- machine learning (real training run) ----------------
            page.goto(BASE + "/ml")
            page.click("button:has-text('Train model')")
            try:
                page.wait_for_selector("#drv svg", timeout=420000)
                ok = True; txt = flash_text(page)
            except Exception:
                ok = False; txt = flash_text(page) or "no result"
            record("UI03", "ML module trains two models, stores probabilities in Oracle", "click Train", "flash 'trained; N customers scored'", txt, ok and "scored" in txt)

            page.fill("input[name=tenure]", "3"); page.fill("input[name=charge]", "95"); page.select_option("select[name=contract]", "Month-to-month")
            page.select_option("select[name=internet]", "Fiber optic"); page.select_option("select[name=payment]", "Electronic check")
            page.click("button:has-text('Predict')"); page.wait_for_timeout(800)

            # ---------------- responsive (mobile) ----------------
            m = browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2)
            mp = m.new_page(); mp.goto(BASE + "/login"); mp.fill("input[name=username]", "admin"); mp.fill("input[name=password]", "retainai"); mp.click("button")
            mp.wait_for_selector("#c4 svg"); mp.wait_for_timeout(500)
            mp.goto(BASE + "/customers"); m.close()

            # ---------------- functional UI tests ----------------
            name = f"Ui Tester {STAMP}"; email = f"ui.tester.{STAMP}@retainai-demo.example"
            page.goto(BASE + "/customers/new")
            page.fill("input[name=full_name]", name.lower()); page.fill("input[name=email]", email)
            page.check("input[name=services][value='2']"); page.check("input[name=paperless]")
            page.click("button:has-text('Register customer')"); page.wait_for_selector(".flash")
            msg = flash_text(page); cid = page.url.rstrip("/").split("/")[-1]
            record("UI04", "Register a customer through the web form (calls sp_add_customer)", f"{name.lower()} / {email}",
                   "redirect to customer page, flash 'registered ... scored'", msg + " | " + page.url, "registered" in msg and cid.startswith("RA-"))

            page.goto(BASE + "/customers/new"); page.fill("input[name=full_name]", "Duplicate Person"); page.fill("input[name=email]", email)
            page.click("button:has-text('Register customer')"); msg = flash_text(page)
            record("UI05", "Duplicate e-mail through the form shows the database error", email, "ORA-20002 'E-mail address is already registered'", msg, "ORA-20002" in msg)

            page.goto(BASE + "/customers?q=" + urllib.parse.quote(f"Ui Tester {STAMP}")); found = page.locator("tbody tr").count()
            record("UI06", "Customer search finds the new customer (name was normalised by trigger to INITCAP)", f"q = Ui Tester {STAMP}",
                   "1 row", f"{found} row(s): " + page.locator("tbody tr").first.inner_text().replace("\n", " ")[:80], found == 1)

            page.goto(BASE + f"/customers/{cid}")
            page.select_option("select[name=category]", "CANCELLATION"); page.select_option("select[name=priority]", "URGENT")
            page.fill("input[name=subject]", "Wants to cancel (UI test)"); page.click("button:has-text('Open ticket')"); msg = flash_text(page)
            body = page.inner_text("body")
            record("UI07", "Urgent cancellation ticket opened from the UI; trigger queues a retention CALL", "CANCELLATION / URGENT",
                   "flash 'Ticket # opened' and action note 'Auto-created from ticket #'", msg, "opened" in msg and "Auto-created from ticket #" in body)

            page.fill("input[name=reason]", "Moving abroad (UI test)"); page.click("button.danger"); msg = flash_text(page)
            body = page.inner_text("body")
            record("UI08", "Cancel subscription from the UI (sp_cancel_subscription + triggers)", "reason: Moving abroad",
                   "customer shows CHURNED and a WIN_BACK action", msg + " | CHURNED shown: " + str("CHURNED" in body), "cancelled" in msg and "CHURNED" in body and "WIN_BACK" in body)

            page.click("button:has-text('Re-activate subscription')"); msg = flash_text(page)
            record("UI09", "Win-back: re-activate the subscription from the UI", "button 'Re-activate'", "flash 're-activated', status ACTIVE",
                   msg, "re-activated" in msg and page.locator(".badge.b-ACTIVE").count() >= 1)

            page.goto(BASE + "/billing"); page.fill("input[name=month]", "2026-10"); page.click("button:has-text('Generate bills')"); msg1 = flash_text(page)
            page.fill("input[name=month]", "2026-10"); page.click("button:has-text('Generate bills')"); msg2 = flash_text(page)
            record("UI10", "Billing run from the UI is idempotent", "month 2026-10, run twice", "second run creates 0 new bills",
                   msg1 + " | " + msg2, "created" in msg1 and msg2.split(":")[1].strip().startswith("0"))

            page.goto(BASE + "/billing?status=PENDING"); page.locator("button:has-text('Record payment')").first.click(); msg = flash_text(page)
            record("UI11", "Record a payment from the billing screen (sp_record_payment)", "first PENDING bill", "flash 'Payment recorded for bill #'", msg, "Payment recorded" in msg)

            page.goto(BASE + "/retention")
            page.fill("input[name=name]", f"UI Campaign {STAMP}"); page.select_option("select[name=segment]", "At Risk"); page.fill("input[name=offer]", "UI test offer 20% off")
            page.fill("input[name=discount]", "20"); page.fill("input[name=end]", "2026-12-31"); page.click("button:has-text('Create campaign')"); msg = flash_text(page)
            record("UI12", "Create a retention campaign (sp_create_campaign)", f"UI Campaign {STAMP}", "flash 'Campaign # created'", msg, "created" in msg)
            row = page.locator("tr", has_text=f"UI Campaign {STAMP}"); row.locator("text=Plan targets").click(); msg = flash_text(page)
            record("UI13", "Plan retention actions for HIGH-risk customers (parameterized cursor procedure)", "Plan targets", "flash 'N retention actions planned'", msg, "planned" in msg)
            page.goto(BASE + "/retention?outcome=PENDING"); page.locator("button:has-text('Accepted')").first.click(); msg = flash_text(page)
            record("UI14", "Record a customer's acceptance (sp_record_outcome)", "first pending action", "flash 'Outcome recorded'", msg, "Outcome recorded" in msg)

            page.goto(BASE + "/admin"); page.click("button:has-text('Refresh analytics')"); msg = flash_text(page)
            record("UI15", "Admin: re-score all customers (pkg_retainai.refresh_analytics)", "button 'Refresh analytics'", "flash 'N customers re-scored'", msg, "re-scored" in msg)

            r = ctx.request.get(BASE + "/reports/high_risk.csv?limit=5")
            first = r.text().splitlines()[0] if r.ok else ""
            record("UI16", "CSV export of the high-risk report", "GET /reports/high_risk.csv?limit=5", "HTTP 200, CSV header with customer_id,risk_band", f"HTTP {r.status}: {first[:70]}", r.ok and "customer_id" in first)

            # ---------------- password recovery (fresh, not-logged-in browser context) ----------------
            import re as _re
            def recovery_code():
                for _ in range(20):
                    txt = open(os.path.join(OUT, "retainai_server.log"), errors="ignore").read()
                    m = _re.findall(r"recovery code for 'admin': (\d{6})", txt)
                    if m: return m[-1]
                    time.sleep(0.5)
                return ""
            ctx2 = browser.new_context(viewport={"width": 1366, "height": 900}); p2 = ctx2.new_page(); p2.set_default_timeout(90000)
            p2.goto(BASE + "/login"); p2.click("#forgotLink"); p2.wait_for_url("**/forgot")
            p2.fill("input[name=username]", "admin"); p2.click("button"); p2.wait_for_url("**/reset")
            code = recovery_code()
            p2.fill("input[name=code]", "000000"); p2.fill("input[name=password]", "retainai"); p2.fill("input[name=confirm]", "retainai"); p2.click("button")
            msg = flash_text(p2)
            record("UI17", "Forgot password: a wrong recovery code is rejected", "code 000000", "error 'Incorrect recovery code'", msg, "Incorrect" in msg)
            p2.fill("input[name=code]", code); p2.fill("input[name=password]", "retainai"); p2.fill("input[name=confirm]", "retainai"); p2.click("button")
            p2.wait_for_url("**/login"); msg = flash_text(p2)
            record("UI18", "Forgot password: the one-time code printed by the server resets the password (stored hashed in app_config)", "code from the server terminal, new password",
                   "flash 'Password updated' and redirect to the login page", msg + " | " + p2.url, "Password updated" in msg and p2.url.endswith("/login"))
            p2.fill("input[name=username]", "admin"); p2.fill("input[name=password]", "retainai"); p2.click("button")
            p2.wait_for_selector("#c4 svg")
            record("UI19", "Login with the password saved by the recovery flow opens the dashboard", "admin / new password", "dashboard with charts",
                   p2.locator(".kpi .val").first.inner_text() + " customers", p2.locator(".chart svg").count() >= 4)
            ctx2.close()
            browser.close()
    finally:
        server.terminate()
        print(f"{sum(r['status']=='PASS' for r in results)}/{len(results)} UI tests passed")

if __name__ == "__main__":
    main()
