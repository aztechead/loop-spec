#!/usr/bin/env bash
# Run one shell command with wall-clock and no-output deadlines.
#
# Usage:
#   run-with-watchdog.sh --root ROOT --command COMMAND --log LOG
#     [--timeout-secs N] [--idle-timeout-secs N]
#
# Exit: the command's exit code, or 124 for either watchdog deadline.
# A JSON sidecar is always written to <log>.watchdog.json.
set -uo pipefail

die2() { echo "run-with-watchdog: $*" >&2; exit 2; }

root=""
command=""
log=""
timeout_secs="${LOOP_SPEC_COMMAND_TIMEOUT_SECS:-1800}"
idle_timeout_secs="${LOOP_SPEC_COMMAND_IDLE_TIMEOUT_SECS:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --command) command="${2:-}"; shift 2 ;;
    --log) log="${2:-}"; shift 2 ;;
    --timeout-secs) timeout_secs="${2:-}"; shift 2 ;;
    --idle-timeout-secs) idle_timeout_secs="${2:-}"; shift 2 ;;
    *) die2 "unknown argument '$1'" ;;
  esac
done

[[ -n "$root" && -d "$root" ]] || die2 "--root must name a directory"
[[ -n "$command" ]] || die2 "--command is required"
[[ -n "$log" ]] || die2 "--log is required"
[[ "$timeout_secs" =~ ^[0-9]+$ ]] || die2 "--timeout-secs must be a non-negative integer"
[[ "$idle_timeout_secs" =~ ^[0-9]+$ ]] || die2 "--idle-timeout-secs must be a non-negative integer"

root="$(cd "$root" && pwd -P)"
case "$log" in
  /*) ;;
  *) log="$root/$log" ;;
esac
mkdir -p "$(dirname "$log")"

WATCHDOG_ROOT="$root" WATCHDOG_COMMAND="$command" WATCHDOG_LOG="$log" \
WATCHDOG_TIMEOUT_SECS="$timeout_secs" WATCHDOG_IDLE_TIMEOUT_SECS="$idle_timeout_secs" \
python3 - <<'PY'
import json
import os
import selectors
import signal
import subprocess
import sys
import time

root = os.environ["WATCHDOG_ROOT"]
command = os.environ["WATCHDOG_COMMAND"]
log_path = os.environ["WATCHDOG_LOG"]
timeout = int(os.environ["WATCHDOG_TIMEOUT_SECS"])
idle_timeout = int(os.environ["WATCHDOG_IDLE_TIMEOUT_SECS"])
sidecar = log_path + ".watchdog.json"
started = time.monotonic()
last_output = started
interrupted = None


def on_signal(signum, _frame):
    global interrupted
    interrupted = signum


for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, on_signal)


def write_sidecar(status, exit_code):
    now = time.monotonic()
    value = {
        "schema": 1,
        "status": status,
        "exitCode": exit_code,
        "elapsedSeconds": round(now - started, 3),
        "idleSeconds": round(now - last_output, 3),
        "timeoutSeconds": timeout,
        "idleTimeoutSeconds": idle_timeout,
    }
    tmp = sidecar + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"))
        handle.write("\n")
    os.replace(tmp, sidecar)


def stop_group(proc):
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()


try:
    proc = subprocess.Popen(
        ["bash", "-c", command],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
except OSError as exc:
    with open(log_path, "wb") as handle:
        handle.write(("run-with-watchdog: spawn failed: %s\n" % exc).encode())
    write_sidecar("spawn_failed", 126)
    sys.exit(126)

selector = selectors.DefaultSelector()
selector.register(proc.stdout, selectors.EVENT_READ)
status = "completed"
exit_code = 0

with open(log_path, "wb") as log:
    while True:
        now = time.monotonic()
        if interrupted is not None:
            status = "signal"
            exit_code = 128 + interrupted
            stop_group(proc)
            break
        if timeout and now - started >= timeout:
            status = "timeout"
            exit_code = 124
            stop_group(proc)
            break
        if idle_timeout and now - last_output >= idle_timeout:
            status = "idle_timeout"
            exit_code = 124
            stop_group(proc)
            break

        events = selector.select(timeout=0.25)
        for key, _ in events:
            chunk = os.read(key.fileobj.fileno(), 65536)
            if chunk:
                log.write(chunk)
                log.flush()
                last_output = time.monotonic()
            else:
                selector.unregister(key.fileobj)

        rc = proc.poll()
        if rc is not None and not selector.get_map():
            exit_code = 128 + (-rc) if rc < 0 else rc
            status = "signal" if rc < 0 else "completed"
            break

write_sidecar(status, exit_code)
sys.exit(exit_code)
PY
