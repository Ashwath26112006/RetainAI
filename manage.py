"""Project command runner - use from the VS Code terminal:  python manage.py <command>

  install   install the Python packages
  schema    create the RETAINAI schema owner (OS-authenticated SYSDBA, no password needed)
  build     build all database objects, load the data, run reports and the 34 SQL test cases
  run       start the web application  (http://127.0.0.1:5000, admin / retainai)
  uitests   run the 19 browser test cases (UI01-UI19)
  setup     install + schema + build
"""
import os, subprocess, sys, shutil

ROOT = os.path.dirname(os.path.abspath(__file__))
ORACLE_HOME = os.environ.get("ORACLE_HOME_XE", r"C:\app\ashwa\product\21c\dbhomeXE")
DSN = os.environ.get("RETAINAI_DSN", "localhost:1521/XEPDB1")
USER, PWD = os.environ.get("RETAINAI_USER", "retainai"), os.environ.get("RETAINAI_PASSWORD", "RetainAI2026")
os.chdir(ROOT)


def sqlplus_exe():
    exe = shutil.which("sqlplus")
    if exe:
        return exe
    cand = os.path.join(ORACLE_HOME, "bin", "sqlplus.exe")
    if os.path.exists(cand):
        return cand
    sys.exit("sqlplus not found - set ORACLE_HOME_XE to your Oracle home or add its bin folder to PATH")


def run(cmd):
    print(">", " ".join(cmd)); r = subprocess.run(cmd)
    if r.returncode:
        sys.exit(r.returncode)


def sql(login, script):
    run([sqlplus_exe(), "-L", "-S", login, "@" + script])


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd in ("install", "setup"):
        run([sys.executable, "-m", "pip", "install", "-r", "requirements.txt"])
    if cmd in ("schema", "setup"):
        pwd = os.environ.get("SYSTEM_PWD")
        sql(f"system/{pwd}@{DSN}" if pwd else "/ as sysdba", os.path.join("sql", "00_create_user.sql"))
    if cmd in ("build", "setup"):
        sql(f"{USER}/{PWD}@{DSN}", os.path.join("sql", "run_all.sql"))
    if cmd == "run":
        run([sys.executable, os.path.join("app", "app.py")])
    if cmd == "uitests":
        run([sys.executable, os.path.join("scripts", "ui_tests.py")])
    if cmd not in ("install", "schema", "build", "run", "uitests", "setup"):
        print(__doc__)


if __name__ == "__main__":
    main()
