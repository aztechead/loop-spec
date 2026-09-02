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

# F2-F4: prepared Python environments use their owning runner.
DIR="$WORK/uv-python"
mkdir -p "$DIR"
touch "$DIR/pyproject.toml" "$DIR/uv.lock"
got=$(cd "$DIR" && bash "$LIB")
check "F2: uv.lock -> uv run pytest" "uv run pytest" "$got"

DIR="$WORK/poetry-python"
mkdir -p "$DIR"
touch "$DIR/pyproject.toml" "$DIR/poetry.lock"
got=$(cd "$DIR" && bash "$LIB")
check "F3: poetry.lock -> poetry run pytest" "poetry run pytest" "$got"

DIR="$WORK/venv-python"
mkdir -p "$DIR/.venv/bin"
touch "$DIR/pyproject.toml" "$DIR/.venv/bin/python"
chmod +x "$DIR/.venv/bin/python"
got=$(cd "$DIR" && bash "$LIB")
check "F4: prepared venv -> venv pytest" ".venv/bin/python -m pytest" "$got"

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

# J: polyglot — every matching language command, joined with && (no Makefile)
DIR="$WORK/priority-package"
mkdir -p "$DIR"
printf '{"name":"foo"}\n' > "$DIR/package.json"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "J: package.json + Cargo.toml join both commands" "npm test && cargo test" "$got"

# K: directory argument passed explicitly
DIR="$WORK/explicit-dir"
mkdir -p "$DIR"
printf 'module example.com/bar\n\ngo 1.21\n' > "$DIR/go.mod"
got=$(bash "$LIB" "$DIR")
check "K: explicit directory argument" "go test ./..." "$got"

# M: language-agnostic markers (Clojure, Elixir, JVM, Ruby, PHP)
DIR="$WORK/lein"
mkdir -p "$DIR"
printf '(defproject foo "0.1.0")\n' > "$DIR/project.clj"
got=$(cd "$DIR" && bash "$LIB")
check "M: project.clj -> lein test" "lein test" "$got"

DIR="$WORK/deps-edn"
mkdir -p "$DIR"
printf '{:paths ["src"]}\n' > "$DIR/deps.edn"
got=$(cd "$DIR" && bash "$LIB")
check "M: deps.edn -> clojure -M:test" "clojure -M:test" "$got"

DIR="$WORK/mix"
mkdir -p "$DIR"
printf 'defmodule Foo.MixProject do\nend\n' > "$DIR/mix.exs"
got=$(cd "$DIR" && bash "$LIB")
check "M: mix.exs -> mix test" "mix test" "$got"

DIR="$WORK/maven"
mkdir -p "$DIR"
printf '<project></project>\n' > "$DIR/pom.xml"
got=$(cd "$DIR" && bash "$LIB")
check "M: pom.xml -> mvn test" "mvn test" "$got"

DIR="$WORK/gradle"
mkdir -p "$DIR"
printf 'plugins {}\n' > "$DIR/build.gradle"
got=$(cd "$DIR" && bash "$LIB")
check "M: build.gradle -> gradle test" "gradle test" "$got"

DIR="$WORK/gradle-kts"
mkdir -p "$DIR"
printf 'plugins {}\n' > "$DIR/build.gradle.kts"
got=$(cd "$DIR" && bash "$LIB")
check "M: build.gradle.kts -> gradle test" "gradle test" "$got"

DIR="$WORK/ruby"
mkdir -p "$DIR"
printf 'source "https://rubygems.org"\n' > "$DIR/Gemfile"
got=$(cd "$DIR" && bash "$LIB")
check "M: Gemfile -> bundle exec rake test" "bundle exec rake test" "$got"

DIR="$WORK/composer"
mkdir -p "$DIR"
printf '{"name":"foo/bar"}\n' > "$DIR/composer.json"
got=$(cd "$DIR" && bash "$LIB")
check "M: composer.json -> composer test" "composer test" "$got"

DIR="$WORK/lein-over-deps"
mkdir -p "$DIR"
printf '(defproject foo "0.1.0")\n' > "$DIR/project.clj"
printf '{:paths ["src"]}\n' > "$DIR/deps.edn"
got=$(cd "$DIR" && bash "$LIB")
check "M: project.clj XOR deps.edn (lein only)" "lein test" "$got"

# N: additional language markers (one command per isolated tree)
expect_marker() {
  local name="$1" expected="$2"
  shift 2
  local d="$WORK/$name"
  mkdir -p "$d"
  local rel
  for rel in "$@"; do
    mkdir -p "$d/$(dirname "$rel")"
    : > "$d/$rel"
  done
  got=$(cd "$d" && bash "$LIB")
  check "N: $name -> $expected" "$expected" "$got"
}

expect_marker "bun-lock" "bun test" bun.lock
expect_marker "bun-lockb" "bun test" bun.lockb
expect_marker "deno-json" "deno test" deno.json
expect_marker "deno-jsonc" "deno test" deno.jsonc
expect_marker "phpunit-xml" "phpunit" phpunit.xml
expect_marker "phpunit-xml-dist" "phpunit" phpunit.xml.dist
expect_marker "dotnet-sln" "dotnet test" Foo.sln
expect_marker "dotnet-csproj" "dotnet test" Foo.csproj
expect_marker "dotnet-fsproj" "dotnet test" Foo.fsproj
expect_marker "dotnet-vbproj" "dotnet test" Foo.vbproj
expect_marker "swift" "swift test" Package.swift
expect_marker "sbt" "sbt test" build.sbt
expect_marker "stack" "stack test" stack.yaml
expect_marker "cabal-project" "cabal test" cabal.project
expect_marker "cabal-file" "cabal test" foo.cabal
expect_marker "zig" "zig build test" build.zig
expect_marker "julia" "julia --project=. -e 'using Pkg; Pkg.test()'" Project.toml
expect_marker "crystal" "crystal spec" shard.yml
expect_marker "cmake" "ctest --output-on-failure" CMakeLists.txt
expect_marker "meson" "meson test" meson.build
expect_marker "bazel-workspace" "bazel test //..." WORKSPACE
expect_marker "bazel-workspace-bzl" "bazel test //..." WORKSPACE.bazel
expect_marker "bazel-module" "bazel test //..." MODULE.bazel
expect_marker "dune" "dune runtest" dune-project
expect_marker "elm" "elm-test" elm.json
expect_marker "nimble" "nimble test" foo.nimble
expect_marker "dub-json" "dub test" dub.json
expect_marker "dub-sdl" "dub test" dub.sdl
expect_marker "perl-makefile" "prove -l" Makefile.PL
expect_marker "perl-build" "prove -l" Build.PL
expect_marker "perl-cpanfile" "prove -l" cpanfile

DIR="$WORK/dart-only"
mkdir -p "$DIR"
printf 'name: foo\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n' > "$DIR/pubspec.yaml"
got=$(cd "$DIR" && bash "$LIB")
check "N: dart pubspec -> dart test" "dart test" "$got"

DIR="$WORK/flutter"
mkdir -p "$DIR"
printf 'name: foo\ndependencies:\n  flutter:\n    sdk: flutter\n' > "$DIR/pubspec.yaml"
got=$(cd "$DIR" && bash "$LIB")
check "N: flutter pubspec -> flutter test" "flutter test" "$got"

DIR="$WORK/r-desc"
mkdir -p "$DIR"
printf 'Package: foo\nVersion: 0.1.0\n' > "$DIR/DESCRIPTION"
got=$(cd "$DIR" && bash "$LIB")
check "N: R DESCRIPTION -> Rscript testthat" "Rscript -e 'testthat::test_local()'" "$got"

DIR="$WORK/justfile"
mkdir -p "$DIR"
printf 'test:\n\t@echo hi\n' > "$DIR/justfile"
got=$(cd "$DIR" && bash "$LIB")
check "N: justfile test recipe -> just test" "just test" "$got"

DIR="$WORK/Justfile-cap"
mkdir -p "$DIR"
printf 'test:\n\t@echo hi\n' > "$DIR/Justfile"
got=$(cd "$DIR" && bash "$LIB")
check "N: Justfile test recipe -> just test" "just test" "$got"

DIR="$WORK/taskfile"
mkdir -p "$DIR"
printf 'version: "3"\ntasks:\n  test:\n    cmds: ["echo hi"]\n' > "$DIR/Taskfile.yml"
got=$(cd "$DIR" && bash "$LIB")
check "N: Taskfile.yml test task -> task test" "task test" "$got"

# Family XOR: one JS runner, bun beats npm, deno beats npm when bun is absent
DIR="$WORK/bun-over-npm"
mkdir -p "$DIR"
touch "$DIR/bun.lock" "$DIR/package.json"
got=$(cd "$DIR" && bash "$LIB")
check "N: bun.lock XOR npm (bun test)" "bun test" "$got"

DIR="$WORK/deno-over-npm"
mkdir -p "$DIR"
touch "$DIR/deno.json" "$DIR/package.json"
got=$(cd "$DIR" && bash "$LIB")
check "N: deno.json XOR npm (deno test)" "deno test" "$got"

DIR="$WORK/phpunit-with-composer"
mkdir -p "$DIR"
touch "$DIR/composer.json" "$DIR/phpunit.xml"
got=$(cd "$DIR" && bash "$LIB")
check "N: composer XOR phpunit (composer test)" "composer test" "$got"

DIR="$WORK/stack-over-cabal"
mkdir -p "$DIR"
touch "$DIR/stack.yaml" "$DIR/foo.cabal"
got=$(cd "$DIR" && bash "$LIB")
check "N: stack XOR cabal (stack test)" "stack test" "$got"

# Polyglot join across three families; Makefile test: stays exclusive
DIR="$WORK/polyglot-three"
mkdir -p "$DIR"
printf '{"name":"foo"}\n' > "$DIR/package.json"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
printf 'module example.com/foo\n\ngo 1.21\n' > "$DIR/go.mod"
got=$(cd "$DIR" && bash "$LIB")
check "N: npm + cargo + go join with &&" "npm test && cargo test && go test ./..." "$got"

DIR="$WORK/makefile-exclusive-polyglot"
mkdir -p "$DIR"
printf 'test:\n\t@echo running tests\n' > "$DIR/Makefile"
printf '{"name":"foo"}\n' > "$DIR/package.json"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "N: Makefile test: exclusive over polyglot" "make test" "$got"

# Project runners with a test recipe are exclusive, like Makefile — not stacked
# on cargo/npm. A justfile that does not define test: is not an override.
DIR="$WORK/just-over-cargo"
mkdir -p "$DIR"
printf 'test:\n\t@echo hi\n' > "$DIR/justfile"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "N: justfile test: exclusive over cargo" "just test" "$got"

DIR="$WORK/justfile-no-test"
mkdir -p "$DIR"
printf 'build:\n\t@echo hi\n' > "$DIR/justfile"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "N: justfile without test: falls through to cargo" "cargo test" "$got"

DIR="$WORK/makefile-over-just"
mkdir -p "$DIR"
printf 'test:\n\t@echo running tests\n' > "$DIR/Makefile"
printf 'test:\n\t@echo hi\n' > "$DIR/justfile"
got=$(cd "$DIR" && bash "$LIB")
check "N: Makefile test: exclusive over justfile" "make test" "$got"

DIR="$WORK/task-over-cargo"
mkdir -p "$DIR"
printf 'version: "3"\ntasks:\n  build:\n    cmds: ["echo"]\n  test:\n    cmds: ["echo hi"]\n' > "$DIR/Taskfile.yml"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "N: Taskfile task test exclusive over cargo" "task test" "$got"

# Nested YAML keys named test are not a Taskfile test task.
DIR="$WORK/taskfile-env-test"
mkdir -p "$DIR"
printf 'version: "3"\nenv:\n  test: development\ntasks:\n  build:\n    cmds: ["echo hi"]\n' > "$DIR/Taskfile.yml"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "N: Taskfile env.test is not a test task" "cargo test" "$got"

DIR="$WORK/taskfile-nested-test"
mkdir -p "$DIR"
printf 'version: "3"\ntasks:\n  build:\n    vars:\n      test: unit\n    cmds: ["echo hi"]\n' > "$DIR/Taskfile.yml"
printf '[package]\nname = "foo"\n' > "$DIR/Cargo.toml"
got=$(cd "$DIR" && bash "$LIB")
check "N: Taskfile nested vars.test is not a test task" "cargo test" "$got"

# Build-system files next to a language manifest are native addons / extra
# toolchains, not a second test suite. Fallback only when they are the only marker.
DIR="$WORK/npm-cmake"
mkdir -p "$DIR"
printf '{"name":"foo"}\n' > "$DIR/package.json"
touch "$DIR/CMakeLists.txt"
got=$(cd "$DIR" && bash "$LIB")
check "N: package.json + CMakeLists.txt is npm only" "npm test" "$got"

DIR="$WORK/npm-meson"
mkdir -p "$DIR"
printf '{"name":"foo"}\n' > "$DIR/package.json"
touch "$DIR/meson.build"
got=$(cd "$DIR" && bash "$LIB")
check "N: package.json + meson.build is npm only" "npm test" "$got"

DIR="$WORK/npm-bazel"
mkdir -p "$DIR"
printf '{"name":"foo"}\n' > "$DIR/package.json"
touch "$DIR/WORKSPACE"
got=$(cd "$DIR" && bash "$LIB")
check "N: package.json + WORKSPACE is npm only" "npm test" "$got"

DIR="$WORK/py-cmake"
mkdir -p "$DIR"
touch "$DIR/pyproject.toml" "$DIR/CMakeLists.txt"
got=$(cd "$DIR" && bash "$LIB")
check "N: pyproject + CMakeLists.txt is pytest only" "python -m pytest" "$got"

# Polyglot python -m pytest && go test ./... must still get the venv rewrite.
if grep -qF '*"python -m pytest"*' "$ROOT/lib/feature-bootstrap.sh"; then
  echo "PASS: feature bootstrap upgrades any command containing python -m pytest"
  ((PASS++)) || true
else
  echo "FAIL: feature bootstrap still exact-matches python -m pytest (polyglot misses the venv rewrite)"
  ((FAIL++)) || true
fi

# L: exit 0 in all cases
for case_name in "makefile-test" "package-json" "cargo" "pyproject" "setup-py" "go-mod" "uv-python" "poetry-python" "venv-python" "empty" "lein" "deps-edn" "bun-lock" "deno-json" "dotnet-csproj" "swift" "polyglot-three"; do
  exit_code=0
  (cd "$WORK/$case_name" && bash "$LIB" >/dev/null) || exit_code=$?
  check_exit "L: exit 0 for $case_name" "0" "$exit_code"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
