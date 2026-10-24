"""Optional machine-learning churn model (scikit-learn) trained on data read from Oracle."""
import os
import pickle
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, f1_score, precision_score, recall_score, roc_auc_score, confusion_matrix
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

import db

MODEL_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model.pkl")
NUM = ["tenure_months", "monthly_charge", "addon_count"]
CAT = ["contract_name", "internet_service", "payment_method", "paperless_billing", "senior_citizen",
       "has_partner", "has_dependents", "phone_service"]

FEATURE_SQL = """
SELECT customer_id, customer_status, tenure_months, monthly_charge, addon_count, contract_name, internet_service,
       payment_method, paperless_billing, senior_citizen, has_partner, has_dependents, phone_service
  FROM v_customer_360
"""


def load_frame():
    df = pd.DataFrame(db.query(FEATURE_SQL))
    for c in NUM:
        df[c] = df[c].astype(float)
    df["y"] = (df["customer_status"] == "CHURNED").astype(int)
    return df


def _pipe(clf):
    pre = ColumnTransformer([("num", StandardScaler(), NUM),
                             ("cat", OneHotEncoder(handle_unknown="ignore"), CAT)])
    return Pipeline([("pre", pre), ("clf", clf)])


def train_and_score():
    """Train two candidate models, keep the one with the best hold-out ROC-AUC,
    write every customer's churn probability back to Oracle (procedure SP_SAVE_ML_SCORE)."""
    df = load_frame()
    X, y = df[NUM + CAT], df["y"]
    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.25, stratify=y, random_state=42)
    candidates = {
        "Logistic Regression": _pipe(LogisticRegression(max_iter=2000, C=1.0)),
        "Gradient Boosting": _pipe(GradientBoostingClassifier(random_state=42)),
    }
    results = {}
    for name, pipe in candidates.items():
        pipe.fit(Xtr, ytr)
        p = pipe.predict_proba(Xte)[:, 1]
        pred = (p >= 0.5).astype(int)
        results[name] = dict(
            model=name, auc=roc_auc_score(yte, p), accuracy=accuracy_score(yte, pred),
            precision=precision_score(yte, pred, zero_division=0), recall=recall_score(yte, pred),
            f1=f1_score(yte, pred), cm=confusion_matrix(yte, pred).tolist())
    best_name = max(results, key=lambda k: results[k]["auc"])
    best = candidates[best_name]
    best.fit(X, y)  # final model uses all labelled history
    probs = best.predict_proba(X)[:, 1]

    # top drivers (logistic regression coefficients, if that model won; otherwise feature importances)
    names = best.named_steps["pre"].get_feature_names_out()
    clf = best.named_steps["clf"]
    weights = clf.coef_[0] if hasattr(clf, "coef_") else clf.feature_importances_
    order = np.argsort(-np.abs(weights))[:10]
    drivers = [(str(names[i]).replace("num__", "").replace("cat__", ""), float(weights[i])) for i in order]

    rows = [(cid, float(round(p, 6)), best_name) for cid, p in zip(df["customer_id"], probs)]
    with db.pool().acquire() as con:
        cur = con.cursor()
        cur.executemany("BEGIN sp_save_ml_score(:1, :2, :3); END;", rows)
        r = results[best_name]
        cur.callproc("sp_log_ml_run", [best_name, len(Xtr), len(Xte), round(r["accuracy"], 4), round(r["precision"], 4),
                                       round(r["recall"], 4), round(r["f1"], 4), round(r["auc"], 4),
                                       "; ".join(f"{n}={w:.3f}" for n, w in drivers)])
        con.commit()
    with open(MODEL_FILE, "wb") as f:
        pickle.dump(best, f)
    return dict(best=best_name, results=results, drivers=drivers, n_train=len(Xtr), n_test=len(Xte),
                scored=len(rows))


def predict_one(values):
    if not os.path.exists(MODEL_FILE):
        return None
    with open(MODEL_FILE, "rb") as f:
        model = pickle.load(f)
    row = pd.DataFrame([values])[NUM + CAT]
    return float(model.predict_proba(row)[0, 1])
