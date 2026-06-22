#!/usr/bin/env bash
# rules.sh - Self-learning loop rules manager (RULES.md).
#
# Implements the "self-learning loop" idea: every repeated mistake becomes a
# permanent, human-owned rule that is carried forward into future loop runs.
# Rules live in a curated markdown file the user owns; this script only does the
# mechanical add/list/render so the loop can append a lesson and the SessionStart
# hook can inject the current rules.
#
# Usage:
#   rules.sh add <rule text> [--check "<deterministic command>"]
#       Append a rule (idempotent on exact rule text). Optional --check records a
#       deterministic command that enforces the rule (preferred over prose notes).
#       Prints "added" or "exists" on stdout.
#
#   rules.sh list
#       Print each rule bullet, one per line (no markdown decoration).
#
#   rules.sh render
#       Print the full RULES.md body suitable for context injection. Empty output
#       (exit 0) when there are no rules yet.
#
#   rules.sh path
#       Print the resolved RULES.md path.
#
# File: $LOOP_SPEC_RULES_FILE else ${CLAUDE_PROJECT_DIR:-.}/.loop-spec/RULES.md
#
# Design notes (from the self-learning-loop guidance):
#   - The user owns the file; this script never rewrites existing rule text.
#   - Prefer deterministic checks (--check) over plain notes.
#   - Adds are idempotent so the same lesson is never duplicated.

set -euo pipefail

RULES_FILE="${LOOP_SPEC_RULES_FILE:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec/RULES.md}"

HEADER='# RULES.md

Self-learning loop rules. Every repeated mistake becomes a permanent check here so
the loop cannot repeat it. You own this file -- curate it. Prefer deterministic
checks (a command that fails) over prose notes.

## Rules
'

ensure_file() {
  if [[ ! -f "$RULES_FILE" ]]; then
    mkdir -p "$(dirname "$RULES_FILE")"
    printf '%s' "$HEADER" > "$RULES_FILE"
  fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
  add)
    rule=""
    check=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --check) check="${2:-}"; shift 2 ;;
        *) rule="${rule:+$rule }$1"; shift ;;
      esac
    done
    if [[ -z "$rule" ]]; then
      echo "rules.sh add: empty rule text" >&2
      exit 2
    fi
    ensure_file
    # Idempotent: skip if the exact rule text already present.
    if grep -Fq -- "$rule" "$RULES_FILE" 2>/dev/null; then
      echo "exists"
      exit 0
    fi
    line="- [ ] ${rule}"
    [[ -n "$check" ]] && line="${line}  (check: \`${check}\`)"
    printf '%s\n' "$line" >> "$RULES_FILE"
    echo "added"
    ;;
  list)
    [[ -f "$RULES_FILE" ]] || exit 0
    # Strip the "- [ ] " / "- [x] " bullet prefix; emit rule text only.
    grep -E '^- \[[ xX]\] ' "$RULES_FILE" 2>/dev/null | sed -E 's/^- \[[ xX]\] //' || true
    ;;
  render)
    [[ -f "$RULES_FILE" ]] || exit 0
    # Only render when at least one rule exists; otherwise stay silent.
    if grep -qE '^- \[[ xX]\] ' "$RULES_FILE" 2>/dev/null; then
      cat "$RULES_FILE"
    fi
    ;;
  path)
    echo "$RULES_FILE"
    ;;
  *)
    echo "rules.sh: unknown command '${cmd}' (add|list|render|path)" >&2
    exit 2
    ;;
esac
