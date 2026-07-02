#!/usr/bin/env bash
# evidence.sh - Append-only evidence ledger for the grounding protocol.
#
# Why: design-phase skills must back external-system facts with read-only probe
# output captured at assertion time. Model context is lost to compaction; a file
# committed alongside the artifact is the durable audit trail. This script writes
# and queries that ledger -- the same pattern decisions.sh uses for autonomous-mode
# decisions -- so every evidence id (EVID-NNN) has a permanent, machine-checkable
# home that grounding-lint.sh can verify at gate time.
#
# Usage:
#   evidence.sh add <ledger_path> <claim> <command> <output>
#   evidence.sh list <ledger_path>
#   evidence.sh next-id <ledger_path>
#
# Exit codes: 0 success, 1 bad invocation or unwritable path.
set -uo pipefail

HEADING="# Evidence ledger"

# Sanitize: replace literal | with /, replace newlines/tabs with single space.
_sanitize() {
  local s="$1"
  s="${s//|//}"
  s="$(printf '%s' "$s" | tr '\n\t' '  ')"
  printf '%s' "$s"
}

# Truncate to 300 chars; append … when truncated.
_truncate() {
  local s="$1"
  if [[ ${#s} -gt 300 ]]; then
    printf '%s…' "${s:0:300}"
  else
    printf '%s' "$s"
  fi
}

# Count existing EVID entries in ledger (0 if missing or empty).
# grep -c exits 1 (no matches) but still prints "0"; capture into local var
# so the || branch doesn't emit a second "0".
_count_evid() {
  local ledger="$1"
  [[ -f "$ledger" ]] || { printf '0'; return 0; }
  local n
  n="$(grep -c '^- EVID-' "$ledger" 2>/dev/null)" || n="0"
  printf '%s' "$n"
}

# Return the ID that the next add would assign.
_next_id_for() {
  local ledger="$1"
  local count
  count="$(_count_evid "$ledger")"
  printf 'EVID-%03d' "$((count + 1))"
}

case "${1:-}" in
  add)
    ledger="${2:-}"; claim="${3:-}"; cmd_arg="${4:-}"; output="${5:-}"
    if [[ -z "$ledger" || -z "$claim" || -z "$cmd_arg" ]]; then
      echo "usage: evidence.sh add <ledger_path> <claim> <command> <output>" >&2
      exit 1
    fi

    sc="$(_sanitize "$claim")"
    scmd="$(_sanitize "$cmd_arg")"
    sout="$(_sanitize "${output:-}")"
    sout="$(_truncate "$sout")"

    # Idempotency: scan existing entries for matching sanitized claim + command.
    if [[ -f "$ledger" ]]; then
      while IFS= read -r line; do
        case "$line" in
          "- EVID-"*)
            # Format: - EVID-NNN | <ts> | claim: <claim> | cmd: <command> | out: <output>
            # Claim and command are sanitized (no |), so field splitting on " | " is safe.
            tmp="${line#*| claim: }"; existing_claim="${tmp%% | cmd: *}"
            tmp="${line#*| cmd: }";   existing_cmd="${tmp%% | out: *}"
            tmp="${line#- }";         existing_id="${tmp%% | *}"
            if [[ "$existing_claim" == "$sc" && "$existing_cmd" == "$scmd" ]]; then
              printf '%s\n' "$existing_id"
              exit 0
            fi
            ;;
        esac
      done < "$ledger"
    fi

    # Create ledger directory and file with heading if not present.
    ledger_dir="$(dirname "$ledger")"
    if [[ ! -d "$ledger_dir" ]]; then
      mkdir -p "$ledger_dir" 2>/dev/null \
        || { echo "evidence.sh: cannot create directory: $ledger_dir" >&2; exit 1; }
    fi
    if [[ ! -f "$ledger" ]]; then
      printf '%s\n' "$HEADING" > "$ledger" 2>/dev/null \
        || { echo "evidence.sh: cannot write to: $ledger" >&2; exit 1; }
    fi

    new_id="$(_next_id_for "$ledger")"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Use %s\n to avoid printf interpreting a leading dash in the line as an option.
    printf '%s\n' "- $new_id | $ts | claim: $sc | cmd: $scmd | out: $sout" >> "$ledger" \
      || { echo "evidence.sh: cannot append to: $ledger" >&2; exit 1; }
    printf '%s\n' "$new_id"
    ;;

  list)
    ledger="${2:-}"
    [[ -n "$ledger" ]] || { echo "usage: evidence.sh list <ledger_path>" >&2; exit 1; }
    [[ -f "$ledger" ]] || exit 0
    grep '^- EVID-' "$ledger" 2>/dev/null || true
    exit 0
    ;;

  next-id)
    ledger="${2:-}"
    [[ -n "$ledger" ]] || { echo "usage: evidence.sh next-id <ledger_path>" >&2; exit 1; }
    _next_id_for "$ledger"
    printf '\n'
    ;;

  *)
    echo "usage: evidence.sh add|list|next-id" >&2
    exit 1
    ;;
esac
