#!/usr/bin/env bash
# TaskCompleted hook: phase-aware quality gate on task completion.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# SCOPE: only loop-spec-owned tasks are gated. A task is loop-spec-owned when
# tool_input.metadata.loopSpec == true (written by EXECUTE Step 4) or the
# subject matches "task-NNN: ...". Ordinary task-tracking completions (main
# thread, other plugins) pass through untouched — gating them broke core task
# tracking and ran the project's lint/typecheck on every unrelated completion.
#
# Behavior by currentPhase in feature.json (marked tasks only):
#   execute  -> run lint and typecheck commands from feature.json.commands if configured
#   discuss  -> validate task metadata has required fields (blockedBy, files, verifyCommand, acceptanceCriteria)
#   plan     -> validate task metadata has required fields
#   other    -> allow (exit 0)
#
# If feature.json is missing, exit 0 (graceful).
# LOOP_SPEC_FEATURE_DIR env var overrides the default feature directory location.
# Kill switch: LOOP_SPEC_TASK_GUARD=0 -> exit 0 unconditionally.
# Fail-open: malformed payload or python3 failure -> exit 0 (never a hook error).
set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

if [[ "${LOOP_SPEC_TASK_GUARD:-1}" == "0" ]]; then
  exit 0
fi

INPUT=$(cat 2>/dev/null) || true
[[ -z "$INPUT" ]] && exit 0

# Locate feature.json
FEATURE_DIR="${LOOP_SPEC_FEATURE_DIR:-}"
FEATURE_JSON=""

if [[ -n "$FEATURE_DIR" ]]; then
  FEATURE_JSON="$FEATURE_DIR/feature.json"
else
  # Default: resolve to user's project root via CLAUDE_PROJECT_DIR (set by CC harness),
  # not via dirname of the hook script (which resolves to the plugin install dir).
  REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  # Fast path: no .loop-spec/features dir means no active feature — skip the find.
  if [[ ! -d "$REPO_ROOT/.loop-spec/features" ]]; then
    exit 0
  fi
  FEATURE_JSON=$(find "$REPO_ROOT/.loop-spec/features" -maxdepth 2 -name "feature.json" 2>/dev/null | head -1 || true)
fi

# Missing feature.json: graceful exit
if [[ -z "$FEATURE_JSON" || ! -f "$FEATURE_JSON" ]]; then
  exit 0
fi

# Scope check: pass through any completion that is not a loop-spec-owned task.
MARKED=$(printf '%s' "$INPUT" | python3 -c "
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('no')
    sys.exit(0)
tool_input = d.get('tool_input') or {}
metadata = tool_input.get('metadata') or {}
subject = tool_input.get('subject') or ''
marked = metadata.get('loopSpec') is True or bool(re.match(r'^task-[0-9]+:', subject))
print('yes' if marked else 'no')
" 2>/dev/null) || MARKED="no"

if [[ "$MARKED" != "yes" ]]; then
  exit 0
fi

# Read phase using python3 with path as argument (avoids interpolation issues)
CURRENT_PHASE=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('currentPhase', ''))
except Exception:
    print('')
" "$FEATURE_JSON" 2>/dev/null) || CURRENT_PHASE=""

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
" 2>/dev/null || echo "OK"
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
" "$FEATURE_JSON" 2>/dev/null) || LINT_CMD=""

    TYPECHECK_CMD=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('commands', {}).get('typecheck', '') or '')
except Exception:
    print('')
" "$FEATURE_JSON" 2>/dev/null) || TYPECHECK_CMD=""

    if [[ -n "$LINT_CMD" ]]; then
      lint_rc=0
      run_check "$LINT_CMD" || lint_rc=$?
      if [[ "$lint_rc" -ne 0 ]]; then
        echo "DENY: lint failed (command: $LINT_CMD). Fix lint errors before marking task completed. (Disable: LOOP_SPEC_TASK_GUARD=0)" >&2
        exit 2
      fi
    fi

    if [[ -n "$TYPECHECK_CMD" ]]; then
      tc_rc=0
      run_check "$TYPECHECK_CMD" || tc_rc=$?
      if [[ "$tc_rc" -ne 0 ]]; then
        echo "DENY: typecheck failed (command: $TYPECHECK_CMD). Fix type errors before marking task completed. (Disable: LOOP_SPEC_TASK_GUARD=0)" >&2
        exit 2
      fi
    fi
    ;;

  discuss|plan)
    RESULT=$(validate_metadata)
    if [[ "$RESULT" != "OK" ]]; then
      MISSING_FIELDS="${RESULT#MISSING:}"
      echo "DENY: loop-spec task metadata missing or invalid required fields: $MISSING_FIELDS. All loop-spec tasks must have blockedBy, files, verifyCommand, and acceptanceCriteria. (Disable: LOOP_SPEC_TASK_GUARD=0)" >&2
      exit 2
    fi
    ;;

  *)
    # Unknown/other phase: allow
    ;;
esac

exit 0
