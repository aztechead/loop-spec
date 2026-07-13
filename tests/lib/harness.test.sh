#!/usr/bin/env bash
# Tests for lib/harness.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/lib/harness.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

# run <verb> [env assignments...]
# Invokes the lib in a clean env so the real session's harness vars can't leak in.
run() {
  local verb="$1"; shift
  env -u LOOP_SPEC_HARNESS -u CLAUDECODE -u PI_CODING_AGENT_DIR "$@" \
    bash "$LIB" "$verb"
}

# --- detect: override wins over everything ---
got=$(run detect LOOP_SPEC_HARNESS=pi)
check "override pi -> pi" "pi" "$got"

got=$(run detect LOOP_SPEC_HARNESS=claude PI_CODING_AGENT_DIR=/x)
check "override claude beats pi env hint" "claude" "$got"

got=$(run detect LOOP_SPEC_HARNESS=pi CLAUDECODE=1)
check "override pi beats CLAUDECODE" "pi" "$got"

got=$(run detect LOOP_SPEC_HARNESS=opencode)
check "override opencode -> opencode" "opencode" "$got"

got=$(run detect LOOP_SPEC_HARNESS=opencode CLAUDECODE=1)
check "override opencode beats CLAUDECODE" "opencode" "$got"

got=$(run detect LOOP_SPEC_HARNESS=opencode PI_CODING_AGENT_DIR=/x)
check "override opencode beats pi env hint" "opencode" "$got"

# --- detect: unknown override falls through ---
got=$(run detect LOOP_SPEC_HARNESS=garbage)
check "unknown override -> default claude" "claude" "$got"

got=$(run detect LOOP_SPEC_HARNESS=garbage PI_CODING_AGENT_DIR=/x)
check "unknown override falls through to pi hint" "pi" "$got"

# --- detect: env signals ---
got=$(run detect CLAUDECODE=1)
check "CLAUDECODE=1 -> claude" "claude" "$got"

got=$(run detect CLAUDECODE=1 PI_CODING_AGENT_DIR=/x)
check "CLAUDECODE beats pi hint" "claude" "$got"

got=$(run detect PI_CODING_AGENT_DIR=/x)
check "PI_CODING_AGENT_DIR -> pi" "pi" "$got"

got=$(run detect)
check "no signals -> default claude" "claude" "$got"

# --- cli mirrors detect ---
got=$(run cli LOOP_SPEC_HARNESS=pi)
check "cli under pi -> pi" "pi" "$got"

got=$(run cli)
check "cli default -> claude" "claude" "$got"

got=$(run cli LOOP_SPEC_HARNESS=opencode)
check "cli under opencode -> opencode" "opencode" "$got"

# --- subagents ---
got=$(run subagents LOOP_SPEC_HARNESS=pi)
check "subagents under pi -> false" "false" "$got"

got=$(run subagents CLAUDECODE=1)
check "subagents under claude -> true" "true" "$got"

# opencode's task tool shares the Agent call shape, so the capability holds.
got=$(run subagents LOOP_SPEC_HARNESS=opencode)
check "subagents under opencode -> true" "true" "$got"

# --- unknown command exits 2 ---
rc=0
run bogus >/dev/null 2>&1 || rc=$?
check "unknown command exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
