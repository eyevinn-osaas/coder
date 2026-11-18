#!/usr/bin/env python3
"""Minimal stand-in for the Coder endpoints used by osc-entrypoint.sh.

Serves /healthz, GET /api/v2/users/first (404 until a first user exists, then
200) and POST /api/v2/users/first (201, then 409). Every request is appended to
the file given by --log as one JSON line (method, path); POST bodies are written
to --bodies so a test can inspect them without them ending up in any log.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--bodies", required=True)
    ap.add_argument("--user-exists", action="store_true")
    ap.add_argument("--post-status", type=int, default=201)
    args = ap.parse_args()
    state = {"exists": args.user_exists}

    class Handler(BaseHTTPRequestHandler):
        def _record(self, body=""):
            with open(args.log, "a") as f:
                f.write(json.dumps({"method": self.command, "path": self.path}) + "\n")
            if body:
                with open(args.bodies, "a") as f:
                    f.write(body + "\n")

        def _send(self, code, text):
            data = text.encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._record()
            if self.path == "/healthz":
                self._send(200, "OK")
            elif self.path == "/api/v2/users/first":
                if state["exists"]:
                    self._send(200, '{"message":"The initial user has already been created!"}')
                else:
                    self._send(404, '{"message":"The initial user has not been created!"}')
            else:
                self._send(404, "{}")

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode()
            self._record(body)
            if self.path != "/api/v2/users/first":
                self._send(404, "{}")
            elif state["exists"]:
                self._send(409, '{"message":"The initial user has already been created."}')
            elif args.post_status == 201:
                state["exists"] = True
                self._send(201, '{"user_id":"stub"}')
            else:
                self._send(args.post_status, '{"message":"Password is invalid"}')

        def log_message(self, *a):
            pass

    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
