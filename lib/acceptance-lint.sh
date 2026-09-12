#!/usr/bin/env bash
# Lint acceptance criteria for bare-substring grep checks.
#
# Why: a criterion like `grep -c "allVersions" file returns 0` measures whether a STRING
# appears in source, not whether the BEHAVIOR exists -- it passes on a code comment and
# fails on an incidental substring. The planner is told to prefer behavioral checks and to
# anchor any grep (whole-word / code-only / comment-excluding); this gate enforces it so
# guidance does not silently drift back into bare greps.
#
# Usage: acceptance-lint.sh [<tasks JSON path> | -]
#   A JSON array of task objects, each with an `acceptanceCriteria` array of strings (the
#   planner's tasks[] shape) -- the SAME structure EXECUTE consumes. `-` or no argument
#   reads stdin; PLAN pipes the tasks it just authored, the graph gate names the persisted
#   `tasks.json` (a graph node has no pipeline to pipe through).
#
# A criterion is FLAGGED when it contains a `grep` whose target looks like a plain
# substring and it carries NONE of the anchoring markers that make a grep behavior-ish:
#   -w / -F-with-word / \b / ^ / $ / function|def|class boundary / a `grep -v` comment strip.
#
# Output: one line per flagged criterion (taskId + the criterion). Intended as a blocking
# feasibility check (plan Step 4b).
#
# Exit codes: 0 clean, 1 any flagged criterion, 2 bad invocation -- unreadable, empty, or
# non-JSON input is a usage error, never a finding. Conflating the two made an unreadable
# input read as "criteria are bad", which is a different instruction to whoever acts on it.
set -uo pipefail

source_path="${1:--}"
if [[ "$source_path" == "-" ]]; then
  input="$(cat)"
elif [[ -f "$source_path" ]]; then
  input="$(<"$source_path")"
else
  echo "acceptance-lint: tasks file not found: $source_path" >&2
  exit 2
fi

# A regex test, not ${input//[[:space:]]/}: bash 3.2 (the declared floor) takes minutes to
# strip whitespace from a 17KB tasks.json, which hung the PLAN gate on a live run.
[[ "$input" =~ [^[:space:]] ]] || { echo "acceptance-lint: empty input" >&2; exit 2; }
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$input" || {
  echo "acceptance-lint: input is not a JSON array of tasks" >&2
  exit 2
}

flagged=0

# Emit "taskId<TAB>criterion" for every criterion mentioning grep.
while IFS=$'\t' read -r tid crit; do
  [[ -z "$crit" ]] && continue
  # Only consider criteria that INVOKE grep, not a tool whose name merely contains it
  # (a criterion calling `grep_symbol` read as a grep invocation and flagged six
  # behavioral criteria, 6.6.2 live run).
  grep_invocation='(^|[[:space:]|;($`])grep([[:space:]]|$)'
  [[ "$crit" =~ $grep_invocation ]] || continue
  # Anchored / behavioral markers that exempt the grep.
  exempt=0
  # A flag cluster ending in -w (`grep -qw`) is still a whole-word match; the old
  # exact-token check only matched a standalone ` -w`/`-w ` and missed the cluster,
  # defeating the anchor test and costing a planner round (6.6.2 live run).
  word_flag_cluster='(^|[[:space:]])-[A-Za-z]*w([[:space:]]|$)'
  [[ "$crit" =~ $word_flag_cluster ]] && exempt=1
  case "$crit" in
    *'\b'*) exempt=1 ;;                      # word-boundary regex
    *'grep -v'*) exempt=1 ;;                 # comment/line exclusion pipeline
    *'grep -E'*'^'*) exempt=1 ;;             # anchored extended regex
    *'grep -E'*'function '*) exempt=1 ;;     # construct-anchored
    *'grep -E'*'def '*) exempt=1 ;;
    *'grep -E'*'class '*) exempt=1 ;;
  esac
  # Declarative files have no functions to anchor on: a whole-line or key = value match
  # in HCL, YAML, TOML, INI, or JSON is the honest check, not a substring accident. A
  # live IaC plan paid two planner rounds rewriting 37 such criteria (and three rewrites
  # were wrong: -w cannot anchor a target that starts with $ or ").
  if [[ "$exempt" -eq 0 ]] && [[ "$crit" =~ \.(hcl|tf|tfvars|ya?ml|toml|ini|json|cfg|conf|env|properties)([^a-zA-Z0-9]|$) ]] \
     && [[ "$crit" =~ grep.*(-F|-x|-q|-c|-E).*(=|:|^\^|\^[a-zA-Z_]) ]]; then
    exempt=1
  fi
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
