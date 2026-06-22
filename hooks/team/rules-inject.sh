#!/usr/bin/env bash
# rules-inject.sh - Carry self-learning loop rules forward on SessionStart.
#
# Reads .loop-spec/RULES.md (via lib/rules.sh render) and injects it as context
# so every loop run is held to the lessons learned in prior runs. This is the
# "self-learning loop": a mistake becomes a permanent rule, and the rule is
# enforced on the next run instead of living only in chat.
#
# DEFAULT ON, but inert until rules exist: with no RULES.md (or no rules in it)
# the hook emits nothing. Only projects that already use loop-spec are touched.
#
# Suppressed when LOOP_SPEC_RULES=0 (kill switch).
#
# Environment:
#   LOOP_SPEC_RULES     Set to "0" to disable injection. Default: on.
#   CLAUDE_PROJECT_DIR  Project root. Defaults to CWD.

set -euo pipefail
trap 'exit 0' ERR

if [[ "${LOOP_SPEC_RULES:-1}" == "0" ]]; then
  printf '{}\n'
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Only act inside loop-spec projects (avoid littering / noise elsewhere).
if [[ ! -d "${PROJECT_DIR}/.loop-spec" ]]; then
  printf '{}\n'
  exit 0
fi

# Resolve lib/rules.sh relative to this hook (hooks/team/ -> repo root).
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_LIB="${HOOK_DIR}/../../lib/rules.sh"

BODY=""
if [[ -f "$RULES_LIB" ]]; then
  BODY=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RULES_LIB" render 2>/dev/null || true)
fi

# Nothing to inject (no rules yet).
if [[ -z "$BODY" ]]; then
  printf '{}\n'
  exit 0
fi

DIRECTIVE="SELF-LEARNING RULES ACTIVE: This project carries forward rules learned from prior loop runs. Treat every rule below as a hard constraint for this session; if a deterministic check is given, run it rather than reasoning about compliance. Do not repeat a mistake that already has a rule.

${BODY}

Add a new rule via lib/rules.sh add (or /loop-spec:rules add) whenever the loop repeats a mistake. Disable injection with LOOP_SPEC_RULES=0."

# Emit valid JSON. RULES.md is user-authored markdown (tabs, quotes, backslashes,
# control chars), so let jq do the escaping rather than a hand-rolled sed/tr that
# misses U+0000-U+001F. jq is a hard runtime dependency (jq >= 1.5).
jq -n --arg ctx "$DIRECTIVE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
