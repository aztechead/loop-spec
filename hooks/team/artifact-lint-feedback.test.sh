#!/usr/bin/env bash
# Tests for hooks/team/artifact-lint-feedback.sh
# PostToolUse (Write|Edit): a cycle artifact that fails its lint is reported to the author at once.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/artifact-lint-feedback.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" payload="$3"
  shift 3
  local actual=0
  env "$@" bash "$HOOK" >/dev/null 2>&1 <<< "$payload" || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"; ((FAIL++)) || true
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/artifact-lint-feedback.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DOCS="$WORK/docs/loop-spec/features/demo"; STATE="$WORK/.loop-spec/features/demo"
mkdir -p "$DOCS" "$STATE"

payload() { python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$1" "$2"; }

# A PLAN.md in the planner's own shape (the live failure) is reported on Write.
printf '# Plan\n\n## Tasks\n\n### task-001 - x\n\n- **files**: a.sh\n- **verifyCommand**: true\n' > "$DOCS/PLAN.md"
check "malformed PLAN.md write is reported" 2 "$(payload Write "$DOCS/PLAN.md")"
check "malformed PLAN.md edit is reported" 2 "$(payload Edit "$DOCS/PLAN.md")"

# The feedback names the flags the exit gate would raise.
msg="$(bash "$HOOK" 2>&1 >/dev/null <<< "$(payload Write "$DOCS/PLAN.md")" || true)"
check "feedback carries FLAG lines" 0 "$(payload Read "$DOCS/PLAN.md")"
if grep -q 'FLAG' <<<"$msg" && grep -q 'before reporting DONE' <<<"$msg"; then
  echo "PASS: feedback names the flags and the DONE rule"; ((PASS++)) || true
else
  echo "FAIL: feedback text: $msg"; ((FAIL++)) || true
fi

# tasks.json with a bare-substring grep criterion (the second live failure).
printf '[{"id":"task-001","title":"t","files":["a"],"verifyCommand":"true","acceptanceCriteria":["grep -c foo a returns 1"],"blockedBy":[]}]\n' > "$STATE/tasks.json"
check "bare-grep tasks.json write is reported" 2 "$(payload Write "$STATE/tasks.json")"
printf '[{"id":"task-001","title":"t","files":["notes.md"],"verifyCommand":"grep -q PASS notes.md","acceptanceCriteria":["grep -w PASS notes.md exits 0"],"blockedBy":[]}]\n' > "$STATE/tasks.json"
check "self-reported verify in tasks.json is reported" 2 "$(payload Write "$STATE/tasks.json")"
msg="$(bash "$HOOK" 2>&1 >/dev/null <<< "$(payload Write "$STATE/tasks.json")" || true)"
if grep -q 'self-reported' <<<"$msg"; then echo "PASS: feedback names the verify-lint rule"; ((PASS++)) || true; else echo "FAIL: verify-lint feedback text: $msg"; ((FAIL++)) || true; fi

# A VERIFICATION.md whose acceptance table the ITERATE floor cannot read is reported.
printf '# Spec\n\n## Success criteria\n\n### Good Enough\n\n- [ ] `true` exits 0\n\n### Exceptional\n\n- [ ] more\n' > "$DOCS/SPEC.md"
printf '# Verification\n\n## Acceptance Criteria Results\n\n- GE-001: pass\n' > "$DOCS/VERIFICATION.md"
check "VERIFICATION.md without the floor table is reported" 2 "$(payload Write "$DOCS/VERIFICATION.md")"
msg="$(bash "$HOOK" 2>&1 >/dev/null <<< "$(payload Write "$DOCS/VERIFICATION.md")" || true)"
if grep -q 'converged-floor: FLOOR' <<<"$msg"; then
  echo "PASS: feedback names the floor violation"; ((PASS++)) || true
else
  echo "FAIL: floor feedback text: $msg"; ((FAIL++)) || true
fi

# Files that are not cycle artifacts, or that pass, say nothing.
printf 'x\n' > "$WORK/README.md"
check "a non-artifact write is silent" 0 "$(payload Write "$WORK/README.md")"
check "a Read is silent" 0 "$(payload Read "$DOCS/PLAN.md")"
check "a missing file is silent" 0 "$(payload Write "$DOCS/nope/PLAN.md")"
check "kill switch is silent" 0 "$(payload Write "$DOCS/PLAN.md")" LOOP_SPEC_ARTIFACT_LINT_FEEDBACK=0
check "malformed payload is silent" 0 'not json'

echo
echo "artifact-lint-feedback: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
