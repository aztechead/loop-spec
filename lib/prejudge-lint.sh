#!/usr/bin/env bash
# prejudge-lint.sh - Fail if a dispatch prompt coaches a reviewer.
#
# Why: Superpowers v6.0.0 caught controllers writing "do not flag X" / "at most
# Minor"; the flaw shipped. A script decides whether a TEMPLATE contains those
# phrases. Free-form model output is out of scope (that would be a judgment
# selecting a path).
#
# Usage:
#   prejudge-lint.sh scan <file> [file ...]
#
# Output: one finding per banned phrase, then a count line.
# Exit: 0 clean, 1 findings, 2 usage.
set -euo pipefail

[[ "${1:-}" == "scan" && $# -ge 2 ]] || {
  echo "usage: prejudge-lint.sh scan <file> [file ...]" >&2
  exit 2
}
shift

python3 - "$@" <<'PY'
from __future__ import print_function
import re, sys

# Phrase, not a word: "the plan chose" is coaching; "plan-mandated" is the
# allowed label a reviewer uses for the lead to adjudicate.
BANNED = [
    ("do-not-flag", re.compile(r"do\s+not\s+flag|don't\s+flag", re.I)),
    ("dont-treat", re.compile(r"don'?t\s+treat\b|do\s+not\s+treat\b", re.I)),
    ("at-most-minor", re.compile(r"at\s+most\s+minor", re.I)),
    ("plan-chose", re.compile(r"the\s+plan\s+chose", re.I)),
    ("ignore-finding", re.compile(r"ignore\s+(this|the|that)\s+finding", re.I)),
]

findings = 0
for path in sys.argv[1:]:
    try:
        text = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError as exc:
        print("%s:0: tell=unreadable: %s" % (path, exc))
        findings += 1
        continue
    for name, rx in BANNED:
        for i, line in enumerate(text.splitlines(), 1):
            if rx.search(line):
                print("%s:%d: tell=%s: %s" % (path, i, name, line.strip()[:120]))
                findings += 1
print("prejudge-lint: %d finding(s)" % findings)
sys.exit(1 if findings else 0)
PY
