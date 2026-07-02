#!/usr/bin/env bash
# Tests for lib/parse-invocation.sh (inline token grammar, single implementation).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/parse-invocation.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

field() { jq -r ".$2" <<<"$1"; }

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/parse-invocation-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# bad invocation
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "no subcommand exits 1" "1" "$ec"

# plain description
out="$(bash "$SCRIPT" parse "add csv export to reports")"
check "description mode" "description" "$(field "$out" mode)"
check "description title" "add csv export to reports" "$(field "$out" title)"
check "description slug" "add-csv-export-to-reports" "$(field "$out" slug)"
check "default style" "auto" "$(field "$out" style)"
check "default autonomous" "false" "$(field "$out" autonomous)"
check "default greenfield" "false" "$(field "$out" greenfield)"

# style token stripped from anywhere in the text
out="$(bash "$SCRIPT" parse "add csv export style:step to reports")"
check "style parsed mid-text" "step" "$(field "$out" style)"
check "style stripped from title" "add csv export to reports" "$(field "$out" title)"

# legacy tokens stripped, reported, never in the title (the oracle-pollution bug)
out="$(bash "$SCRIPT" parse "tier:quality add csv export preset:full")"
check "legacy stripped from title" "add csv export" "$(field "$out" title)"
check "legacy list" "tier:quality preset:full" "$(jq -r '.legacy | join(" ")' <<<"$out")"

# autonomous token
out="$(bash "$SCRIPT" parse "autonomous add csv export")"
check "autonomous parsed" "true" "$(field "$out" autonomous)"
check "autonomous stripped from title" "add csv export" "$(field "$out" title)"

# leading new = greenfield, in any order with other leading tokens
out="$(bash "$SCRIPT" parse "new build a todo app")"
check "leading new is greenfield" "true" "$(field "$out" greenfield)"
check "new stripped from title" "build a todo app" "$(field "$out" title)"
out="$(bash "$SCRIPT" parse "autonomous new build a todo app")"
check "new after autonomous still greenfield" "true" "$(field "$out" greenfield)"
check "autonomous+new title" "build a todo app" "$(field "$out" title)"

# new after title text has started is ordinary text
out="$(bash "$SCRIPT" parse "add new export button")"
check "mid-text new not greenfield" "false" "$(field "$out" greenfield)"
check "mid-text new kept in title" "add new export button" "$(field "$out" title)"

# --no-run
out="$(bash "$SCRIPT" parse "--no-run some pasted text")"
check "no-run parsed" "true" "$(field "$out" no_run)"
check "no-run stripped" "some pasted text" "$(field "$out" title)"

# backlog mode
out="$(bash "$SCRIPT" parse "backlog")"
check "backlog mode" "backlog" "$(field "$out" mode)"
check "backlog empty title" "" "$(field "$out" title)"
out="$(bash "$SCRIPT" parse "backlog autonomous")"
check "backlog with autonomous" "backlog" "$(field "$out" mode)"
check "backlog autonomous flag" "true" "$(field "$out" autonomous)"

# spec-file mode: single token resolving to a readable .md
echo "# My Spec" > "$WORK/spec.md"
out="$(cd "$WORK" && bash "$SCRIPT" parse "spec.md")"
check "spec-file mode" "spec-file" "$(field "$out" mode)"
check "spec path absolutized" "$WORK/spec.md" "$(field "$out" spec_path)"
out="$(cd "$WORK" && bash "$SCRIPT" parse "autonomous spec.md")"
check "spec-file with autonomous" "spec-file" "$(field "$out" mode)"

# a .md path that does not exist is a description, not spec-file
out="$(bash "$SCRIPT" parse "no-such-file.md")"
check "missing .md falls back to description" "description" "$(field "$out" mode)"
check "missing .md null spec_path" "null" "$(field "$out" spec_path)"

# multi-token text where one word ends in .md stays a description
out="$(cd "$WORK" && bash "$SCRIPT" parse "update spec.md docs")"
check "multi-token .md is description" "description" "$(field "$out" mode)"

# bare invocation
out="$(bash "$SCRIPT" parse "")"
check "bare mode" "bare" "$(field "$out" mode)"
out="$(bash "$SCRIPT" parse "autonomous")"
check "tokens-only is bare" "bare" "$(field "$out" mode)"
check "tokens-only autonomous" "true" "$(field "$out" autonomous)"

# word-split vs single-blob invocation parse identically
a="$(bash "$SCRIPT" parse "autonomous new build app")"
b="$(bash "$SCRIPT" parse autonomous new build app)"
check "blob and word-split identical" "$a" "$b"

# glob characters in the text never expand against cwd
mkdir -p "$WORK/globdir"; touch "$WORK/globdir/a.md" "$WORK/globdir/b.md"
out="$(cd "$WORK/globdir" && bash "$SCRIPT" parse "fix *.md handling in exporter")"
check "glob chars stay literal" "fix *.md handling in exporter" "$(field "$out" title)"
check "glob text is description" "description" "$(field "$out" mode)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
