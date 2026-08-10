#!/usr/bin/env python3
"""
verify.py — the behavioral check a handoff-port bundle's `verifyCommand`
runs against the claimant's own work, before the claimant is allowed to call
`complete` (skills/shared/handoff-port.md; claimant.py step 4). Stdlib only.

Starts the app.py at the given path on an ephemeral port, GETs /, and checks
the response is exactly what the task promised. Exits 0 on match, 1 otherwise
(missing file, server never came up, wrong body) -- the same failure a task
that was never actually done would produce, which is the point: a claimant
that skips the work fails this and must not complete.

Usage: verify.py <path-to-app.py>
"""

import subprocess
import sys
import time
import urllib.error
import urllib.request

EXPECTED_BODY = b"hello world"
STARTUP_TIMEOUT_S = 5


def main(argv):
    if len(argv) != 1:
        print("usage: verify.py <path-to-app.py>", file=sys.stderr)
        return 2
    app_path = argv[0]

    try:
        proc = subprocess.Popen(
            [sys.executable, app_path, "--port", "0"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as exc:
        print(f"verify: could not launch {app_path}: {exc}", file=sys.stderr)
        return 1

    try:
        deadline = time.monotonic() + STARTUP_TIMEOUT_S
        port_line = ""
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                print(
                    f"verify: app.py exited before printing a port "
                    f"(rc={proc.returncode}); stderr={proc.stderr.read()}",
                    file=sys.stderr,
                )
                return 1
            port_line = proc.stdout.readline().strip()
            if port_line:
                break
        if not port_line.isdigit():
            print(f"verify: app.py never printed a bound port (got {port_line!r})", file=sys.stderr)
            return 1
        port = int(port_line)

        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=STARTUP_TIMEOUT_S) as resp:
                status = resp.status
                body = resp.read()
        except urllib.error.URLError as exc:
            print(f"verify: GET / failed: {exc}", file=sys.stderr)
            return 1

        if status != 200 or body != EXPECTED_BODY:
            print(f"verify: expected 200 {EXPECTED_BODY!r}, got {status} {body!r}", file=sys.stderr)
            return 1
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=STARTUP_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
