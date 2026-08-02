#!/usr/bin/env bash
# PreToolUse hook: enforce LOOP_SPEC_WORKTREES=0 at the tool boundary.
#
# The cycle and EXECUTE selectors route this mode through an in-place feature branch
# with serial implementation. This hook is the fail-closed backstop for every worktree
# entry point reachable from a tool call. Claude Code names three:
#   "Applies to --worktree, EnterWorktree, and agent isolation."
# so covering only the first two would leave `Agent({isolation: "worktree"})` -- a
# documented parameter in skills/shared/harness-call-contracts.md -- as an open bypass.
# Also caught: a raw `git worktree add` and loop-spec's own feature-worktree helper.
#
# Two worktree paths are deliberately NOT handled here, because neither is a tool call:
#   - `claude --worktree` is the operator establishing the checkout at launch, not an
#     agent routing around the setting.
#   - agent frontmatter `isolation: worktree` is resolved from the agent definition and
#     never appears in tool_input, so no hook can see it. tests/validate-agents.sh
#     forbids the key in loop-spec's own agents instead.
#
# Claude Code contract:
#   exit 0 = allow
#   exit 2 = deny (stderr shown to the model)
set -euo pipefail

# Scope FIRST, value second. This hook is registered on "Agent|Bash|EnterWorktree",
# so it sees every Bash call in every project the operator ever opens -- including
# repositories that have nothing to do with loop-spec. Validating the setting before
# the project-scope check meant one stray export (LOOP_SPEC_WORKTREES=true, the most
# natural typo for a boolean) denied EVERY tool call EVERYWHERE, with no recovery: the
# session could not run `echo` to diagnose itself, and an unattended run has no operator
# to notice. Scope is cheap and has no failure mode; check it first.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJECT_DIR/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

# An unrecognized value is a misconfiguration, not an authorization. Resolve it to the
# RESTRICTIVE mode (0) rather than denying the whole tool surface: the setting's own
# safe direction is "no worktrees", so treating an unknown value as 0 still honors the
# conservative reading while bounding the blast radius to worktree-creating calls. The
# session keeps enough tool access to read the environment and correct it.
case "${LOOP_SPEC_WORKTREES:-1}" in
  1) exit 0 ;;
  0) ;;
  *)
    echo "loop-spec: LOOP_SPEC_WORKTREES must be 0 or 1 (got '${LOOP_SPEC_WORKTREES}'); treating it as 0 (no worktrees) for this call. Set it to 0 or 1 explicitly." >&2
    ;;
esac

# Malformed hook input must not strand the session.
trap 'exit 0' ERR
command -v python3 &>/dev/null || exit 0

INPUT=$(cat)
VERDICT=$(printf '%s' "$INPUT" | python3 -c '
import json
import re
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    print("allow")
    raise SystemExit(0)

tool = str(payload.get("tool_name") or "")
tool_input = payload.get("tool_input") or {}
if tool == "EnterWorktree":
    print("enter-worktree")
    raise SystemExit(0)

if tool == "Agent":
    if str(tool_input.get("isolation") or "").strip().lower() == "worktree":
        print("agent-worktree-isolation")
        raise SystemExit(0)
    print("allow")
    raise SystemExit(0)

if tool == "Bash":
    command = str(tool_input.get("command") or "")
    if re.search(r"\bgit\b[^\n;&|]*\bworktree\s+add\b", command, re.I):
        print("git-worktree-add")
        raise SystemExit(0)
    # Match an INVOCATION of the helper, not a mention of its name. A bare
    # substring match also denies `rg create-feature-worktree` and every other
    # read-only inspection, which is noise: lib/git-ops.sh refuses the subcommand
    # itself under this setting, so the tool boundary only has to catch the call.
    if re.search(
        r"git-ops\.sh[^\n;&|]*\bcreate-feature-worktree\b"
        r"|(?:^|[\n;&|(]|&&|\|\|)\s*create-feature-worktree\b",
        command,
    ):
        print("feature-worktree-helper")
        raise SystemExit(0)

print("allow")
' 2>/dev/null || echo "allow")

[[ "$VERDICT" != "allow" ]] || exit 0

echo "DENY: LOOP_SPEC_WORKTREES=0 requires in-place execution; '$VERDICT' would create or enter a worktree. Continue on the clean in-place feat/<slug> branch and use the serial EXECUTE rung." >&2
exit 2
