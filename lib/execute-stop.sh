#!/usr/bin/env bash
# execute-stop.sh - Probe whether an EXECUTE conflict must stop the run.
#
# Why: Superpowers v6.3.0 made ruling the default so a session does not sit
# blocked on a reversible question. Four things still stop the run:
# irreversible/destructive work, a security-sensitive action, a side effect
# outside this worktree (merge/push/publish), and an explicit plan-broken
# override. Everything else is a ruling. This script emits ANSWER and REASON
# on one line; unknown text fails safe to ruling (continue), never to stop.
#
# Usage:
#   execute-stop.sh classify <text>
#   execute-stop.sh classify --plan-broken <text>
#
# Output:
#   stop=true reason=<destructive|security|side-effect-outside|plan-broken> matched=<term>
#   stop=false reason=ruling matched=
#
# Exit: 0 always with an answer, 2 usage.
set -euo pipefail

PLAN_BROKEN=0
if [[ "${1:-}" == "classify" ]]; then
  shift
  if [[ "${1:-}" == "--plan-broken" ]]; then
    PLAN_BROKEN=1
    shift
  fi
else
  echo "usage: execute-stop.sh classify [--plan-broken] <text>" >&2
  exit 2
fi
text="${*:-}"
[[ -n "$text" ]] || { echo "usage: execute-stop.sh classify [--plan-broken] <text>" >&2; exit 2; }

if [[ "$PLAN_BROKEN" == "1" ]]; then
  echo "stop=true reason=plan-broken matched=operator-override"
  exit 0
fi

python3 -c '
from __future__ import print_function
import re, sys
text = sys.argv[1]
checks = [
    ("destructive", [
        ("rm -rf", re.compile(r"\brm\s+-rf\b", re.I)),
        ("force-push", re.compile(r"\b(?:git\s+push\s+.*--force|--force-with-lease)\b", re.I)),
        ("drop-table", re.compile(r"\bdrop\s+table\b", re.I)),
        ("irreversible", re.compile(r"\birreversible\b", re.I)),
        ("destroy", re.compile(r"\bdestroy(?:s|ing|ed)?\b", re.I)),
    ]),
    ("security", [
        ("credential", re.compile(r"\bcredentials?\b", re.I)),
        ("secret", re.compile(r"\bsecrets?\b", re.I)),
        ("auth", re.compile(r"\bauthn?\b", re.I)),
    ]),
    ("side-effect-outside", [
        ("push-origin", re.compile(r"\b(?:git\s+push|push\s+to\s+(?:origin|shared))\b", re.I)),
        ("merge-main", re.compile(r"\bmerge\s+(?:to\s+)?(?:main|master|trunk)\b", re.I)),
        ("publish", re.compile(r"\b(?:npm\s+publish|pypi\s+upload|gh\s+release)\b", re.I)),
    ]),
]
for reason, terms in checks:
    for name, rx in terms:
        if rx.search(text):
            print("stop=true reason=%s matched=%s" % (reason, name))
            sys.exit(0)
print("stop=false reason=ruling matched=")
' "$text"
