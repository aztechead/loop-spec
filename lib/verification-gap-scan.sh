#!/usr/bin/env bash
# verification-gap-scan.sh - Which definitions this change adds or edits are
# named by no test?
#
# Why: "is the new behavior actually pinned?" is the one review question the
# existing scans do not ask. test-tamper-scan.sh defends the tests that already
# exist, criteria-coverage.sh checks the acceptance checklist, and the code
# reviewer lists missed coverage as one Important-bucket item among many. None
# of them answers whether a changed symbol is referenced by any test at all --
# and a reviewer asked to answer it from memory will guess. This measures it.
#
# What it is NOT: proof of coverage. A test naming a symbol may assert nothing
# about it, and a symbol no test names may still be covered through its caller.
# The answer is a starting fact for the verification-gap reviewer
# (skills/shared/review-prompts/verification-gap.md), never a gate verdict.
#
# Usage:
#   verification-gap-scan.sh <base-ref> [head-ref]
#
# Environment:
#   LOOP_SPEC_VGAP_MAX_FILES  test-corpus file cap (default 2000). A miss against a
#                             truncated corpus reports covered=unknown, never covered=no.
#
# Output, ANSWER first:
#   symbol=render_body path=lib/pr-body.sh covered=no reason=named by 0 of 84 test files
#   symbol=lint path=lib/deliver.sh covered=yes reason=tests/lib/deliver.test.sh
#   scanned=2 uncovered=1 unknown=0 reason=main..HEAD across 84 test files
#
# Exit codes:
#   0  facts emitted
#   1  no definition changed in a non-test file (nothing to answer)
#   2  usage error or git failure
set -euo pipefail

[[ $# -ge 1 && $# -le 2 ]] || {
  echo "usage: verification-gap-scan.sh <base-ref> [head-ref]" >&2
  exit 2
}
base="$1"
head="${2:-HEAD}"

diff_text="$(git diff --unified=0 --find-renames "$base" "$head" 2>/dev/null)" || {
  echo "verification-gap-scan: git diff $base..$head failed" >&2
  exit 2
}

# The corpus is the repo's tests as they stand AFTER the change: a test added by
# this very diff is exactly the evidence that closes a gap, so excluding it
# would report every new symbol as uncovered.
test_files="$(git ls-files 2>/dev/null |
  grep -Ei '(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.[A-Za-z0-9]+$|_test\.[A-Za-z0-9]+$' || true)"

# The diff and the corpus list go through FILES, not the environment. A large
# change (65 files here) blows past E2BIG and the scan dies with "Argument list
# too long" -- so the gate failed on exactly the diffs it is most needed for.
scan_tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-vgap.XXXXXX")"
trap 'rm -rf "$scan_tmp"' EXIT
printf '%s' "$diff_text" > "$scan_tmp/diff.txt"
printf '%s' "$test_files" > "$scan_tmp/test-files.txt"

BASE_REF="$base" HEAD_REF="$head" DIFF_FILE="$scan_tmp/diff.txt" \
TEST_FILES_FILE="$scan_tmp/test-files.txt" \
python3 - <<'PY'
from __future__ import print_function

import os
import re
import sys

base = os.environ["BASE_REF"]
head = os.environ["HEAD_REF"]

# Definition shapes we can read confidently. A pattern that over-matched would
# manufacture symbols nobody defined and bury the real answer in noise, so
# anything ambiguous is simply not extracted.
DEF_RE = re.compile(
    r"^\s*(?:export\s+)?(?:async\s+)?(?:public\s+|private\s+|protected\s+|static\s+)*"
    r"(?:def|func|function|fn|class|interface|type)\s+([A-Za-z_][A-Za-z0-9_]*)"
    r"|^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r"(?:async\s+)?(?:function\b|\([^)]*\)\s*=>)"
    r"|^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{"          # bash: name() {
)

TEST_PATH = re.compile(
    r"(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.[A-Za-z0-9]+$|_test\.[A-Za-z0-9]+$",
    re.I,
)

def _read_input(file_var, inline_var):
    """Prefer the file form; keep the env form working for older callers."""
    path = os.environ.get(file_var)
    if path:
        with open(path) as handle:
            return handle.read()
    return os.environ.get(inline_var, "")


test_files = [path for path in _read_input("TEST_FILES_FILE", "TEST_FILES").splitlines() if path.strip()]

# Symbols shared by half the language's files answer nothing about this change.
TOO_COMMON = {
    "main", "run", "init", "setup", "teardown", "test", "check", "usage",
    "get", "set", "add", "new", "handler", "callback", "value", "data",
    # Measured, not guessed: running this probe on its own diff answered
    # covered=yes for `read`, `report`, and `budget` by matching unrelated test
    # files that happen to use the word. A name that ubiquitous cannot answer
    # the question either way.
    "read", "write", "report", "load", "parse", "emit", "open", "close",
}

found = []          # (symbol, path) in first-seen order
seen = set()
path = None
for line in _read_input("DIFF_FILE", "DIFF_TEXT").splitlines():
    if line.startswith("+++ b/"):
        candidate = line[6:].strip()
        path = None if TEST_PATH.search(candidate) else candidate
        continue
    if line.startswith("+++ ") or line.startswith("--- "):
        continue
    if path is None or not line.startswith("+") or line.startswith("+++"):
        continue
    match = DEF_RE.match(line[1:])
    if not match:
        continue
    symbol = next(group for group in match.groups() if group)
    if symbol in TOO_COMMON or len(symbol) < 3:
        continue
    key = (symbol, path)
    if key in seen:
        continue
    seen.add(key)
    found.append(key)

if not found:
    print("scanned=0 reason=no definition changed in a non-test file between {} and {}".format(base, head))
    sys.exit(1)

# One read per test file, not one per symbol: the corpus is scanned once and
# every symbol answered from it. Bounded like every other probe here -- a
# monorepo's test tree would otherwise be pulled into memory on every VERIFY.
MAX_CORPUS_FILES = int(os.environ.get("LOOP_SPEC_VGAP_MAX_FILES") or 2000)
MAX_CORPUS_BYTES = 64 * 1024 * 1024

corpus = []
corpus_bytes = 0
truncated = False
for test_path in test_files:
    if len(corpus) >= MAX_CORPUS_FILES or corpus_bytes >= MAX_CORPUS_BYTES:
        truncated = True
        break
    try:
        with open(test_path, "r", encoding="utf-8", errors="replace") as handle:
            body = handle.read()
    except OSError:
        continue
    corpus_bytes += len(body)
    corpus.append((test_path, body))

uncovered = 0
unknown = 0
for symbol, source_path in found:
    word = re.compile(r"\b{}\b".format(re.escape(symbol)))
    hits = [test_path for test_path, body in corpus if word.search(body)]
    if hits:
        shown = ", ".join(hits[:3])
        if len(hits) > 3:
            shown += ", +{} more".format(len(hits) - 3)
        print("symbol={} path={} covered=yes reason={}".format(symbol, source_path, shown))
    elif truncated:
        # A miss against a partial corpus is not evidence of absence. Saying
        # covered=no here would hand the reviewer a finding the search never
        # earned, which is the exact overclaim the prompt warns against.
        unknown += 1
        print("symbol={} path={} covered=unknown reason=corpus truncated at {} of {} test files; absence not established".format(
            symbol, source_path, len(corpus), len(test_files)))
    else:
        uncovered += 1
        print("symbol={} path={} covered=no reason=named by 0 of {} test files".format(
            symbol, source_path, len(corpus)))

print("scanned={} uncovered={} unknown={} reason={}..{} across {} test files{}".format(
    len(found), uncovered, unknown, base, head, len(corpus),
    " (truncated from {})".format(len(test_files)) if truncated else ""))
PY
