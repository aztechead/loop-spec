#!/usr/bin/env bash
# route-judgment.sh - Validate a route-judge verdict and authorize the oneshot/full route.
#
# The judge (agents/route-judge.md) supplies one semantic judgment after read-only
# grounding; this script owns authorization. A malformed, low-confidence, or
# open-question verdict, or one that names a security or destructive surface, fails to
# route=full so the cycle keeps moving on the safest path. An interface or data-format
# surface is the judge's complexity input, never a veto: a wrong oneshot costs one
# reviewed pass and the exit gates lengthen it, a wrong full costs the whole cycle.
# The judge's own file count above 3 is full as well: the oneshot reviewer and spec lint
# hold the footprint at 3, and the 6.8.0 live run paid an implementation pass to learn
# from the reviewer what the verdict had already counted (a 7-file package split).
# It never infers route semantics beyond what the verdict already claims.
#
# Usage:
#   route-judgment.sh validate <verdict.json>
#   route-judgment.sh validate - <<'JSON' ... JSON
#
# Pass the file the judge wrote whenever there is one; `-` is for a verdict already on a
# heredoc or a pipe. `-` waits STDIN_WAIT_SECONDS for the first line and then fails,
# because an agent harness's Bash tool leaves stdin OPEN: an unbounded read there spends
# the whole tool timeout (the 6.8.0 live run lost 10 minutes on the first SPEC judge call,
# and the retry with stdin closed answered at once).
#
# Output is exactly one line:
#   route=oneshot reason=judge: <first reason claim> (complexity N, confidence C)
#   route=full reason=judge: <text> code=<code>
#
# Exit codes: 0 for any judged answer, including unusable-verdict; 2 on bad usage, a
# missing file, an unreadable input path, or stdin that never delivered a verdict.

set -euo pipefail

usage() {
  echo "Usage: route-judgment.sh validate <verdict.json | ->" >&2
  exit 2
}

[[ "${1:-}" == "validate" ]] || usage
source_path="${2:-}"
[[ -n "$source_path" ]] || usage
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_dir/runtime-preflight.sh" check-jq

# Whole seconds: bash 3.2 `read -t` takes no fraction, and a verdict already on the pipe
# needs none. Each read gets its own window, so a slow producer is not cut off.
STDIN_WAIT_SECONDS=3

read_stdin() {
  local line raw=""
  while IFS= read -r -t "$STDIN_WAIT_SECONDS" line; do
    raw="$raw$line"$'\n'
  done
  # read returns 1 at EOF and >128 on timeout; either way a final line with no newline
  # of its own is in $line, and a clean EOF leaves it empty.
  [[ -z "$line" ]] || raw="$raw$line"$'\n'
  printf '%s' "$raw"
}

if [[ "$source_path" == "-" ]]; then
  raw="$(read_stdin)"
  [[ -n "${raw//[[:space:]]/}" ]] || {
    echo "route-judgment.sh: no verdict arrived on stdin within ${STDIN_WAIT_SECONDS}s. Pass the file the judge wrote (route-judgment.sh validate verdict.json), or send the verdict on a heredoc (validate - <<JSON ... JSON). A harness Bash tool leaves stdin open, so a bare dash waits for a writer that never comes." >&2
    exit 2
  }
elif [[ -f "$source_path" ]]; then
  raw="$(<"$source_path")"
else
  echo "route-judgment.sh: verdict file not found: $source_path" >&2
  exit 2
fi

# A saved final message often arrives fenced (```json ... ```); the fence is not the
# verdict, so it is stripped before the schema is read.
raw="$(sed -e '1{/^[[:space:]]*```/d;}' -e '${/^[[:space:]]*```[[:space:]]*$/d;}' <<<"$raw")"

# One jq program owns every code in the contract's checked order. An input that
# fails to parse is caught here rather than left to crash the pipeline, because
# "not JSON at all" is unusable-verdict, not a bad-usage exit. Output is
# "code<TAB>text"; an empty code means the oneshot answer, and its text already
# carries the "(complexity N, confidence C)" suffix so bash never re-parses $raw.
result="$(jq -Rrn --arg raw "$raw" '
  ($raw | try fromjson catch null) as $v |
  def valid_surfaces:
    ($v.surfaces | type == "object") and
    (["interface", "dataFormat", "security", "destructive"]
      | all($v.surfaces[.] | type == "boolean"));
  def valid_reasons:
    ($v.reasons | type == "array") and (($v.reasons | length) > 0) and
    ($v.reasons | all(type == "object" and (.claim | type == "string") and (.cite | type == "string")));
  def usable:
    ($v | type == "object") and
    ($v.schema == 1) and
    (($v.route == "oneshot") or ($v.route == "full")) and
    (($v.complexity | type == "number") and ($v.complexity | floor == .) and $v.complexity >= 1 and $v.complexity <= 5) and
    (($v.confidence | type == "number") and $v.confidence >= 0 and $v.confidence <= 1) and
    (($v.files | type == "number") and ($v.files | floor == .) and $v.files >= 0) and
    valid_surfaces and
    (($v.openQuestions | type == "array") and ($v.openQuestions | all(type == "string"))) and
    valid_reasons;
  if (usable | not) then
      "unusable-verdict\tthe verdict is missing, malformed, or fails the schema"
    elif $v.route == "full" then
      "judge-selected-full\t" + $v.reasons[0].claim
    elif $v.confidence < 0.7 then
      "low-confidence\tconfidence \($v.confidence) is below the 0.7 route threshold"
    elif ($v.openQuestions | length) > 0 then
      "open-questions\t" + $v.openQuestions[0]
    elif $v.surfaces.security then
      "surface-security\tthe judge could not rule out a security surface"
    elif $v.surfaces.destructive then
      "surface-destructive\tthe judge could not rule out a destructive surface"
    elif $v.files > 3 then
      "files-over-bound\tthe judge counts \($v.files) files; oneshot holds at most 3"
    else
      "\t" + $v.reasons[0].claim + " (complexity \($v.complexity), confidence \($v.confidence))"
    end
  # The output contract is one line and the driver parses it as one; a claim the
  # judge wrapped across lines must not turn a valid verdict into unusable-verdict.
  | split("\t") | .[0] + "\t" + (.[1] | gsub("[[:space:]]+"; " "))
')"

# Not `read`: with IFS set to a whitespace character, read strips a leading
# empty field instead of preserving it, which is exactly the oneshot case.
code="${result%%$'\t'*}"
text="${result#*$'\t'}"

if [[ -z "$code" ]]; then
  printf 'route=oneshot reason=judge: %s\n' "$text"
else
  printf 'route=full reason=judge: %s code=%s\n' "$text" "$code"
fi
