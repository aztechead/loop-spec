#!/usr/bin/env bash
# fixlist-route.sh - Decide who applies each critique or lint finding: the lead, or the author.
#
# Why: every PLAN revision on a live run (evals/findings-2026-09-07-tf-meldn.md, round 4)
# was a planner round trip over SendMessage, five of them in a 42-minute phase, and every
# finding named a task id and a field ("task-005 is not blockedBy task-002", "task-003's
# verify clause fails open"). The lead holds tasks.json and re-renders it in one call; a
# fresh planner context re-reads the spec, the plan, and the tree to change one field.
# This probe sorts the findings so the lead edits what names a task or a Grounding
# bullet and the author is re-dispatched only for what does not (a missing task, a wrong
# decomposition, an architecture change). Fail-safe: a finding the rules cannot place
# goes to the author.
#
# Usage:
#   fixlist-route.sh route <findings.json | ->    a JSON array of finding strings
#
# Output, one line per finding, then the summary line:
#   lead    <n>  <finding>       names task-NNN, or a ## Grounding / EVID / ASSUMPTION line
#   author  <n>  <finding>       everything else
#   ANSWER=<lead|author|split> REASON=<counts>
#
# Exit: 0 routed; 2 usage or unreadable input.
set -uo pipefail

[[ "${1:-}" == "route" && $# -eq 2 ]] || { echo "usage: fixlist-route.sh route <findings.json | ->" >&2; exit 2; }
src="$2"
if [[ "$src" == "-" ]]; then input="$(cat)"; else
  [[ -f "$src" ]] || { echo "fixlist-route: no such file $src" >&2; exit 2; }
  input="$(cat "$src")"
fi
[[ "$input" =~ [^[:space:]] ]] || { echo "fixlist-route: empty input" >&2; exit 2; }

python3 - "$input" <<'PY'
import json
import re
import sys

try:
    items = json.loads(sys.argv[1])
except ValueError as exc:
    print("fixlist-route: input is not JSON: %s" % exc, file=sys.stderr)
    raise SystemExit(2)
if not isinstance(items, list) or not all(isinstance(i, str) for i in items):
    print("fixlist-route: input must be a JSON array of strings", file=sys.stderr)
    raise SystemExit(2)

task_ref = re.compile(r"\btask-\d{3}\b", re.I)
grounding = re.compile(r"\bEVID-\d{3}\b|\bASSUMPTION\b|## Grounding|grounding-lint|UNGROUNDED", re.I)
# A finding that names a task but asks for a NEW one or a re-split is the author's.
structural = re.compile(r"\b(?:missing task|new task|add a task|split (?:task|into)|merge task|re-?decompos|re-?plan|architecture|no task (?:covers|for))\b", re.I)

lead = author = 0
for n, item in enumerate(items, 1):
    flat = " ".join(item.split())
    if structural.search(flat) or not (task_ref.search(flat) or grounding.search(flat)):
        author += 1
        print("author\t%d\t%s" % (n, flat))
    else:
        lead += 1
        print("lead\t%d\t%s" % (n, flat))
answer = "lead" if author == 0 else ("author" if lead == 0 else "split")
print("ANSWER=%s REASON=%d lead-editable, %d for the author" % (answer, lead, author))
PY
