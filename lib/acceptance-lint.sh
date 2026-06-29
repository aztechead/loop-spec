#!/usr/bin/env bash
# Lint acceptance criteria for bare-substring grep checks.
#
# Why: a criterion like `grep -c "allVersions" file returns 0` measures whether a STRING
# appears in source, not whether the BEHAVIOR exists -- it passes on a code comment and
# fails on an incidental substring. The planner is told to prefer behavioral checks and to
# anchor any grep (whole-word / code-only / comment-excluding); this gate enforces it so
# guidance does not silently drift back into bare greps.
#
# Input: a JSON array of task objects on stdin, each with an `acceptanceCriteria` array of
# strings (the planner's tasks[] shape). Reads the SAME structure EXECUTE consumes.
#
# A criterion is FLAGGED when it contains a `grep` whose target looks like a plain
# substring and it carries NONE of the anchoring markers that make a grep behavior-ish:
#   -w / -F-with-word / \b / ^ / $ / function|def|class boundary / a `grep -v` comment strip.
#
# Output: one line per flagged criterion (taskId + the criterion). Exit 1 if any flagged,
# else 0. Intended as a blocking feasibility check (plan Step 4b).
set -uo pipefail

input="$(cat)"
[[ -z "$input" ]] && { echo "acceptance-lint: empty input" >&2; exit 1; }
echo "$input" | jq -e . >/dev/null 2>&1 || { echo "acceptance-lint: input is not valid JSON" >&2; exit 1; }

flagged=0

# Emit "taskId<TAB>criterion" for every criterion mentioning grep.
while IFS=$'\t' read -r tid crit; do
  [[ -z "$crit" ]] && continue
  # Only consider criteria that invoke grep at all.
  case "$crit" in
    *grep*) : ;;
    *) continue ;;
  esac
  # Anchored / behavioral markers that exempt the grep.
  exempt=0
  case "$crit" in
    *" -w"*|*"-w "*) exempt=1 ;;            # whole-word match
    *'\b'*) exempt=1 ;;                      # word-boundary regex
    *'grep -v'*) exempt=1 ;;                 # comment/line exclusion pipeline
    *'grep -E'*'^'*) exempt=1 ;;             # anchored extended regex
    *'grep -E'*'function '*) exempt=1 ;;     # construct-anchored
    *'grep -E'*'def '*) exempt=1 ;;
    *'grep -E'*'class '*) exempt=1 ;;
  esac
  if [[ "$exempt" -eq 0 ]]; then
    echo "FLAG ${tid}: bare-substring grep acceptance -> $crit"
    flagged=$((flagged+1))
  fi
done < <(echo "$input" | jq -r '.[] | .id as $id | (.acceptanceCriteria // [])[] | "\($id)\t\(.)"')

if [[ "$flagged" -gt 0 ]]; then
  echo "acceptance-lint: $flagged criterion(s) use a bare-substring grep." >&2
  echo "  Use a behavioral check (a named test that must pass), or anchor the grep" >&2
  echo "  (grep -w / -E with \\b / ^, or strip comments with grep -v first)." >&2
  exit 1
fi
echo "acceptance-lint: ok (no bare-substring grep criteria)"
exit 0
