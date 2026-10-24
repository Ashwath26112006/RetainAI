"""Thin Oracle access layer (python-oracledb, thin mode - no Oracle client needed)."""
import os
import datetime as dt
import oracledb

DSN = os.getenv("RETAINAI_DSN", "localhost:1521/XEPDB1")
USER = os.getenv("RETAINAI_USER", "retainai")
PASSWORD = os.getenv("RETAINAI_PASSWORD", "RetainAI2026")

_pool = None


def pool():
    global _pool
    if _pool is None:
        _pool = oracledb.create_pool(user=USER, password=PASSWORD, dsn=DSN, min=1, max=8, increment=1)
    return _pool


def _clean(v):
    if isinstance(v, oracledb.LOB):
        return v.read()
    return v


def _rows(cur):
    cols = [d[0].lower() for d in cur.description]
    return [dict(zip(cols, (_clean(x) for x in r))) for r in cur.fetchall()]


def query(sql, params=None):
    """Run a SELECT and return a list of dicts (lower-case keys)."""
    with pool().acquire() as con:
        cur = con.cursor()
        cur.execute(sql, params or {})
        return _rows(cur)


def one(sql, params=None):
    rows = query(sql, params)
    return rows[0] if rows else None


def scalar(sql, params=None):
    r = one(sql, params)
    return None if r is None else next(iter(r.values()))


def execute(sql, params=None):
    with pool().acquire() as con:
        cur = con.cursor()
        cur.execute(sql, params or {})
        con.commit()
        return cur.rowcount


def call(proc, args=(), outs=()):
    """Call a stored procedure. `outs` is a tuple of python types (str/int/float) for trailing OUT params.
    Returns the list of OUT values (or None)."""
    with pool().acquire() as con:
        cur = con.cursor()
        out_vars = []
        for t in outs:
            if t is str:
                out_vars.append(cur.var(oracledb.DB_TYPE_VARCHAR, 100))
            else:
                out_vars.append(cur.var(oracledb.DB_TYPE_NUMBER))
        cur.callproc(proc, list(args) + out_vars)
        con.commit()
        return [v.getvalue() for v in out_vars] if out_vars else None


def call_cursor(proc, args=()):
    """Call a procedure whose LAST parameter is an OUT SYS_REFCURSOR; return rows as dicts."""
    with pool().acquire() as con:
        cur = con.cursor()
        rc = con.cursor()
        cur.callproc(proc, list(args) + [rc])
        return _rows(rc)


def func(name, args=()):
    with pool().acquire() as con:
        cur = con.cursor()
        return cur.callfunc(name, oracledb.DB_TYPE_NUMBER, list(args))


def to_date(s):
    return dt.datetime.strptime(s, "%Y-%m-%d") if s else None
