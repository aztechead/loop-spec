#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/verification-grounding-lint.sh"
WORK="${TMPDIR:-/tmp}/verification-grounding-lint-test-$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/tests" "$WORK/workspace/repo-a/src" "$WORK/workspace/repo-b/tests"
printf 'one\ntwo\nthree\n' > "$WORK/src/app.py"
printf 'test\n' > "$WORK/tests/app.test.py"
printf 'code\n' > "$WORK/workspace/repo-a/src/a.py"
printf 'test\n' > "$WORK/workspace/repo-b/tests/a.test.py"
cat > "$WORK/SPEC.md" <<'EOF'
## Success criteria
### Good Enough
- [ ] first criterion
### Exceptional
- [ ] stretch criterion
EOF

PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" artifact="$3"; shift 3
  local rc=0 output=""
  output="$(bash "$SCRIPT" "$artifact" "$@" 2>&1)" || rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS+1)); echo "PASS: $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $name (expected $expected, got $rc): $output"
  fi
}

cat > "$WORK/valid.md" <<'EOF'
# Verification

## Repository grounding
- criterion: SC-1 | implementation: src/app.py:2 - implements the behavior | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/no-integration.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/app.py:2 - implements the behavior | integration: none - standalone documentation contract has no runtime caller
EOF

cat > "$WORK/missing-criterion.md" <<'EOF'
## Repository grounding
- criterion: SC-2 | implementation: src/app.py:2 - implements the behavior | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/missing-file.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/missing.py:2 - invented reference | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/bad-line.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/app.py:99 - line is out of range | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/traversal.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: ../outside.py:1 - escapes the repository | integration: none - standalone behavior has no caller
EOF

cat > "$WORK/duplicate.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/app.py:1 - first row | integration: tests/app.test.py:1 - first integration
- criterion: SC-1 | implementation: src/app.py:2 - duplicate row | integration: tests/app.test.py:1 - duplicate integration
EOF

cat > "$WORK/workspace.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: repo-a/src/a.py:1 - implementation repository | integration: repo-b/tests/a.test.py:1 - integration repository
EOF

printf '# Verification\n' > "$WORK/no-section.md"

echo "=== verification-grounding-lint.sh tests ==="
check "valid evidence passes" 0 "$WORK/valid.md" --repo "$WORK" --criterion SC-1
sed 's/SC-1/GE-001/' "$WORK/valid.md" > "$WORK/spec-derived.md"
check "Good Enough IDs derive from SPEC" 0 "$WORK/spec-derived.md" --repo "$WORK" --spec "$WORK/SPEC.md"
check "explicit no-integration reason passes" 0 "$WORK/no-integration.md" --repo "$WORK" --criterion SC-1
check "missing section fails" 1 "$WORK/no-section.md" --repo "$WORK" --criterion SC-1
check "missing expected criterion fails" 1 "$WORK/missing-criterion.md" --repo "$WORK" --criterion SC-1
check "missing cited file fails" 1 "$WORK/missing-file.md" --repo "$WORK" --criterion SC-1
check "out-of-range line fails" 1 "$WORK/bad-line.md" --repo "$WORK" --criterion SC-1
check "path traversal fails" 1 "$WORK/traversal.md" --repo "$WORK" --criterion SC-1
check "duplicate criterion fails" 1 "$WORK/duplicate.md" --repo "$WORK" --criterion SC-1
check "workspace-relative evidence passes" 0 "$WORK/workspace.md" --repo "$WORK/workspace" --criterion SC-1
check "missing artifact fails" 1 "$WORK/absent.md" --repo "$WORK" --criterion SC-1

out="$(bash "$SCRIPT" "$WORK/valid.md" --repo "$WORK" --criterion SC-1)"
if [[ "$out" == "verification-grounding-lint: ok" ]]; then
  PASS=$((PASS+1)); echo "PASS: success output is stable"
else
  FAIL=$((FAIL+1)); echo "FAIL: success output is stable"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
