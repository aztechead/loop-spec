#!/usr/bin/env bash
# backlog.sh - Deferred-work backlog manager (.loop-spec/BACKLOG.md).
#
# The project-scope analog of a Ralph loop's fix_plan.md: a persistent, prioritized
# list of deferred work that survives feature completion. Two producers feed it
# automatically (VERIFY's tier-deferred findings; ITERATE's limit-spent gaps) and
# the cycle's backlog-drain mode consumes it one feature per loop.
#
# Usage:
#   backlog.sh add <source-slug> <type> <text> [--id <gap-id>]
#       Append an unchecked entry. Idempotent on exact text or gap-id (prints "exists").
#       type: verify-deferred | iterate-gap | manual
#   backlog.sh next
#       Print the first unchecked entry's text (without markup). Exit 1 when empty.
#   backlog.sh next --json
#       Print the first unchecked entry as JSON {id, date, slug, type, text}
#       (id null when the entry carries none). Exit 1 when empty.
#   backlog.sh list --json
#       Print ALL unchecked entries as a JSON array (same per-entry shape as
#       next --json, in file order). Empty array when none. Exit 0 always.
#   backlog.sh done <text>
#       Check off the first unchecked entry whose text matches exactly.
#   backlog.sh gap-id <text>
#       Print the deterministic 8-hex gap id of <text> (normalized: lowercase,
#       punctuation stripped, whitespace collapsed, then sha256). The SAME input
#       always yields the SAME id -- ITERATE stamps it at add-time and compares it
#       at harvest-time so terminal detection is exact equality, never fuzzy text.
#   backlog.sh terminal <gap-id> <note>
#       Check off the first unchecked entry carrying id=<gap-id> and append
#       " -- TERMINAL: <note>". Exit 1 when no such entry.
#   backlog.sh is-terminal <gap-id>
#       Exit 0 if any entry carrying id=<gap-id> is marked TERMINAL, else exit 1.
#   backlog.sh count
#       Print the number of unchecked entries.
#   backlog.sh path
#       Print the resolved BACKLOG.md path.
#
# File: $LOOP_SPEC_BACKLOG_FILE else ${CLAUDE_PROJECT_DIR:-.}/.loop-spec/BACKLOG.md
# Entry format: "- [ ] ({date} {source-slug} {type}[ id={gap-id}]) {text}"
set -euo pipefail

BACKLOG_FILE="${LOOP_SPEC_BACKLOG_FILE:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec/BACKLOG.md}"

HEADER='# BACKLOG.md

Deferred work harvested by loop-spec: findings a tier deferred, goal gaps an
iteration limit could not close, and manual entries. The cycle drains it with
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

# Extract "id=xxxx" from an entry line's metadata group -> id or empty.
entry_id() {
  local line="$1" meta
  [[ "$line" == "- ["*"] ("* ]] || { printf ''; return; }
  meta="${line#*\(}"
  meta="${meta%%\)*}"
  if [[ "$meta" =~ id=([A-Za-z0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

gap_id_of() {
  python3 -c '
import hashlib, re, sys
t = re.sub(r"[^a-z0-9]+", " ", sys.argv[1].lower()).strip()
print(hashlib.sha256(t.encode()).hexdigest()[:8])
' "$1"
}

case "${1:-}" in
  add)
    slug="${2:-}"; type="${3:-manual}"; text="${4:-}"
    gid=""
    if [[ "${5:-}" == "--id" ]]; then
      gid="${6:-}"
      [[ -z "$gid" ]] && { echo "usage: backlog.sh add <source-slug> <type> <text> [--id <gap-id>]" >&2; exit 2; }
    fi
    if [[ -z "$slug" || -z "$text" ]]; then
      echo "usage: backlog.sh add <source-slug> <type> <text> [--id <gap-id>]" >&2; exit 2
    fi
    ensure_file
    # A TERMINAL gap id is never re-queued: two spent limits mean the approach is
    # wrong, not under-iterated (autonomous ladder rung 5). Refuse loudly.
    if [[ -n "$gid" ]]; then
      while IFS= read -r line; do
        [[ "$line" == "- ["*"] ("* ]] || continue
        if [[ "$(entry_id "$line")" == "$gid" && "$line" == *" -- TERMINAL: "* ]]; then
          echo "terminal: gap id $gid is closed TERMINAL; not re-queued" >&2
          echo "terminal"
          exit 0
        fi
      done < "$BACKLOG_FILE"
    fi
    # Idempotent on bare text OR gap-id across unchecked entries.
    while IFS= read -r line; do
      [[ "$line" == "- [ ] "* ]] || continue
      if [[ "$(entry_text "$line")" == "$text" ]]; then
        echo "exists"; exit 0
      fi
      if [[ -n "$gid" && "$(entry_id "$line")" == "$gid" ]]; then
        echo "exists"; exit 0
      fi
    done < "$BACKLOG_FILE"
    meta="$(date -u +%Y-%m-%d) $slug $type"
    [[ -n "$gid" ]] && meta="$meta id=$gid"
    printf -- '- [ ] (%s) %s\n' "$meta" "$text" >> "$BACKLOG_FILE"
    echo "added"
    ;;
  next)
    [[ -f "$BACKLOG_FILE" ]] || exit 1
    as_json=0
    [[ "${2:-}" == "--json" ]] && as_json=1
    while IFS= read -r line; do
      if [[ "$line" == "- [ ] "* ]]; then
        if [[ "$as_json" -eq 1 ]]; then
          meta="${line#*\(}"; meta="${meta%%\)*}"
          read -r e_date e_slug e_type _rest <<< "$meta"
          gid="$(entry_id "$line")"
          jq -cn \
            --arg id "$gid" --arg date "${e_date:-}" --arg slug "${e_slug:-}" \
            --arg type "${e_type:-}" --arg text "$(entry_text "$line")" \
            '{id: (if $id == "" then null else $id end), date: $date, slug: $slug, type: $type, text: $text}'
        else
          entry_text "$line"; echo
        fi
        exit 0
      fi
    done < "$BACKLOG_FILE"
    exit 1
    ;;
  list)
    # Only the machine-readable form exists: the human-readable list IS the file.
    [[ "${2:-}" == "--json" ]] || { echo "usage: backlog.sh list --json" >&2; exit 2; }
    [[ -f "$BACKLOG_FILE" ]] || { echo "[]"; exit 0; }
    {
      while IFS= read -r line; do
        [[ "$line" == "- [ ] "* ]] || continue
        meta="${line#*\(}"; meta="${meta%%\)*}"
        read -r e_date e_slug e_type _rest <<< "$meta"
        gid="$(entry_id "$line")"
        jq -cn \
          --arg id "$gid" --arg date "${e_date:-}" --arg slug "${e_slug:-}" \
          --arg type "${e_type:-}" --arg text "$(entry_text "$line")" \
          '{id: (if $id == "" then null else $id end), date: $date, slug: $slug, type: $type, text: $text}'
      done < "$BACKLOG_FILE"
    } | jq -cs .
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
  gap-id)
    text="${2:-}"
    [[ -z "$text" ]] && { echo "usage: backlog.sh gap-id <text>" >&2; exit 2; }
    gap_id_of "$text"
    ;;
  terminal)
    gid="${2:-}"; note="${3:-}"
    if [[ -z "$gid" || -z "$note" ]]; then
      echo "usage: backlog.sh terminal <gap-id> <note>" >&2; exit 2
    fi
    [[ -f "$BACKLOG_FILE" ]] || { echo "backlog.sh: no backlog file" >&2; exit 1; }
    tmp="$(mktemp)"
    found=0
    while IFS= read -r line; do
      if [[ "$found" -eq 0 && "$line" == "- [ ] "* ]] && [[ "$(entry_id "$line")" == "$gid" ]]; then
        printf -- '- [x]%s -- TERMINAL: %s\n' "${line#- \[ \]}" "$note" >> "$tmp"
        found=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$BACKLOG_FILE"
    mv "$tmp" "$BACKLOG_FILE"
    [[ "$found" -eq 1 ]] && echo "terminal" || { echo "not found" >&2; exit 1; }
    ;;
  is-terminal)
    gid="${2:-}"
    [[ -z "$gid" ]] && { echo "usage: backlog.sh is-terminal <gap-id>" >&2; exit 2; }
    [[ -f "$BACKLOG_FILE" ]] || exit 1
    while IFS= read -r line; do
      [[ "$line" == "- ["*"] ("* ]] || continue
      if [[ "$(entry_id "$line")" == "$gid" && "$line" == *" -- TERMINAL: "* ]]; then
        exit 0
      fi
    done < "$BACKLOG_FILE"
    exit 1
    ;;
  count)
    if [[ -f "$BACKLOG_FILE" ]]; then
      # NOT `grep -c ... || echo 0`: grep prints "0" AND exits 1 on zero matches,
      # so that form emits "0\n0" and breaks numeric callers.
      grep -c '^- \[ \] ' "$BACKLOG_FILE" 2>/dev/null || true
    else
      echo 0
    fi
    ;;
  path)
    echo "$BACKLOG_FILE"
    ;;
  *)
    echo "usage: backlog.sh add|next|list|done|gap-id|terminal|is-terminal|count|path" >&2
    exit 2
    ;;
esac
