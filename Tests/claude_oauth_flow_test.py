#!/usr/bin/env python3
"""Run the Swift flow test against a loopback-only, synthetic OAuth service."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def main():
    observed = {"callback_posts": 0, "session_deletes": 0, "codes": [], "states": [], "providers": []}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send_json(self, status, value):
            encoded = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self):
            if self.path != "/test/stats":
                self.send_json(404, {"error": "unexpected fixture path"})
                return
            with lock:
                self.send_json(200, observed)

        def do_POST(self):
            if self.path != "/v8/management/oauth/callback" or self.headers.get("Authorization") != "Bearer fixture-management-key":
                self.send_json(400, {"error": "unexpected fixture callback"})
                return
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            with lock:
                observed["callback_posts"] += 1
                observed["codes"].append(data.get("code"))
                observed["states"].append(data.get("state"))
                observed["providers"].append(data.get("provider"))
            self.send_json(200, {"status": "ok"})

        def do_DELETE(self):
            parsed = urlsplit(self.path)
            if (parsed.path != "/v8/management/oauth/session"
                    or parse_qs(parsed.query) != {"state": ["fixture-state"]}
                    or self.headers.get("Authorization") != "Bearer fixture-management-key"):
                self.send_json(400, {"error": "unexpected fixture cancellation"})
                return
            with lock:
                observed["session_deletes"] += 1
            self.send_json(200, {"status": "ok", "cancelled": True})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if server.server_address[1] == 18418:
        server.server_close()
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="bridgedock-oauth-flow-") as root:
            env = dict(os.environ)
            env.update({"BRIDGEDOCK_OAUTH_TEST_MODE": "loopback-fixtures-only",
                        "BRIDGEDOCK_DATA_DIR": root,
                        "BRIDGEDOCK_TEST_CORE_PORT": str(server.server_address[1])})
            result = subprocess.run([str(Path(sys.argv[1]).resolve())], env=env, timeout=45)
            if result.returncode:
                raise SystemExit(result.returncode)
            assert observed == {"callback_posts": 1, "session_deletes": 1,
                                "codes": ["fixture-authorization-code"],
                                "states": ["fixture-state"], "providers": ["claude"]}
            print("PASS loopback spy: exactly one synthetic callback POST and one session DELETE")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
