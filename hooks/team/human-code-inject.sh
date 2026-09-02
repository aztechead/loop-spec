#!/usr/bin/env bash
# human-code-inject.sh - Inject the code-for-humans and docs-for-humans directives
# on SessionStart.
# Reads .loop-spec/human-code.conf from CLAUDE_PROJECT_DIR (or CWD).
#
# DEFAULT IS ON (like grill-inject and simplicity-inject, unlike opt-in
# discipline): the directive is injected unless explicitly disabled. The
# dispatch rungs carry their own copy for agents a SessionStart hook cannot
# reach; this covers the main thread, where most ad-hoc edits are made.
#
# Suppressed only when:
#   - .loop-spec/human-code.conf contains ENABLED=0, OR
#   - LOOP_SPEC_HUMAN_CODE=0 is set (session-level kill switch), OR
#   - the project is not a loop-spec project (no .loop-spec/ dir).
#
# Environment variables:
#   LOOP_SPEC_HUMAN_CODE  Set to "0" to disable (kill switch). Default: on.
#   CLAUDE_PROJECT_DIR    Project root to find conf file. Defaults to CWD.

set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Kill switch.
if [[ "${LOOP_SPEC_HUMAN_CODE:-1}" == "0" ]]; then
  printf '{}\n'
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Self-scope: only act inside loop-spec projects, matching every other loop-spec
# SessionStart hook. A default-ON directive must not inject into unrelated
# projects just because the plugin is installed.
if [[ ! -d "${PROJECT_DIR}/.loop-spec" ]]; then
  printf '{}\n'
  exit 0
fi

CONF_FILE="${PROJECT_DIR}/.loop-spec/human-code.conf"

# The directive names contracts to READ and scripts to RUN. The session cwd is the
# user's project, not the plugin, so both resolve from this hook's location.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" 2>/dev/null && pwd || true)"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd || true)"

# Opt-out: if the conf file exists AND pins ENABLED=0, stay silent.
# Absent conf file => default ON (inject).
if [[ -f "$CONF_FILE" ]] && grep -q "ENABLED=0" "$CONF_FILE" 2>/dev/null; then
  printf '{}\n'
  exit 0
fi

DIRECTIVE="CODE FOR HUMANS MODE ACTIVE (default): house style over habit. Read ${PLUGIN_ROOT}/skills/shared/human-code.md before writing code — do not paste it. Read the neighbors. Comments carry WHY, never what. Density matches the file, not an absolute. Never cut simplicity: markers or file-header purpose blocks.
Before DONE: bash ${LIB_DIR}/house-style.sh probe <files>; bash ${LIB_DIR}/house-style.sh compare <files you touched>; bash ${LIB_DIR}/comment-tells.sh scan <files>; bash ${LIB_DIR}/failure-tells.sh scan <files>.
CODE A HUMAN CAN OPERATE: fail loudly, or say why you did not.

DOCS FOR HUMANS: the markdown is a deliverable too. Read ${PLUGIN_ROOT}/skills/shared/human-docs.md. Hold one job per document. A change that makes a document false is fixed in the SAME diff. NEVER cut frontmatter.
Before DONE: bash ${LIB_DIR}/doc-tells.sh scan <markdown you touched>.

Disable with /loop-spec:settings human-code off or LOOP_SPEC_HUMAN_CODE=0."

# Emit valid JSON via jq (hard dependency) rather than a hand-rolled escaper.
jq -n --arg ctx "$DIRECTIVE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
