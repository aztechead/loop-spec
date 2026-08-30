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
PHASE_TX="$WORK/phase.jsonl"

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
  if [[ -f "$PHASE_TX" ]]; then
    payload="$(python3 -c 'import json,sys
try:
    d=json.loads(sys.argv[1]); d.setdefault("transcript_path", sys.argv[2]); print(json.dumps(d))
except Exception:
    print(sys.argv[1])' "$payload" "$PHASE_TX")"
  fi
  (
    cd "$WORK"
    env CLAUDE_PROJECT_DIR="$WORK" "$@" bash "$HOOK" >/dev/null 2>&1 <<<"$payload"
  ) || actual_exit=$?
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
  (
    cd "$WORK"
    env CLAUDE_PROJECT_DIR="$WORK" "$@" bash "$HOOK" 2>&1 >/dev/null <<<"$payload"
  ) || true
}

REAL='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Gate outcome","question":"Gate: deploy API. Use Other to type 1-5 concrete observable criteria, or choose an existing source. Each criterion must name the observable and its exact passing value, regex, or threshold.","options":[{"label":"Copy from task'\''s acceptanceCriteria","description":"Use the existing concrete list"},{"label":"Stop - revise task","description":"Keep requiresUserSpecification and return control"}],"multiSelect":false}]}}'
DUMMY_FLAT='{"tool_name":"AskUserQuestion","tool_input":{"header":"wait","question":"not a real question","options":["n/a","n/a2","Type something"]}}'
DUMMY_WRAPPED='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"wait","question":"This is not a real question","options":[{"label":"n/a","description":"keep-alive"},{"label":"Type something","description":"occupy the wait"}],"multiSelect":false}]}}'
REOPEN='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Re-open SPEC","question":"ITERATE judges the goal still unmet because of a SPEC-level gap: missing timeout behavior. Re-open SPEC/DISCUSS, ship as-is, or stop?","options":[{"label":"Re-open SPEC/DISCUSS","description":"Rewind"},{"label":"Ship as-is","description":"Complete now"},{"label":"Stop - hand back","description":"Pause"}],"multiSelect":false}]}}'
PLAN_GAP='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Plan gap","question":"Plan-adherence found PLAN.md ids with no completed task: T1. Re-queue the missing work, or abort EXECUTE?","options":[{"label":"Re-queue missing tasks","description":"Create TaskCreate entries"},{"label":"Abort EXECUTE","description":"Stop the phase"}],"multiSelect":false}]}}'
MECHANISM='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Mechanism","question":"Use Other to paste the exact shell command that captures proof, or choose an existing mechanism. API and inspection checks must be expressed as executable commands.","options":[{"label":"Use task verifyCommand","description":"Keep the existing concrete command"},{"label":"Subagent with briefing","description":"Specify a subagent proof contract"},{"label":"Stop - revise task","description":"Keep requiresUserSpecification and return control"}],"multiSelect":false}]}}'
SCOPE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Scope","question":"Run this once, or over multiple targets?","options":[{"label":"Once","description":"One target"},{"label":"Per instance / target","description":"Every target"},{"label":"First on one, then on all","description":"Stage rollout"},{"label":"Custom","description":"Describe it"}],"multiSelect":false}]}}'
ON_FAILURE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"On failure","question":"If the gate fails, what happens?","options":[{"label":"Stop the plan (Recommended)","description":"Stop"},{"label":"Reopen this task, continue others","description":"Reopen"},{"label":"Log and continue","description":"Continue"}],"multiSelect":false}]}}'
DISPATCH_BRIEF='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Briefing","question":"Use Other to paste the exact prompt / briefing the subagent should receive, or choose a source. This becomes the dispatch contract -- the agent cannot substitute a shorter version at runtime.","options":[{"label":"Use instances/<tag>/seed-briefing.md","description":"Use a per-target briefing file"},{"label":"Generate from task description","description":"Build from Goal, Files, and Acceptance Criteria"},{"label":"Stop - revise task","description":"Keep requiresUserSpecification and return control"}],"multiSelect":false}]}}'
OTHER_ITERATE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Continue","question":"Keep going while the judge runs?","options":[{"label":"Yes","description":"Continue"},{"label":"Stop","description":"Pause"}],"multiSelect":false}]}}'
SPOOFED_SCOPE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Scope","question":"Keep going while the agent runs?","options":[{"label":"Yes","description":"Continue"},{"label":"Stop","description":"Pause"}],"multiSelect":false}]}}'
RESUME='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Resume","question":"Resume demo or start a new feature?","options":[{"label":"Resume demo","description":"Continue the existing cycle"},{"label":"New feature","description":"Start different work"}],"multiSelect":false}]}}'
KEEPALIVE_SCOPE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Keepalive","question":"Which keepalive interval should the service use?","options":[{"label":"30 seconds","description":"Detect failures sooner"},{"label":"60 seconds","description":"Reduce background traffic"}],"multiSelect":false}]}}'
PING_SCOPE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Ping","question":"Which ping interval should the health check use?","options":[{"label":"30 seconds","description":"Detect failures sooner"},{"label":"60 seconds","description":"Reduce background traffic"}],"multiSelect":false}]}}'
MIXED_EXECUTE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Plan gap","question":"Re-queue the missing work?","options":[{"label":"Re-queue","description":"Continue"},{"label":"Abort","description":"Stop"}]},{"header":"Continue","question":"Keep going while the agent runs?","options":[{"label":"Yes","description":"Continue"},{"label":"Stop","description":"Pause"}]}]}}'
MIXED_ITERATE='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Re-open SPEC","question":"Rewind to refine the spec?","options":[{"label":"Re-open","description":"Rewind"},{"label":"Ship","description":"Continue"}]},{"header":"Continue","question":"Keep going while the judge runs?","options":[{"label":"Yes","description":"Continue"},{"label":"Stop","description":"Pause"}]}]}}'
MULTI_SELECT_REAL="${REAL/\"multiSelect\":false/\"multiSelect\":true}"

set_skill() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill_1","name":"Skill","input":{"skill":"loop-spec:%s"}}]}}\n' "$1" > "$PHASE_TX"
}

set_nested_skill() {
  set_skill "$1"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"skill_2","name":"Skill","input":{"skill":"loop-spec:%s"}}]}}\n' "$2" >> "$PHASE_TX"
}

set_phase() {
  python3 - "$WORK" "$1" <<'PY'
import json, os, sys
root, phase = sys.argv[1], sys.argv[2]
path = os.path.join(root, ".loop-spec", "features", "demo", "feature.json")
json.dump({"currentPhase": phase, "updatedAt": "2026-08-28T00:00:00Z"}, open(path, "w"))
PY
  set_skill "$1"
}

echo "=== placeholder-question-guard.sh tests ==="
set_skill execute

check "a: real specifying-gates question ALLOW" 0 "$REAL"
check "a2: EXECUTE plan-adherence Plan gap ALLOW" 0 "$PLAN_GAP"
check "a2b: EXECUTE mechanism question ALLOW" 0 "$MECHANISM"
check "a2c: EXECUTE scope question ALLOW" 0 "$SCOPE"
check "a2d: EXECUTE failure-policy question ALLOW" 0 "$ON_FAILURE"
check "a2e: EXECUTE briefing question ALLOW" 0 "$DISPATCH_BRIEF"
check "a3: EXECUTE rejects a keep-going question" 2 "$OTHER_ITERATE"
check "a4: EXECUTE rejects an allowlisted header with the wrong contract" 2 "$SPOOFED_SCOPE"
check "a5: EXECUTE rejects a mixed allowed and forbidden batch" 2 "$MIXED_EXECUTE"
check "a5b: EXECUTE rejects multi-select gate contracts" 2 "$MULTI_SELECT_REAL"
set_nested_skill execute specifying-gates
check "a6: nested utility skills preserve EXECUTE restrictions" 2 "$OTHER_ITERATE"
set_nested_skill verify specifying-gates
check "a7: direct specifying-gates activation clears a stale late phase" 0 "$REAL"
set_nested_skill iterate discuss
check "a8: DISCUSS clears a stale ITERATE restriction" 0 "$REAL"
set_nested_skill verify spec
check "a9: SPEC clears a stale VERIFY restriction" 0 "$REAL"
set_skill execute
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

set_phase verify
set_skill cycle
check "h2: cycle resume question ignores the persisted phase" 0 "$RESUME"

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
check "n2: ITERATE rejects a mixed allowed and forbidden batch" 2 "$MIXED_ITERATE"

set_phase spec
check "o: SPEC still allows a real interview question" 0 "$REAL"
check "o2: SPEC allows a real keepalive question" 0 "$KEEPALIVE_SCOPE"
check "o3: SPEC allows a real ping question" 0 "$PING_SCOPE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
