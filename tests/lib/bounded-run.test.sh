#!/usr/bin/env bash
# Tests for lib/bounded-run.sh — the shared bounded-execution seam.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/bounded-run.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bounded-run-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

# --- loop_spec_resolve_timeout ------------------------------------------------
check "empty value falls back to the default" "60" \
  "$(loop_spec_resolve_timeout "" 60)"
check "valid value passes through" "45" \
  "$(loop_spec_resolve_timeout 45 60)"
check "leading zeros do not become octal" "8" \
  "$(loop_spec_resolve_timeout 08 60)"

rc=0; loop_spec_resolve_timeout 0 60 >/dev/null 2>&1 || rc=$?
check "zero is rejected (reads as 'no limit', the footgun this removes)" "1" "$rc"
rc=0; loop_spec_resolve_timeout "abc" 60 >/dev/null 2>&1 || rc=$?
check "non-numeric is rejected" "1" "$rc"
rc=0; loop_spec_resolve_timeout 99999 60 >/dev/null 2>&1 || rc=$?
check "above the 3600s ceiling is rejected" "1" "$rc"
rc=0; loop_spec_resolve_timeout -5 60 >/dev/null 2>&1 || rc=$?
check "negative is rejected" "1" "$rc"

# --- loop_spec_run_bounded ----------------------------------------------------
rc=0
loop_spec_run_bounded 10 "$TMP/o" "$TMP/e" printf 'hello' || rc=$?
check "successful command returns its exit code" "0" "$rc"
check "stdout is captured" "hello" "$(cat "$TMP/o")"

rc=0
loop_spec_run_bounded 10 "$TMP/o" "$TMP/e" bash -c 'exit 7' || rc=$?
check "non-zero exit code is propagated" "7" "$rc"

rc=0
loop_spec_run_bounded 10 "$TMP/o" "$TMP/e" bash -c 'echo boom >&2; exit 1' || rc=$?
check "stderr is captured" "boom" "$(cat "$TMP/e")"

# The whole point: a command that would never return must return.
start=$SECONDS
rc=0
loop_spec_run_bounded 1 "$TMP/o" "$TMP/e" sleep 30 || rc=$?
elapsed=$((SECONDS - start))
check "a hanging command times out with 124" "124" "$rc"
check "timeout is enforced promptly (<10s for a 1s deadline)" "yes" \
  "$([[ "$elapsed" -lt 10 ]] && echo yes || echo "no (${elapsed}s)")"
check "timeout is reported on stderr" "yes" \
  "$(grep -q 'timed out' "$TMP/e" && echo yes || echo no)"

# A wrapper whose CHILD hangs must also be killed: signalling only the direct child
# leaves the grandchild holding the pipe and communicate() blocks anyway.
start=$SECONDS
rc=0
loop_spec_run_bounded 1 "$TMP/o" "$TMP/e" bash -c 'sleep 30 & wait' || rc=$?
elapsed=$((SECONDS - start))
check "a hanging grandchild is killed with the process group" "124" "$rc"
check "process-group kill is prompt (<10s)" "yes" \
  "$([[ "$elapsed" -lt 10 ]] && echo yes || echo "no (${elapsed}s)")"

rc=0
loop_spec_run_bounded 10 "$TMP/o" "$TMP/e" /nonexistent/binary || rc=$?
check "missing binary reports 127 rather than crashing" "127" "$rc"

# --- loop_spec_run_bounded_shell ----------------------------------------------
rc=0
loop_spec_run_bounded_shell 10 "$TMP/s" 'echo out; echo err >&2' || rc=$?
check "shell form returns success" "0" "$rc"
check "shell form merges stdout and stderr" "yes" \
  "$(grep -q out "$TMP/s" && grep -q err "$TMP/s" && echo yes || echo no)"

rc=0
loop_spec_run_bounded_shell 1 "$TMP/s" 'sleep 30' || rc=$?
check "shell form enforces the deadline" "124" "$rc"

# --- loop_spec_disable_interactive_prompts ------------------------------------
(
  loop_spec_disable_interactive_prompts
  [[ "$GH_PROMPT_DISABLED" == "1" && "$GIT_TERMINAL_PROMPT" == "0" ]]
) && r=ok || r=bad
check "prompt disabling exports both variables" "ok" "$r"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
