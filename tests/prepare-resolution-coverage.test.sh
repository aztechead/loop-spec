#!/usr/bin/env bash
# Prepare-resolution coverage: the resolver's workspace answer and the guardrail that
# covers the case it declines must both stay wired.
#
# Dogfooding: on a uv-workspace repository whose frontend lives in webapp/frontend/, the
# root-only lockfile probe reported no Node ecosystem, the model hand-rolled `npm install`,
# that rewrote package-lock.json, and preparation failed the "tree unchanged" guard --
# costing a restore plus a redo before the cycle could start. The resolver now answers for
# a subdirectory ecosystem (lib/prepare-environment.sh, unit-tested in
# tests/lib/prepare-environment.test.sh), and detect-commands.md forbids the mutating
# install for the cases the resolver still declines to guess.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "lib/prepare-environment.sh	\\(cd \\\$dir && "
  "lib/prepare-environment.sh	ecosystem_subdirs"
  "lib/prepare-environment.sh	command_dirs"
  "skills/cycle/references/detect-commands.md	never hand-roll a lockfile-mutating install"
  "skills/cycle/references/detect-commands.md	npm ci"
  "skills/cycle/references/detect-commands.md	pnpm install --frozen-lockfile"
  "skills/cycle/references/detect-commands.md	uv sync --frozen"
  "skills/cycle/references/detect-commands.md	(cd <subdir> && npm ci)"
  "skills/shared/feature-state-schema.md	webapp/frontend && npm ci"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: missing file $f"
    FAIL=$((FAIL + 1))
    continue
  fi
  if grep -qiF -- "$rx" "$f" 2>/dev/null || grep -qiE -- "$rx" "$f" 2>/dev/null; then
    echo "PASS: $f carries '$rx'"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $f is missing '$rx'"
    FAIL=$((FAIL + 1))
  fi
done

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
