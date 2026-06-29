#!/usr/bin/env bash
# Meta-test: every *.test.sh in the repo MUST be registered in tests/run-all.sh.
# Prevents orphaned unit tests that silently never run in CI (how
# lib/ralph-remediation.test.sh and lib/pause-snapshot.test.sh went unexecuted).
#
# Scope: all *.test.sh under the repo EXCEPT
#   - this file (the meta-test references run-all.sh, not itself)
#   - skills/loop-runner/** (the bundled loop-runner ships its own runner, invoked as a
#     single suite by run-all.sh; its internal tests are not named *.test.sh anyway)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ALL="$REPO_ROOT/tests/run-all.sh"
SELF="tests/all-tests-registered.test.sh"

fail=0
pass=0

run_all_contents="$(cat "$RUN_ALL")"

while IFS= read -r f; do
  rel="${f#"$REPO_ROOT"/}"
  [[ "$rel" == "$SELF" ]] && continue
  case "$rel" in skills/loop-runner/*) continue;; esac
  if grep -qF "$rel" <<<"$run_all_contents"; then
    pass=$((pass+1))
  else
    echo "FAIL: $rel is not registered in tests/run-all.sh (orphaned test, never runs in CI)"
    fail=$((fail+1))
  fi
done < <(find "$REPO_ROOT" -name "*.test.sh" -not -path "*/node_modules/*" | sort)

echo "Results: $pass registered, $fail orphaned"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: every *.test.sh is registered in run-all.sh"
