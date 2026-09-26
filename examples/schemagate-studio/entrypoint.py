"""Start schemagate Studio against the sandbox database.

Maps ADB_CONNECT_STRING (host:port/service) and ADB_ADMIN_PASSWORD onto the
SQLAlchemy URL + TLS connect args that schemagate expects, optionally seeds a
tiny demo schema (customers / products / orders) when the schema is empty,
then runs `schemagate studio` bound to all interfaces.
"""

import json
import os
import subprocess
import sys
import time

connect = os.environ.get("ADB_CONNECT_STRING", "")
password = os.environ.get("ADB_ADMIN_PASSWORD", "")
port = os.environ.get("STUDIO_PORT", "8770")
if not connect or not password:
    # No database in this sandbox: run Studio on schemagate's bundled demo database instead.
    print("no ADB_CONNECT_STRING / ADB_ADMIN_PASSWORD: starting Studio on the bundled demo database "
          "(request the sandbox with a database to reflect a real ATP)", flush=True)
    sys.exit(subprocess.call([sys.executable, "-m", "schemagate.cli", "studio",
                              "--host", "0.0.0.0", "--port", port, "--no-browser"]))

host_port, service = connect.split("/", 1)
host, dbport = host_port.split(":")
dsn = (f"(description=(retry_count=20)(retry_delay=3)(address=(protocol=tcps)(port={dbport})(host={host}))"
       f"(connect_data=(service_name={service}))(security=(ssl_server_dn_match=yes)))")
os.environ["SCHEMAGATE_DATABASE_URL"] = "oracle+oracledb://@"
os.environ["SCHEMAGATE_CONNECT_ARGS"] = json.dumps({"user": "ADMIN", "password": password, "dsn": dsn})

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

SEED = [
    """create table customers (id number generated always as identity primary key,
       name varchar2(100) not null, email varchar2(200), country varchar2(60), created_at date default sysdate)""",
    """create table products (id number generated always as identity primary key,
       name varchar2(100) not null, category varchar2(60), price number(10,2) not null)""",
    """create table orders (id number generated always as identity primary key,
       customer_id number references customers(id), product_id number references products(id),
       qty number default 1 not null, status varchar2(20) default 'NEW', ordered_at date default sysdate)""",
    "insert into customers (name, email, country) values ('Ada Lovelace', 'ada@example.com', 'UK')",
    "insert into customers (name, email, country) values ('Grace Hopper', 'grace@example.com', 'US')",
    "insert into customers (name, email, country) values ('Linus Torvalds', 'linus@example.com', 'FI')",
    "insert into products (name, category, price) values ('Laptop', 'Hardware', 1299)",
    "insert into products (name, category, price) values ('Monitor', 'Hardware', 349)",
    "insert into products (name, category, price) values ('IDE licence', 'Software', 199)",
    "insert into orders (customer_id, product_id, qty, status) values (1, 1, 1, 'SHIPPED')",
    "insert into orders (customer_id, product_id, qty, status) values (2, 3, 5, 'NEW')",
    "insert into orders (customer_id, product_id, qty, status) values (3, 2, 2, 'PAID')",
    "comment on table customers is 'People who buy from us'",
    "comment on table orders is 'One row per purchase; status NEW, PAID, SHIPPED'",
]

for attempt in range(30):
    try:
        with oracledb.connect(user="ADMIN", password=password, dsn=dsn) as c:
            cur = c.cursor()
            cur.execute("select count(*) from user_tables")
            n = cur.fetchone()[0]
            if n == 0 and os.environ.get("SEED_SQL"):
                run_seed(cur)
                c.commit()
            elif n == 0 and os.environ.get("SEED_DEMO", "yes").lower() != "no":
                for stmt in SEED:
                    cur.execute(stmt)
                c.commit()
                print("seeded demo schema: customers, products, orders", flush=True)
            else:
                print(f"database has {n} tables; not seeding", flush=True)
        break
    except Exception as e:  # noqa: BLE001
        print(f"database not ready ({e}); retry {attempt}", flush=True)
        time.sleep(10)

print(f"schemagate studio on :{port} reflecting {host}/{service}", flush=True)
sys.exit(subprocess.call([sys.executable, "-m", "schemagate.cli", "studio",
                          "--url", "oracle+oracledb://@", "--host", "0.0.0.0", "--port", port, "--no-browser"]))
