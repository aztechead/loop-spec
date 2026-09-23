#!/usr/bin/env bash
# A message that tells the lead to run `bash lib/<script>` sends it to the target
# repository's own lib/, which in a consumer repository does not hold loop-spec (the
# 6.9.1 upstream report's RULES.md check). Every such hint names the resolved install
# path instead; this fails when a new one names the bare relative path.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
hits="$(grep -rnE "(bash|[Rr]un:?|[Rr]e-?run) [\"'\`]?lib/[a-z_/.-]+\.(sh|py)" lib hooks \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '\.test\.')"
if [[ -n "$hits" ]]; then
  echo "FAIL: a lead-facing hint names a repo-relative lib/ script; print the resolved path (\$SCRIPT_DIR/<script>):"
  echo "$hits"
  exit 1
fi
echo "PASS: no lead-facing hint names a repo-relative lib/ script"
