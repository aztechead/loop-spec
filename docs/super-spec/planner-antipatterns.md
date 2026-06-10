# Planner Acceptance Criteria Antipatterns

Six banned phrases and their required concrete replacements. Each acceptance criterion must contain at least one machine-verifiable anchor (exact value, regex, exit code, file path, grep pattern, or JSON path). Subjective descriptions that cannot be tested by a script are not acceptance criteria.

---

## DO NOT: "looks correct"

**BAD:** `The output looks correct.`

**Instead:** Name the exact value or structure you expect.

**GOOD:** `grep -c "plan_task_ids" output.json` returns 1; `jq '.plan_task_ids | length'` returns 3.

---

## DO NOT: "properly configured"

**BAD:** `The hook is properly configured in hooks.json.`

**Instead:** Verify with a concrete jq or grep command.

**GOOD:** `jq '.hooks.PreToolUse | map(select(.matcher == "Agent")) | length' hooks/hooks.json` returns 1.

---

## DO NOT: "consistent with"

**BAD:** `The output format is consistent with the existing lib/ scripts.`

**Instead:** State the exact format requirement.

**GOOD:** `bash lib/foo.sh | jq '.result'` returns `"ok"`; the script exits 0 on success and 1 on error.

---

## DO NOT: "align X with Y" (or "aligns with", "aligned with")

**BAD:** `Align the new hook behavior with the existing hooks.`

**Instead:** Specify the exact behavior you require, not a comparison to another file.

**GOOD:** `SUPER_SPEC_FOO=0 bash hooks/team/foo.sh <<< '{}'` exits 0 with no stdout output.

---

## DO NOT: "matches Y" (or "matches the expected", "matches the format")

**BAD:** `The JSON output matches the expected schema.`

**Instead:** Use a JSON path expression with an expected value.

**GOOD:** `echo '### task-001: do a thing' | bash lib/plan-adherence.sh /dev/stdin | jq '.plan_task_ids[0]'` returns `"task-001"`.

---

## DO NOT: "well-formed" (without a schema reference)

**BAD:** `The PLAN.md is well-formed.`

**Instead:** Reference a specific schema, or replace with a grep/jq check on the exact fields required.

**GOOD:** `grep -c "^### task-[0-9]\+:" docs/super-spec/features/foo/PLAN.md` returns 3 or more; `grep -c "read_first:" docs/super-spec/features/foo/PLAN.md` returns 3 or more.

---

## Quick reference

| Banned phrase | Replace with |
|---|---|
| "looks correct" | exact value check, grep count, or jq path |
| "properly configured" | `jq` or `grep` confirming the specific field/entry |
| "consistent with" | explicit format or behavior statement |
| "align X with Y" | specific behavior requirement for X |
| "matches Y" | JSON path with expected value, or grep with count |
| "well-formed" | schema reference or field-by-field grep/jq check |
