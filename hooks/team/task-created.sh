#!/usr/bin/env bash
# PreToolUse hook: validate required task metadata fields at TaskCreate time.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# Validates that tool_input.metadata contains all required fields:
#   blockedBy, files, verifyCommand, acceptanceCriteria
#
# Exit 2 with DENY: message to stderr listing missing/invalid fields.
# Exit 0 when all required fields are present and valid.
set -euo pipefail

INPUT=$(cat)

validate_metadata() {
  printf '%s' "$INPUT" | python3 -c "
import json, sys

d = json.load(sys.stdin)
metadata = d.get('tool_input', {}).get('metadata', None)

required = ['blockedBy', 'files', 'verifyCommand', 'acceptanceCriteria']
missing = []

if metadata is None:
    print('MISSING:' + ','.join(required))
    sys.exit(0)

for field in required:
    if field not in metadata:
        missing.append(field)
        continue
    val = metadata[field]
    if field == 'verifyCommand' and (not isinstance(val, str) or not val.strip()):
        missing.append(field)
        continue
    if field == 'acceptanceCriteria' and (not isinstance(val, list) or len(val) == 0):
        missing.append(field)
        continue

if missing:
    print('MISSING:' + ','.join(missing))
else:
    print('OK')
"
}

RESULT=$(validate_metadata)
if [[ "$RESULT" != "OK" ]]; then
  MISSING_FIELDS="${RESULT#MISSING:}"
  echo "DENY: Task metadata missing or invalid required fields: $MISSING_FIELDS. All tasks must have blockedBy, files, verifyCommand, and acceptanceCriteria." >&2
  exit 2
fi

exit 0
