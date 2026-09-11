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
#   spec-writer, planner             -> docs/loop-spec/features/** (legacy pre-v1 features), or
#                                       .loop-spec/features/<slug>/publication-staging/** for the
#                                       single feature its own dispatch brief named (mined from
#                                       the brief's own absolute paths; unknown = denied, never
#                                       "any feature") -- v1 is the default, so the docs tree is
#                                       publication_protected_deny's to guard and the maker's copy
#                                       is the staged draft the lead lands with
#                                       cycle-driver.sh spec fill / plan write|patterns
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
#   any caller                       -> never SPEC.md or VERIFICATION.md of a feature on the
#                                       oneshot route (lib/graph/probes/oneshot.sh answers
#                                       route=oneshot for it): the driver's `spec fill`,
#                                       `spec escalate`, `spec footprint drop`, and
#                                       `verification fill` are the writers
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

# Every scope/protected-path decision below judges the RESOLVED location a write
# actually lands at, never the literal path the tool call names: a maker allowed to
# write under publication-staging could otherwise plant a symlink there pointing at
# SPEC.md/VERIFICATION.md (or a caller could name a symlinked "output.txt" that
# resolves to feature.json) and write through it undetected -- this hook would only
# ever have seen the literal, allowed-looking path. lib/resolve-symlink.sh does the
# resolution (shared with lib/harness.sh protected-path's own candidate resolution,
# so the two guards never disagree about where a path lands); FILE_PATH itself stays
# literal for DENY messages (what the caller actually typed), FILE_PATH_REAL is what
# every check below judges.
resolve_target() {
  local target="$1" abs
  abs="$target"
  [[ "$abs" == /* ]] || abs="${CLAUDE_PROJECT_DIR:-$PWD}/$abs"
  bash "$(dirname "${BASH_SOURCE[0]}")/../lib/resolve-symlink.sh" "$abs" 2>/dev/null || printf '%s' "$abs"
}
FILE_PATH_REAL="$(resolve_target "$FILE_PATH")"

# The files lib/cycle-result.sh, lib/feature-write.sh, and lib/deliver.sh own are never
# Write or Edit targets, whoever the caller is: a haiku eval run whose result the writer
# refused twice wrote .loop-spec/last-result.json by hand and a supervisor read a run
# that never reached DELIVER as completed (the 2026-09-06 live evals).
# hooks/team/result-forgery-guard.sh covers the same files from the shell.
case "$FILE_PATH_REAL" in
  */.loop-spec/*)
    case "$(basename "$FILE_PATH_REAL")" in
      last-result.json|result.json|active-run.json|feature.json|delivery.json)
        echo "DENY: $TOOL_NAME targets $FILE_PATH, a loop-spec contract file that only lib/cycle-result.sh, lib/feature-write.sh, or lib/deliver.sh may write. A result those writers refuse is a run that has not earned it: return to the cycle, or publish the honest status with --reason. (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
        exit 2
        ;;
    esac
    ;;
esac

# The installed plugin is never a write target, whoever the caller is: a sonnet eval
# run patched lib/runtime-ignore.sh in the plugin checkout to get past a gate
# (the 2026-09-06 live evals, finding 1). Paths resolve by real location, so a
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
CALLER_INFO=$(python3 - "$TRANSCRIPT_PATH" <<'PY' 2>/dev/null
import json, re, sys

transcript_path = sys.argv[1] if len(sys.argv) > 1 else ""
if not transcript_path:
    sys.exit(0)

dispatches = []          # (tool_use_id or None, subagent_type, prompt) in order
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
                        tool_input = part.get("input", {})
                        subtype = tool_input.get("subagent_type", "")
                        if subtype:
                            dispatches.append((part.get("id"), subtype, tool_input.get("prompt", "")))
            elif entry.get("type") == "user":
                for part in content:
                    if not isinstance(part, dict):
                        continue
                    if part.get("type") == "tool_result" and part.get("tool_use_id"):
                        result_ids.add(part["tool_use_id"])
except Exception:
    sys.exit(0)

caller = ""
caller_prompt = ""
for tid, subtype, prompt in dispatches:
    if tid is not None and tid in result_ids:
        continue  # dispatch finished; not the active caller
    caller = subtype
    caller_prompt = prompt

# The slug of the feature this dispatch is FOR, mined from the brief's own
# absolute paths (agents/planner.md's Input names spec_path/patterns_path under
# <feature_dir>/... or docs/loop-spec/features/<slug>/...): the first
# "features/<slug>/" segment named in the prompt. Empty when the brief carries
# no such path -- callers must treat that as "unknown", not "any feature".
slug = ""
m = re.search(r"features/([^/\s]+)/", caller_prompt)
if m:
    slug = m.group(1)

print(caller)
print(slug)
PY
) || CALLER_INFO=""

CALLER=$(printf '%s' "$CALLER_INFO" | sed -n '1p')
CALLER_SLUG=$(printf '%s' "$CALLER_INFO" | sed -n '2p')

# Path match helper: returns 0 if the RESOLVED file path (FILE_PATH_REAL, computed
# above) is under the given prefix
# segment. FILE_PATH_REAL is always absolute, so only the fragment match applies.
path_allowed() {
  local prefix="$1"
  if [[ "$FILE_PATH_REAL" == */${prefix}/* || "$FILE_PATH_REAL" == */${prefix} ]]; then
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
# for every caller (port audit 1, F5); the driver's `spec skeleton`
# and `spec write` are the path that cannot miss. No feature.json anywhere means
# nothing to compare, so the write stays allowed.
feature_checkout_deny() {
  local rel slug project target target_dir wt home homes=()
  rel="${FILE_PATH_REAL#*docs/loop-spec/features/}"
  [[ "$rel" != "$FILE_PATH_REAL" && "$rel" == */* ]] || return 0
  slug="${rel%%/*}"
  project="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd -P)" || return 0
  target="$FILE_PATH_REAL"
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

# publication_protected_deny: the ONE protected-path policy (lib/harness.sh
# protected-path) covers driver-owned authoritative markdown (SPEC/PLAN/
# VERIFICATION/PATTERNS on the oneshot route or the v1 requirements format),
# feature.json[.bak], tasks.json, observations/**, publication-generations/**,
# and migration-generations/** -- never publication-staging/**, dispatch/**, or
# review-attempts/**, which stay a maker's to write (SPEC "The driver owns
# execution observations" / "Migration preserves originals..."). Five format
# REDO rounds on a live bug fix came from a lead that filled the driver-written
# SPEC/VERIFICATION skeleton by hand (port audit 3, N1); this
# extends that same lesson to every driver-owned path task-009 adds instead of
# reimplementing the route/format check here.
publication_protected_deny() {
  local rel slug checkout fd target verdict reason
  case "$FILE_PATH_REAL" in
    */.loop-spec/features/*)
      rel="${FILE_PATH_REAL#*.loop-spec/features/}"
      [[ "$rel" == */* ]] || return 0
      slug="${rel%%/*}"
      checkout="${FILE_PATH_REAL%.loop-spec/features/*}"
      [[ -n "$checkout" ]] || checkout="${CLAUDE_PROJECT_DIR:-$PWD}/"
      fd="${checkout}.loop-spec/features/$slug"
      ;;
    */docs/loop-spec/features/*)
      rel="${FILE_PATH_REAL#*docs/loop-spec/features/}"
      [[ "$rel" == */* ]] || return 0
      slug="${rel%%/*}"
      checkout="${FILE_PATH_REAL%docs/loop-spec/features/*}"
      [[ -n "$checkout" ]] || checkout="${CLAUDE_PROJECT_DIR:-$PWD}/"
      fd="${checkout}.loop-spec/features/$slug"
      ;;
    *) return 0 ;;
  esac
  # No feature state yet means nothing this policy protects exists to compare
  # against (feature_checkout_deny above already made this call for the docs tree).
  [[ -f "$fd/feature.json" ]] || return 0
  target="$FILE_PATH_REAL"
  verdict="$(bash "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh" protected-path --path "$target" --feature-dir "$fd" 2>/dev/null)" \
    || verdict="protected=yes reason=the protected-path probe failed to answer"
  [[ "${verdict%% *}" == "protected=yes" ]] || return 0
  reason="${verdict#*reason=}"
  echo "DENY: $TOOL_NAME targets $FILE_PATH ($reason). Fill it through the driver: cycle-driver.sh spec fill --feature-dir $fd (--intent, --file/--note, --criterion, --grounding), spec escalate --reason, spec footprint drop --file --reason, or verification fill --feature-dir $fd (--row/--implementation/--proof/--evidence/--output, --review, --tests) for docs artifacts; lib/feature-write.sh set|reconcile-inventory for feature state; or lib/artifact-publication.sh capture|publish for a staged artifact/observation/migration record. (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
  exit 2
}
publication_protected_deny

case "$CALLER" in
  spec-writer|planner)
    if path_allowed "docs/loop-spec/features"; then
      exit 0
    fi
    # v1 (now the default) protects docs/loop-spec/features/**/{SPEC,PLAN,PATTERNS}.md
    # (publication_protected_deny above already catches those writes); the maker's
    # own copy is the staged draft under the feature's state dir, scoped to the
    # single feature this dispatch named in its brief -- never any other feature's
    # staging, and never when the brief named none (fail closed, not "any feature").
    if path_allowed ".loop-spec/features"; then
      rel="${FILE_PATH_REAL#*.loop-spec/features/}"
      if [[ "$rel" != "$FILE_PATH_REAL" && "$rel" == */publication-staging/* ]]; then
        slug="${rel%%/*}"
        if [[ -n "$CALLER_SLUG" && "$slug" == "$CALLER_SLUG" ]]; then
          exit 0
        fi
        echo "DENY: $CALLER may only $TOOL_NAME under .loop-spec/features/<slug>/publication-staging/** for the feature named in its own dispatch brief (attempted: $FILE_PATH, dispatched for: ${CALLER_SLUG:-unknown}). (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
        exit 2
      fi
    fi
    echo "DENY: $CALLER may only $TOOL_NAME under docs/loop-spec/features/** or .loop-spec/features/<slug>/publication-staging/** (attempted: $FILE_PATH). (Disable: LOOP_SPEC_PATH_GUARD=0)" >&2
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
