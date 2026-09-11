#!/usr/bin/env bash
# resolve-symlink.sh - Resolve a candidate path to what it actually names on disk.
#
# Why: two path guards judge a candidate against a protected location --
# hooks/restrict-agent-paths.sh's Write/Edit scope checks and
# lib/harness.sh protected-path's route/format checks. Both must judge the
# RESOLVED target, never the literal path a tool call or shell command names: a
# maker allowed to write under publication-staging could otherwise plant a
# symlink there pointing at SPEC.md/feature.json/tasks.json and write through it
# undetected (a security hardening pass, see hooks/team/result-forgery-guard.sh's
# comment for the shell-command half of the same fix). This is the one place that
# resolution logic lives, so the two guards can never quietly disagree about where
# a path lands.
#
# Usage:
#   resolve-symlink.sh PATH
#
# PATH may be relative or absolute. A target that exists (file, dir, or a
# symlink, dangling or not) is resolved with python3's os.path.realpath. A
# target that does not exist yet -- the common case for a fresh Write -- has no
# link to follow, so its real parent directory is resolved and the literal
# basename rejoined: this still catches a symlinked STAGING DIRECTORY while a
# plain new file resolves to itself, unchanged.
#
# Exit: 0 always, printing the resolved path. Resolution failure (missing
# python3, an unreadable parent) prints PATH unchanged rather than failing --
# callers judge whatever comes back, and a probe that cannot resolve is not
# license to skip the judgment.
set -euo pipefail

path="${1:-}"
[[ -n "$path" ]] || { echo "usage: resolve-symlink.sh PATH" >&2; exit 2; }

python3 -c "
import os, sys
p = sys.argv[1]
if os.path.islink(p) or os.path.exists(p):
  print(os.path.realpath(p))
else:
  parent = os.path.dirname(p) or '.'
  print(os.path.join(os.path.realpath(parent), os.path.basename(p)))
" "$path" 2>/dev/null || printf '%s\n' "$path"
