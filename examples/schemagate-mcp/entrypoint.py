"""Start schemagate's MCP server against the sandbox database.

Maps the Sandbox Factory environment (ADB_CONNECT_STRING = host:port/service,
ADB_ADMIN_PASSWORD) onto what schemagate expects: a SQLAlchemy URL plus
connect args holding a full TLS descriptor, exactly like the OCI Terraform
module for schemagate does.
"""

import json
import os
import runpy
import sys
import time

connect = os.environ.get("ADB_CONNECT_STRING", "")
password = os.environ.get("ADB_ADMIN_PASSWORD", "")
if not connect or not password:
    print("ADB_CONNECT_STRING / ADB_ADMIN_PASSWORD missing: request the sandbox with a database", flush=True)
    sys.exit(1)

host_port, service = connect.split("/", 1)
host, port = host_port.split(":")
dsn = (f"(description=(retry_count=20)(retry_delay=3)(address=(protocol=tcps)(port={port})(host={host}))"
       f"(connect_data=(service_name={service}))(security=(ssl_server_dn_match=yes)))")

os.environ.setdefault("SCHEMAGATE_DATABASE_URL", "oracle+oracledb://@")
os.environ.setdefault("SCHEMAGATE_CONNECT_ARGS", json.dumps({"user": "ADMIN", "password": password, "dsn": dsn}))

# Wait for the database to accept connections (it can still be finishing up).
import oracledb  # noqa: E402

def run_seed(cur):
    """SEED_SQL (base64 of ';'-separated Oracle statements) is loaded when the schema has no tables."""
    import base64 as _b64
    raw = os.environ.get("SEED_SQL", "")
    if not raw:
        return False
    try:
        sql = _b64.b64decode(raw).decode()
    except Exception:  # noqa: BLE001
        sql = raw
    n = 0
    for stmt in [s.strip() for s in sql.split(";") if s.strip()]:
        try:
            cur.execute(stmt)
            n += 1
        except Exception as e:  # noqa: BLE001
            print(f"seed statement failed ({e}): {stmt[:80]}", flush=True)
    print(f"seeded {n} statements from SEED_SQL", flush=True)
    return n > 0

for attempt in range(30):
    try:
        with oracledb.connect(user="ADMIN", password=password, dsn=dsn) as c:
            cur = c.cursor()
            cur.execute("select count(*) from user_tables")
            if cur.fetchone()[0] == 0 and os.environ.get("SEED_SQL"):
                run_seed(cur)
                c.commit()
        break
    except Exception as e:  # noqa: BLE001
        print(f"database not ready ({e}); retry {attempt}", flush=True)
        time.sleep(10)

print(f"schemagate MCP on :{os.environ['SCHEMAGATE_MCP_PORT']} reflecting {host}/{service}", flush=True)
sys.argv = ["schemagate.mcp_server"]
runpy.run_module("schemagate.mcp_server", run_name="__main__")
