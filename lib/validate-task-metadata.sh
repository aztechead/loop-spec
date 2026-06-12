#!/usr/bin/env bash
# Validate a task-metadata JSON object before TaskCreate.
#
# Usage:
#   bash lib/validate-task-metadata.sh '<metadata-json>'
#
# Required metadata fields:
#   - blockedBy:          array (may be empty)
#   - files:              array (may be empty)
#   - verifyCommand:      non-empty string
#   - acceptanceCriteria: non-empty array
#
# Exit codes:
#   0  metadata OK
#   1  invocation error (no/invalid argument)
#   2  validation failure (missing or invalid required field). Failure message printed to stderr.
#
# Rationale:
#   The Claude Code agent-teams docs reserve the `TaskCreated` event for
#   intercepting task creation, but its payload schema is not published, and
#   `PreToolUse: TaskCreate` is not a documented matcher (TaskCreate is not in
#   the listed PreToolUse tool set). To avoid depending on undocumented hook
#   behavior, loop-spec validates task metadata orchestrator-side instead --
#   the cycle's EXECUTE phase (skills/execute/SKILL.md Step 3) calls this
#   script once per task before invoking TaskCreate.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: validate-task-metadata.sh '<metadata-json>'" >&2
  exit 1
fi

METADATA="$1"

RESULT=$(printf '%s' "$METADATA" | python3 -c "
import json, sys

try:
    metadata = json.loads(sys.stdin.read())
except json.JSONDecodeError as e:
    print(f'INVALID_JSON:{e}')
    sys.exit(0)

required = ['blockedBy', 'files', 'verifyCommand', 'acceptanceCriteria']
missing = []

if not isinstance(metadata, dict):
    print('NOT_AN_OBJECT')
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
    if field in ('blockedBy', 'files') and not isinstance(val, list):
        missing.append(field)
        continue

if missing:
    print('MISSING:' + ','.join(missing))
    sys.exit(0)

# Type-check optional fields when present.
FAILURE_POLICY_VALUES = {'stop-plan', 'reopen-continue', 'log-continue'}
GATE_SCOPE_VALUES = {'once', 'per-target', 'one-then-all', 'custom'}

optional_errors = []

def check_optional(field, validator, description):
    if field in metadata:
        val = metadata[field]
        if not validator(val):
            optional_errors.append(f'{field}:{description}')

check_optional('userGate', lambda v: isinstance(v, bool), 'must be bool')
check_optional('requireABCompare', lambda v: isinstance(v, bool), 'must be bool')
check_optional('requiresUserSpecification', lambda v: isinstance(v, bool), 'must be bool')
check_optional('subagentType', lambda v: isinstance(v, str), 'must be string')
check_optional('model', lambda v: isinstance(v, str), 'must be string')
check_optional('dispatchBrief', lambda v: isinstance(v, str), 'must be string')
check_optional('failurePolicy', lambda v: isinstance(v, str) and v in FAILURE_POLICY_VALUES,
               f'must be one of: {sorted(FAILURE_POLICY_VALUES)}')
check_optional('gateScope', lambda v: isinstance(v, str) and v in GATE_SCOPE_VALUES,
               f'must be one of: {sorted(GATE_SCOPE_VALUES)}')
check_optional('requireEvidenceTokens', lambda v: isinstance(v, list),
               'must be array')
check_optional('repo', lambda v: isinstance(v, str), 'must be string')

if optional_errors:
    print('INVALID_OPTIONAL:' + ','.join(optional_errors))
else:
    print('OK')
")

case "$RESULT" in
  OK)
    exit 0
    ;;
  INVALID_JSON:*)
    echo "DENY: task metadata is not valid JSON: ${RESULT#INVALID_JSON:}" >&2
    exit 2
    ;;
  NOT_AN_OBJECT)
    echo "DENY: task metadata must be a JSON object" >&2
    exit 2
    ;;
  MISSING:*)
    echo "DENY: task metadata missing or invalid required fields: ${RESULT#MISSING:}" >&2
    exit 2
    ;;
  INVALID_OPTIONAL:*)
    echo "DENY: task metadata has invalid optional field values: ${RESULT#INVALID_OPTIONAL:}" >&2
    exit 2
    ;;
  *)
    echo "DENY: validate-task-metadata internal error: $RESULT" >&2
    exit 2
    ;;
esac
