#!/usr/bin/env bash
# Tests for lib/detect-test-cmd.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/detect-test-cmd.sh"
PASS=0
FAIL=0

WORK="${TMPDIR:-/tmp}/loop-spec-detect-test-cmd.$$"
trap 'rm -rf "$WORK"' EXIT

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

check_exit() {
  local name="$1"
  local expected_exit="$2"
  local actual_exit="$3"
  if [[ "$actual_exit" == "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

# A: Makefile with test: target -> make test
DIR="$WORK/makefile-test"
mkdir -p "$DIR"
printf 'build:\n\t@echo building\n\ntest:\n\t@echo running tests\n' > "$DIR/Makefile"
got=$(cd "$DIR" && bash "$LIB")
check "A: Makefile with test: target -> make test" "make test" "$got"

# B: package.json -> npm test
DIR="$WORK/package-json"
mkdir -p "$DIR"
printf '{"name":"foo","scripts":{"test":"jest"}}\n' > "$DIR/package.json"
got=$(cd "$DIR" && bash "$LIB")
check "B: package.json -> npm test" "npm test" "$got"

# C: Cargo.toml -> cargo test
DIR="$WORK/cargo"
mkdir -p "$DIR"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "C: Cargo.toml -> cargo test" "cargo test" "$got"

# D: pyproject.toml -> python -m pytest
DIR="$WORK/pyproject"
mkdir -p "$DIR"
printf '[tool.pytest.ini_options]\ntestpaths = ["tests"]\n' > "$DIR/pyproject.toml"
got=$(cd "$DIR" && bash "$LIB")
check "D: pyproject.toml -> python -m pytest" "python -m pytest" "$got"

# E: setup.py -> python -m pytest
DIR="$WORK/setup-py"
mkdir -p "$DIR"
printf 'from setuptools import setup\nsetup(name="foo")\n' > "$DIR/setup.py"
got=$(cd "$DIR" && bash "$LIB")
check "E: setup.py -> python -m pytest" "python -m pytest" "$got"

# F: go.mod -> go test ./...
DIR="$WORK/go-mod"
mkdir -p "$DIR"
printf 'module example.com/foo\n\ngo 1.21\n' > "$DIR/go.mod"
got=$(cd "$DIR" && bash "$LIB")
check "F: go.mod -> go test ./..." "go test ./..." "$got"

# G: Makefile without test: target -> falls through to next marker; if only Makefile present and no test: target, should not emit make test
DIR="$WORK/makefile-no-test"
mkdir -p "$DIR"
printf 'build:\n\t@echo building\n' > "$DIR/Makefile"
got=$(cd "$DIR" && bash "$LIB")
check "G: Makefile without test: target -> empty output" "" "$got"

# H: no markers -> empty output, exit 0
DIR="$WORK/empty"
mkdir -p "$DIR"
exit_code=0
got=$(cd "$DIR" && bash "$LIB") || exit_code=$?
check "H: no markers -> empty output" "" "$got"
check_exit "H: no markers -> exit 0" "0" "$exit_code"

# I: priority - Makefile (with test:) wins over package.json
DIR="$WORK/priority-makefile"
mkdir -p "$DIR"
printf 'test:\n\t@echo running tests\n' > "$DIR/Makefile"
printf '{"name":"foo"}\n' > "$DIR/package.json"
got=$(cd "$DIR" && bash "$LIB")
check "I: Makefile wins over package.json" "make test" "$got"

# J: priority - package.json wins over Cargo.toml (no Makefile present)
DIR="$WORK/priority-package"
mkdir -p "$DIR"
printf '{"name":"foo"}\n' > "$DIR/package.json"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "J: package.json wins over Cargo.toml" "npm test" "$got"

# K: directory argument passed explicitly
DIR="$WORK/explicit-dir"
mkdir -p "$DIR"
printf 'module example.com/bar\n\ngo 1.21\n' > "$DIR/go.mod"
got=$(bash "$LIB" "$DIR")
check "K: explicit directory argument" "go test ./..." "$got"

# L: exit 0 in all cases
for case_name in "makefile-test" "package-json" "cargo" "pyproject" "setup-py" "go-mod" "empty"; do
  exit_code=0
  (cd "$WORK/$case_name" && bash "$LIB") || exit_code=$?
  check_exit "L: exit 0 for $case_name" "0" "$exit_code"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
