"""Records the real hardware / software environment used for the run (written to outputs/environment.json)."""
import json, os, platform, subprocess, sys

def ps(cmd):
    try:
        return subprocess.run(["powershell", "-NoProfile", "-Command", cmd], capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception as e:
        return f"n/a ({e})"

info = {"python": sys.version.split()[0], "platform": platform.platform(), "machine": platform.machine()}
if os.name == "nt":
    info["cpu"] = ps("(Get-CimInstance Win32_Processor | Select-Object -First 1).Name")
    info["ram_gb"] = ps("[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)")
    info["disk"] = ps("$d=Get-CimInstance Win32_DiskDrive | Select-Object -First 1; \"$($d.Model) $([math]::Round($d.Size/1GB)) GB\"")
    info["os"] = ps("(Get-CimInstance Win32_OperatingSystem).Caption + ' ' + (Get-CimInstance Win32_OperatingSystem).Version")
    info["edge"] = ps("(Get-Item \"${env:ProgramFiles(x86)}\\Microsoft\\Edge\\Application\\msedge.exe\").VersionInfo.ProductVersion")
for mod in ("flask", "oracledb", "sklearn", "pandas", "numpy", "playwright"):
    try:
        m = __import__(mod)
        info[mod] = getattr(m, "__version__", getattr(m, "version", "installed"))
    except Exception as e:
        info[mod] = f"missing ({e})"
try:
    import oracledb
    c = oracledb.connect(user=os.getenv("RETAINAI_USER", "retainai"), password=os.getenv("RETAINAI_PASSWORD", "RetainAI2026"),
                         dsn=os.getenv("RETAINAI_DSN", "localhost:1521/XEPDB1"))
    info["oracle_version"] = c.version
    cur = c.cursor()
    cur.execute("SELECT banner_full FROM v$version FETCH FIRST 1 ROW ONLY") if False else None
except Exception as e:
    info["oracle_version"] = f"unavailable ({e})"
os.makedirs("outputs", exist_ok=True)
json.dump(info, open(os.path.join("outputs", "environment.json"), "w"), indent=2)
print(json.dumps(info, indent=2))
