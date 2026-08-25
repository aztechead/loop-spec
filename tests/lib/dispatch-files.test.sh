#!/usr/bin/env bash
# Tests for lib/dispatch-files.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/dispatch-files.sh"
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

WORK="${TMPDIR:-/tmp}/dispatch-files-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat"
FDIR="$WORK/feat"

cat > "$FDIR/tasks.json" <<'EOF'
[
  {
    "id": "task-001",
    "subject": "rename foo",
    "brief": "Rename foo to bar in one file.",
    "files": ["src/foo.sh"],
    "blockedBy": [],
    "verifyCommand": "bash -n src/foo.sh",
    "acceptanceCriteria": ["foo is gone"],
    "interfaces": {"consumes": "none", "produces": "bar"},
    "batchGroup": "rename-foo"
  }
]
EOF

ec=0
bash "$SCRIPT" brief >/dev/null 2>&1 || ec=$?
check "brief without args exits 2" "2" "$ec"

brief=$(bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-001)
check "brief path default" "$FDIR/dispatch/task-001-brief.md" "$brief"
[[ -f "$brief" ]] && r=ok || r=missing
check "brief file exists" "ok" "$r"
grep -q "rename foo" "$brief" && r=ok || r=missing
check "brief carries subject" "ok" "$r"
grep -q "src/foo.sh" "$brief" && r=ok || r=missing
check "brief carries files" "ok" "$r"
grep -q "Produces: bar" "$brief" && r=ok || r=missing
check "brief carries interfaces" "ok" "$r"

report=$(bash "$SCRIPT" report-path --feature-dir "$FDIR" --task-id task-001)
check "report-path" "$FDIR/dispatch/task-001-report.md" "$report"

ec=0
bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-999 >/dev/null 2>&1 || ec=$?
check "unknown task exits 2" "2" "$ec"

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m init
BASE=$(git -C "$REPO" rev-parse HEAD)
printf 'b\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m change
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

ec=0
bash "$SCRIPT" package --repo "$REPO" --base HEAD~1 --head "$HEAD_SHA" >/dev/null 2>&1 || ec=$?
check "HEAD~1 as BASE exits 2" "2" "$ec"

pkg=$(bash "$SCRIPT" package --repo "$REPO" --base "$BASE" --head "$HEAD_SHA" --out "$FDIR/dispatch/pkg.md")
check "package path" "$FDIR/dispatch/pkg.md" "$pkg"
grep -q "$BASE..$HEAD_SHA" "$pkg" && r=ok || r=missing
check "package names the range" "ok" "$r"
grep -q "a.txt" "$pkg" && r=ok || r=missing
check "package lists changed files" "ok" "$r"
grep -q "^## Diff$" "$pkg" && r=ok || r=missing
check "package includes the diff" "ok" "$r"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
