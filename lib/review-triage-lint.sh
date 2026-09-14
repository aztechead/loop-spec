#!/usr/bin/env bash
# review-triage-lint.sh - Every code-review finding in VERIFICATION.md carries a location
# and a verdict, and a rejected finding carries its disproof.
#
# Why: a reviewer's finding is a claim, and the lead's answer to it used to be prose the
# next reader could not check. A head-to-head run wrote a false off-by-one to its
# backlog because nobody had to say where the line was or why the finding was wrong
# (the port plan, WP6). The `verify` and `oneshot` exits run
# this over every bullet under `## Code review`, whatever subheading: one bullet per finding, shaped
#   - <file>:<line> — <claim> | verdict: true — <commit, backlog id, or fix>
#   - <file>:<line> — <claim> | verdict: false — <disproof: what shows the finding wrong>
# A `false` with no disproof sentence, a finding with no `file:line`, and a finding with
# no verdict are FLAGs. `none` under a severity heading is a clean section.
#
# Usage: review-triage-lint.sh <VERIFICATION.md>
# Output: `FLAG <path>:<line>: <message>` per finding; exit 1 when any, 0 when clean
# (or when the file has no `## Code review` findings), 2 bad call.
set -euo pipefail

artifact="${1:-}"
[[ -n "$artifact" && $# -eq 1 ]] || { echo "usage: review-triage-lint.sh <VERIFICATION.md>" >&2; exit 2; }
[[ -f "$artifact" ]] || { echo "FLAG $artifact:0: artifact does not exist"; exit 1; }

PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - "$artifact" <<'PY'
import re
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
SEVERITY = re.compile(r"^#### (Critical|Important|Minor|Performance)\b")
# A location is a path (a separator, or a known source extension) and a line; a bare
# `word:12` (a heading id, a time) is not one (port audit 1, F10).
LOCATION = re.compile(r"(?<![\w/.-])((?:[\w.-]+/)+[\w.-]+|[\w.-]+\.(?:py|pyi|js|jsx|ts|tsx|mjs|cjs|sh|bash|go|rs|java|kt|rb|php|cs|c|h|cc|cpp|hpp|swift|m|sql|md|json|jsonl|yaml|yml|toml|ini|cfg|html|css|scss|vue|svelte|tf|proto|graphql)|Makefile|Dockerfile|Justfile|Rakefile|Gemfile|Procfile|LICENSE|NOTICE|README|CHANGELOG):(\d+)\b")
VERDICT = re.compile(r"\|\s*verdict:\s*(true|false)\b\s*(?:[—:-]\s*)?(.*)$")
SHAPE = ("expected `- <file>:<line> — <claim> | verdict: true — <commit, backlog id, or fix>` "
         "or `| verdict: false — <disproof>`")

flags = []
in_review = False
for no, line in enumerate(lines, 1):
    s = line.strip()
    if s.startswith("## "):
        in_review = s == "## Code review"
        continue
    # Every bullet under `## Code review` is a finding, whatever subheading it sits
    # under: a finding parked under `### Resolution` was a finding the lint never read.
    if not in_review or s.startswith("#") or not line.startswith("- "):
        continue
    text = s[2:].strip()
    if text.lower() in ("none", "none.", "n/a"):
        continue
    where = next((m for m in LOCATION.finditer(text) if not m.group(1).isdigit()), None)
    if where is None:
        flags.append((no, "finding has no file:line; %s" % SHAPE))
    verdict = VERDICT.search(text)
    if verdict is None:
        flags.append((no, "finding has no verdict; %s" % SHAPE))
        continue
    tail = verdict.group(2).split(" | routing:", 1)[0].strip()
    if verdict.group(1) == "false" and len(tail.split()) < 5:
        flags.append((no, "verdict: false needs a disproof sentence (what you ran or read that shows the finding wrong)"))
    elif verdict.group(1) == "true" and not tail:
        flags.append((no, "verdict: true needs its evidence (the commit, the backlog id, or the fix)"))
from review_routes import findings
try:
    findings("\n".join(lines))
except ValueError as exc:
    flags.append((0, str(exc)))
for no, message in flags:
    print("FLAG %s:%d: %s" % (path, no, message))
sys.exit(1 if flags else 0)
PY
