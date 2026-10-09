#!/usr/bin/env python3
"""Minimal OpenAI-compatible mock for the Pop provider-switch test.

Listens on 127.0.0.1:18790 and answers POST /v1/chat/completions with a
two-token SSE stream ("MOCK_" then "ALIVE") followed by the [DONE] sentinel.
Standard library only — this is a test fixture, not an app dependency.

Prints `MOCK_REQUEST_RECEIVED` once per request so the probe log proves the
server actually saw the call.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = 18790

SSE_CHUNKS = [
    {"choices": [{"delta": {"content": "MOCK_"}}]},
    {"choices": [{"delta": {"content": "ALIVE"}}]},
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # silence the default stderr access log
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)  # drain the body; nothing in it is used

        print("MOCK_REQUEST_RECEIVED", flush=True)

        if not self.path.endswith("/chat/completions"):
            self.send_error(404, "unknown path")
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        for chunk in SSE_CHUNKS:
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

        # A trailing non-SSE JSON line: a correct parser ignores it, which is
        # exactly the robustness this fixture is here to check.
        self.wfile.write(json.dumps({"stub": True, "note": "not an SSE frame"}).encode() + b"\n")
        self.wfile.flush()

        self.close_connection = True


def main():
    server = HTTPServer((HOST, PORT), Handler)
    print(f"MOCK_SERVER_LISTENING {HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())