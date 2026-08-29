#!/usr/bin/env bash
# Tests for hooks/team/placeholder-question-guard.sh
# PreToolUse (AskUserQuestion): deny dummy wait questions and in-flight-agent waits.
# Usage: bash hooks/team/placeholder-question-guard.test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/placeholder-question-guard.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/placeholder-question-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/.loop-spec/features/demo"
cat > "$WORK/.loop-spec/features/demo/feature.json" <<'EOF'
{"currentPhase":"execute","updatedAt":"2026-08-28T00:00:00Z"}
EOF

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  shift 3
  local actual_exit=0
  env CLAUDE_PROJECT_DIR="$WORK" "$@" bash "$HOOK" >/dev/null 2>&1 <<<"$payload" || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

stderr_of() {
  local payload="$1"
  shift
  env CLAUDE_PROJECT_DIR="$WORK" "$@" bash "$HOOK" 2>&1 >/dev/null <<<"$payload" || true
}

REAL='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Gate outcome","question":"What exact state proves this works?","options":[{"label":"I will type the criteria","description":"Write observable conditions"},{"label":"Copy from acceptanceCriteria","description":"Use the existing list"}],"multiSelect":false}]}}'
DUMMY_FLAT='{"tool_name":"AskUserQuestion","tool_input":{"header":"wait","question":"not a real question","options":["n/a","n/a2","Type something"]}}'
DUMMY_WRAPPED='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"wait","question":"This is not a real question","options":[{"label":"n/a","description":"keep-alive"},{"label":"Type something","description":"occupy the wait"}],"multiSelect":false}]}}'
REOPEN='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Re-open SPEC","question":"Rewind to refine the spec toward the original goal?","options":[{"label":"Re-open SPEC/DISCUSS","description":"Rewind"},{"label":"Ship as-is","description":"Complete now"}],"multiSelect":false}]}}'
OTHER_ITERATE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Continue","question":"Keep going while the judge runs?","options":[{"label":"Yes","description":"Continue"},{"label":"Stop","description":"Pause"}],"multiSelect":false}]}}'

set_phase() {
  python3 - "$WORK" "$1" <<'PY'
import json, os, sys
root, phase = sys.argv[1], sys.argv[2]
path = os.path.join(root, ".loop-spec", "features", "demo", "feature.json")
json.dump({"currentPhase": phase, "updatedAt": "2026-08-28T00:00:00Z"}, open(path, "w"))
PY
}

echo "=== placeholder-question-guard.sh tests ==="

check "a: real specifying-gates question ALLOW" 0 "$REAL"
check "b: live dummy flat shape DENY" 2 "$DUMMY_FLAT"
check "c: dummy wrapped questions DENY" 2 "$DUMMY_WRAPPED"

dummy_err="$(stderr_of "$DUMMY_FLAT")"
if grep -q "not a wait" <<<"$dummy_err"; then
  echo "PASS: b2: dummy denial names the wait forbid"
  ((PASS++)) || true
else
  echo "FAIL: b2: dummy denial names the wait forbid (got: $dummy_err)"
  ((FAIL++)) || true
fi

check "d: malformed payload fail-open ALLOW" 0 'this is not json'
check "e: empty stdin fail-open ALLOW" 0 ''
check "f: other tool ALLOW" 0 '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'

actual_exit=0
LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD=0 CLAUDE_PROJECT_DIR="$WORK" \
  bash "$HOOK" >/dev/null 2>&1 <<<"$DUMMY_FLAT" || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: g: kill switch ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: g: kill switch ALLOW (got $actual_exit)"
  ((FAIL++)) || true
fi

NO_CYCLE="$(mktemp -d "${TMPDIR:-/tmp}/placeholder-question-nocycle.XXXXXX")"
actual_exit=0
(
  cd "$NO_CYCLE"
  CLAUDE_PROJECT_DIR="$NO_CYCLE" bash "$HOOK" >/dev/null 2>&1 <<<"$DUMMY_FLAT"
) || actual_exit=$?
rmdir "$NO_CYCLE"
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: h: no .loop-spec ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: h: no .loop-spec ALLOW (got $actual_exit)"
  ((FAIL++)) || true
fi

OPEN_TX="$WORK/open.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"description":"implement task"}}]}}' > "$OPEN_TX"
OPEN_PAYLOAD="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["transcript_path"]=sys.argv[2]; print(json.dumps(d))' "$REAL" "$OPEN_TX")"
check "i: real question while Agent is open DENY" 2 "$OPEN_PAYLOAD"

DONE_TX="$WORK/done.jsonl"
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"description":"implement task"}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"done"}]}}'
} > "$DONE_TX"
DONE_PAYLOAD="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["transcript_path"]=sys.argv[2]; print(json.dumps(d))' "$REAL" "$DONE_TX")"
check "j: real question after Agent completes ALLOW" 0 "$DONE_PAYLOAD"

set_phase deliver
check "k: DELIVER rejects even a real-looking question" 2 "$REAL"

set_phase verify
check "l: VERIFY rejects even a real-looking question" 2 "$REAL"

set_phase iterate
check "m: ITERATE allows Re-open SPEC" 0 "$REOPEN"
check "n: ITERATE rejects a keep-going question" 2 "$OTHER_ITERATE"

set_phase spec
check "o: SPEC still allows a real interview question" 0 "$REAL"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
