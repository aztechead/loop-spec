#!/usr/bin/env bash
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
bash "$SCRIPT" --root "$WORK" --command 'sleep 5' --log idle.log \
  --timeout-secs 4 --idle-timeout-secs 1 || ec=$?
check "silent command trips idle watchdog" "124" "$ec"
check "idle sidecar names reason" "idle_timeout" \
  "$(jq -r '.status' "$WORK/idle.log.watchdog.json")"

ec=0
bash "$SCRIPT" --root "$WORK" --command 'while :; do printf x; sleep 0.2; done' \
  --log wall.log --timeout-secs 1 --idle-timeout-secs 3 || ec=$?
check "active command trips wall watchdog" "124" "$ec"
check "wall sidecar names reason" "timeout" \
  "$(jq -r '.status' "$WORK/wall.log.watchdog.json")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
