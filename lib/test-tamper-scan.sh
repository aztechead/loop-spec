#!/usr/bin/env bash
# Detect test tampering on a feature branch (anti-reward-hacking gate).
#
# The classic agent failure mode (documented across Ralph-loop practice) is making
# the oracle pass instead of the code work: deleting a failing test, adding a skip
# annotation, focusing a subset with .only, or swallowing a test command's exit code
# with `|| true`. VERIFY runs the suite the implementer may have edited, so this scan
# runs FIRST and fails fast on any tampering signal in the diff.
#
# Usage: test-tamper-scan.sh <base-sha> [repo-path]
#   repo-path defaults to "." (single-repo mode; workspace mode calls once per repo).
#
# Exit codes:
#   0  no tampering signals
#   1  one or more signals found (printed to stdout as "file: signal")
#   2  bad invocation / not a git repo
#
# Scope: files whose path matches the test-file heuristic (test/spec segments or
# suffixes). Only ADDED lines are scanned for skip/focus/swallow patterns, so
# pre-existing skips never fire.
set -euo pipefail

base_sha="${1:-}"
repo="${2:-.}"

if [[ -z "$base_sha" ]]; then
  echo "usage: test-tamper-scan.sh <base-sha> [repo-path]" >&2
  exit 2
fi
if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "test-tamper-scan: not a git repo: $repo" >&2
  exit 2
fi

# Test-file heuristic (path-based, language-agnostic).
is_test_file() {
  local f="$1"
  [[ "$f" =~ (^|/)(tests?|specs?|__tests__)(/|$) ]] && return 0
  [[ "$f" =~ (\.test\.|\.spec\.|_test\.|_spec\.) ]] && return 0
  [[ "$f" =~ (^|/)test_[^/]+\.py$ ]] && return 0
  return 1
}

findings=()

# 1) Deleted test files.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if is_test_file "$f"; then
    findings+=("$f: test file DELETED")
  fi
done < <(git -C "$repo" diff --diff-filter=D --name-only "${base_sha}..HEAD" 2>/dev/null)

# 2) Skip / focus / exit-code-swallow patterns on ADDED lines of changed test files.
# Word-ish anchors keep false positives down (e.g. "skipped" in a string won't match
# the annotation forms below).
# `xit(`/`xdescribe(`/`xtest(` are Jasmine/Jest skipped-test forms. They need a
# LEFT boundary: without one, `xit\(` matches the tail of `e|xit(`, so every
# sys.exit(), os._exit() and plain exit() in a shell or Python test reads as a
# skipped test. That false positive fires on any repo whose tests call exit().
skip_re='(it|test|describe|context)\.(skip|only)\(|(^|[^A-Za-z0-9_.])(xit|xdescribe|xtest)\(|@pytest\.mark\.skip|@unittest\.skip|unittest\.skip\(|t\.Skip\(|#\[ignore\]|@Disabled|@Ignore'
swallow_re='\|\|[[:space:]]*true'
# The signal is a TEST COMMAND's exit code being discarded. Fixture setup and
# teardown are not test commands, and a cleanup that fails must not fail the
# suite -- `trap 'rm -rf "$WORK"' EXIT` is correct, not tampering. Exempt lines
# whose command is housekeeping. Anything that runs the thing under test still
# flags.
swallow_exempt_re='^[[:space:]]*(trap|rm|rmdir|chmod|chown|mkdir|cp|mv|touch|unset|kill|pkill|popd|pushd|deactivate)[[:space:]]'

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  is_test_file "$f" || continue
  added="$(git -C "$repo" diff "${base_sha}..HEAD" -- "$f" 2>/dev/null | grep -E '^\+[^+]' || true)"
  [[ -z "$added" ]] && continue
  if echo "$added" | grep -qE "$skip_re"; then
    while IFS= read -r line; do
      findings+=("$f: skip/focus added: ${line#+}")
    done < <(echo "$added" | grep -E "$skip_re" | head -5)
  fi
  swallowed="$(echo "$added" | grep -E "$swallow_re" | sed 's/^+//' | grep -vE "$swallow_exempt_re" || true)"
  if [[ -n "$swallowed" ]]; then
    while IFS= read -r line; do
      findings+=("$f: exit code swallowed: $line")
    done < <(printf '%s\n' "$swallowed" | head -5)
  fi
done < <(git -C "$repo" diff --diff-filter=ACMR --name-only "${base_sha}..HEAD" 2>/dev/null)

if [[ ${#findings[@]} -eq 0 ]]; then
  exit 0
fi

echo "Test tampering signals:"
for item in "${findings[@]}"; do
  echo "  - $item"
done
exit 1
