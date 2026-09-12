#!/usr/bin/env bash
# Every shipped shell script under lib/ and hooks/ runs under `set -euo pipefail`, or
# its `set` line says on the same line why it does not. One mode with one rule is what
# the peers with a bash layer do (Spec Kit: `set -e` everywhere; Superpowers:
# `set -euo pipefail`); this tree ran two modes side by side, decided per file with
# nothing recording the choice, so reviewers relitigated one script at a time.
#
# The one sanctioned relaxation is dropping -e, and it is a trailing comment on the
# `set` line, e.g.
#   set -uo pipefail  # collects each probe's exit code into one JSON answer
# so the reason travels with the line a reviewer reads. Any other mode fails. A sourced
# library takes the full mode: every sourcer runs it already, and `set -uo` in a sourced
# file cannot clear a caller's -e anyway. Tests (*.test.sh) are outside the rule: a
# runner that stops at its first failing check loses the rest of its report.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0

while IFS= read -r f; do
  rel="${f#"$REPO_ROOT"/}"
  line="$(grep -m1 -E '^[[:space:]]*set -' "$f" || true)"
  if [[ -z "$line" ]]; then
    echo "FAIL: $rel has no set line (set -euo pipefail, or set ... # <why not>)"
    fail=$((fail+1))
  elif [[ "$line" =~ ^[[:space:]]*set\ -euo\ pipefail([[:space:]]*|[[:space:]]+#.*)$ ]]; then
    pass=$((pass+1))
  elif [[ "$line" =~ ^[[:space:]]*set\ -uo\ pipefail[[:space:]]+#[[:space:]]*[^[:space:]].* ]]; then
    pass=$((pass+1))
  else
    echo "FAIL: $rel: '$line' is not set -euo pipefail and carries no same-line reason"
    fail=$((fail+1))
  fi
done < <(find "$REPO_ROOT/lib" "$REPO_ROOT/hooks" -name '*.sh' -not -name '*.test.sh' -not -path '*/node_modules/*' | sort)

echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
