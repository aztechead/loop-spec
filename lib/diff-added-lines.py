"""Emit the lines a diff ADDED, as `path<TAB>lineno<TAB>text`.

Shared by the probes that answer "what did this change introduce?" rather than
"what does this file contain" -- comment-tells.sh, duplication-scan.sh, and
indirection-scan.sh all need the same three columns, and a fourth copy of this
parser is exactly the finding duplication-scan.sh reports.

Reads `git diff --unified=0` output on stdin. Unified=0 is required: the parser
trusts that every `+` line inside a hunk is an addition, which only holds with
no context lines.

Usage:
  git diff --unified=0 --no-color <base> [head] | python3 diff-added-lines.py
"""
from __future__ import print_function

import re
import sys

HUNK_START = re.compile(r"\+(\d+)")


def main():
    path, lineno = None, 0
    for line in sys.stdin:
        if line.startswith("+++ b/"):
            path = line[6:].rstrip("\n")
        elif line.startswith("@@"):
            match = HUNK_START.search(line)
            lineno = int(match.group(1)) if match else 0
        elif line.startswith("+") and not line.startswith("+++") and path:
            sys.stdout.write("{}\t{}\t{}".format(path, lineno, line[1:]))
            lineno += 1


if __name__ == "__main__":
    main()
