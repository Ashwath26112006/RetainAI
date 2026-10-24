# RetainAI – Customer Retention Analytics Platform

RetainAI finds customers who are likely to leave and helps a retention team act on it. It combines an Oracle 21c database with a Flask web application.

What’s inside

17-table, third-normal-form Oracle schema loaded with 7,043 customers from the public Telco Customer Churn dataset
7 functions, 20 procedures, 1 package, 10 triggers and all five cursor types in PL/SQL
A rule-based churn risk score, plus an optional ML model (Logistic Regression / Gradient Boosting) whose probabilities are stored back in Oracle
Web dashboard, customer 360 view, billing, support tickets, retention campaigns and reports; every change goes through a stored procedure
34 SQL test cases and 19 browser tests

Data note: customer demographics, services, charges and churn labels are real; names, e-mails, billing history, tickets and campaign responses are synthetic.

Stack: Oracle 21c XE, PL/SQL, Python, Flask, python-oracledb, scikit-learn, Playwright
