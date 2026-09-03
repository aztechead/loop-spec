#!/usr/bin/env bash
# Tests for hooks/team/oracle-record.sh (supervisor answers recorded from the payload).
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/oracle-record.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-oracle-record.$$"
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/proj"; FEAT="$PROJ/.loop-spec/features/alpha"
mkdir -p "$FEAT"
printf '{"slug":"alpha","autonomous":true,"currentPhase":"spec"}' > "$FEAT/feature.json"
export CLAUDE_PROJECT_DIR="$PROJ" LOOP_SPEC_PROFILE="$WORK/none.json"
unset LOOP_SPEC_ORACLE LOOP_SPEC_ORACLE_WRITE LOOP_SPEC_AUTONOMOUS 2>/dev/null || true
cd "$PROJ"

payload='{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which store?","header":"Store","options":[{"label":"sqlite (Recommended)","description":"file"},{"label":"postgres","description":"server"}],"multiSelect":false},{"question":"Which sections?","header":"Docs","options":[{"label":"Intro","description":""},{"label":"API","description":""}],"multiSelect":true}]},"tool_response":{"questions":[],"answers":{"Which store?":"postgres","Which sections?":["Intro","API"]}}}'

# no supervisor named: nothing recorded, exit 0
ec=0; bash "$HOOK" <<<"$payload" || ec=$?
check "self oracle: exit 0" "0" "$ec"
check "self oracle: nothing recorded" "0" "$(bash "$REPO_ROOT/lib/decisions.sh" count "$FEAT")"

# supervisor named: one supervised decision per question, answers from the payload
export LOOP_SPEC_ORACLE=supervisor
ec=0; bash "$HOOK" <<<"$payload" || ec=$?
check "supervisor: exit 0" "0" "$ec"
check "supervisor: two decisions" "2" "$(bash "$REPO_ROOT/lib/decisions.sh" count "$FEAT")"
check "supervisor: kind supervised" "supervised" "$(bash "$REPO_ROOT/lib/decisions.sh" list "$FEAT" | head -1 | jq -r .kind)"
check "supervisor: phase from feature.json" "spec" "$(bash "$REPO_ROOT/lib/decisions.sh" list "$FEAT" | head -1 | jq -r .phase)"
check "supervisor: answer from the payload" "postgres" "$(bash "$REPO_ROOT/lib/decisions.sh" list "$FEAT" | head -1 | jq -r .answer)"
check "supervisor: multi-select joined" "Intro, API" "$(bash "$REPO_ROOT/lib/decisions.sh" list "$FEAT" | tail -1 | jq -r .answer)"

# active-run.json names the feature dir even from another cwd
mkdir -p "$WORK/elsewhere/.loop-spec"; printf '{"featureDir":"%s"}' "$FEAT" > "$WORK/elsewhere/.loop-spec/active-run.json"
( cd "$WORK/elsewhere" && CLAUDE_PROJECT_DIR="$WORK/elsewhere" bash "$HOOK" <<<"$payload" )
check "active-run.json resolves the feature" "4" "$(bash "$REPO_ROOT/lib/decisions.sh" count "$FEAT")"

# a failed question tool records oracle-unavailable
failure='{"hook_event_name":"PostToolUseFailure","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Runtime?","header":"Runtime","options":[]}]},"error":"denied by callback"}'
bash "$HOOK" <<<"$failure"
check "failure: kind oracle-unavailable" "oracle-unavailable" "$(bash "$REPO_ROOT/lib/decisions.sh" list "$FEAT" | tail -1 | jq -r .kind)"
check "failure: rationale carries the error" "yes" "$(bash "$REPO_ROOT/lib/decisions.sh" list "$FEAT" | tail -1 | jq -r .rationale | grep -q 'denied by callback' && echo yes || echo no)"

# other tools, empty payloads, and the kill switch are ignored
bash "$HOOK" <<<'{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}'
bash "$HOOK" <<<''
LOOP_SPEC_ORACLE_RECORD=0 bash "$HOOK" <<<"$payload"
check "other tools, empty input, kill switch: unchanged" "5" "$(bash "$REPO_ROOT/lib/decisions.sh" count "$FEAT")"

# two open features and no active-run.json: ambiguous, nothing written
rm -f "$WORK/elsewhere/.loop-spec/active-run.json"
mkdir -p "$PROJ/.loop-spec/features/beta"; printf '{"slug":"beta","autonomous":true,"currentPhase":"plan"}' > "$PROJ/.loop-spec/features/beta/feature.json"
bash "$HOOK" <<<"$payload"
check "ambiguous feature: nothing written" "5" "$(bash "$REPO_ROOT/lib/decisions.sh" count "$FEAT")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
