#!/usr/bin/env bash
# python-path.sh - a directory holding only the real python3 behind a version-manager
# shim, so a PATH prefix skips the shim on every launch that follows.
#
# Usage: python-path.sh            prints one directory, or nothing when there is no shim
#        python-path.sh --explain  the same, then ANSWER=<dir|none> REASON=... on stderr
#
# The directory is private (${TMPDIR:-/tmp}/loop-spec-python-<uid>, mode 0700) and holds
# one symlink, python3. Printing the interpreter's own directory put Homebrew's whole bin
# first on PATH, which shadowed the operator's newer `claude` with the cask's old one
# and every nested session then failed on "does not support this model" (6.6.4 live
# run 2). Only the interpreter moves; nothing else on PATH changes order.
#
# Why: a pyenv, asdf, or mise shim is a script that asks the manager to pick a version
# on EVERY `python3` launch, about 0.15 s against 0.02 s for the interpreter itself. The
# plugin starts python hundreds of times per phase (lib/feature_read.py alone is one
# launch per field read), so the shim was most of a phase exit's wall clock and half of
# tests/run-all.sh. Callers that run many scripts (lib/cycle-driver.sh, tests/run-all.sh)
# put the printed directory first on PATH once; every child inherits it.
#
# Fails safe: no shim, a manager that cannot answer, or a private directory this user
# does not own (a symlink or directory planted at the predictable /tmp name by someone
# else would make the link THEIR python3) prints nothing and PATH stays as it was. The
# interpreter chosen is the one the shim would have chosen (`<manager> which python3`
# honours the version files and env the shim reads), never a different python.
set -uo pipefail

explain=0
[[ "${1:-}" == "--explain" ]] && explain=1

# private_dir <interpreter> -> prints the directory holding only python3 -> interpreter,
# or nothing (with the reason on stderr) when it cannot be made this user's own.
private_dir() {
  local real="$1" dir="${TMPDIR:-/tmp}/loop-spec-python-$(id -u)"
  [[ -e "$dir" || -L "$dir" ]] || mkdir -m 700 "$dir" 2>/dev/null
  if [[ -L "$dir" || ! -d "$dir" || ! -O "$dir" ]]; then
    echo "$dir is not a directory this user owns" >&2; return 1
  fi
  chmod 700 "$dir" 2>/dev/null || true
  ln -sfn "$real" "$dir/python3" 2>/dev/null || { echo "cannot write $dir/python3" >&2; return 1; }
  printf '%s\n' "$dir"
}

resolved="$(command -v python3 2>/dev/null || true)"
answer="" reason="" manager=""
case "$resolved" in
  "") reason="python3 is not on PATH" ;;
  */.pyenv/shims/python3|*/pyenv/shims/python3) manager="pyenv" ;;
  */.asdf/shims/python3|*/asdf/shims/python3) manager="asdf" ;;
  */mise/shims/python3) manager="mise" ;;
  *) reason="$resolved is not a version-manager shim" ;;
esac
if [[ -n "$manager" ]]; then
  if ! command -v "$manager" >/dev/null 2>&1; then
    reason="$manager shim at $resolved but $manager is not on PATH"
  else
    real="$("$manager" which python3 2>/dev/null || true)"
    if [[ -n "$real" && -x "$real" && "$real" != "$resolved" ]]; then
      # One capture: the directory on success, the refusal on failure (no reason file
      # at another predictable temp path).
      if out="$(private_dir "$real" 2>&1)"; then
        answer="$out"; reason="$manager shim at $resolved; $manager which -> $real, linked as $answer/python3"
      else
        answer=""; reason="$manager shim at $resolved but $out"
      fi
    else
      reason="$manager shim at $resolved but $manager which python3 answered nothing"
    fi
  fi
fi

[[ -n "$answer" ]] && printf '%s\n' "$answer"
(( explain )) && echo "ANSWER=${answer:-none} REASON=$reason" >&2
exit 0
