#!/usr/bin/env bash
# adhoc-ledger.sh - Micro-cycle audit ledger for ad-hoc work (.loop-spec/adhoc-ledger.md).
#
# The full cycle's core value that survives at ad-hoc scale is the committed audit
# trail: what was asked, what "done" meant, how it was verified. Feature-scale work
# gets a whole docs/loop-spec/features/{slug}/ tree; ad-hoc work gets ~5 appended
# lines here. One file, greppable, and a future retro pass can mine it the same way
# retro.sh mines events.jsonl (see docs/loop-spec/ROADMAP-3.0.md, pillar B).
#
# Usage:
#   adhoc-ledger.sh add --title <t> --criteria <c> --verify <cmd> --result <pass|fail|partial> [--notes <n>]
#       Append one entry. --criteria may be passed multiple times (one bullet each).
#       Prints "added" on stdout.
#
#   adhoc-ledger.sh list [--limit <n>]
#       Print entry heading lines (timestamp + title), newest last. Default limit 20.
#
#   adhoc-ledger.sh path
#       Print the resolved ledger path.
#
# File override: LOOP_SPEC_ADHOC_LEDGER (default ${CLAUDE_PROJECT_DIR:-.}/.loop-spec/adhoc-ledger.md).
#
# Design notes:
#   - Append-only: this script never rewrites existing entries; the user curates the file.
#   - No dedup: unlike rules.sh, two runs of the same task are two entries (it is a log).

set -euo pipefail

LEDGER_FILE="${LOOP_SPEC_ADHOC_LEDGER:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec/adhoc-ledger.md}"

HEADER='# adhoc-ledger.md

Micro-cycle audit ledger. One entry per ad-hoc task: what was asked, the done-criteria
stated before code, the verification command actually run, and its result. Appended by
`lib/adhoc-ledger.sh add`; you own and curate this file.
'

usage() {
  sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
}

cmd_add() {
  local title="" verify="" result="" notes=""
  local -a criteria=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)    title="$2"; shift 2;;
      --criteria) criteria+=("$2"); shift 2;;
      --verify)   verify="$2"; shift 2;;
      --result)   result="$2"; shift 2;;
      --notes)    notes="$2"; shift 2;;
      *) echo "adhoc-ledger.sh: unknown flag '$1'" >&2; exit 2;;
    esac
  done

  [[ -n "$title" ]]  || { echo "adhoc-ledger.sh add: --title is required" >&2; exit 2; }
  [[ -n "$verify" ]] || { echo "adhoc-ledger.sh add: --verify is required" >&2; exit 2; }
  [[ ${#criteria[@]} -gt 0 ]] || { echo "adhoc-ledger.sh add: at least one --criteria is required" >&2; exit 2; }
  case "$result" in
    pass|fail|partial) ;;
    *) echo "adhoc-ledger.sh add: --result must be pass, fail, or partial (got '${result}')" >&2; exit 2;;
  esac

  mkdir -p "$(dirname "$LEDGER_FILE")"
  [[ -f "$LEDGER_FILE" ]] || printf '%s\n' "$HEADER" > "$LEDGER_FILE"

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '\n## %s — %s\n' "$now" "$title"
    local c
    for c in "${criteria[@]}"; do
      printf -- '- criteria: %s\n' "$c"
    done
    printf -- '- verify: `%s` → %s\n' "$verify" "$result"
    [[ -n "$notes" ]] && printf -- '- notes: %s\n' "$notes"
  } >> "$LEDGER_FILE"

  echo "added"
}

cmd_list() {
  local limit=20
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2;;
      *) echo "adhoc-ledger.sh: unknown flag '$1'" >&2; exit 2;;
    esac
  done
  [[ -f "$LEDGER_FILE" ]] || exit 0
  grep '^## ' "$LEDGER_FILE" | tail -n "$limit" | sed 's/^## //'
}

case "${1:-}" in
  add)  shift; cmd_add "$@";;
  list) shift; cmd_list "$@";;
  path) echo "$LEDGER_FILE";;
  -h|--help|help) usage;;
  *) usage >&2; exit 2;;
esac
