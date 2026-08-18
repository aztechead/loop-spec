#!/usr/bin/env bash
# Selection contracts for the changed-file edit-loop gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_UNIT="$ROOT/tests/run-unit.sh"
PASS=0
FAIL=0

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

rc=0
out="$(bash "$RUN_UNIT" --list 2>&1)" || rc=$?
check "list mode requires at least one path" "2" "$rc"
check "list-mode usage is specific" "1" \
  "$(grep -c 'run-unit.sh --list <path>' <<<"$out")"

out="$(bash "$RUN_UNIT" --list \
  skills/shared/human-code.md skills/shared/human-docs.md)"
check "executable contract docs select the code-for-humans coverage suite" "1" \
  "$(grep -c '^tests/human-code-coverage.test.sh$' <<<"$out")"
check "executable contract docs select the docs-for-humans coverage suite" "1" \
  "$(grep -c '^tests/human-docs-coverage.test.sh$' <<<"$out")"
check "executable contract docs still select the docs linter" "1" \
  "$(grep -c '^tests/lib/doc-tells.test.sh$' <<<"$out")"

out="$(bash "$RUN_UNIT" --list agents/code-reviewer.md commands/loop-debug.md)"
check "agent instructions select their registered coupling suites" "1" \
  "$(grep -c '^tests/plain-language-coverage.test.sh$' <<<"$out")"
check "command instructions select their registered coupling suites" "1" \
  "$(grep -c '^tests/pr-feedback-coverage.test.sh$' <<<"$out")"

out="$(bash "$RUN_UNIT" --list README.md)"
check "ordinary prose still selects the docs linter" "1" \
  "$(grep -c '^tests/lib/doc-tells.test.sh$' <<<"$out")"
check "ordinary prose does not expand into broad coupling coverage" "0" \
  "$(grep -c '^tests/adk-extension.test.sh$' <<<"$out")"

check "the edit gate checks only comments introduced by the diff" "1" \
  "$(grep -c 'comment-tells.sh diff "\$BASE"' "$RUN_UNIT")"
check "the edit gate checks only failure tells introduced by the diff" "1" \
  "$(grep -c 'failure-tells.sh diff "\$BASE"' "$RUN_UNIT")"
check "the edit gate checks only doc tells introduced by the diff" "1" \
  "$(grep -c 'doc-tells.sh diff "\$BASE"' "$RUN_UNIT")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
