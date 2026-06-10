#!/usr/bin/env bash
# lib/regression-scan.sh <project-root>
#
# Reads docs/loop-spec/features/*/VERIFICATION.md for completed features,
# extracts test commands, runs them, and outputs structured JSON.
#
# Output: {"prior_features":[{"slug":"...","status":"pass|fail"}], "failed_tests":[{"slug":"...","command":"...","exit_code":N,"output":"..."}]}
#
# Fail-open: any parse error or missing path produces empty arrays and exits 0.
# Read-only: never modifies any file.
#
# Usage: bash lib/regression-scan.sh <project-root>
#
# Exit codes:
#   0 always (fail-open advisory script)
set -euo pipefail

EMPTY_JSON='{"prior_features":[],"failed_tests":[]}'

# Validate argument.
if [[ $# -ne 1 ]]; then
  printf '%s\n' "$EMPTY_JSON"
  exit 0
fi

PROJECT_ROOT="$1"
FEATURES_DIR="$PROJECT_ROOT/docs/loop-spec/features"

if [[ ! -d "$FEATURES_DIR" ]]; then
  printf '%s\n' "$EMPTY_JSON"
  exit 0
fi

# Collect VERIFICATION.md files.
mapfile -t VERIF_FILES < <(find "$FEATURES_DIR" -name "VERIFICATION.md" -type f 2>/dev/null | sort)

if [[ "${#VERIF_FILES[@]}" -eq 0 ]]; then
  printf '%s\n' "$EMPTY_JSON"
  exit 0
fi

# Extract verify commands from a VERIFICATION.md file.
# Looks for backtick-enclosed commands in table rows (pattern: | ... | `cmd` | ...)
# and bare lines like: Verify: `cmd` or `bash tests/...` or `make test`.
extract_commands() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import re
import sys

verif_path = sys.argv[1]
try:
    with open(verif_path) as f:
        content = f.read()
except Exception:
    sys.exit(0)

commands = []
seen = set()

# Pattern 1: backtick commands in markdown table cells
# e.g. | 1 | some criterion | `bash tests/foo.sh` | PASS |
for m in re.finditer(r'\|\s*`([^`]+)`\s*\|', content):
    cmd = m.group(1).strip()
    if cmd and cmd not in seen:
        commands.append(cmd)
        seen.add(cmd)

# Pattern 2: Verify: `cmd` lines (task spec pattern)
for m in re.finditer(r'Verify:\s*`([^`]+)`', content):
    cmd = m.group(1).strip()
    if cmd and cmd not in seen:
        commands.append(cmd)
        seen.add(cmd)

# Pattern 3: fenced bash blocks (```bash ... ```) - extract commands that look like test runners
in_bash_block = False
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('```bash'):
        in_bash_block = True
        continue
    if in_bash_block and stripped.startswith('```'):
        in_bash_block = False
        continue
    if in_bash_block:
        # Only extract lines that look like test runner invocations
        if (stripped.startswith('bash tests/') or
                stripped.startswith('make test') or
                stripped.startswith('bash hooks/') or
                stripped.startswith('jq ') or
                stripped.startswith('grep ')):
            if stripped and stripped not in seen:
                commands.append(stripped)
                seen.add(stripped)

for cmd in commands:
    print(cmd)
PYEOF
}

# Build result arrays using python3 for safe JSON construction.
PRIOR_FEATURES_JSON="[]"
FAILED_TESTS_JSON="[]"

for VERIF_FILE in "${VERIF_FILES[@]}"; do
  # Derive slug from directory name.
  FEATURE_DIR="$(dirname "$VERIF_FILE")"
  SLUG="$(basename "$FEATURE_DIR")"

  # Extract commands; on any failure continue with empty list (fail-open).
  mapfile -t COMMANDS < <(extract_commands "$VERIF_FILE" 2>/dev/null || true)

  FEATURE_STATUS="pass"
  FEATURE_FAILED=()
  FEATURE_FAILED_CMDS=()
  FEATURE_FAILED_CODES=()
  FEATURE_FAILED_OUTPUTS=()

  for CMD in "${COMMANDS[@]}"; do
    [[ -z "$CMD" ]] && continue
    actual_exit=0
    actual_output=""
    actual_output=$(bash -c "$CMD" 2>&1) || actual_exit=$?
    if [[ "$actual_exit" -ne 0 ]]; then
      FEATURE_STATUS="fail"
      FEATURE_FAILED+=("$SLUG")
      FEATURE_FAILED_CMDS+=("$CMD")
      FEATURE_FAILED_CODES+=("$actual_exit")
      FEATURE_FAILED_OUTPUTS+=("$actual_output")
    fi
  done

  # Append to prior_features array.
  PRIOR_FEATURES_JSON=$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
arr.append({'slug': sys.argv[2], 'status': sys.argv[3]})
print(json.dumps(arr))
" "$PRIOR_FEATURES_JSON" "$SLUG" "$FEATURE_STATUS" 2>/dev/null) || PRIOR_FEATURES_JSON="$PRIOR_FEATURES_JSON"

  # Append failed tests.
  for i in "${!FEATURE_FAILED[@]}"; do
    FAILED_TESTS_JSON=$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
arr.append({
    'slug': sys.argv[2],
    'command': sys.argv[3],
    'exit_code': int(sys.argv[4]),
    'output': sys.argv[5]
})
print(json.dumps(arr))
" "$FAILED_TESTS_JSON" \
      "${FEATURE_FAILED[$i]}" \
      "${FEATURE_FAILED_CMDS[$i]}" \
      "${FEATURE_FAILED_CODES[$i]}" \
      "${FEATURE_FAILED_OUTPUTS[$i]}" 2>/dev/null) || FAILED_TESTS_JSON="$FAILED_TESTS_JSON"
  done
done

# Emit final JSON.
python3 -c "
import json, sys
prior = json.loads(sys.argv[1])
failed = json.loads(sys.argv[2])
print(json.dumps({'prior_features': prior, 'failed_tests': failed}))
" "$PRIOR_FEATURES_JSON" "$FAILED_TESTS_JSON" 2>/dev/null || printf '%s\n' "$EMPTY_JSON"
