#!/usr/bin/env bash
# Tests for lib/placeholder-scan.sh — no stub implementations survive VERIFY.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/placeholder-scan.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/placeholder-scan-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

git -C "$WORK" init -q -b main
git -C "$WORK" config user.email t@t
git -C "$WORK" config user.name t
printf 'def f():\n    return 1\n' > "$WORK/app.py"
printf '# notes\nTODO: existing doc note\n' > "$WORK/NOTES.md"
git -C "$WORK" add . && git -C "$WORK" commit -qm base
BASE="$(git -C "$WORK" rev-parse HEAD)"

# Clean diff -> ok.
printf 'def f():\n    return 2\n' > "$WORK/app.py"
git -C "$WORK" add . && git -C "$WORK" commit -qm change
bash "$LIB" "$BASE" "$WORK" >/dev/null 2>&1
check "clean diff ok (exit 0)" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Added TODO in code -> flagged.
printf 'def f():\n    # TODO: finish this\n    return 2\n' > "$WORK/app.py"
git -C "$WORK" add . && git -C "$WORK" commit -qm todo
out="$(bash "$LIB" "$BASE" "$WORK" 2>/dev/null)"; rc=$?
check "added TODO flagged (exit 1)" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "flag names file:line and marker" "$(grep -q "app.py:2: placeholder marker 'TODO'" <<<"$out" && echo 1 || echo 0)"
check "final answer line with reason" "$(grep -q '^placeholder-scan: 1 signal(s)' <<<"$out" && echo 1 || echo 0)"

# NotImplementedError -> flagged.
printf 'def f():\n    raise NotImplementedError\n' > "$WORK/app.py"
git -C "$WORK" add . && git -C "$WORK" commit -qm stub
bash "$LIB" "$BASE" "$WORK" >/dev/null 2>&1
check "NotImplementedError flagged" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# "not implemented" throw -> flagged.
printf 'export function f() { throw new Error("not implemented"); }\n' > "$WORK/app.ts"
git -C "$WORK" add . && git -C "$WORK" commit -qm ts-stub
bash "$LIB" "$BASE" "$WORK" >/dev/null 2>&1
check "'not implemented' throw flagged" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Markers in markdown are exempt (artifacts discuss TODOs legitimately).
git -C "$WORK" checkout -q "$BASE" -- . 2>/dev/null; git -C "$WORK" reset -q "$BASE" --hard
git -C "$WORK" checkout -q -b docs
printf '# notes\nTODO: existing doc note\nTODO: new doc note\n' > "$WORK/NOTES.md"
git -C "$WORK" add . && git -C "$WORK" commit -qm docs
bash "$LIB" "$BASE" "$WORK" >/dev/null 2>&1
check "markdown TODO exempt" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Pre-existing marker (not in diff) never fires.
git -C "$WORK" reset -q "$BASE" --hard
git -C "$WORK" checkout -q -b pre
printf 'def g():\n    # FIXME: old\n    return 1\n' > "$WORK/old.py"
git -C "$WORK" add . && git -C "$WORK" commit -qm old
PRE="$(git -C "$WORK" rev-parse HEAD)"
printf 'def g():\n    # FIXME: old\n    return 2\n' > "$WORK/old.py"
git -C "$WORK" add . && git -C "$WORK" commit -qm touch-only
bash "$LIB" "$PRE" "$WORK" >/dev/null 2>&1
check "pre-existing marker not flagged" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Word boundary: 'TODOS' as part of an identifier does not fire... but plain
# HACK does.
printf 'const AUTODOSE = 1;\n' > "$WORK/ok.js"
git -C "$WORK" add . && git -C "$WORK" commit -qm ident
bash "$LIB" "$PRE" "$WORK" >/dev/null 2>&1
check "identifier containing todo not flagged" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Bad invocation.
bash "$LIB" >/dev/null 2>&1
check "missing args exit 2" "$([[ $? -eq 2 ]] && echo 1 || echo 0)"
bash "$LIB" HEAD /nonexistent-dir-xyz >/dev/null 2>&1
check "not a repo exit 2" "$([[ $? -eq 2 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
