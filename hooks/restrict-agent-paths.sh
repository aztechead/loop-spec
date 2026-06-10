#!/usr/bin/env bash
# PreToolUse hook: restrict Write/Edit paths per subagent_type.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# Caller identity is determined by parsing the session transcript to find the
# most recent Agent dispatch that is still OPEN (its tool_use id has no matching
# tool_result yet) and reading its subagent_type field. Matching on the last
# dispatch regardless of completion misattributed main-thread writes to a
# long-finished subagent and produced spurious DENYs.
#
# Caller subagent_type is namespaced "loop-spec:<role>" (plugin agents); the
# legacy bare "loop-spec-<role>" form is also accepted. Both are normalized to the
# bare <role> before matching.
#
# Rules (by role):
#   spec-writer, planner, pattern-mapper -> docs/loop-spec/features/**
#   mapper-*                          -> docs/loop-spec/codebase/**
#   implementer, verifier            -> unrestricted
#   main thread (no open Agent dispatch) -> unrestricted
#   all other subagent_types         -> unrestricted
#
# Fast path: when the project has no .loop-spec/features state (no cycle has
# ever run here), exit 0 before parsing anything — this hook must not tax every
# Write/Edit in unrelated projects. LOOP_SPEC_PATH_GUARD_FORCE=1 bypasses the
# fast path (used by tests).
#
# Kill switch: LOOP_SPEC_PATH_GUARD=0 -> exit 0 unconditionally.
# Fail-open: malformed payload or parse failure -> exit 0 (never a hook error).
set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

if [[ "${LOOP_SPEC_PATH_GUARD:-1}" == "0" ]]; then
  exit 0
fi

# Fast path: no loop-spec state in this project -> nothing to restrict.
if [[ "${LOOP_SPEC_PATH_GUARD_FORCE:-0}" != "1" ]]; then
  if [[ ! -d "$PWD/.loop-spec/features" && ! -d "${CLAUDE_PROJECT_DIR:-/nonexistent}/.loop-spec/features" ]]; then
    exit 0
  fi
fi

INPUT=$(cat 2>/dev/null) || true
[[ -z "$INPUT" ]] && exit 0

PARSED=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool_name = d.get('tool_name') or ''
tool_input = d.get('tool_input') or {}
print(tool_name)
print(tool_input.get('file_path') or '')
print(d.get('transcript_path') or '')
" 2>/dev/null) || PARSED=""

[[ -z "$PARSED" ]] && exit 0

TOOL_NAME=$(printf '%s' "$PARSED" | sed -n '1p')
FILE_PATH=$(printf '%s' "$PARSED" | sed -n '2p')
TRANSCRIPT_PATH=$(printf '%s' "$PARSED" | sed -n '3p')

# Only restrict Write and Edit tool calls
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

# Parse transcript to find the caller subagent_type: the most recent Agent
# dispatch whose tool_use id has NOT been answered by a tool_result. A dispatch
# with a matching tool_result is finished — writes after it belong to the main
# thread, not to that subagent. Dispatches without ids (older transcripts,
# fixtures) cannot be matched and are conservatively treated as open.
CALLER=$(python3 - "$TRANSCRIPT_PATH" <<'PY' 2>/dev/null
import json, sys

transcript_path = sys.argv[1] if len(sys.argv) > 1 else ""
if not transcript_path:
    sys.exit(0)

dispatches = []          # (tool_use_id or None, subagent_type) in order
result_ids = set()

try:
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            message = entry.get("message", {})
            if not isinstance(message, dict):
                continue
            content = message.get("content", [])
            if not isinstance(content, list):
                continue
            if entry.get("type") == "assistant":
                for part in content:
                    if not isinstance(part, dict):
                        continue
                    if part.get("type") == "tool_use" and part.get("name") == "Agent":
                        subtype = part.get("input", {}).get("subagent_type", "")
                        if subtype:
                            dispatches.append((part.get("id"), subtype))
            elif entry.get("type") == "user":
                for part in content:
                    if not isinstance(part, dict):
                        continue
                    if part.get("type") == "tool_result" and part.get("tool_use_id"):
                        result_ids.add(part["tool_use_id"])
except Exception:
    sys.exit(0)

caller = ""
for tid, subtype in dispatches:
    if tid is not None and tid in result_ids:
        continue  # dispatch finished; not the active caller
    caller = subtype

print(caller)
PY
) || CALLER=""

# Path match helper: returns 0 if FILE_PATH is under the given prefix segment.
# Handles both relative and absolute paths by matching on the path fragment.
path_allowed() {
  local prefix="$1"
  # Relative match
  if [[ "$FILE_PATH" == ${prefix}/* || "$FILE_PATH" == ${prefix} ]]; then
    return 0
  fi
  # Absolute path containing the prefix segment (e.g. /Users/.../docs/loop-spec/features/...)
  if [[ "$FILE_PATH" == */${prefix}/* || "$FILE_PATH" == */${prefix} ]]; then
    return 0
  fi
  return 1
}

# Normalize the caller to a bare role name. Plugin agents are namespaced
# "loop-spec:<role>" in the transcript; older transcripts may carry the legacy
# "loop-spec-<role>" form. Strip either prefix so the role patterns below match
# regardless of how the harness recorded the subagent_type.
CALLER="${CALLER#loop-spec:}"
CALLER="${CALLER#loop-spec-}"

case "$CALLER" in
  spec-writer|planner|pattern-mapper)
    if path_allowed "docs/loop-spec/features"; then
      exit 0
    fi
    echo "DENY: $CALLER may only $TOOL_NAME under docs/loop-spec/features/** (attempted: $FILE_PATH). (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
    exit 2
    ;;
  mapper-*)
    if path_allowed "docs/loop-spec/codebase"; then
      exit 0
    fi
    echo "DENY: $CALLER may only $TOOL_NAME under docs/loop-spec/codebase/** (attempted: $FILE_PATH). (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
    exit 2
    ;;
  implementer|verifier|"")
    # Implementers, verifiers, and main thread are unrestricted
    exit 0
    ;;
  *)
    # Unknown subagent types: allow (defensive default)
    exit 0
    ;;
esac
