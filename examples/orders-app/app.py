"""Orders demo: a tiny web app that really uses the sandbox's Autonomous Database.

Reads ADB_CONNECT_STRING / ADB_ADMIN_PASSWORD (injected by the sandbox stack),
creates an ORDERS table on first start, and serves:
  GET  /             HTML page: order form + list + counts
  POST /order        add an order (form or JSON: item, qty)
  GET  /api/orders   JSON list
  GET  /health       200 when the database answers
"""

import html
import json
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

import oracledb

PORT = int(os.environ.get("PORT", "8080"))
SANDBOX = os.environ.get("SANDBOX_ID", "?")
EXPIRES = os.environ.get("SANDBOX_EXPIRES", "?")
CONNECT = os.environ.get("ADB_CONNECT_STRING", "")
PASSWORD = os.environ.get("ADB_ADMIN_PASSWORD", "")


def dsn() -> str:
    host_port, service = CONNECT.split("/", 1)
    host, port = host_port.split(":")
    return (f"(description=(retry_count=5)(retry_delay=3)(address=(protocol=tcps)(port={port})(host={host}))"
            f"(connect_data=(service_name={service}))(security=(ssl_server_dn_match=yes)))")


def db():
    return oracledb.connect(user="ADMIN", password=PASSWORD, dsn=dsn())


def init():
    with db() as c:
        cur = c.cursor()
        cur.execute("select count(*) from user_tables where table_name = 'ORDERS'")
        if cur.fetchone()[0] == 0:
            cur.execute("""create table orders (
                id number generated always as identity primary key,
                item varchar2(200) not null, qty number default 1 not null,
                created_at timestamp default systimestamp not null)""")
            c.commit()
            print("created table ORDERS", flush=True)


def orders():
    with db() as c:
        cur = c.cursor()
        cur.execute("select id, item, qty, to_char(created_at, 'YYYY-MM-DD HH24:MI:SS') from orders order by id desc fetch first 50 rows only")
        return [dict(id=r[0], item=r[1], qty=r[2], created_at=r[3]) for r in cur.fetchall()]


def add(item: str, qty: int):
    with db() as c:
        c.cursor().execute("insert into orders (item, qty) values (:1, :2)", [item[:200], max(1, qty)])
        c.commit()


PAGE = """<!doctype html><meta charset="utf-8"><title>Orders on {sbx}</title>
<style>body{{font-family:system-ui,sans-serif;max-width:760px;margin:40px auto;padding:0 16px;color:#1f2937}}
h1{{margin-bottom:4px}}.sub{{color:#6b7280;margin-bottom:24px}}form{{display:flex;gap:8px;margin-bottom:20px}}
input{{padding:10px;border:1px solid #cfd6df;border-radius:8px;font-size:14px}}button{{background:#1a73e8;color:#fff;border:0;border-radius:8px;padding:10px 18px;font-weight:600}}
table{{width:100%;border-collapse:collapse}}td,th{{padding:8px 10px;border-bottom:1px solid #e5e7eb;text-align:left}}
.k{{display:inline-block;background:#f1f5f9;border-radius:999px;padding:3px 10px;font-size:12px;margin-right:6px}}</style>
<h1>Orders</h1><div class="sub"><span class="k">sandbox {sbx}</span><span class="k">expires {exp}</span><span class="k">Autonomous Database {db}</span><span class="k">{n} orders</span></div>
<form method="post" action="/order"><input name="item" placeholder="What was ordered?" required autofocus><input name="qty" type="number" value="1" min="1" style="width:80px"><button>Add order</button></form>
<table><tr><th>#</th><th>Item</th><th>Qty</th><th>Created</th></tr>{rows}</table>
<p class="sub">Every row lives in the sandbox's ATP. <a href="/api/orders">JSON</a> &middot; <a href="/health">health</a></p>"""


class H(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            if self.path.startswith("/api/orders"):
                return self.send(200, json.dumps(orders(), indent=1), "application/json")
            if self.path.startswith("/health"):
                with db() as c:
                    c.cursor().execute("select 1 from dual")
                return self.send(200, "ok", "text/plain")
            rows = orders()
            table = "".join(f"<tr><td>{r['id']}</td><td>{html.escape(r['item'])}</td><td>{r['qty']}</td><td>{r['created_at']}</td></tr>" for r in rows)
            return self.send(200, PAGE.format(sbx=SANDBOX, exp=EXPIRES, db=os.environ.get("ADB_DB_NAME", "?"), n=len(rows), rows=table or "<tr><td colspan=4>No orders yet</td></tr>"))
        except Exception as e:  # noqa: BLE001
            return self.send(500, f"error: {e}", "text/plain")

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(n).decode()
            if self.headers.get("Content-Type", "").startswith("application/json"):
                body = json.loads(raw or "{}")
            else:
                body = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
            add(str(body.get("item", "")).strip() or "unnamed", int(body.get("qty", 1)))
            if self.headers.get("Content-Type", "").startswith("application/json"):
                return self.send(201, json.dumps({"ok": True}), "application/json")
            self.send_response(303)
            self.send_header("Location", "/")
            self.end_headers()
        except Exception as e:  # noqa: BLE001
            return self.send(500, f"error: {e}", "text/plain")

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    print(f"orders app on {PORT}; db {CONNECT or 'MISSING'}", flush=True)
    for attempt in range(30):
        try:
            init()
            break
        except Exception as e:  # noqa: BLE001
            print(f"db not ready ({e}); retry {attempt}", flush=True)
            import time
            time.sleep(10)
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
