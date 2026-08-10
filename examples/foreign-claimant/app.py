#!/usr/bin/env python3
"""
app.py — the deliverable a foreign claimant produces for the "serve GET / ->
hello world" task (examples/foreign-claimant/claimant.py). Stdlib only, no
frameworks (CLAUDE.md forbids pip for shipped code).

GET / -> 200, text/plain, body exactly "hello world". Anything else -> 404.

Usage: app.py [--port N]   (N=0, the default, binds an ephemeral port)
Prints the bound port to stdout on startup so a caller can find it before
this process starts serving.
"""

import argparse
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

BODY = b"hello world"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, fmt, *args):
        pass  # quiet by default; this is a demo server, not a log source


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args(argv)

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
