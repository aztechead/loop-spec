#!/usr/bin/env bash
# adhoc-ledger.sh - Micro-cycle audit ledger for ad-hoc work (.loop-spec/adhoc-ledger.md).
#
# The full cycle's core value that survives at ad-hoc scale is the committed audit
# trail: what was asked, what "done" meant, how it was grounded and verified. Feature-scale work
# gets a whole docs/loop-spec/features/{slug}/ tree; ad-hoc work gets ~5 appended
# lines here. One file, greppable, and a future retro pass can mine it the same way
# retro.sh mines events.jsonl (see docs/loop-spec/ROADMAP-3.0.md, pillar B).
#
# Usage: add | list | path  (run with -h for the full flag reference; usage()
# below is the single source of truth for it).
# File override: LOOP_SPEC_ADHOC_LEDGER (default ${CLAUDE_PROJECT_DIR:-.}/.loop-spec/adhoc-ledger.md).
#
# Design notes:
#   - Append-only: this script never rewrites existing entries; the user curates the file.
#   - No dedup: unlike rules.sh, two runs of the same task are two entries (it is a log).

set -euo pipefail

LEDGER_FILE="${LOOP_SPEC_ADHOC_LEDGER:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec/adhoc-ledger.md}"

HEADER='# adhoc-ledger.md

Micro-cycle audit ledger. One entry per ad-hoc task: what was asked, the done-criteria
stated before code, the repository grounding checked after code, the verification
command actually run, and its result. Appended by `lib/adhoc-ledger.sh add`; you own
and curate this file.
'

usage() {
  cat <<'EOF'
adhoc-ledger.sh - Micro-cycle audit ledger for ad-hoc work (.loop-spec/adhoc-ledger.md).

Usage:
  adhoc-ledger.sh add --title <t> --criteria <c> [--grounding <evidence>] --verify <cmd> --result <pass|fail|partial> [--pr <url>] [--notes <n>]
      Append one entry. --criteria may be passed multiple times (one bullet each).
      --grounding may be repeated for post-change repository evidence; pass requires
      exactly one grounding entry per criterion. Failed/partial outcomes may omit it.
      For pass, copy each --criteria value byte-for-byte at the start of its grounding:
        --criteria "<criterion>" \
        --grounding "<criterion> | repo: <file>:<positive line> | integration: <file>:<positive line>"
      With no separate integration site, use:
        --grounding "<criterion> | repo: <file>:<positive line> | integration: none - <reason of at least 10 characters>"
      --pr records the delivery PR URL (terminal feedback check contract).
      Prints "added" on stdout.

  adhoc-ledger.sh list [--limit <n>]
      Print entry heading lines (timestamp + title), newest last. Default limit 20.

  adhoc-ledger.sh path
      Print the resolved ledger path.

File override: LOOP_SPEC_ADHOC_LEDGER (default ${CLAUDE_PROJECT_DIR:-.}/.loop-spec/adhoc-ledger.md).
EOF
}

# require_value <flag> <argc-remaining>: a value flag with nothing after it gets
# the usage-contract exit 2, not a raw `set -u` unbound-variable death.
require_value() {
  [[ "$2" -ge 2 ]] || { echo "adhoc-ledger.sh: $1 requires a value" >&2; exit 2; }
}

grounding_contract_error() {
  echo "adhoc-ledger.sh add: $1" >&2
  echo "copy each --criteria value byte-for-byte as its --grounding prefix." >&2
  echo "Accepted: '<criterion> | repo: <file>:<positive line> | integration: <file>:<positive line>'" >&2
  echo "Or: '<criterion> | repo: <file>:<positive line> | integration: none - <reason of at least 10 characters>'" >&2
}

cmd_add() {
  local title="" verify="" result="" notes="" pr=""
  local -a criteria=() grounding=()
  local grounding_count=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)    require_value "$1" $#; title="$2"; shift 2;;
      --criteria) require_value "$1" $#; criteria+=("$2"); shift 2;;
      --grounding) require_value "$1" $#; grounding[$grounding_count]="$2"; grounding_count=$((grounding_count+1)); shift 2;;
      --verify)   require_value "$1" $#; verify="$2"; shift 2;;
      --result)   require_value "$1" $#; result="$2"; shift 2;;
      --notes)    require_value "$1" $#; notes="$2"; shift 2;;
      --pr)       require_value "$1" $#; pr="$2"; shift 2;;
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
  if [[ "$result" == "pass" && "$grounding_count" -ne "${#criteria[@]}" ]]; then
    grounding_contract_error "pass requires exactly one --grounding per --criteria"
    exit 2
  fi
  if [[ "$result" == "pass" ]]; then
    grounding_re='^.+ \| repo: .+:[1-9][0-9]* \| integration: (.+:[1-9][0-9]*|none - .{10,})$'
    for grounding_entry in "${grounding[@]}"; do
      if [[ ! "$grounding_entry" =~ $grounding_re ]]; then
        grounding_contract_error "rejected grounding: '$grounding_entry'"
        exit 2
      fi
    done
    for criterion_entry in "${criteria[@]}"; do
      criterion_seen=0
      grounding_seen=0
      for candidate in "${criteria[@]}"; do
        [[ "$candidate" == "$criterion_entry" ]] && criterion_seen=$((criterion_seen+1))
      done
      for grounding_entry in "${grounding[@]}"; do
        grounding_criterion="${grounding_entry%% | repo:*}"
        [[ "$grounding_criterion" == "$criterion_entry" ]] && grounding_seen=$((grounding_seen+1))
      done
      if [[ "$criterion_seen" -ne "$grounding_seen" ]]; then
        grounding_contract_error "each --criteria value requires exactly one matching --grounding prefix"
        exit 2
      fi
    done
    for grounding_entry in "${grounding[@]}"; do
      grounding_criterion="${grounding_entry%% | repo:*}"
      known=0
      for criterion_entry in "${criteria[@]}"; do
        [[ "$criterion_entry" == "$grounding_criterion" ]] && known=1
      done
      if [[ "$known" -ne 1 ]]; then
        grounding_contract_error "grounding criterion '$grounding_criterion' is not declared by --criteria"
        exit 2
      fi
    done
  fi

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
    if [[ "$grounding_count" -gt 0 ]]; then
      for c in "${grounding[@]}"; do
        printf -- '- grounding: %s\n' "$c"
      done
    fi
    printf -- '- verify: `%s` → %s\n' "$verify" "$result"
    [[ -n "$pr" ]] && printf -- '- pr: %s\n' "$pr"
    [[ -n "$notes" ]] && printf -- '- notes: %s\n' "$notes"
  } >> "$LEDGER_FILE"

  echo "added"
}

cmd_list() {
  local limit=20
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) require_value "$1" $#; limit="$2"; shift 2;;
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
