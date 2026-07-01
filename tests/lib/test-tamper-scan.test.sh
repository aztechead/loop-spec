#!/usr/bin/env bash
# Tests for lib/test-tamper-scan.sh (anti-reward-hacking gate).
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/test-tamper-scan.sh"
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

WORK="${TMPDIR:-/tmp}/tamper-scan-test.$$"
trap 'rm -rf "$WORK"' EXIT

make_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m "$2"
}

# === Case A: clean diff (source change + new test) -> exit 0 ===
R="$WORK/a"; make_repo "$R"
mkdir -p "$R/tests"
echo 'def test_ok(): assert True' > "$R/tests/test_ok.py"
commit_all "$R" base
base="$(git -C "$R" rev-parse HEAD)"
echo 'x = 1' > "$R/app.py"
echo 'def test_new(): assert True' > "$R/tests/test_new.py"
commit_all "$R" feature
ec=0; bash "$SCRIPT" "$base" "$R" >/dev/null 2>&1 || ec=$?
check "A: clean diff exits 0" "0" "$ec"

# === Case B: deleted test file -> exit 1, named ===
R="$WORK/b"; make_repo "$R"
mkdir -p "$R/tests"
echo 'def test_x(): assert True' > "$R/tests/test_x.py"
commit_all "$R" base
base="$(git -C "$R" rev-parse HEAD)"
rm "$R/tests/test_x.py"
commit_all "$R" delete
ec=0; out="$(bash "$SCRIPT" "$base" "$R" 2>&1)" || ec=$?
check "B: deleted test exits 1" "1" "$ec"
echo "$out" | grep -qF "tests/test_x.py" && named=yes || named=no
check "B: deleted test named" "yes" "$named"

# === Case C: skip annotation added to test file -> exit 1 ===
R="$WORK/c"; make_repo "$R"
mkdir -p "$R/tests"
printf 'def test_y():\n    assert True\n' > "$R/tests/test_y.py"
commit_all "$R" base
base="$(git -C "$R" rev-parse HEAD)"
printf 'import pytest\n@pytest.mark.skip\ndef test_y():\n    assert True\n' > "$R/tests/test_y.py"
commit_all "$R" skipit
ec=0; bash "$SCRIPT" "$base" "$R" >/dev/null 2>&1 || ec=$?
check "C: added @pytest.mark.skip exits 1" "1" "$ec"

# === Case D: .only added in JS spec -> exit 1 ===
R="$WORK/d"; make_repo "$R"
mkdir -p "$R/src"
printf "it('works', f);\n" > "$R/src/app.spec.js"
commit_all "$R" base
base="$(git -C "$R" rev-parse HEAD)"
printf "it.only('works', f);\n" > "$R/src/app.spec.js"
commit_all "$R" focus
ec=0; bash "$SCRIPT" "$base" "$R" >/dev/null 2>&1 || ec=$?
check "D: it.only added exits 1" "1" "$ec"

# === Case E: '|| true' added to test script -> exit 1 ===
R="$WORK/e"; make_repo "$R"
mkdir -p "$R/tests"
printf 'run_suite\n' > "$R/tests/run.sh"
commit_all "$R" base
base="$(git -C "$R" rev-parse HEAD)"
printf 'run_suite || true\n' > "$R/tests/run.sh"
commit_all "$R" swallow
ec=0; bash "$SCRIPT" "$base" "$R" >/dev/null 2>&1 || ec=$?
check "E: || true added exits 1" "1" "$ec"

# === Case F: pre-existing skip untouched -> exit 0 (only ADDED lines scanned) ===
R="$WORK/f"; make_repo "$R"
mkdir -p "$R/tests"
printf 'import pytest\n@pytest.mark.skip\ndef test_z():\n    assert True\n' > "$R/tests/test_z.py"
commit_all "$R" base
base="$(git -C "$R" rev-parse HEAD)"
echo 'x = 2' > "$R/app.py"
commit_all "$R" unrelated
ec=0; bash "$SCRIPT" "$base" "$R" >/dev/null 2>&1 || ec=$?
check "F: pre-existing skip exits 0" "0" "$ec"

# === Case G: skip word added in NON-test file -> exit 0 (scope guard) ===
R="$WORK/g"; make_repo "$R"
echo 'x = 1' > "$R/app.py"
commit_all "$R" base
base="$(git -C "$R" rev-parse HEAD)"
printf 'def frobnicate():\n    unittest.skip("not a test file")\n' > "$R/app.py"
commit_all "$R" nontest
ec=0; bash "$SCRIPT" "$base" "$R" >/dev/null 2>&1 || ec=$?
check "G: skip in non-test file exits 0" "0" "$ec"

# === Case H: bad invocation ===
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "H: missing base-sha exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
