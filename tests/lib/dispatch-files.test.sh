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
    "goal": "A caller can use bar.",
    "files": ["src/foo.sh"],
    "blockedBy": [],
    "verifyCommand": "bash -n src/foo.sh",
    "expected": "syntax check passes",
    "acceptanceCriteria": ["foo is gone"],
    "steps": ["Add the rename", "Run the check"],
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
grep -q "A caller can use bar." "$brief" && r=ok || r=missing
check "brief carries goal" "ok" "$r"
grep -q "Expected: syntax check passes" "$brief" && r=ok || r=missing
check "brief carries expected result" "ok" "$r"
grep -q -- "- Run the check" "$brief" && r=ok || r=missing
check "brief carries steps" "ok" "$r"
grep -q "Produces: bar" "$brief" && r=ok || r=missing
check "brief carries interfaces" "ok" "$r"

# The brief renders the shared engineering contracts this task's files call for into
# one file beside it, so the implementer reads one file instead of opening up to eight.
cat > "$FDIR/tasks.json" <<'EOF'
[
  {
    "id": "task-003",
    "subject": "add helper",
    "brief": "Add a helper and its test.",
    "files": ["lib/x.sh", "tests/lib/x.test.sh"],
    "blockedBy": [],
    "verifyCommand": "true",
    "acceptanceCriteria": ["works"]
  }
]
EOF
bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-003 --out "$WORK/code-brief.md" >/dev/null
check "brief: names the rendered contracts file under Read first" "1" "$(grep -c '^## Read first' "$WORK/code-brief.md")"
check "brief: contracts file exists beside the brief, named by task id" "1" "$([[ -f "$WORK/task-003-contracts.md" ]] && echo 1 || echo 0)"
check "contracts: code task renders human-code" "1" "$(grep -c '<!-- source: .*/human-code.md -->' "$WORK/task-003-contracts.md")"
check "contracts: test file renders writing-good-tests" "1" "$(grep -c '<!-- source: .*/writing-good-tests.md -->' "$WORK/task-003-contracts.md")"
check "contracts: code-only task skips human-docs" "0" "$(grep -c '<!-- source: .*/human-docs.md -->' "$WORK/task-003-contracts.md")"
check "contracts: the always set is present" "3" "$(grep -cE '<!-- source: .*/(engineering-directives|implementer-contract|execution-discipline).md -->' "$WORK/task-003-contracts.md")"
check "contracts: engineering code directives are rendered" "1" "$(grep -c '^## Code directives$' "$WORK/task-003-contracts.md")"
check "contracts: engineering version evidence is rendered" "1" "$(grep -c '^## Version evidence$' "$WORK/task-003-contracts.md")"
check "contracts: engineering test directives are rendered" "1" "$(grep -c '^## Test directives$' "$WORK/task-003-contracts.md")"
check "contracts: engineering phase handoff is omitted" "0" "$(grep -c '^## Phase handoff directives' "$WORK/task-003-contracts.md" || true)"
check "contracts: version evidence body is retained" "1" "$(grep -c 'Read the repository' "$WORK/task-003-contracts.md")"
check "contracts: TDD body is retained" "1" "$(grep -c 'Write the failing test first' "$WORK/task-003-contracts.md")"
check "contracts: seven-rung simplicity body is retained" "1" "$(grep -c '(7) Only then:' "$WORK/task-003-contracts.md")"
check "contracts: validation exception is retained" "1" "$(grep -c 'cut input validation at trust boundaries' "$WORK/task-003-contracts.md")"
check "contracts: security accessibility exceptions are retained" "1" "$(grep -c 'security, accessibility' "$WORK/task-003-contracts.md")"
check "contracts: probe fallback body is retained" "1" "$(grep -c 'When no path is available' "$WORK/task-003-contracts.md")"
check "contracts: diagnostic references defer full-source reads" "2" "$(grep -c 'consult only if a probe needs interpretation' "$WORK/task-003-contracts.md")"
check "contracts: laziness compact directive is rendered" "1" "$(grep -c '^> Rendered sections: Compact directive' "$WORK/task-003-contracts.md")"
check "contracts: laziness historical rungs are omitted" "0" "$(grep -c '^## Rungs 1 and 2' "$WORK/task-003-contracts.md" || true)"

cat > "$FDIR/tasks.json" <<'EOF'
[
  {
    "id": "task-004",
    "subject": "update readme",
    "brief": "Update README.",
    "files": ["README.md"],
    "blockedBy": [],
    "verifyCommand": "true",
    "acceptanceCriteria": ["updated"]
  }
]
EOF
bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-004 --out "$WORK/docs-brief.md" >/dev/null
check "contracts: docs-only task renders human-docs" "1" "$(grep -c '<!-- source: .*/human-docs.md -->' "$WORK/task-004-contracts.md")"
check "contracts: docs-only task skips human-code" "0" "$(grep -c '<!-- source: .*/human-code.md -->' "$WORK/task-004-contracts.md")"

# A standalone spec/ directory is a conventional test location (for example
# Ruby RSpec), so it pulls in writing-good-tests just like tests/ and __tests__/.
cat > "$FDIR/tasks.json" <<'EOF'
[
  {
    "id": "task-006",
    "subject": "update spec skill",
    "brief": "Edit the spec skill.",
    "files": ["spec/models/item_spec.rb"],
    "blockedBy": [],
    "verifyCommand": "true",
    "acceptanceCriteria": ["updated"]
  }
]
EOF
bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-006 --out "$WORK/spec-dir-brief.md" >/dev/null
check "contracts: a standalone spec/ test path renders writing-good-tests" "1" "$(grep -c '<!-- source: .*/writing-good-tests.md -->' "$WORK/task-006-contracts.md")"

# MDX can contain executable examples as well as human-facing docs, so it gets
# both contracts. A nested __tests__/spec path is a test path by its shape.
cat > "$FDIR/tasks.json" <<'EOF'
[
  {
    "id": "task-007",
    "subject": "update component",
    "brief": "Update the MDX component and its spec.",
    "files": ["docs/example.mdx", "src/__tests__/spec/component.test.ts"],
    "blockedBy": [],
    "verifyCommand": "true",
    "acceptanceCriteria": ["updated"]
  }
]
EOF
bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-007 --out "$WORK/mdx-brief.md" >/dev/null
check "contracts: MDX task renders human-docs" "1" "$(grep -c '<!-- source: .*/human-docs.md -->' "$WORK/task-007-contracts.md")"
check "contracts: MDX task renders human-code" "1" "$(grep -c '<!-- source: .*/human-code.md -->' "$WORK/task-007-contracts.md")"
check "contracts: nested __tests__/spec task renders writing-good-tests" "1" "$(grep -c '<!-- source: .*/writing-good-tests.md -->' "$WORK/task-007-contracts.md")"
check "contracts: approach selection source stays outside bundle" "0" "$(grep -c '<!-- source: .*/approach-selection.md -->' "$WORK/task-007-contracts.md" || true)"

cat > "$FDIR/tasks.json" <<'EOF'
[
  {
    "id": "task-008",
    "subject": "update guide",
    "brief": "Update the executable MDX guide.",
    "files": ["docs/guide.mdx"],
    "blockedBy": [],
    "verifyCommand": "true",
    "acceptanceCriteria": ["updated"]
  }
]
EOF
bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-008 --out "$WORK/mdx-only-brief.md" >/dev/null
check "contracts: MDX-only task renders human-docs" "1" "$(grep -c '<!-- source: .*/human-docs.md -->' "$WORK/task-008-contracts.md")"
check "contracts: MDX-only task renders human-code" "1" "$(grep -c '<!-- source: .*/human-code.md -->' "$WORK/task-008-contracts.md")"

# A missing contract source must fail the brief loudly rather than write a Read-first
# pointer at a file that was never rendered.
PLUGIN="$WORK/plugin"; mkdir -p "$PLUGIN/lib" "$PLUGIN/skills/shared"
cp "$ROOT/lib/dispatch-files.sh" "$PLUGIN/lib/dispatch-files.sh"
for f in "$ROOT"/skills/shared/*.md; do
  base="$(basename "$f")"
  [[ "$base" == "human-docs.md" ]] && continue
  cp "$f" "$PLUGIN/skills/shared/$base"
done
MISSING="$WORK/missing-contract"; mkdir -p "$MISSING"
printf '[{"id":"task-005","subject":"update readme","brief":"Update README.","files":["README.md"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["updated"]}]' > "$MISSING/tasks.json"
ec=0; err="$(bash "$PLUGIN/lib/dispatch-files.sh" brief --feature-dir "$MISSING" --task-id task-005 2>&1 >/dev/null)" || ec=$?
check "a missing contract source fails the brief loudly" "2" "$ec"
grep -q "contract source missing" <<<"$err" && r=ok || r=missing
check "the missing-contract error names the source" "ok" "$r"

# A required section missing from an otherwise present source must fail closed.
cp "$ROOT/skills/shared/human-docs.md" "$PLUGIN/skills/shared/human-docs.md"
python3 - "$PLUGIN/skills/shared/engineering-directives.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
text = text.replace("## Version evidence\n", "", 1)
open(p, "w", encoding="utf-8").write(text)
PY
ec=0; err="$(bash "$PLUGIN/lib/dispatch-files.sh" brief --feature-dir "$MISSING" --task-id task-005 2>&1 >/dev/null)" || ec=$?
check "a missing required contract section fails the brief" "2" "$ec"
check "the missing-section error names the required heading" "1" "$(grep -c 'required contract section missing.*Version evidence' <<<"$err")"

# The brief must carry fields produced by PLAN extraction, not only fields hand-built
# by a caller. This catches loss between the durable Markdown artifact and dispatch.
cat > "$FDIR/PLAN.md" <<'EOF'
## Tasks
### task-001: extracted task
**Goal:** caller gains the extracted capability
**Files:**
- src/extracted.sh
**Verify:** `true` -> passes
**Acceptance criteria:**
- [ ] extracted criterion
**Steps:**
- [ ] extracted step
**BlockedBy:** []
EOF
bash "$ROOT/lib/plan-tasks.sh" extract "$FDIR/PLAN.md" > "$FDIR/tasks.json"
brief_extracted=$(bash "$SCRIPT" brief --feature-dir "$FDIR" --task-id task-001)
grep -q "caller gains the extracted capability" "$brief_extracted" && r=ok || r=missing
check "brief carries extracted goal" "ok" "$r"
grep -q -- "- extracted step" "$brief_extracted" && r=ok || r=missing
check "brief carries extracted steps" "ok" "$r"
grep -q "Expected: passes" "$brief_extracted" && r=ok || r=missing
check "brief carries extracted expected result" "ok" "$r"

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

git -C "$REPO" commit --allow-empty -qm "feat: NO_JIRA verified no change"
EMPTY_HEAD=$(git -C "$REPO" rev-parse HEAD)
pkg_empty=$(bash "$SCRIPT" package --repo "$REPO" --base "$HEAD_SHA" --head "$EMPTY_HEAD" --out "$FDIR/dispatch/no-code-change.md")
check "package permits a distinct empty commit" "$FDIR/dispatch/no-code-change.md" "$pkg_empty"
check "package labels a distinct empty commit for review" "1" "$(grep -c '^## No code changes$' "$pkg_empty")"
check "package requires verification for a no-code-change commit" "1" "$(grep -c 'verify the current tree against the task brief' "$pkg_empty")"

ec=0; bash "$SCRIPT" package --repo "$REPO" --base "$BASE" --head "$BASE" --out "$FDIR/dispatch/empty.md" >/dev/null 2>&1 || ec=$?
check "package rejects head equal to recorded base" "2" "$ec"

echo ""

# The brief carries the slices an implementer used to read four artifacts for, and a
# merged chain's brief comes from the collapsed list.
SL="$WORK/sliced"; mkdir -p "$SL"; git -C "$SL" init -q
mkdir -p "$SL/.loop-spec/features/demo/dispatch" "$SL/docs/loop-spec/features/demo"
printf '{"slug":"demo","artifacts":{"plan":"docs/loop-spec/features/demo/PLAN.md"}}' > "$SL/.loop-spec/features/demo/feature.json"
printf '# Plan\n\n## Global constraints\n\n<!-- c\nthis hidden continuation must not leak\n-->\n- Never run apply. <!-- inline reason -->\nVisible constraint continuation.\nVisible before <!-- hidden --> visible after.\n\n## File map\n\n- x\n' > "$SL/docs/loop-spec/features/demo/PLAN.md"
printf '# Evidence\n\n- EVID-001 | t | claim: tofu 1.12 | cmd: tofu version | out: 1.12.6\n- EVID-010 | t | claim: ten | cmd: x | out: y\n' > "$SL/docs/loop-spec/features/demo/EVIDENCE.md"
printf '[{"id":"task-001","subject":"s","brief":"per EVID-001 keep it","files":["a"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["x"]}]' > "$SL/.loop-spec/features/demo/tasks.json"
printf '[{"id":"task-001","subject":"s","brief":"per EVID-001 keep it; merged","files":["a","b"],"memberIds":["task-001","task-002"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["x"]}]' > "$SL/.loop-spec/features/demo/dispatch/tasks-collapsed.json"
printf 'tofu: OpenTofu v1.12.6\n' > "$SL/.loop-spec/features/demo/dispatch/environment.txt"
sliced="$(bash "$SCRIPT" brief --feature-dir "$SL/.loop-spec/features/demo" --task-id task-001)"
check "brief inlines Global constraints verbatim" "1" "$(grep -c '^- Never run apply.$' "$sliced")"
check "brief drops multiline HTML comment continuation" "0" "$(grep -c 'hidden continuation must not leak' "$sliced" || true)"
check "brief keeps visible constraint continuation" "1" "$(grep -c '^Visible constraint continuation.$' "$sliced")"
check "brief preserves visible text around inline HTML comment" "1" "$(grep -c '^Visible before  visible after.$' "$sliced")"
check "brief drops the template comment" "0" "$(grep -c '<!--' "$sliced")"
check "brief carries only the cited EVID rows" "1,0" "$(grep -c '^- EVID-001 ' "$sliced"),$(grep -c 'EVID-010' "$sliced")"
check "brief carries the lead's environment facts" "1" "$(grep -c '^tofu: OpenTofu v1.12.6$' "$sliced")"
check "brief tells the implementer not to open the artifacts" "1" "$(grep -c 'Do not read SPEC.md, PLAN.md, PATTERNS.md, or EVIDENCE.md' "$sliced")"
check "brief prefers the collapsed task" "1" "$(grep -c '^- b$' "$sliced")"
check "brief lists batch members" "1" "$(grep -c '^- task-002$' "$sliced")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
