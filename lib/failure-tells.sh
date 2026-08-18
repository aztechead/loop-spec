#!/usr/bin/env bash
# failure-tells.sh - Deterministic lint: code a person cannot operate when it breaks.
#
# Why: lib/house-style.sh and lib/comment-tells.sh answer "can the next person READ
# this?". Neither asks the other half of "code for humans" -- can the person on call at
# 03:00 find out what happened? That half only shows up on the failure path, which is
# the path nobody rereads, and it fails in three shapes that are decidable from the text:
#
#   swallowed          a caught error whose handler does nothing
#   silent-exit        a non-zero exit with nothing said to the operator first
#   contextless-error  a message whose every word is a synonym for "it broke"
#
# Each one costs the same thing: the program knows what went wrong and does not say it,
# so a person has to reconstruct from the source what the software could have told them.
#
# What this does NOT judge: whether a log line is at the right level, whether an error
# should have been retried, whether a message reads well (that is
# lib/plain-language-lint.sh), or whether the handling is correct at all. Those stay
# judgments -- skills/shared/human-code.md is the contract and says so per rule.
#
# Languages: python, shell, and js/ts (including jsx/tsx). Anything else is skipped and
# counted, never guessed at. A heredoc body inside a shell script is data -- a python
# program, a prompt, a test fixture -- so it is not read as shell, which also means a
# python program embedded that way is not scanned at all.
#
# lib/failure-tells.py owns the rules; this launcher owns arguments and diff plumbing.
#
# Usage:
#   failure-tells.sh scan <file> [file ...]     # whole files
#   failure-tells.sh diff <base_ref> [head_ref] # only the lines a change added
#
# Output: one finding per line, then a count with its reason.
#   lib/deliver.sh:88: tell=silent-exit: exit 1
#   failure-tells: 1 finding(s) (3 file(s))
#
# Exit codes (lint polarity, matching lib/comment-tells.sh):
#   0  clean
#   1  findings reported
#   2  usage error / unreadable input
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-}"
case "$MODE" in
  scan) [[ $# -ge 2 ]] || { echo "usage: failure-tells.sh scan <file> [file ...]" >&2; exit 2; } ;;
  diff) [[ $# -ge 2 && $# -le 3 ]] || { echo "usage: failure-tells.sh diff <base_ref> [head_ref]" >&2; exit 2; } ;;
  *) echo "usage: failure-tells.sh <scan|diff> ..." >&2; exit 2 ;;
esac
shift

if [[ "$MODE" == "diff" ]]; then
  ADDED="${TMPDIR:-/tmp}/failure-tells-$$.tsv"
  trap 'rm -f "$ADDED"' EXIT
  git diff --unified=0 --no-color "$1" ${2:+"$2"} \
    | python3 "$SCRIPT_DIR/diff-added-lines.py" > "$ADDED"
  # A handler reads as a block, so the rules run over the whole file and the TSV only
  # decides which findings this change is answerable for.
  set -- "--tsv" "$ADDED"
fi

exec python3 "$SCRIPT_DIR/failure-tells.py" "$@"
