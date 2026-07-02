#!/usr/bin/env bash
# parse-invocation.sh - Deterministic parser for loop-spec invocation arguments.
#
# Three skills (cycle Step 3, intake Step 1, debug Step 0) parse the same inline
# token grammar out of $ARGUMENTS by prose. The known failure mode of prose parsing
# is a stray token left in the title — e.g. `tier:quality` polluting feature_title,
# which the ITERATE judge then scores against. This script is the single
# implementation: strip every recognized token FIRST, classify what remains.
#
# Usage:
#   parse-invocation.sh parse [--] <arguments...>
#
# Recognized tokens (order-independent unless noted):
#   autonomous            -> .autonomous = true
#   new                   -> .greenfield = true when it appears BEFORE any title
#                            text (i.e. among the leading tokens, in any order with
#                            autonomous/style:); after title text has started it is
#                            ordinary title text ("add new export button")
#   style:X               -> .style = X when X in auto|step|interactive|review-only;
#                            unknown style values are kept with a notice
#   --no-run              -> .no_run = true (intake only; harmless elsewhere)
#   tier:X, preset:X      -> ignored, listed in .legacy[] (caller prints the notice)
#
# Classification of the REMAINING text (mirrors cycle Step 3 resolution order):
#   "backlog" (exactly)                    -> .mode = "backlog"
#   single token resolving to readable .md -> .mode = "spec-file", .spec_path = abs path
#   non-empty text                         -> .mode = "description", .title = text
#   empty                                  -> .mode = "bare"
#
# Output: one JSON object:
#   {mode, title, slug, style, autonomous, greenfield, no_run, spec_path, legacy: []}
#   .title is the token-stripped text ("" for bare/backlog; spec-file title is
#   resolved by the caller from the file's first heading). .slug is the kebab-case
#   of .title ("" when title is empty). .style defaults to "auto".
#
# Exit codes: 0 parsed (answer on stdout), 1 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-}"
[[ "$cmd" == "parse" ]] || {
  echo "usage: parse-invocation.sh parse [--] <arguments...>" >&2
  exit 1
}
shift
[[ "${1:-}" == "--" ]] && shift

autonomous=false
greenfield=false
no_run=false
style="auto"
legacy=()
remaining=()

# noglob: the unquoted $tok below word-splits deliberately, but must never
# glob-expand ("fix *.md handling" would otherwise match files in cwd).
set -f

for tok in "$@"; do
  # Split on whitespace inside a single quoted blob too: callers may pass
  # "$ARGUMENTS" as one string or word-split — both must parse identically.
  for w in $tok; do
    case "$w" in
      autonomous)
        autonomous=true ;;
      new)
        if [[ "${#remaining[@]}" -eq 0 ]]; then
          greenfield=true
        else
          remaining+=("$w")
        fi ;;
      --no-run)
        no_run=true ;;
      style:*)
        style="${w#style:}" ;;  # unknown value still stripped from title; caller validates
      tier:*|preset:*)
        legacy+=("$w") ;;
      *)
        remaining+=("$w") ;;
    esac
  done
done

text="${remaining[*]:-}"

mode="description"
spec_path=""
if [[ -z "$text" ]]; then
  mode="bare"
elif [[ "$text" == "backlog" ]]; then
  mode="backlog"
  text=""
elif [[ "${#remaining[@]}" -eq 1 && "$text" == *.md && -f "$text" && -r "$text" ]]; then
  mode="spec-file"
  spec_path="$(cd "$(dirname "$text")" && pwd)/$(basename "$text")"
  text=""
fi

slug=""
if [[ -n "$text" ]]; then
  slug="$(bash "$SCRIPT_DIR/git-ops.sh" slugify "$text")"
fi

legacy_json="[]"
if [[ "${#legacy[@]}" -gt 0 ]]; then
  legacy_json="$(printf '%s\n' "${legacy[@]}" | jq -R . | jq -cs .)"
fi

jq -cn \
  --arg mode "$mode" \
  --arg title "$text" \
  --arg slug "$slug" \
  --arg style "$style" \
  --argjson autonomous "$autonomous" \
  --argjson greenfield "$greenfield" \
  --argjson no_run "$no_run" \
  --arg spec_path "$spec_path" \
  --argjson legacy "$legacy_json" \
  '{mode: $mode, title: $title, slug: $slug, style: $style,
    autonomous: $autonomous, greenfield: $greenfield, no_run: $no_run,
    spec_path: (if $spec_path == "" then null else $spec_path end),
    legacy: $legacy}'
