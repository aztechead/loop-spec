#!/usr/bin/env bash
# python-path.sh - a directory holding only the real python3 behind a version-manager
# shim, so a PATH prefix skips the shim on every launch that follows.
#
# Usage: python-path.sh            prints one directory, or nothing when there is no shim
#        python-path.sh --explain  the same, then ANSWER=<dir|none> REASON=... on stderr
#
# The directory is private (${TMPDIR:-/tmp}/loop-spec-python-<uid>) and holds one
# symlink, python3. Printing the interpreter's own directory put Homebrew's whole bin
# first on PATH, which shadowed the operator's newer `claude` with the cask's old one
# and every nested session then failed on "does not support this model" (6.6.4 live
# run 2). Only the interpreter moves; nothing else on PATH changes order.
#
# Why: a pyenv shim is a bash script that runs `pyenv exec` to pick a version on EVERY
# `python3` launch, about 0.15 s against 0.02 s for the interpreter itself. The plugin
# starts python hundreds of times per phase (lib/feature_read.py alone is one launch per
# field read), so the shim was most of a phase exit's wall clock and half of
# tests/run-all.sh. Callers that run many scripts (lib/cycle-driver.sh, tests/run-all.sh)
# put the printed directory first on PATH once; every child inherits it.
#
# Fails safe: no shim, or a manager that cannot answer, prints nothing and PATH stays as
# it was. The interpreter chosen is the one the shim would have chosen (`pyenv which`
# honours .python-version and PYENV_VERSION), never a different python.
set -uo pipefail

explain=0
[[ "${1:-}" == "--explain" ]] && explain=1

resolved="$(command -v python3 2>/dev/null || true)"
answer="" reason=""
case "$resolved" in
  "") reason="python3 is not on PATH" ;;
  */.pyenv/shims/python3|*/pyenv/shims/python3)
    if command -v pyenv >/dev/null 2>&1; then
      real="$(pyenv which python3 2>/dev/null || true)"
      if [[ -n "$real" && -x "$real" ]]; then
        answer="${TMPDIR:-/tmp}/loop-spec-python-$(id -u)"
        if mkdir -p "$answer" 2>/dev/null && ln -sfn "$real" "$answer/python3" 2>/dev/null; then
          reason="pyenv shim at $resolved; pyenv which -> $real, linked as $answer/python3"
        else
          answer=""; reason="pyenv shim at $resolved but cannot write $answer"
        fi
      else
        reason="pyenv shim at $resolved but pyenv which python3 answered nothing"
      fi
    else
      reason="pyenv shim at $resolved but pyenv is not on PATH"
    fi
    ;;
  *) reason="$resolved is not a version-manager shim" ;;
esac

[[ -n "$answer" ]] && printf '%s\n' "$answer"
(( explain )) && echo "ANSWER=${answer:-none} REASON=$reason" >&2
exit 0
