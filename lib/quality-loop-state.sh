#!/usr/bin/env bash
# Round/finding/convergence state tracker for the quality-loop skill.
#
# Usage:
#   quality-loop-state.sh scope <file>...
#       Set current scope. Resets round data for files whose entry is missing.
#       Prints the count of files in scope on stdout.
#
#   quality-loop-state.sh record-round <file> <round> <findings-json>
#       Record findings for a file at the given round number.
#       findings-json: [{"source":"code-reviewer|security-reviewer|deterministic",
#                        "category":"...","severity":"CRITICAL|HIGH|MEDIUM|LOW",
#                        "claim":"...","line":N}]
#
#   quality-loop-state.sh status [<file>]
#       Print JSON: per-file {rounds, lastFindingCount, blockingCount, clean}
#       If <file> given, print status for that file only.
#
#   quality-loop-state.sh mark-clean <file> <round>
#       Mark the file clean at the given round.
#       Refuses with exit 2 if the last recorded round has blocking findings:
#         - any deterministic finding
#         - any code-reviewer finding
#         - any security-reviewer finding with severity CRITICAL or HIGH
#
#   quality-loop-state.sh systemic <file>
#       Print category names that appear in BOTH of the last 2 consecutive
#       recorded rounds for <file>. No output = no systemic issues. Exit 0.
#
# State file: $LOOP_SPEC_QL_STATE else .loop-spec/quality-loop.json
# Atomic writes: tmp + rename (mirror of lib/feature-write.sh pattern).
#
# Exit codes:
#   0  success
#   1  bad invocation / state error
#   2  mark-clean refused (blocking findings present)
set -euo pipefail

# ---------------------------------------------------------------------------
# State file resolution
# ---------------------------------------------------------------------------
_state_file() {
  if [[ -n "${LOOP_SPEC_QL_STATE:-}" ]]; then
    printf '%s' "$LOOP_SPEC_QL_STATE"
  else
    printf '%s' ".loop-spec/quality-loop.json"
  fi
}

# ---------------------------------------------------------------------------
# Atomic write: write JSON string to state file via tmp + rename
# ---------------------------------------------------------------------------
_atomic_write() {
  local json="$1"
  local state; state="$(_state_file)"
  local dir; dir="$(dirname "$state")"
  mkdir -p "$dir"
  local tmp="${state}.tmp"
  printf '%s\n' "$json" > "$tmp"
  sync 2>/dev/null || true
  mv "$tmp" "$state"
}

# ---------------------------------------------------------------------------
# Load state: if state file missing or empty, return empty object {}
# ---------------------------------------------------------------------------
_load() {
  local state; state="$(_state_file)"
  if [[ -f "$state" ]]; then
    jq -e . "$state" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

# ---------------------------------------------------------------------------
# Blocking predicate: does a findings array contain any blocking finding?
# A finding is blocking when:
#   source == "deterministic"  (any severity)
#   source == "code-reviewer"  (any severity)
#   source == "security-reviewer" AND severity in (CRITICAL, HIGH)
# ---------------------------------------------------------------------------
_is_blocking_jq='
  [.[] |
    select(
      (.source == "deterministic") or
      (.source == "code-reviewer") or
      (.source == "security-reviewer" and (.severity == "CRITICAL" or .severity == "HIGH"))
    )
  ] | length > 0
'

# ---------------------------------------------------------------------------
# Subcommand: scope
# ---------------------------------------------------------------------------
cmd_scope() {
  if [[ $# -lt 1 ]]; then
    echo "usage: quality-loop-state.sh scope <file>..." >&2
    exit 1
  fi

  local state; state="$(_load)"
  local count=$#

  # Build a jq update: for each file, if the entry is missing, initialise it.
  # We pass the file list as a JSON array and iterate.
  local files_json
  files_json="$(printf '%s\n' "$@" | jq -R . | jq -cs .)"

  local new_state
  new_state="$(
    printf '%s' "$state" | jq \
      --argjson files "$files_json" \
      --argjson now "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" '
      reduce $files[] as $f (
        .;
        if .[$f] == null then
          .[$f] = {"rounds": {}, "clean": false, "scopedAt": $now}
        else
          .
        end
      )
    '
  )"

  _atomic_write "$new_state"
  printf '%d\n' "$count"
}

# ---------------------------------------------------------------------------
# Subcommand: record-round
# ---------------------------------------------------------------------------
cmd_record_round() {
  if [[ $# -ne 3 ]]; then
    echo "usage: quality-loop-state.sh record-round <file> <round> <findings-json>" >&2
    exit 1
  fi

  local file="$1"
  local round="$2"
  local findings_json="$3"

  # Validate findings JSON is a valid array.
  if ! printf '%s' "$findings_json" | jq -e 'if type == "array" then . else error end' >/dev/null 2>&1; then
    echo "quality-loop-state: findings-json must be a JSON array" >&2
    exit 1
  fi

  local state; state="$(_load)"

  local new_state
  new_state="$(
    printf '%s' "$state" | jq \
      --arg file "$file" \
      --arg round "$round" \
      --argjson findings "$findings_json" \
      --argjson now "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" '
      # Ensure file entry exists.
      if .[$file] == null then
        .[$file] = {"rounds": {}, "clean": false, "scopedAt": $now}
      else . end
      | .[$file].rounds[$round] = {
          "findings": $findings,
          "recordedAt": $now,
          "findingCount": ($findings | length),
          "blockingCount": (
            [$findings[] |
              select(
                (.source == "deterministic") or
                (.source == "code-reviewer") or
                (.source == "security-reviewer" and
                 (.severity == "CRITICAL" or .severity == "HIGH"))
              )
            ] | length
          )
        }
      # Reset clean flag when a new round is recorded.
      | .[$file].clean = false
    '
  )"

  _atomic_write "$new_state"
}

# ---------------------------------------------------------------------------
# Subcommand: status
# ---------------------------------------------------------------------------
cmd_status() {
  local state; state="$(_load)"

  if [[ $# -eq 0 ]]; then
    # Summary for all files.
    printf '%s' "$state" | jq '
      with_entries(
        .value |= {
          rounds: (.rounds | keys | length),
          lastFindingCount: (
            if (.rounds | length) == 0 then 0
            else
              .rounds[(.rounds | keys | max_by(tonumber))] .findingCount
            end
          ),
          blockingCount: (
            if (.rounds | length) == 0 then 0
            else
              .rounds[(.rounds | keys | max_by(tonumber))] .blockingCount
            end
          ),
          clean: .clean
        }
      )
    '
  else
    local file="$1"
    printf '%s' "$state" | jq \
      --arg file "$file" '
      if .[$file] == null then {} else
        .[$file] | {
          rounds: (.rounds | keys | length),
          lastFindingCount: (
            if (.rounds | length) == 0 then 0
            else
              .rounds[(.rounds | keys | max_by(tonumber))] .findingCount
            end
          ),
          blockingCount: (
            if (.rounds | length) == 0 then 0
            else
              .rounds[(.rounds | keys | max_by(tonumber))] .blockingCount
            end
          ),
          clean: .clean
        }
      end
    '
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: mark-clean
# ---------------------------------------------------------------------------
cmd_mark_clean() {
  if [[ $# -ne 2 ]]; then
    echo "usage: quality-loop-state.sh mark-clean <file> <round>" >&2
    exit 1
  fi

  local file="$1"
  local round="$2"
  local state; state="$(_load)"

  # Find the last recorded round number for this file.
  local last_round_key
  last_round_key="$(
    printf '%s' "$state" | jq -r \
      --arg file "$file" '
      if .[$file] == null or (.[$file].rounds | length) == 0 then ""
      else .[$file].rounds | keys | max_by(tonumber)
      end
    '
  )"

  if [[ -z "$last_round_key" ]]; then
    # No rounds recorded; allow mark-clean.
    :
  else
    # Check if the last round has blocking findings.
    local has_blocking
    has_blocking="$(
      printf '%s' "$state" | jq -r \
        --arg file "$file" \
        --arg rk "$last_round_key" '
        (.[$file].rounds[$rk].findings // []) |
        [.[] |
          select(
            (.source == "deterministic") or
            (.source == "code-reviewer") or
            (.source == "security-reviewer" and
             (.severity == "CRITICAL" or .severity == "HIGH"))
          )
        ] | length > 0
      '
    )"

    if [[ "$has_blocking" == "true" ]]; then
      echo "quality-loop-state: mark-clean refused: file '$file' has blocking findings in round $last_round_key" >&2
      exit 2
    fi
  fi

  # Mark file clean.
  local new_state
  new_state="$(
    printf '%s' "$state" | jq \
      --arg file "$file" \
      --arg round "$round" \
      --argjson now "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" '
      if .[$file] == null then
        .[$file] = {"rounds": {}, "clean": true, "scopedAt": $now, "cleanRound": $round}
      else
        .[$file].clean = true | .[$file].cleanRound = $round
      end
    '
  )"

  _atomic_write "$new_state"
}

# ---------------------------------------------------------------------------
# Subcommand: systemic
# ---------------------------------------------------------------------------
cmd_systemic() {
  if [[ $# -ne 1 ]]; then
    echo "usage: quality-loop-state.sh systemic <file>" >&2
    exit 1
  fi

  local file="$1"
  local state; state="$(_load)"

  # Get the last two round keys (numerically sorted), then find categories
  # that appear in BOTH.
  printf '%s' "$state" | jq -r \
    --arg file "$file" '
    if .[$file] == null or (.[$file].rounds | length) < 2 then
      # Cannot have 2 consecutive rounds; no systemic categories.
      empty
    else
      # Sort round keys numerically, take the last two.
      (.[$file].rounds | keys | sort_by(tonumber)) as $sorted_keys |
      ($sorted_keys | length) as $n |
      $sorted_keys[$n-2] as $r1_key |
      $sorted_keys[$n-1] as $r2_key |
      # Collect categories from each round.
      ([ .[$file].rounds[$r1_key].findings[]?.category ] | unique) as $cats1 |
      ([ .[$file].rounds[$r2_key].findings[]?.category ] | unique) as $cats2 |
      # Intersection: categories in both rounds.
      ($cats1 | map(select(. as $c | $cats2 | any(. == $c)))) as $common |
      $common[] | select(length > 0)
    end
  '
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "usage: quality-loop-state.sh <scope|record-round|mark-clean|status|systemic> [args...]" >&2
  exit 1
fi

subcmd="$1"
shift

case "$subcmd" in
  scope)        cmd_scope "$@" ;;
  record-round) cmd_record_round "$@" ;;
  status)       cmd_status "$@" ;;
  mark-clean)   cmd_mark_clean "$@" ;;
  systemic)     cmd_systemic "$@" ;;
  *)
    echo "quality-loop-state: unknown subcommand '$subcmd'" >&2
    echo "usage: quality-loop-state.sh <scope|record-round|mark-clean|status|systemic> [args...]" >&2
    exit 1
    ;;
esac
