#!/usr/bin/env bash
# doc-tells.sh - Deterministic lint: markdown a human cannot maintain or operate from.
#
# Why: "write good docs" is unenforceable as prose, exactly like "do not over-comment"
# was before lib/comment-tells.sh. A generated document fails its reader in three ways
# that are decidable from the text and the tree, without judging one sentence:
#
#   dead-link              a relative link whose target is not on disk
#   stale-ref              an inline-code path that no longer exists in this repository
#   undefined-placeholder  a command holding a placeholder the page never explains
#
# The first two are documentation rot: the file moved, the doc kept pointing at where
# it used to be, and the reader who trusts it loses more time than no doc would have
# cost. The third is the operability failure: a runbook a person cannot actually run.
#
# What this does NOT judge, because none of it is decidable from text: whether the doc
# names its reader, whether it mixes a tutorial with reference (Diátaxis), whether a
# command's expected output is stated, or whether prose restates what the code already
# says. Those stay judgments for the writer and the reviewer -- see
# skills/shared/human-docs.md, which is the contract this probe measures one corner of.
# Sentence-level readability is lib/plain-language-lint.sh's job, not this one.
#
# lib/doc-tells.py owns the rules; this launcher owns arguments and the diff plumbing.
#
# Usage:
#   doc-tells.sh scan <file.md> [file.md ...]   # whole documents
#   doc-tells.sh diff <base_ref> [head_ref]     # only the lines a change added
#
# Output: one finding per line, then a count with its reason.
#   docs/runbook.md:42: tell=dead-link: ../ops/rotate.md (no such file from docs/)
#   doc-tells: 1 finding(s) (3 file(s))
#
# Exit codes (lint polarity, matching lib/comment-tells.sh):
#   0  clean
#   1  findings reported
#   2  usage error / unreadable input
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-}"
case "$MODE" in
  scan) [[ $# -ge 2 ]] || { echo "usage: doc-tells.sh scan <file.md> [file.md ...]" >&2; exit 2; } ;;
  diff) [[ $# -ge 2 && $# -le 3 ]] || { echo "usage: doc-tells.sh diff <base_ref> [head_ref]" >&2; exit 2; } ;;
  *) echo "usage: doc-tells.sh <scan|diff> ..." >&2; exit 2 ;;
esac
shift

if [[ "$MODE" == "diff" ]]; then
  ADDED="${TMPDIR:-/tmp}/doc-tells-$$.tsv"
  trap 'rm -f "$ADDED"' EXIT
  git diff --unified=0 --no-color "$1" ${2:+"$2"} -- '*.md' '*.markdown' \
    | python3 "$SCRIPT_DIR/diff-added-lines.py" > "$ADDED"
  # A doc reads as a whole -- fence state and prose both -- so the rules run over the
  # file at the reviewed revision and the TSV only decides which findings are this
  # change's to answer for.
  set -- "--tsv" "$ADDED" ${2:+--rev "$2"}
fi

exec python3 "$SCRIPT_DIR/doc-tells.py" "$@"
