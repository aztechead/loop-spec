#!/usr/bin/env bash
# PreToolUse hook: restrict Write/Edit paths per subagent_type.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# Caller identity is determined by parsing the session transcript to find the
# most recent Agent dispatch and reading its subagent_type field.
#
# Caller subagent_type is namespaced "super-spec:<role>" (plugin agents); the
# legacy bare "super-spec-<role>" form is also accepted. Both are normalized to the
# bare <role> before matching.
#
# Rules (by role):
#   spec-writer, planner, pattern-mapper -> docs/super-spec/features/**
#   mapper-*                          -> docs/super-spec/codebase/**
#   implementer, verifier            -> unrestricted
#   main thread (no enclosing Agent dispatch) -> unrestricted
#   all other subagent_types         -> unrestricted
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name',''))")

# Only restrict Write and Edit tool calls
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))")
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('transcript_path',''))")

# Parse transcript to find caller subagent_type (last Agent dispatch wins)
CALLER=$(python3 - "$TRANSCRIPT_PATH" <<'PY'
import json, sys

transcript_path = sys.argv[1] if len(sys.argv) > 1 else ""
caller = ""

if not transcript_path:
    sys.exit(0)

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
            if entry.get("type") != "assistant":
                continue
            message = entry.get("message", {})
            if not isinstance(message, dict):
                continue
            for part in message.get("content", []):
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "tool_use" and part.get("name") == "Agent":
                    subtype = part.get("input", {}).get("subagent_type", "")
                    if subtype:
                        caller = subtype
except Exception:
    pass

print(caller)
PY
)

# Path match helper: returns 0 if FILE_PATH is under the given prefix segment.
# Handles both relative and absolute paths by matching on the path fragment.
path_allowed() {
  local prefix="$1"
  # Relative match
  if [[ "$FILE_PATH" == ${prefix}/* || "$FILE_PATH" == ${prefix} ]]; then
    return 0
  fi
  # Absolute path containing the prefix segment (e.g. /Users/.../docs/super-spec/features/...)
  if [[ "$FILE_PATH" == */${prefix}/* || "$FILE_PATH" == */${prefix} ]]; then
    return 0
  fi
  return 1
}

# Normalize the caller to a bare role name. Plugin agents are namespaced
# "super-spec:<role>" in the transcript; older transcripts may carry the legacy
# "super-spec-<role>" form. Strip either prefix so the role patterns below match
# regardless of how the harness recorded the subagent_type.
CALLER="${CALLER#super-spec:}"
CALLER="${CALLER#super-spec-}"

case "$CALLER" in
  spec-writer|planner|pattern-mapper)
    if path_allowed "docs/super-spec/features"; then
      exit 0
    fi
    echo "DENY: $CALLER may only $TOOL_NAME under docs/super-spec/features/** (attempted: $FILE_PATH)" >&2
    exit 2
    ;;
  mapper-*)
    if path_allowed "docs/super-spec/codebase"; then
      exit 0
    fi
    echo "DENY: $CALLER may only $TOOL_NAME under docs/super-spec/codebase/** (attempted: $FILE_PATH)" >&2
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
