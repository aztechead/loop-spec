#!/usr/bin/env bash
# Test suite for hooks/team/adhoc-verify-guard.sh
# Stop hook: evidence-before-done for ad-hoc (micro-cycle) work.
# Usage: bash hooks/team/adhoc-verify-guard.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/adhoc-verify-guard.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/adhoc-verify-guard-test-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

TRACE_LOG="$TMPDIR_TEST/trace.log"
export LOOP_SPEC_MICRO_GUARD_TRACE_LOG="$TRACE_LOG"

# Baseline loop-spec project (guard is scoped to .loop-spec projects).
PROJ="$TMPDIR_TEST/proj"; mkdir -p "$PROJ/.loop-spec"

PASS=0
FAIL=0

check() {
  local name="$1" expected_exit="$2" payload="$3"; shift 3
  local actual_exit=0
  echo "$payload" | env CLAUDE_PROJECT_DIR="$PROJ" "$@" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"; ((FAIL++)) || true
  fi
}

# Build a transcript payload from tool_use fragments.
# Each arg is a JSON object for one tool_use item; all land in one assistant turn.
payload() {
  local items=""
  for it in "$@"; do
    [[ -n "$items" ]] && items+=","
    items+="$it"
  done
  printf '{"stop_reason":"end_turn","transcript":[{"role":"assistant","content":[%s]}]}' "$items"
}

EDIT_PY='{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/src/app.py"}}'
WRITE_MD='{"type":"tool_use","name":"Write","input":{"file_path":"/repo/README.md"}}'
WRITE_JSON='{"type":"tool_use","name":"Write","input":{"file_path":"/repo/config/settings.json"}}'
EDIT_NOPATH='{"type":"tool_use","name":"Edit","input":{}}'
BASH_TEST='{"type":"tool_use","name":"Bash","input":{"command":"pytest tests/"}}'
BASH_LS='{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}'
BASH_RAKE='{"type":"tool_use","name":"Bash","input":{"command":"rake spec"}}'
BASH_LEDGER='{"type":"tool_use","name":"Bash","input":{"command":"bash lib/adhoc-ledger.sh add --title t --criteria c --verify v --result pass"}}'

echo "=== adhoc-verify-guard.sh tests ==="

# --- core block/allow logic ---
check "a: code edit, no verification -> BLOCK" 2 "$(payload "$EDIT_PY")"
check "b: code edit, verification after -> ALLOW" 0 "$(payload "$EDIT_PY" "$BASH_TEST")"
check "c: verification BEFORE last edit -> BLOCK (stale evidence)" 2 "$(payload "$BASH_TEST" "$EDIT_PY")"
check "d: no edits at all -> ALLOW" 0 "$(payload "$BASH_LS")"
check "e: prose-only edits (.md) -> ALLOW" 0 "$(payload "$WRITE_MD")"
check "f: code edit + non-verify bash only -> BLOCK" 2 "$(payload "$EDIT_PY" "$BASH_LS")"
check "g: ledger add counts as evidence -> ALLOW" 0 "$(payload "$EDIT_PY" "$BASH_LEDGER")"
check "h: mixed prose+code edit, no verify -> BLOCK" 2 "$(payload "$WRITE_MD" "$EDIT_PY")"
check "h2: config-only edit (.json) -> ALLOW" 0 "$(payload "$WRITE_JSON")"
check "h3: Edit with missing file_path -> ALLOW (never counts as an edit)" 0 "$(payload "$EDIT_NOPATH")"
check "h4: unrecognized runner without VERIFY_CMD -> BLOCK" 2 "$(payload "$EDIT_PY" "$BASH_RAKE")"

# VERIFY_CMD in micro.conf: the project's declared runner counts as evidence
VC="$TMPDIR_TEST/vc"; mkdir -p "$VC/.loop-spec"; printf 'ENABLED=1\nVERIFY_CMD=rake spec\n' > "$VC/.loop-spec/micro.conf"
actual_exit=0
echo "$(payload "$EDIT_PY" "$BASH_RAKE")" | env CLAUDE_PROJECT_DIR="$VC" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then echo "PASS: h5: VERIFY_CMD-declared runner -> ALLOW"; ((PASS++)) || true
else echo "FAIL: h5: VERIFY_CMD-declared runner -> ALLOW (got $actual_exit)"; ((FAIL++)) || true; fi
actual_exit=0
echo "$(payload "$BASH_RAKE" "$EDIT_PY")" | env CLAUDE_PROJECT_DIR="$VC" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 2 ]]; then echo "PASS: h6: VERIFY_CMD evidence predating edit -> still BLOCK"; ((PASS++)) || true
else echo "FAIL: h6: VERIFY_CMD evidence predating edit -> still BLOCK (got $actual_exit)"; ((FAIL++)) || true; fi

# --- stand-down conditions ---
check "i: kill switch LOOP_SPEC_MICRO_GUARD=0 -> ALLOW" 0 "$(payload "$EDIT_PY")" LOOP_SPEC_MICRO_GUARD=0

check "j: stop_hook_active -> ALLOW" 0 \
  '{"stop_hook_active":true,"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/src/app.py"}}]}]}'

# micro.conf ENABLED=0 disarms the guard
OFF="$TMPDIR_TEST/off"; mkdir -p "$OFF/.loop-spec"; printf 'ENABLED=0\n' > "$OFF/.loop-spec/micro.conf"
actual_exit=0
echo "$(payload "$EDIT_PY")" | env CLAUDE_PROJECT_DIR="$OFF" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then echo "PASS: k: micro.conf ENABLED=0 -> ALLOW"; ((PASS++)) || true
else echo "FAIL: k: micro.conf ENABLED=0 -> ALLOW (got $actual_exit)"; ((FAIL++)) || true; fi

# no .loop-spec dir -> out of scope
NOPROJ="$TMPDIR_TEST/noproj"; mkdir -p "$NOPROJ"
actual_exit=0
echo "$(payload "$EDIT_PY")" | env CLAUDE_PROJECT_DIR="$NOPROJ" bash -c "cd '$NOPROJ' && bash '$HOOK'" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then echo "PASS: l: no .loop-spec dir -> ALLOW"; ((PASS++)) || true
else echo "FAIL: l: no .loop-spec dir -> ALLOW (got $actual_exit)"; ((FAIL++)) || true; fi

# in-flight cycle feature -> stand down
CYC="$TMPDIR_TEST/cycle"; mkdir -p "$CYC/.loop-spec/features/my-feat"
printf '{"currentPhase":"execute"}\n' > "$CYC/.loop-spec/features/my-feat/feature.json"
actual_exit=0
echo "$(payload "$EDIT_PY")" | env CLAUDE_PROJECT_DIR="$CYC" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then echo "PASS: m: in-flight feature -> ALLOW"; ((PASS++)) || true
else echo "FAIL: m: in-flight feature -> ALLOW (got $actual_exit)"; ((FAIL++)) || true; fi

# completed feature does NOT disarm the guard
DONE="$TMPDIR_TEST/done"; mkdir -p "$DONE/.loop-spec/features/old-feat"
printf '{"currentPhase":"completed"}\n' > "$DONE/.loop-spec/features/old-feat/feature.json"
actual_exit=0
echo "$(payload "$EDIT_PY")" | env CLAUDE_PROJECT_DIR="$DONE" bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 2 ]]; then echo "PASS: n: completed feature only -> guard still BLOCKS"; ((PASS++)) || true
else echo "FAIL: n: completed feature only -> guard still BLOCKS (got $actual_exit)"; ((FAIL++)) || true; fi

# --- fail-open on malformed input ---
check "o: malformed JSON payload -> ALLOW" 0 'this is not json'
check "p: empty payload -> ALLOW" 0 ''

# --- block message names the remedy ---
msg=$(echo "$(payload "$EDIT_PY")" | env CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null || true)
if printf '%s' "$msg" | grep -q "adhoc-ledger.sh add"; then
  echo "PASS: q: block message names ledger remedy"; ((PASS++)) || true
else
  echo "FAIL: q: block message names ledger remedy (msg: $msg)"; ((FAIL++)) || true
fi
if printf '%s' "$msg" | grep -q "LOOP_SPEC_MICRO_GUARD=0"; then
  echo "PASS: r: block message names kill switch"; ((PASS++)) || true
else
  echo "FAIL: r: block message names kill switch"; ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
