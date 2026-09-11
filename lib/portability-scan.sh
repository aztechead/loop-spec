#!/usr/bin/env bash
# portability-scan.sh - Deterministic probe: does this bash or python assume a
# floor the plugin does not have?
#
# Why: CLAUDE.md fixes the runtime floor at bash >= 3.2, jq >= 1.5, and
# python3 >= 3.7, on POSIX/BSD userland as much as GNU/Linux, because the plugin has
# to run unmodified on macOS (BSD sed/grep/stat/date/mktemp, `/var` symlinked to
# `/private/var`, no `readlink -f`, no `realpath`), stock GNU/Linux, and
# Alpine/BusyBox. "Never assume one platform" is not decidable by rereading a diff --
# a bash-4 construct or a GNU-only flag runs fine on the author's own machine and
# only breaks on whichever peer's it is not. This makes the assumption visible
# without anyone having to reproduce the other platform first.
#
# Two rule sets, both explained fully in lib/portability_scan.py's own header:
#
#   shell   bash >= 4 syntax (mapfile, declare -A, ${var,,}, |&, coproc, ...) and
#           GNU-coreutils-only flags (readlink -f, sed -i with no suffix, stat -c,
#           date -d, grep -P, sort -V, cp --parents, find -printf, xargs -d,
#           an mktemp template with fewer than 3 trailing X's, mktemp -t + --suffix)
#   python  a stdlib feature newer than 3.7: walrus, match statements,
#           str.removeprefix/removesuffix, dict | dict, positional-only `/`
#           parameters, os.sched_*, signal.SIGRTMIN, the f-string {expr=} specifier
#
# `timeout` and `flock` are neither: they are simply absent from a stock macOS
# install. Reported at warning severity, and only when nothing in the file guards
# them (no `command -v`/`type`/`which` check) AND the file ships as part of the
# plugin (lib/, hooks/) -- a fixture proving this rule fires is not a bug to fix.
#
# A shell script's `python3 - <<'PY' ... PY` heredoc (this repo's own convention for
# embedding substantial python -- comment-tells.sh, failure-tells.sh, dozens more) is
# scanned under the PYTHON rules, detected by `python3`/`python` on the opening line.
# Any other heredoc body is data (a jq program, JSON, prompt text) and is skipped,
# matching lib/failure-tells.sh's own convention for the identical reason.
#
# A line carrying `# portability: <reason>` is never reported -- the same per-line
# escape already in use for `# noqa`/`# type: ignore` (lib/adk-install.sh).
#
# Usage:
#   portability-scan.sh scan <file-or-dir> [file-or-dir ...]
#     A directory argument expands to every *.sh/*.bash/*.py file under it; a file
#     with any other extension, given directly, is read and skipped from the count.
#
# Output: one finding per line, then a count with its reason.
#   lib/foo.sh:42: tell=mktemp-template: mktemp /tmp/work (mktemp's template must ...)
#   hooks/bar.sh:9: tell=timeout-no-fallback severity=warning: timeout 5 curl ... (...)
#   portability-scan: 2 finding(s) (2 file(s))
#
# Exit codes (lint polarity, matching lib/comment-tells.sh):
#   0  clean
#   1  findings reported
#   2  usage error / unreadable input
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "${1:-}" == "scan" && $# -ge 2 ]] \
  || { echo "usage: portability-scan.sh scan <file-or-dir> [file-or-dir ...]" >&2; exit 2; }
shift

targets=()
for arg in "$@"; do
  if [[ -d "$arg" ]]; then
    while IFS= read -r found; do
      targets+=("$found")
    done < <(find "$arg" -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.py' \) | sort)
  else
    targets+=("$arg")
  fi
done

# bash 3.2 treats "${targets[@]}" on a genuinely empty array as an unset variable
# under `set -u` (fixed upstream in 4.4); a directory with no matching file is not
# a usage error, so guard the expansion instead of assuming bash 4's behavior.
if [[ ${#targets[@]} -eq 0 ]]; then
  echo "portability-scan: clean (0 file(s))"
  exit 0
fi

exec python3 "$SCRIPT_DIR/portability_scan.py" "${targets[@]}"
