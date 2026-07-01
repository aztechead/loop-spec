#!/usr/bin/env bash
# backlog.sh - Deferred-work backlog manager (.loop-spec/BACKLOG.md).
#
# The project-scope analog of a Ralph loop's fix_plan.md: a persistent, prioritized
# list of deferred work that survives feature completion. Two producers feed it
# automatically (VERIFY's tier-deferred findings; ITERATE's budget-spent gaps) and
# the cycle's backlog-drain mode consumes it one feature per loop.
#
# Usage:
#   backlog.sh add <source-slug> <type> <text>
#       Append an unchecked entry. Idempotent on exact text (prints "exists").
#       type: verify-deferred | iterate-gap | manual
#   backlog.sh next
#       Print the first unchecked entry's text (without markup). Exit 1 when empty.
#   backlog.sh done <text>
#       Check off the first unchecked entry whose text matches exactly.
#   backlog.sh count
#       Print the number of unchecked entries.
#   backlog.sh path
#       Print the resolved BACKLOG.md path.
#
# File: $LOOP_SPEC_BACKLOG_FILE else ${CLAUDE_PROJECT_DIR:-.}/.loop-spec/BACKLOG.md
# Entry format: "- [ ] ({date} {source-slug} {type}) {text}"
set -euo pipefail

BACKLOG_FILE="${LOOP_SPEC_BACKLOG_FILE:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec/BACKLOG.md}"

HEADER='# BACKLOG.md

Deferred work harvested by loop-spec: findings a tier deferred, goal gaps an
iteration budget could not close, and manual entries. The cycle drains it with
`/loop-spec:cycle backlog` (one feature per loop). You own the ordering -- the
drain mode always takes the top unchecked entry.
'

ensure_file() {
  if [[ ! -f "$BACKLOG_FILE" ]]; then
    mkdir -p "$(dirname "$BACKLOG_FILE")"
    printf '%s\n' "$HEADER" > "$BACKLOG_FILE"
  fi
}

# Strip "- [ ] (meta) " prefix from an entry line -> bare text.
entry_text() {
  local line="$1"
  line="${line#- \[ \] }"
  # drop the leading "(...)" metadata group + following space, if present
  if [[ "$line" == \(* ]]; then
    line="${line#*) }"
  fi
  printf '%s' "$line"
}

case "${1:-}" in
  add)
    slug="${2:-}"; type="${3:-manual}"; text="${4:-}"
    if [[ -z "$slug" || -z "$text" ]]; then
      echo "usage: backlog.sh add <source-slug> <type> <text>" >&2; exit 2
    fi
    ensure_file
    # Idempotent on bare text across unchecked entries.
    while IFS= read -r line; do
      [[ "$line" == "- [ ] "* ]] || continue
      if [[ "$(entry_text "$line")" == "$text" ]]; then
        echo "exists"; exit 0
      fi
    done < "$BACKLOG_FILE"
    printf -- '- [ ] (%s %s %s) %s\n' "$(date -u +%Y-%m-%d)" "$slug" "$type" "$text" >> "$BACKLOG_FILE"
    echo "added"
    ;;
  next)
    [[ -f "$BACKLOG_FILE" ]] || exit 1
    while IFS= read -r line; do
      if [[ "$line" == "- [ ] "* ]]; then
        entry_text "$line"; echo; exit 0
      fi
    done < "$BACKLOG_FILE"
    exit 1
    ;;
  done)
    text="${2:-}"
    [[ -z "$text" ]] && { echo "usage: backlog.sh done <text>" >&2; exit 2; }
    [[ -f "$BACKLOG_FILE" ]] || { echo "backlog.sh: no backlog file" >&2; exit 1; }
    tmp="$(mktemp)"
    found=0
    while IFS= read -r line; do
      if [[ "$found" -eq 0 && "$line" == "- [ ] "* ]] && [[ "$(entry_text "$line")" == "$text" ]]; then
        printf -- '- [x]%s\n' "${line#- \[ \]}" >> "$tmp"
        found=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$BACKLOG_FILE"
    mv "$tmp" "$BACKLOG_FILE"
    [[ "$found" -eq 1 ]] && echo "done" || { echo "not found" >&2; exit 1; }
    ;;
  count)
    if [[ -f "$BACKLOG_FILE" ]]; then
      grep -c '^- \[ \] ' "$BACKLOG_FILE" 2>/dev/null || echo 0
    else
      echo 0
    fi
    ;;
  path)
    echo "$BACKLOG_FILE"
    ;;
  *)
    echo "usage: backlog.sh add|next|done|count|path" >&2
    exit 2
    ;;
esac
