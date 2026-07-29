#!/usr/bin/env bash
# Detect placeholder/stub implementations on a feature branch.
#
# The complement of the no-deferral contract (skills/shared/no-deferral.md) at the
# CODE level: a TODO/FIXME comment, a NotImplementedError, or a "not implemented"
# throw in newly added lines is deferred scope written into the implementation —
# a full implementation was promised by the design, a stub shipped instead
# (documented across Ralph-loop practice: "no placeholder implementations").
# VERIFY runs this alongside the test-tamper scan, so a stub fails fast at the
# gate instead of surviving to the PR.
#
# Usage: placeholder-scan.sh <base-sha> [repo-path]
#   repo-path defaults to "." (single-repo mode; workspace mode calls once per repo).
#
# Exit codes:
#   0  no placeholder signals
#   1  one or more signals found (printed to stdout as "file:line: signal")
#   2  bad invocation / not a git repo
#
# Scope: only ADDED lines in the diff against <base-sha> are scanned, so
# pre-existing markers never fire. Markdown/docs files are excluded (artifacts
# legitimately discuss TODOs); test files are INCLUDED (a stubbed test is still
# a stub). One line, ANSWER + REASON: the matched marker is always printed.
set -euo pipefail

base_sha="${1:-}"
repo="${2:-.}"

if [[ -z "$base_sha" ]]; then
  echo "usage: placeholder-scan.sh <base-sha> [repo-path]" >&2
  exit 2
fi
if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "placeholder-scan: not a git repo: $repo" >&2
  exit 2
fi

# Placeholder markers (word-boundary where meaningful). Deliberately tight:
# "placeholder" itself is excluded (HTML input placeholders are legitimate).
PATTERN='(\b(TODO|FIXME|XXX|HACK)\b|NotImplementedError|raise NotImplemented\b|\bunimplemented!\(|\btodo!\(|not implemented|NotImplementedException|UnsupportedOperationException)'

findings=0
current_file=""
new_lineno=0
while IFS= read -r line; do
  case "$line" in
    +++\ b/*)
      current_file="${line#+++ b/}"
      ;;
    @@*)
      # @@ -a,b +c,d @@ — capture the new-file start line.
      new_lineno="$(sed -E 's/^@@ -[0-9]+(,[0-9]+)? \+([0-9]+).*/\2/' <<<"$line")"
      ;;
    +*)
      added="${line#+}"
      # Skip docs/markdown — artifacts legitimately discuss TODOs.
      if [[ -n "$current_file" && ! "$current_file" =~ \.(md|markdown|rst|txt)$ ]]; then
        match="$(grep -oE "$PATTERN" <<<"$added" | head -1 || true)"
        if [[ -n "$match" ]]; then
          echo "$current_file:$new_lineno: placeholder marker '$match' in added line — full implementations only; ship the code the design promised"
          findings=$((findings + 1))
        fi
      fi
      new_lineno=$((new_lineno + 1))
      ;;
    -*)
      : # removed line — new-file line number does not advance
      ;;
    *)
      new_lineno=$((new_lineno + 1))
      ;;
  esac
done < <(git -C "$repo" diff "$base_sha" --unified=0 -- . 2>/dev/null)

if [[ "$findings" -gt 0 ]]; then
  echo "placeholder-scan: $findings signal(s) (diff vs ${base_sha:0:12})"
  exit 1
fi
echo "placeholder-scan: ok (diff vs ${base_sha:0:12})"
