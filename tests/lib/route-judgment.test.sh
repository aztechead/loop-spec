#!/usr/bin/env bash
# Unit tests for lib/route-judgment.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/route-judgment.sh"
PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# base_verdict: the contract example with every surface false, so the unmodified
# fixture is a genuine oneshot candidate and every test overrides exactly the field
# under test.
base_verdict() {
  jq -nc '{schema: 1, route: "oneshot", complexity: 2, confidence: 0.9, files: 3,
    surfaces: {interface: false, dataFormat: false, security: false, destructive: false},
    openQuestions: [],
    reasons: [{claim: "remove deletes one line of todo.txt the user owns", cite: "todo.py:14"}]}'
}

verdict() { base_verdict | jq -c "$1"; }

validate() {
  local input="$1" file="$WORK/verdict.json"
  printf '%s\n' "$input" > "$file"
  bash "$SCRIPT" validate "$file"
}

assert_contains() {
  local name="$1" needle="$2" input="$3" actual
  actual="$(validate "$input")"
  [[ "$actual" == *"$needle"* ]] \
    && pass "$name" \
    || fail "$name (expected to contain '$needle', got '$actual')"
}

# Valid oneshot: reason prefix and the complexity/confidence suffix.
assert_contains "valid oneshot: route and reason prefix" \
  "route=oneshot reason=judge: remove deletes one line of todo.txt the user owns" "$(base_verdict)"
assert_contains "valid oneshot: complexity/confidence suffix" \
  "(complexity 2, confidence 0.9)" "$(base_verdict)"

# route=full is authoritative.
assert_contains "judge-selected full" "code=judge-selected-full" "$(verdict '.route = "full"')"

# Confidence below threshold.
assert_contains "low confidence" "code=low-confidence" "$(verdict '.confidence = 0.6')"

# Open question, first one named in the reason.
assert_contains "open question code" "code=open-questions" \
  "$(verdict '.openQuestions = ["should renumbering preserve blank ids?"]')"
assert_contains "open question text in reason" "should renumbering preserve blank ids?" \
  "$(verdict '.openQuestions = ["should renumbering preserve blank ids?"]')"

# Each surface, and surface precedence order.
assert_contains "dataFormat surface is a complexity input, not a veto" "route=oneshot" \
  "$(verdict '.surfaces.dataFormat = true')"
assert_contains "interface surface is a complexity input, not a veto" "route=oneshot" \
  "$(verdict '.surfaces.interface = true')"
assert_contains "security and destructive both true picks security first" \
  "code=surface-security" \
  "$(verdict '.surfaces.security = true | .surfaces.destructive = true')"
assert_contains "destructive surface" "code=surface-destructive" \
  "$(verdict '.surfaces.destructive = true')"
assert_contains "the judge's own file count above 3 is full" "code=files-over-bound" \
  "$(verdict '.files = 7')"
assert_contains "three files is within the bound" "route=oneshot" \
  "$(verdict '.files = 3')"

# Malformed verdicts fail closed to unusable-verdict.
assert_contains "empty reasons is unusable" "code=unusable-verdict" "$(verdict '.reasons = []')"
assert_contains "complexity out of range is unusable" "code=unusable-verdict" "$(verdict '.complexity = 7')"

# A fenced final message is the same verdict.
fenced_out="$(printf '```json\n%s\n```\n' "$(base_verdict)" | bash "$SCRIPT" validate -)"
[[ "$fenced_out" == "route=oneshot reason=judge: "* ]] \
  && pass "a \`\`\`json fence around the verdict is stripped" \
  || fail "a \`\`\`json fence around the verdict is stripped (got '$fenced_out')"

# stdin works via '-'.
stdin_out="$(base_verdict | bash "$SCRIPT" validate -)"
[[ "$stdin_out" == "route=oneshot reason=judge: "* ]] \
  && pass "stdin '-' reads the verdict" \
  || fail "stdin '-' reads the verdict (got '$stdin_out')"

# Not JSON at all is unusable-verdict, not a bad-usage exit.
notjson_file="$WORK/not-json.json"
printf 'not json\n' > "$notjson_file"
notjson_out="$(bash "$SCRIPT" validate "$notjson_file")"
[[ "$notjson_out" == *"code=unusable-verdict"* ]] \
  && pass "non-JSON input is unusable-verdict" \
  || fail "non-JSON input is unusable-verdict (got '$notjson_out')"

# Bad usage: missing file, no args.
missing_exit=0
bash "$SCRIPT" validate "$WORK/does-not-exist.json" >/dev/null 2>&1 || missing_exit=$?
[[ "$missing_exit" -eq 2 ]] \
  && pass "missing file exits 2" \
  || fail "missing file exits 2 (got $missing_exit)"
noargs_exit=0
bash "$SCRIPT" >/dev/null 2>&1 || noargs_exit=$?
[[ "$noargs_exit" -eq 2 ]] \
  && pass "no args exits 2" \
  || fail "no args exits 2 (got $noargs_exit)"

# `-` under a harness that leaves stdin open: bounded, loud, and fast. The fifo holds
# stdin open with no writer, which is what a Bash tool call looks like from in here; the
# live run's first judge call spent its whole 10-minute tool timeout on `cat`.
mkfifo "$WORK/held"
exec 9<> "$WORK/held"
held_start="$SECONDS"
held_exit=0
held_out="$(bash "$SCRIPT" validate - <&9 2>&1)" || held_exit=$?
exec 9>&-
held_elapsed=$((SECONDS - held_start))
[[ "$held_exit" -ne 0 ]] \
  && pass "held-open stdin exits non-zero" \
  || fail "held-open stdin exits non-zero (got $held_exit)"
[[ "$held_elapsed" -lt 10 ]] \
  && pass "held-open stdin gives up in seconds" \
  || fail "held-open stdin gives up in seconds (took ${held_elapsed}s)"
[[ "$held_out" == *"no verdict arrived on stdin"* && "$held_out" == *"validate verdict.json"* ]] \
  && pass "the refusal names the fix" \
  || fail "the refusal names the fix (got '$held_out')"

# A verdict on a heredoc still validates: `-` is not broken, only bounded.
heredoc_out="$(bash "$SCRIPT" validate - <<JSON
$(base_verdict)
JSON
)"
[[ "$heredoc_out" == "route=oneshot reason=judge: remove deletes one line of todo.txt the user owns"* ]] \
  && pass "a heredoc verdict validates" \
  || fail "a heredoc verdict validates (got '$heredoc_out')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
