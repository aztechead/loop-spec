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

# artifact-lint accepts an array for consumes/produces; the brief is prose an
# implementer reads, so an array joins instead of printing raw JSON.
cat > "$FDIR/tasks.json" <<'EOF'
[
  {
    "id": "task-002",
    "subject": "wire the bridge",
    "brief": "Wire it.",
    "files": ["src/bridge.sh"],
    "blockedBy": [],
    "verifyCommand": "true",
    "acceptanceCriteria": ["wired"],
    "interfaces": {"consumes": ["lib/a.sh api", "lib/b.sh api"], "produces": "lib/c.sh api"}
  }
]
EOF
brief2=$(bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-002)
grep -q "Consumes: lib/a.sh api, lib/b.sh api" "$brief2" && r=ok || r=missing
check "brief joins an interfaces array" "ok" "$r"
grep -q '\[' "$brief2" && r=json || r=ok
check "brief carries no raw JSON array" "ok" "$r"

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

# The brief carries the slices an implementer used to read four artifacts for, and a
# merged chain's brief comes from the collapsed list.
SL="$WORK/sliced"; mkdir -p "$SL"; git -C "$SL" init -q
mkdir -p "$SL/.loop-spec/features/demo/dispatch" "$SL/docs/loop-spec/features/demo"
printf '{"slug":"demo","artifacts":{"plan":"docs/loop-spec/features/demo/PLAN.md"}}' > "$SL/.loop-spec/features/demo/feature.json"
printf '# Plan\n\n## Global constraints\n\n<!-- c -->\n- Never run apply.\n\n## File map\n\n- x\n' > "$SL/docs/loop-spec/features/demo/PLAN.md"
printf '# Evidence\n\n- EVID-001 | t | claim: tofu 1.12 | cmd: tofu version | out: 1.12.6\n- EVID-010 | t | claim: ten | cmd: x | out: y\n' > "$SL/docs/loop-spec/features/demo/EVIDENCE.md"
printf '[{"id":"task-001","subject":"s","brief":"per EVID-001 keep it","files":["a"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["x"]}]' > "$SL/.loop-spec/features/demo/tasks.json"
printf '[{"id":"task-001","subject":"s","brief":"per EVID-001 keep it; merged","files":["a","b"],"memberIds":["task-001","task-002"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["x"]}]' > "$SL/.loop-spec/features/demo/dispatch/tasks-collapsed.json"
printf 'tofu: OpenTofu v1.12.6\n' > "$SL/.loop-spec/features/demo/dispatch/environment.txt"
sliced="$(bash "$SCRIPT" brief --feature-dir "$SL/.loop-spec/features/demo" --task-id task-001)"
check "brief inlines Global constraints verbatim" "1" "$(grep -c '^- Never run apply.$' "$sliced")"
check "brief drops the template comment" "0" "$(grep -c '<!--' "$sliced")"
check "brief carries only the cited EVID rows" "1,0" "$(grep -c '^- EVID-001 ' "$sliced"),$(grep -c 'EVID-010' "$sliced")"
check "brief carries the lead's environment facts" "1" "$(grep -c '^tofu: OpenTofu v1.12.6$' "$sliced")"
check "brief tells the implementer not to open the artifacts" "1" "$(grep -c 'Do not read SPEC.md, PLAN.md, PATTERNS.md, or EVIDENCE.md' "$sliced")"
check "brief prefers the collapsed task" "1" "$(grep -c '^- b$' "$sliced")"
check "brief lists batch members" "1" "$(grep -c '^- task-002$' "$sliced")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
