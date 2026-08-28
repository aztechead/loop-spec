#!/usr/bin/env bash
# Instant contract checks for lib/run-with-watchdog.sh.
#
# Deadline-expiry cases (idle/wall timeouts that must wait out real seconds)
# were removed with the rest of the timing-dependent tests: the suite is
# offline-and-instant by policy. The success path, non-zero exit, and usage
# refusals (including --timeout-secs 0, which used to disable the deadline)
# stay — they complete without sleeping.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/run-with-watchdog.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-watchdog-test.$$"
PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

ec=0
bash "$SCRIPT" --root "$WORK" --command 'printf "ready\n"' --log success.log \
  --timeout-secs 5 --idle-timeout-secs 2 || ec=$?
check "successful command preserves exit" "0" "$ec"
check "successful output is logged" "ready" "$(<"$WORK/success.log")"
check "success sidecar is terminal" "completed:0" \
  "$(jq -r '.status + ":" + (.exitCode | tostring)' "$WORK/success.log.watchdog.json")"

ec=0
bash "$SCRIPT" --root "$WORK" --command 'printf "boom\n"; exit 7' --log fail.log \
  --timeout-secs 5 --idle-timeout-secs 2 || ec=$?
check "non-zero command preserves exit" "7" "$ec"
check "non-zero sidecar is completed with that code" "completed:7" \
  "$(jq -r '.status + ":" + (.exitCode | tostring)' "$WORK/fail.log.watchdog.json")"

ec=0
bash "$SCRIPT" --root "$WORK" --command 'true' --log unused.log \
  --timeout-secs 0 --idle-timeout-secs 2 >/dev/null 2>&1 || ec=$?
check "timeout-secs 0 is refused" "2" "$ec"

ec=0
bash "$SCRIPT" --root "$WORK" --command 'true' --log unused.log \
  --timeout-secs 5 --idle-timeout-secs 0 >/dev/null 2>&1 || ec=$?
check "idle-timeout-secs 0 is refused" "2" "$ec"

ec=0
bash "$SCRIPT" --command 'true' --log unused.log >/dev/null 2>&1 || ec=$?
check "missing --root is refused" "2" "$ec"

ec=0
bash "$SCRIPT" --root "$WORK" --log unused.log >/dev/null 2>&1 || ec=$?
check "missing --command is refused" "2" "$ec"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
