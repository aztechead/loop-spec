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
#   spec-writer, planner             -> docs/loop-spec/features/** only
#   any caller                       -> a write under docs/loop-spec/features/<slug>/ lands
#                                       in the checkout that holds that feature's
#                                       feature.json, when one does
#   pattern-mapper                   -> docs/loop-spec/features/** + .claude/agent-memory/** (memory: project)
#   code-reviewer                    -> .claude/agent-memory/** ONLY (read-only for code; the
#                                       `memory: project` frontmatter auto-enables Write/Edit,
#                                       so this case keeps the role's no-code-writes invariant)
#   implementer, verifier            -> unrestricted
#   main thread (no open Agent dispatch) -> unrestricted
#   all other subagent_types         -> unrestricted
#   any caller                       -> never .loop-spec/**/{last-result,result,active-run,
#                                       feature,delivery}.json, never the installed plugin
#
# Fast path: when the project has no .loop-spec/ state (no cycle has
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
  if [[ ! -d "$PWD/.loop-spec" && ! -d "${CLAUDE_PROJECT_DIR:-/nonexistent}/.loop-spec" ]]; then
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

# The files lib/cycle-result.sh, lib/feature-write.sh, and lib/deliver.sh own are never
# Write or Edit targets, whoever the caller is: a haiku eval run whose result the writer
# refused twice wrote .loop-spec/last-result.json by hand and a supervisor read a run
# that never reached DELIVER as completed (evals/findings-2026-09-06.md).
# hooks/team/result-forgery-guard.sh covers the same files from the shell.
case "$FILE_PATH" in
  .loop-spec/*|*/.loop-spec/*)
    case "$(basename "$FILE_PATH")" in
      last-result.json|result.json|active-run.json|feature.json|delivery.json)
        echo "DENY: $TOOL_NAME targets $FILE_PATH, a loop-spec contract file that only lib/cycle-result.sh, lib/feature-write.sh, or lib/deliver.sh may write. A result those writers refuse is a run that has not earned it: return to the cycle, or publish the honest status with --reason. (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
        exit 2
        ;;
    esac
    ;;
esac

# The installed plugin is never a write target, whoever the caller is: a sonnet eval
# run patched lib/runtime-ignore.sh in the plugin checkout to get past a gate
# (evals/findings-2026-09-06.md, finding 1). Paths resolve by real location, so a
# feature worktree under the project stays writable, and the rule is off when the
# plugin root is the project or inside it (loop-spec developing itself).
plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [[ -n "$plugin_root" && -d "$plugin_root" ]]; then
  plugin_real="$(cd "$plugin_root" && pwd -P)"
  project_real="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd -P)" || project_real="$PWD"
  if [[ "$plugin_real" != "$project_real" && "$plugin_real" != "$project_real"/* ]]; then
    target="$FILE_PATH"
    [[ "$target" == /* ]] || target="$project_real/$target"
    target_dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || target_dir="$(dirname "$target")"
    target_real="$target_dir/$(basename "$target")"
    if [[ "$target_real" == "$plugin_real" || "$target_real" == "$plugin_real"/* ]]; then
      echo "DENY: $TOOL_NAME targets the installed loop-spec plugin ($plugin_real), which no cycle may edit (attempted: $FILE_PATH). A gate that blocks you is a finding to report, not a file to patch. (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
      exit 2
    fi
  fi
fi

# Parse transcript to find the caller subagent_type: the most recent Agent
# dispatch whose tool_use id has NOT been answered by a tool_result. A dispatch
# with a matching tool_result is finished — writes after it belong to the main
# thread, not to that subagent. Dispatches without ids (older transcripts,
# fixtures) cannot be matched and are conservatively treated as open.
# simplicity: this JSONL walk is near-duplicated in hooks/team/placeholder-question-guard.sh
# (different outputs: caller name here, open/phase there); extract a shared walker when a
# third hook needs one.
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

# feature_checkout_deny: a Write under docs/loop-spec/features/<slug>/ must land in the
# checkout that holds that feature's feature.json. Agents share the lead's cwd, which
# is the main checkout when the feature lives in a worktree: the spec-writer wrote
# SPEC.md next to the lead while phase-exit.sh read the worktree, and the 6.3.0 fastapi
# bug-fix run escalated after four blind REDO attempts. The lead did the same on the
# dda2cca run, on the short route, where it writes the spec itself, so the rule holds
# for every caller (orchestrator-port-followup.md, F5); the driver's `spec skeleton`
# and `spec write` are the path that cannot miss. No feature.json anywhere means
# nothing to compare, so the write stays allowed.
feature_checkout_deny() {
  local rel slug project target target_dir wt home homes=()
  rel="${FILE_PATH#*docs/loop-spec/features/}"
  [[ "$rel" != "$FILE_PATH" && "$rel" == */* ]] || return 0
  slug="${rel%%/*}"
  project="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd -P)" || return 0
  target="$FILE_PATH"; [[ "$target" == /* ]] || target="$project/$target"
  target_dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || target_dir="$(dirname "$target")"
  while IFS= read -r wt; do
    wt="${wt#worktree }"
    if wt="$(cd "$wt" 2>/dev/null && pwd -P)" && [[ -f "$wt/docs/loop-spec/features/$slug/feature.json" ]]; then
      homes[${#homes[@]}]="$wt"
    fi
  done < <(git -C "$project" worktree list --porcelain 2>/dev/null | grep '^worktree ' || true)
  [[ ${#homes[@]} -gt 0 ]] || return 0
  for home in "${homes[@]}"; do
    if [[ "$target_dir" == "$home" || "$target_dir" == "$home"/* ]]; then return 0; fi
  done
  echo "DENY: $CALLER $TOOL_NAME targets $FILE_PATH, but feature '$slug' lives in the checkout ${homes[0]} (its feature.json is there) and the phase exit gate reads that copy, never this one. Write ${homes[0]}/docs/loop-spec/features/$rel instead. (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
  exit 2
}

if path_allowed "docs/loop-spec/features"; then
  feature_checkout_deny
fi

case "$CALLER" in
  spec-writer|planner)
    if path_allowed "docs/loop-spec/features"; then
      exit 0
    fi
    echo "DENY: $CALLER may only $TOOL_NAME under docs/loop-spec/features/** (attempted: $FILE_PATH). (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
    exit 2
    ;;
  pattern-mapper)
    if path_allowed "docs/loop-spec/features" || path_allowed ".claude/agent-memory"; then
      exit 0
    fi
    echo "DENY: $CALLER may only $TOOL_NAME under docs/loop-spec/features/** or .claude/agent-memory/** (attempted: $FILE_PATH). (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
    exit 2
    ;;
  code-reviewer)
    if path_allowed ".claude/agent-memory"; then
      exit 0
    fi
    echo "DENY: $CALLER is read-only for code; it may only $TOOL_NAME under .claude/agent-memory/** (attempted: $FILE_PATH). (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
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
