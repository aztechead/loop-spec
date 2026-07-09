#!/usr/bin/env bash
# rules.sh - Self-learning loop rules manager (RULES.md).
#
# Implements the "self-learning loop" idea: every repeated mistake becomes a
# permanent, human-owned rule that is carried forward into future loop runs.
# Rules live in a curated markdown file the user owns; this script only does the
# mechanical add/list/render so the loop can append a lesson and the SessionStart
# hook can inject the current rules.
#
# TWO LAYERS:
#   project  ($LOOP_SPEC_RULES_FILE else ${CLAUDE_PROJECT_DIR:-.}/.loop-spec/RULES.md)
#   global   ($LOOP_SPEC_GLOBAL_RULES_FILE else $HOME/.loop-spec/RULES.md)
# Global rules are lessons that travel across projects ("never --no-verify",
# "always read the failing test before editing"). `render` and `list` emit the
# MERGED view (global first, then project; exact-duplicate rule text is emitted
# once, from the project file). `add`/`path` target the project file unless
# --global is passed.
#
# Usage:
#   rules.sh add <rule text> [--check "<deterministic command>"] [--global]
#       Append a rule (idempotent on exact rule text within the target file).
#       Optional --check records a deterministic command that enforces the rule
#       (preferred over prose notes). Prints "added" or "exists" on stdout.
#
#   rules.sh list [--global]
#       Print each rule bullet, one per line (no markdown decoration).
#       Default: merged global + project (deduped). --global: global only.
#
#   rules.sh render
#       Print the rules body suitable for context injection: the project file,
#       followed by a "## Global rules" section for global rules not already in
#       the project file. Empty output (exit 0) when there are no rules at all.
#
#   rules.sh path [--global]
#       Print the resolved RULES.md path (project default, --global for global).
#
# Design notes (from the self-learning-loop guidance):
#   - The user owns the files; this script never rewrites existing rule text.
#   - Prefer deterministic checks (--check) over plain notes.
#   - Adds are idempotent so the same lesson is never duplicated.

set -euo pipefail

PROJECT_RULES_FILE="${LOOP_SPEC_RULES_FILE:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec/RULES.md}"
GLOBAL_RULES_FILE="${LOOP_SPEC_GLOBAL_RULES_FILE:-$HOME/.loop-spec/RULES.md}"

HEADER='# RULES.md

Self-learning loop rules. Every repeated mistake becomes a permanent check here so
the loop cannot repeat it. You own this file -- curate it. Prefer deterministic
checks (a command that fails) over prose notes.

## Rules
'

GLOBAL_HEADER='# RULES.md (global)

Self-learning rules that travel across ALL your loop-spec projects. Injected
after each project'"'"'s own RULES.md. You own this file -- curate it. Prefer
deterministic checks (a command that fails) over prose notes.

## Rules
'

ensure_file() { # ensure_file <path> <header>
  if [[ ! -f "$1" ]]; then
    mkdir -p "$(dirname "$1")"
    printf '%s' "$2" > "$1"
  fi
}

# Emit rule bullets of a file, one per line, full bullet form.
_bullets() { # _bullets <file>
  [[ -f "$1" ]] || return 0
  grep -E '^- \[[ xX]\] ' "$1" 2>/dev/null || true
}

# Strip bullet prefix and optional check suffix -> bare rule text.
_bare() { sed -E 's/^- \[[ xX]\] //; s/  \(check: `.*`\)$//'; }

cmd="${1:-}"
shift || true

# --global may appear anywhere in the remaining args; extract it.
GLOBAL=0
args=()
for a in "$@"; do
  if [[ "$a" == "--global" ]]; then GLOBAL=1; else args+=("$a"); fi
done
set -- ${args[@]+"${args[@]}"}

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
    if [[ "$GLOBAL" == "1" ]]; then
      target="$GLOBAL_RULES_FILE"; header="$GLOBAL_HEADER"
    else
      target="$PROJECT_RULES_FILE"; header="$HEADER"
    fi
    ensure_file "$target" "$header"
    # Idempotent on the WHOLE rule text, not a substring: strip each existing
    # bullet's "- [ ] " prefix and optional "  (check: `...`)" suffix, then do a
    # fixed-string whole-line match. A substring match (the old behavior) would
    # silently swallow a new rule that is a substring of an existing one.
    if _bullets "$target" | _bare | grep -Fxq -- "$rule"; then
      echo "exists"
      exit 0
    fi
    line="- [ ] ${rule}"
    [[ -n "$check" ]] && line="${line}  (check: \`${check}\`)"
    printf '%s\n' "$line" >> "$target"
    echo "added"
    ;;
  list)
    if [[ "$GLOBAL" == "1" ]]; then
      _bullets "$GLOBAL_RULES_FILE" | _bare
      exit 0
    fi
    # Merged: project rules first, then global rules whose text is not already
    # present in the project file (project wins on exact duplicates).
    proj_bare="$(_bullets "$PROJECT_RULES_FILE" | _bare)"
    printf '%s\n' "$proj_bare" | grep -v '^$' || true
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      grep -Fxq -- "$g" <<<"$proj_bare" || printf '%s\n' "$g"
    done < <(_bullets "$GLOBAL_RULES_FILE" | _bare)
    ;;
  render)
    proj_has=0
    glob_has=0
    _bullets "$PROJECT_RULES_FILE" | grep -q . && proj_has=1
    _bullets "$GLOBAL_RULES_FILE" | grep -q . && glob_has=1
    [[ "$proj_has" == "0" && "$glob_has" == "0" ]] && exit 0

    if [[ "$proj_has" == "1" ]]; then
      cat "$PROJECT_RULES_FILE"
    fi
    if [[ "$glob_has" == "1" ]]; then
      proj_bare="$(_bullets "$PROJECT_RULES_FILE" | _bare)"
      # Only the global bullets not already present in the project file.
      extra=""
      while IFS= read -r line; do
        bare="$(printf '%s\n' "$line" | _bare)"
        grep -Fxq -- "$bare" <<<"$proj_bare" || extra="${extra}${line}"$'\n'
      done < <(_bullets "$GLOBAL_RULES_FILE")
      if [[ -n "$extra" ]]; then
        [[ "$proj_has" == "1" ]] && printf '\n'
        printf '## Global rules (%s)\n\n' "$GLOBAL_RULES_FILE"
        printf '%s' "$extra"
      fi
    fi
    ;;
  path)
    if [[ "$GLOBAL" == "1" ]]; then
      echo "$GLOBAL_RULES_FILE"
    else
      echo "$PROJECT_RULES_FILE"
    fi
    ;;
  *)
    echo "rules.sh: unknown command '${cmd}' (add|list|render|path; --global targets the cross-project layer)" >&2
    exit 2
    ;;
esac
