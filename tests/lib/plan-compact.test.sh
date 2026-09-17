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

write_patterns() {
  local legacy="${2:-0}"
  if [[ "$legacy" == 1 ]]; then
    cat > "$1" <<EOF
EOF
  else
    cat > "$1" <<EOF
---
type: Pattern Index
---
EOF
  fi
  cat >> "$1" <<EOF
# PATTERNS.md - export pipeline

## Concept: staged export

Use a bounded writer and preserve the existing repository adapter boundary.
EOF
  if [[ "$legacy" == 1 ]]; then
    cat >> "$1" <<'EOF'
```python
# representative legacy adapter shape
def export_rows(store, writer):
    return writer.write(store.rows())
```

EOF
  fi
  cat >> "$1" <<'EOF'
Source analog: `api/export.py:42-68`; `lib/export_store.py:10-31`.

## Concept: deterministic command

The command returns a stable result and records failures at the caller boundary.
EOF
  if [[ "$legacy" == 1 ]]; then
    cat >> "$1" <<'EOF'
```python
def test_export_command_returns_zero():
    assert run_export() == 0
```
EOF
  fi
  printf 'Test analog: `tests/test_export.py:18-44` (focused command result).\n' >> "$1"
}

write_tasks() {
  local plan="$1" with_table="$2"
  {
    if [[ "$with_table" == 0 ]]; then
      printf '%s\n' '---' 'type: Implementation Plan' 'sources:' '  - resource: SPEC.md' '  - resource: PATTERNS.md' '---'
    fi
    printf '%s\n' '# Export - Implementation Plan' ''
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
    printf '## Tasks\n\n'
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
write_patterns "$WORK/legacy-PATTERNS.md" 1
write_patterns "$WORK/compact-PATTERNS.md" 0
cat > "$WORK/SPEC.md" <<'EOF'
---
type: Specification
---
# Export

## Problem

Exports need a bounded and deterministic writer.

<decisions>
- Decision: preserve the repository adapter boundary.
</decisions>

## Success criteria

### Good Enough

- [ ] The export command exits 0 when the focused command test passes.

## Grounding

- none
EOF

{ printf '%s\n' '---' 'type: Implementation Plan' '---'; cat "$WORK/legacy-PLAN.md"; } > "$WORK/legacy-PLAN.typed.md"
legacy_json="$(bash "$ROOT/lib/plan-tasks.sh" extract "$WORK/legacy-PLAN.typed.md")"
compact_json="$(bash "$ROOT/lib/plan-tasks.sh" extract "$WORK/compact-PLAN.md")"
mkdir -p "$WORK/compact-bundle"
cp "$WORK/compact-PLAN.md" "$WORK/compact-bundle/PLAN.md"
cp "$WORK/compact-PATTERNS.md" "$WORK/compact-bundle/PATTERNS.md"
cp "$WORK/SPEC.md" "$WORK/compact-bundle/SPEC.md"
bash "$ROOT/lib/okf.sh" index "$WORK/compact-bundle" >/dev/null
index_bytes="$(wc -c < "$WORK/compact-bundle/index.md" | tr -d ' ')"
index_words="$(wc -w < "$WORK/compact-bundle/index.md" | tr -d ' ')"
check "legacy and compact plans extract three coherent tasks" 3 "$(jq 'length' <<<"$compact_json")"
check "legacy and compact plans have equivalent extracted tasks" \
  "$(jq -S -c . <<<"$legacy_json")" "$(jq -S -c . <<<"$compact_json")"
check "compact plan covers exactly seven unique files" 7 "$(jq '[.[].files[]] | unique | length' <<<"$compact_json")"
check "legacy extracted tasks pass structural tasks lint" 0 "$(bash "$ROOT/lib/artifact-lint.sh" tasks - <<<"$legacy_json" >/dev/null 2>&1; echo $?)"
check "compact extracted tasks pass structural tasks lint" 0 "$(bash "$ROOT/lib/artifact-lint.sh" tasks - <<<"$compact_json" >/dev/null 2>&1; echo $?)"
check "legacy plan covers SPEC criteria" 0 "$(bash "$ROOT/lib/criteria-coverage.sh" "$WORK/SPEC.md" "$WORK/legacy-PLAN.typed.md" >/dev/null 2>&1; echo $?)"
check "compact plan covers SPEC criteria" 0 "$(bash "$ROOT/lib/criteria-coverage.sh" "$WORK/SPEC.md" "$WORK/compact-PLAN.md" >/dev/null 2>&1; echo $?)"
check "legacy plan covers SPEC decision" 0 "$(bash "$ROOT/lib/decision-coverage.sh" "$WORK/SPEC.md" "$WORK/legacy-PLAN.typed.md" >/dev/null 2>&1; echo $?)"
check "compact plan covers SPEC decision" 0 "$(bash "$ROOT/lib/decision-coverage.sh" "$WORK/SPEC.md" "$WORK/compact-PLAN.md" >/dev/null 2>&1; echo $?)"
check "compact plan passes structural lint" 0 "$(bash "$ROOT/lib/artifact-lint.sh" plan "$WORK/compact-PLAN.md" >/dev/null 2>&1; echo $?)"
check "legacy task criteria pass acceptance lint" 0 "$(bash "$ROOT/lib/acceptance-lint.sh" - <<<"$legacy_json" >/dev/null 2>&1; echo $?)"
check "compact task criteria pass acceptance lint" 0 "$(bash "$ROOT/lib/acceptance-lint.sh" - <<<"$compact_json" >/dev/null 2>&1; echo $?)"
check "compact PATTERNS passes structural lint" 0 "$(bash "$ROOT/lib/artifact-lint.sh" patterns "$WORK/compact-PATTERNS.md" >/dev/null 2>&1; echo $?)"
check "legacy PATTERNS retains cited analog excerpts" 1 "$(grep -c 'Source analog' "$WORK/legacy-PATTERNS.md")"
check "compact PATTERNS retains the same source reference" 1 "$(grep -c 'Source analog' "$WORK/compact-PATTERNS.md")"
check "compact and legacy retain identical source references" \
  "$(grep -E '^(Source|Test) analog:' "$WORK/legacy-PATTERNS.md")" \
  "$(grep -E '^(Source|Test) analog:' "$WORK/compact-PATTERNS.md")"
check "legacy PATTERNS contains representative source excerpt" 1 "$(grep -c 'representative legacy adapter shape' "$WORK/legacy-PATTERNS.md")"
check "compact PATTERNS omits representative source excerpt" 0 "$(grep -c 'representative legacy adapter shape' "$WORK/compact-PATTERNS.md")"

legacy_bytes="$(wc -c < "$WORK/legacy-PLAN.md" | tr -d ' ')"
compact_bytes="$(wc -c < "$WORK/compact-PLAN.md" | tr -d ' ')"
legacy_words="$(wc -w < "$WORK/legacy-PLAN.md" | tr -d ' ')"
compact_words="$(wc -w < "$WORK/compact-PLAN.md" | tr -d ' ')"
echo "REPORT: legacy_plan_bytes=$legacy_bytes compact_plan_bytes=$compact_bytes legacy_plan_words=$legacy_words compact_plan_words=$compact_words"
patterns_legacy_bytes="$(wc -c < "$WORK/legacy-PATTERNS.md" | tr -d ' ')"
patterns_compact_bytes="$(wc -c < "$WORK/compact-PATTERNS.md" | tr -d ' ')"
patterns_legacy_words="$(wc -w < "$WORK/legacy-PATTERNS.md" | tr -d ' ')"
patterns_compact_words="$(wc -w < "$WORK/compact-PATTERNS.md" | tr -d ' ')"
echo "REPORT: legacy_patterns_bytes=$patterns_legacy_bytes compact_patterns_bytes=$patterns_compact_bytes legacy_patterns_words=$patterns_legacy_words compact_patterns_words=$patterns_compact_words synthetic_fixture=1"
echo "REPORT: compact_index_bytes=$index_bytes compact_index_words=$index_words compact_total_bytes=$((compact_bytes + patterns_compact_bytes + index_bytes)) compact_total_words=$((compact_words + patterns_compact_words + index_words)) synthetic_fixture=1"
check "compact total including index remains below legacy PLAN+PATTERNS" 1 "$(( compact_bytes + patterns_compact_bytes + index_bytes < legacy_bytes + patterns_legacy_bytes ))"
check "compact fixture is smaller by bytes" 1 "$(( compact_bytes < legacy_bytes ))"
check "compact fixture is smaller by words" 1 "$(( compact_words < legacy_words ))"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
