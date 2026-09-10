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
#   autonomous            -> .autonomous = true when it sits at an EDGE of the
#                            arguments: among the leading tokens, or among the
#                            trailing ones ("<description> autonomous style:step").
#                            Inside the description it is ordinary title text: a
#                            loop-spec feature described as "fix the autonomous chain
#                            bound" armed autonomous mode and stripped the word.
#   new                   -> .greenfield = true when it appears BEFORE any title
#                            text (i.e. among the leading tokens, in any order with
#                            autonomous/style:); after title text has started it is
#                            ordinary title text ("add new export button")
#   style:X               -> .style = X when X in auto|step|interactive|review-only;
#                            unknown style values are kept with a notice
#   phase:fresh           -> stripped; every phase already hands off (the only mode)
#   phase:continuous      -> ignored, listed in .legacy[] (continuous routing is gone)
#   profile:X             -> .profile = X when X in compact|maintenance|standard; unknown
#                            values are stripped and left unset (lib/cycle-profile.sh
#                            owns the answer space and its own fail-safe)
#   --no-run              -> .no_run = true (intake only; harmless elsewhere)
#   protected:A,B         -> .protected = [A, B]: repository-relative files the task
#                            forbids the change to touch (an eval task's protected
#                            list, "do not change the tests"). The one source of a
#                            read-only footprint file (lib/footprint.sh); a read-only
#                            mark the lead writes on any other file is not honored
#                            (port audit 4, item 1)
#   tier:X, preset:X      -> ignored, listed in .legacy[] (caller prints the notice)
#   any other -flag       -> refused (exit 1) while it LEADS the arguments; after the
#                            first description word it is description text
#                            ("python3 -m unittest", "accepts --due YYYY-MM-DD")
#
# Classification of the REMAINING text (mirrors cycle Step 3 resolution order):
#   "backlog" (exactly)                    -> .mode = "backlog"
#   single token resolving to readable .md -> .mode = "spec-file", .spec_path = abs path
#   non-empty text                         -> .mode = "description", .title = text
#   empty                                  -> .mode = "bare"
#
# Output: one JSON object:
#   {mode, title, slug, style, profile, autonomous, greenfield, no_run,
#    spec_path, protected: [], legacy: []}
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
profile=""
legacy=()
protected=()
remaining=()

# noglob: the unquoted $tok below word-splits deliberately, but must never
# glob-expand ("fix *.md handling" would otherwise match files in cwd).
set -f

# Split on whitespace inside a single quoted blob too: callers may pass
# "$ARGUMENTS" as one string or word-split — both must parse identically.
words=()
for tok in "$@"; do
  for w in $tok; do words+=("$w"); done
done

# The trailing token zone starts after the last non-token word; `autonomous` is
# honored only before the first non-token word or from that index on.
trail_start=${#words[@]}
while (( trail_start > 0 )); do
  case "${words[trail_start-1]}" in
    autonomous|new|--no-run|style:*|phase:fresh|phase:continuous|profile:*|protected:*|tier:*|preset:*)
      trail_start=$((trail_start - 1)) ;;
    *) break ;;
  esac
done

i=0
for w in ${words[@]+"${words[@]}"}; do
  idx=$i; i=$((i + 1))
  case "$w" in
    autonomous)
      if [[ "${#remaining[@]}" -eq 0 || "$idx" -ge "$trail_start" ]]; then
        autonomous=true
      else
        remaining+=("$w")
      fi ;;
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
    phase:fresh)
      : ;;  # stripped from the title; handoff after every phase is the only mode
    phase:continuous)
      legacy+=("$w") ;;
    profile:compact|profile:maintenance|profile:standard)
      profile="${w#profile:}" ;;
    profile:*)
      : ;;  # stripped from the title; an unrecognized profile is simply not set
    protected:*)
      IFS=',' read -r -a parts <<<"${w#protected:}"
      for part in ${parts[@]+"${parts[@]}"}; do [[ -n "$part" ]] && protected+=("$part"); done ;;
    tier:*|preset:*)
      legacy+=("$w") ;;
    -*)
      # A leading flag is never a description: `begin --help` once initialized a feature
      # titled "--help" in autonomous mode, with a branch and a worktree to clean up by
      # hand. After description words a dash token is the description's own text
      # ("runnable by python3 -m unittest", "`add` accepts --due YYYY-MM-DD"): refusing
      # those made a lead rephrase the task, and the rephrased slug matched no paused
      # feature, so the next invocation started a second cycle.
      if [[ "${#remaining[@]}" -eq 0 ]]; then
        echo "parse-invocation: unknown flag '$w'; the inline tokens are autonomous, new, style:<s>, phase:<m>, profile:<p>, protected:<a,b>, --no-run" >&2
        exit 1
      fi
      remaining+=("$w") ;;
    *)
      remaining+=("$w") ;;
  esac
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
protected_json="[]"
if [[ "${#protected[@]}" -gt 0 ]]; then
  protected_json="$(printf '%s\n' "${protected[@]}" | jq -R . | jq -cs 'unique')"
fi

jq -cn \
  --arg mode "$mode" \
  --arg title "$text" \
  --arg slug "$slug" \
  --arg style "$style" \
  --arg profile "$profile" \
  --argjson autonomous "$autonomous" \
  --argjson greenfield "$greenfield" \
  --argjson no_run "$no_run" \
  --arg spec_path "$spec_path" \
  --argjson legacy "$legacy_json" \
  --argjson protected "$protected_json" \
  '{mode: $mode, title: $title, slug: $slug, style: $style,
    profile: (if $profile == "" then null else $profile end),
    autonomous: $autonomous, greenfield: $greenfield, no_run: $no_run,
    spec_path: (if $spec_path == "" then null else $spec_path end),
    protected: $protected, legacy: $legacy}'
