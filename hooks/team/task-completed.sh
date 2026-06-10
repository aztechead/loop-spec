#!/usr/bin/env bash
# TaskCompleted hook: phase-aware quality gate on task completion.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# Behavior by currentPhase in feature.json:
#   execute  -> run lint and typecheck commands from feature.json.commands if configured
#   discuss  -> validate task metadata has required fields (blockedBy, files, verifyCommand, acceptanceCriteria)
#   plan     -> validate task metadata has required fields
#   other    -> allow (exit 0)
#
# If feature.json is missing, exit 0 (graceful).
# SUPER_SPEC_FEATURE_DIR env var overrides the default feature directory location.
set -euo pipefail

INPUT=$(cat)

# Locate feature.json
FEATURE_DIR="${SUPER_SPEC_FEATURE_DIR:-}"
FEATURE_JSON=""

if [[ -n "$FEATURE_DIR" ]]; then
  FEATURE_JSON="$FEATURE_DIR/feature.json"
else
  # Default: resolve to user's project root via CLAUDE_PROJECT_DIR (set by CC harness),
  # not via dirname of the hook script (which resolves to the plugin install dir).
  REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  FEATURE_JSON=$(find "$REPO_ROOT/.super-spec/features" -maxdepth 2 -name "feature.json" 2>/dev/null | head -1 || true)
fi

# Missing feature.json: graceful exit
if [[ -z "$FEATURE_JSON" || ! -f "$FEATURE_JSON" ]]; then
  exit 0
fi

# Read phase and commands using python3 with path as argument (avoids interpolation issues)
CURRENT_PHASE=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('currentPhase', ''))
except Exception:
    print('')
" "$FEATURE_JSON")

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

run_check() {
  # Run a project-configured lint/typecheck command and return its exit code.
  # The command string comes from feature.json (commands.lint / commands.typecheck), which is a
  # project-controlled file but may originate from an untrusted PR branch in some workflows.
  # Prior implementation used `bash -c "$cmd"`, which executes arbitrary shell from feature.json --
  # an attacker who can influence feature.json can execute arbitrary code on this user's machine.
  # Defense: restrict to a conservative allowlist of characters (alnum, space, `_./@:=+-`) and
  # execute via array exec with no shell interpretation. This still supports typical project
  # configurations like `npm run lint`, `ruff check src`, `pyright`, `tsc --noEmit`, etc., while
  # rejecting any shell metacharacters (;, &, |, `, $, <, >, (, ), {, }, ', ", \, newline).
  local cmd="$1"
  if [[ "$cmd" =~ [^[:alnum:][:space:]_./@:=+-] ]]; then
    echo "DENY: feature.json command contains forbidden character; refusing to execute: $cmd" >&2
    return 2
  fi
  local -a parts
  read -ra parts <<< "$cmd"
  local rc=0
  # Subshell isolates `exit` / `return` builtins (`set -e` aborts on no-op too).
  ( "${parts[@]}" ) >/dev/null 2>&1 || rc=$?
  return $rc
}

case "$CURRENT_PHASE" in
  execute)
    LINT_CMD=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('commands', {}).get('lint', '') or '')
except Exception:
    print('')
" "$FEATURE_JSON")

    TYPECHECK_CMD=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('commands', {}).get('typecheck', '') or '')
except Exception:
    print('')
" "$FEATURE_JSON")

    if [[ -n "$LINT_CMD" ]]; then
      lint_rc=0
      run_check "$LINT_CMD" || lint_rc=$?
      if [[ "$lint_rc" -ne 0 ]]; then
        echo "DENY: lint failed (command: $LINT_CMD). Fix lint errors before marking task completed." >&2
        exit 2
      fi
    fi

    if [[ -n "$TYPECHECK_CMD" ]]; then
      tc_rc=0
      run_check "$TYPECHECK_CMD" || tc_rc=$?
      if [[ "$tc_rc" -ne 0 ]]; then
        echo "DENY: typecheck failed (command: $TYPECHECK_CMD). Fix type errors before marking task completed." >&2
        exit 2
      fi
    fi
    ;;

  discuss|plan)
    RESULT=$(validate_metadata)
    if [[ "$RESULT" != "OK" ]]; then
      MISSING_FIELDS="${RESULT#MISSING:}"
      echo "DENY: Task metadata missing or invalid required fields: $MISSING_FIELDS. All tasks must have blockedBy, files, verifyCommand, and acceptanceCriteria." >&2
      exit 2
    fi
    ;;

  *)
    # Unknown/other phase: allow
    ;;
esac

exit 0
