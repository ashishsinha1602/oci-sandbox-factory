"""Tiny demo app: shows what the sandbox injected into the container."""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("PORT", "8080"))
SHOW = ("SANDBOX_ID", "SANDBOX_EXPIRES", "ADB_DB_NAME", "ADB_CONNECT_STRING", "KAFKA_BOOTSTRAP_SERVERS")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = {
            "hello": "from OCI Sandbox Factory",
            "sandbox": {k: os.environ.get(k) for k in SHOW if os.environ.get(k)},
            "path": self.path,
        }
        data = json.dumps(body, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    print(f"listening on {PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
