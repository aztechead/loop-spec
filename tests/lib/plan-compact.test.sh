#!/usr/bin/env bash
# Compact PLAN representation regression and size report.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/plan-compact.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}

write_tasks() {
  local plan="$1" with_table="$2"
  {
    printf '# Export - Implementation Plan\n\n'
    printf '## Architecture overview\n\nThe export command streams records through a bounded writer.\nThe export command exits 0 when the focused command test passes.\nDecision: preserve the repository adapter boundary.\n\n'
    if [[ "$with_table" == 1 ]]; then
      cat <<'EOF'
## File map

- `api/export.py` - command entrypoint
- `api/format.py` - row formatting
- `lib/export_store.py` - storage adapter
- `lib/export_errors.py` - typed failures
- `tests/test_export.py` - command coverage
- `tests/test_format.py` - formatting coverage
- `tests/test_store.py` - adapter coverage

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | add storage adapter and typed failures | - | lib/export_store.py, lib/export_errors.py, tests/test_store.py | medium |
| task-002 | add row formatting | task-001 | api/format.py, tests/test_format.py | small |
| task-003 | wire API export command | task-001, task-002 | api/export.py, tests/test_export.py | medium |

EOF
    fi
    printf '## Existing code\n\n- export writer: reuse `lib/export.sh:1-20` — interface: one bounded write per call\n\n## Tasks\n\n'
    for n in 1 2 3; do
      case "$n" in
        1) subject='add storage adapter and typed failures'; file='lib/export_store.py|lib/export_errors.py|tests/test_store.py'; deps='[]'; verify='pytest tests/test_store.py -q' ;;
        2) subject='add row formatting'; file='api/format.py|tests/test_format.py'; deps='[task-001]'; verify='pytest tests/test_format.py -q' ;;
        3) subject='wire API export command'; file='api/export.py|tests/test_export.py'; deps='[task-001, task-002]'; verify='pytest tests/test_export.py -q' ;;
      esac
      cat <<EOF
### task-00$n: $subject

**Files:**
EOF
      IFS='|' read -r -a task_files <<< "$file"
      for task_file in "${task_files[@]}"; do
        printf -- '- `%s`\n' "$task_file"
      done
      cat <<EOF

**BlockedBy:** $deps

**Verify:** \`$verify\`

**Acceptance criteria:**
- [ ] \`$verify\` exits 0

EOF
    done
    cat <<'EOF'
## Test strategy

Run the three focused checks and then the repository regression suite.

## Grounding

- none
EOF
  } > "$1"
}

write_tasks "$WORK/legacy-PLAN.md" 1
write_tasks "$WORK/compact-PLAN.md" 0
cat > "$WORK/SPEC.md" <<'EOF'
# Export

## Problem

Exports need a bounded and deterministic writer.

## Success criteria

### Good Enough

- [ ] The export command exits 0 when the focused command test passes.

<decisions>
- Decision: preserve the repository adapter boundary.
</decisions>

## Grounding

- none
EOF

legacy_json="$(bash "$ROOT/lib/plan-tasks.sh" extract "$WORK/legacy-PLAN.md")"
compact_json="$(bash "$ROOT/lib/plan-tasks.sh" extract "$WORK/compact-PLAN.md")"
check "legacy and compact plans extract three coherent tasks" 3 "$(jq 'length' <<<"$compact_json")"
check "legacy and compact plans have equivalent extracted tasks" \
  "$(jq -S -c . <<<"$legacy_json")" "$(jq -S -c . <<<"$compact_json")"
check "compact plan covers exactly seven unique files" 7 "$(jq '[.[].files[]] | unique | length' <<<"$compact_json")"
check "legacy extracted tasks pass structural tasks lint" 0 "$(bash "$ROOT/lib/artifact-lint.sh" tasks - <<<"$legacy_json" >/dev/null 2>&1; echo $?)"
check "compact extracted tasks pass structural tasks lint" 0 "$(bash "$ROOT/lib/artifact-lint.sh" tasks - <<<"$compact_json" >/dev/null 2>&1; echo $?)"
check "legacy plan passes structural lint" 0 "$(bash "$ROOT/lib/artifact-lint.sh" plan "$WORK/legacy-PLAN.md" >/dev/null 2>&1; echo $?)"
check "compact plan passes structural lint" 0 "$(bash "$ROOT/lib/artifact-lint.sh" plan "$WORK/compact-PLAN.md" >/dev/null 2>&1; echo $?)"
check "legacy plan covers SPEC criteria" 0 "$(bash "$ROOT/lib/criteria-coverage.sh" "$WORK/SPEC.md" "$WORK/legacy-PLAN.md" >/dev/null 2>&1; echo $?)"
check "compact plan covers SPEC criteria" 0 "$(bash "$ROOT/lib/criteria-coverage.sh" "$WORK/SPEC.md" "$WORK/compact-PLAN.md" >/dev/null 2>&1; echo $?)"
check "legacy plan covers SPEC decision" 0 "$(bash "$ROOT/lib/decision-coverage.sh" "$WORK/SPEC.md" "$WORK/legacy-PLAN.md" >/dev/null 2>&1; echo $?)"
check "compact plan covers SPEC decision" 0 "$(bash "$ROOT/lib/decision-coverage.sh" "$WORK/SPEC.md" "$WORK/compact-PLAN.md" >/dev/null 2>&1; echo $?)"
check "legacy task criteria pass acceptance lint" 0 "$(bash "$ROOT/lib/acceptance-lint.sh" - <<<"$legacy_json" >/dev/null 2>&1; echo $?)"
check "compact task criteria pass acceptance lint" 0 "$(bash "$ROOT/lib/acceptance-lint.sh" - <<<"$compact_json" >/dev/null 2>&1; echo $?)"

legacy_bytes="$(wc -c < "$WORK/legacy-PLAN.md" | tr -d ' ')"
compact_bytes="$(wc -c < "$WORK/compact-PLAN.md" | tr -d ' ')"
legacy_words="$(wc -w < "$WORK/legacy-PLAN.md" | tr -d ' ')"
compact_words="$(wc -w < "$WORK/compact-PLAN.md" | tr -d ' ')"
echo "REPORT: legacy_plan_bytes=$legacy_bytes compact_plan_bytes=$compact_bytes legacy_plan_words=$legacy_words compact_plan_words=$compact_words"
check "compact fixture is smaller by bytes" 1 "$(( compact_bytes < legacy_bytes ))"
check "compact fixture is smaller by words" 1 "$(( compact_words < legacy_words ))"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
