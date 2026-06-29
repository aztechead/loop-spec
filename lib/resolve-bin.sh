#!/usr/bin/env bash
# Resolve the REAL executable path for a tool, sidestepping shell-function / alias shims.
#
# Why: version managers (nvm, pyenv, rbenv, asdf) install `node`/`npm`/`python` as SHELL
# FUNCTIONS, not executables. In a non-interactive shell those functions may be absent or
# (the known nvm+RTK interaction) print help text instead of running -- so `npx vitest` /
# `python -m pytest` silently fail as written. `command -v` also reports functions, so it
# is not a reliable "can I actually execute this" probe. This helper finds a real on-disk
# binary so generated verify/test commands run regardless of the interactive shim layer.
#
# Usage:
#   bash lib/resolve-bin.sh <tool> [project_dir]
#       Prints an absolute path to the best real executable for <tool>, or exits 1 if none.
#       For node tooling, a project-local node_modules/.bin/<tool> wins (project_dir
#       defaults to the cwd) -- preferring the direct binary over npx/npm-run wrappers.
#
# Exit codes: 0 found (path on stdout); 1 not resolvable.
set -uo pipefail

tool="${1:-}"
project_dir="${2:-$PWD}"
[[ -z "$tool" ]] && { echo "usage: resolve-bin.sh <tool> [project_dir]" >&2; exit 1; }

# 1. Project-local node binary (direct binary beats npx/npm-run shims).
if [[ -x "$project_dir/node_modules/.bin/$tool" ]]; then
  ( cd "$project_dir" && printf '%s\n' "$(pwd)/node_modules/.bin/$tool" )
  exit 0
fi

# 2. A real executable on PATH. `type -P` finds an executable FILE only -- it skips
#    shell functions, aliases, and builtins, which is exactly the shim case we avoid.
real="$(type -P "$tool" 2>/dev/null || true)"
if [[ -n "$real" && -x "$real" ]]; then
  printf '%s\n' "$real"
  exit 0
fi

# 3. Common version-manager install / shim directories (newest-first for nvm).
candidates=()
if [[ -d "$HOME/.nvm/versions/node" ]]; then
  while IFS= read -r d; do
    [[ -x "$d/bin/$tool" ]] && candidates+=("$d/bin/$tool")
  done < <(find "$HOME/.nvm/versions/node" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r)
fi
for shimdir in "$HOME/.pyenv/shims" "$HOME/.rbenv/shims" "$HOME/.asdf/shims"; do
  [[ -x "$shimdir/$tool" ]] && candidates+=("$shimdir/$tool")
done
if [[ "${#candidates[@]}" -gt 0 ]]; then
  printf '%s\n' "${candidates[0]}"
  exit 0
fi

echo "resolve-bin: could not resolve a real executable for '$tool'" >&2
exit 1
