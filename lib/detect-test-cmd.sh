#!/usr/bin/env bash
# Probe directory for known test-file markers and print every matching test command.
#
# Usage: detect-test-cmd.sh [<directory>]
#   <directory>  Directory to probe (default: current working directory)
#
# A Makefile with a `test:` target is the exclusive project override (`make test`).
# Otherwise every matching language family contributes one command, joined with
# ` && ` so a polyglot tree is not truncated to whichever marker sorts first.
# Family XOR (one runner, not two for the same ecosystem):
#   bun.lock/bun.lockb | deno.json(c) | package.json
#   uv.lock | poetry.lock | .venv | pyproject/setup.py
#   project.clj | deps.edn
#   stack.yaml | cabal.project/*.cabal
#   composer.json | phpunit.xml(.dist)
#   flutter (sdk: flutter in pubspec.yaml) | dart
#
# Marker -> command (collected in this order after the Makefile override):
#   bun.lock / bun.lockb        -> bun test
#   deno.json / deno.jsonc      -> deno test
#   package.json                -> npm test
#   Cargo.toml                  -> cargo test
#   pyproject.toml + uv.lock    -> uv run pytest
#   pyproject.toml + poetry.lock -> poetry run pytest
#   pyproject/setup + .venv     -> .venv/bin/python -m pytest
#   other pyproject/setup       -> python -m pytest
#   go.mod                      -> go test ./...
#   project.clj                 -> lein test
#   deps.edn                    -> clojure -M:test
#   mix.exs                     -> mix test
#   pom.xml                     -> mvn test
#   build.gradle(.kts)          -> gradle test
#   Gemfile                     -> bundle exec rake test
#   composer.json               -> composer test
#   phpunit.xml(.dist)          -> phpunit
#   *.sln/*.csproj/*.fsproj/*.vbproj (root) -> dotnet test
#   Package.swift               -> swift test
#   pubspec.yaml                -> flutter test | dart test
#   build.sbt                   -> sbt test
#   stack.yaml                  -> stack test
#   cabal.project / *.cabal     -> cabal test
#   build.zig                   -> zig build test
#   Project.toml                -> julia --project=. -e 'using Pkg; Pkg.test()'
#   shard.yml                   -> crystal spec
#   CMakeLists.txt              -> ctest --output-on-failure
#   meson.build                 -> meson test
#   WORKSPACE / MODULE.bazel    -> bazel test //...
#   dune-project                -> dune runtest
#   elm.json                    -> elm-test
#   *.nimble                    -> nimble test
#   dub.json / dub.sdl          -> dub test
#   Makefile.PL / Build.PL / cpanfile -> prove -l
#   DESCRIPTION with Package:   -> Rscript -e 'testthat::test_local()'
#   justfile/Justfile with test: -> just test
#   Taskfile.yml with test:     -> task test
#
# Output: test command string on stdout (empty if no marker found).
# Exit: 0 in all cases.

set -euo pipefail

dir="${1:-$PWD}"
cmds=()

add_cmd() {
  cmds+=("$1")
}

# Unmatched globs stay literal when nullglob is off; -f then fails. Root only.
has_root_glob() {
  local f
  for f in "$dir"/$1; do
    [[ -f "$f" ]] && return 0
  done
  return 1
}

if [[ -f "$dir/Makefile" ]] && grep -qE '^test:' "$dir/Makefile"; then
  printf 'make test\n'
  exit 0
fi

if [[ -f "$dir/bun.lock" || -f "$dir/bun.lockb" ]]; then
  add_cmd 'bun test'
elif [[ -f "$dir/deno.json" || -f "$dir/deno.jsonc" ]]; then
  add_cmd 'deno test'
elif [[ -f "$dir/package.json" ]]; then
  add_cmd 'npm test'
fi

if [[ -f "$dir/Cargo.toml" ]]; then
  add_cmd 'cargo test'
fi

if [[ -f "$dir/pyproject.toml" && -f "$dir/uv.lock" ]]; then
  add_cmd 'uv run pytest'
elif [[ -f "$dir/pyproject.toml" && -f "$dir/poetry.lock" ]]; then
  add_cmd 'poetry run pytest'
elif [[ -f "$dir/pyproject.toml" && -x "$dir/.venv/bin/python" ]]; then
  add_cmd '.venv/bin/python -m pytest'
elif [[ -f "$dir/pyproject.toml" ]]; then
  add_cmd 'python -m pytest'
elif [[ -f "$dir/setup.py" && -x "$dir/.venv/bin/python" ]]; then
  add_cmd '.venv/bin/python -m pytest'
elif [[ -f "$dir/setup.py" ]]; then
  add_cmd 'python -m pytest'
fi

if [[ -f "$dir/go.mod" ]]; then
  add_cmd 'go test ./...'
fi

if [[ -f "$dir/project.clj" ]]; then
  add_cmd 'lein test'
elif [[ -f "$dir/deps.edn" ]]; then
  add_cmd 'clojure -M:test'
fi

if [[ -f "$dir/mix.exs" ]]; then
  add_cmd 'mix test'
fi

if [[ -f "$dir/pom.xml" ]]; then
  add_cmd 'mvn test'
fi

if [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]; then
  add_cmd 'gradle test'
fi

if [[ -f "$dir/Gemfile" ]]; then
  add_cmd 'bundle exec rake test'
fi

if [[ -f "$dir/composer.json" ]]; then
  add_cmd 'composer test'
elif [[ -f "$dir/phpunit.xml" || -f "$dir/phpunit.xml.dist" ]]; then
  add_cmd 'phpunit'
fi

if has_root_glob '*.sln' || has_root_glob '*.csproj' || has_root_glob '*.fsproj' || has_root_glob '*.vbproj'; then
  add_cmd 'dotnet test'
fi

if [[ -f "$dir/Package.swift" ]]; then
  add_cmd 'swift test'
fi

if [[ -f "$dir/pubspec.yaml" ]]; then
  if grep -qE 'sdk:[[:space:]]*flutter' "$dir/pubspec.yaml"; then
    add_cmd 'flutter test'
  else
    add_cmd 'dart test'
  fi
fi

if [[ -f "$dir/build.sbt" ]]; then
  add_cmd 'sbt test'
fi

if [[ -f "$dir/stack.yaml" ]]; then
  add_cmd 'stack test'
elif [[ -f "$dir/cabal.project" ]] || has_root_glob '*.cabal'; then
  add_cmd 'cabal test'
fi

if [[ -f "$dir/build.zig" ]]; then
  add_cmd 'zig build test'
fi

if [[ -f "$dir/Project.toml" ]]; then
  add_cmd "julia --project=. -e 'using Pkg; Pkg.test()'"
fi

if [[ -f "$dir/shard.yml" ]]; then
  add_cmd 'crystal spec'
fi

if [[ -f "$dir/CMakeLists.txt" ]]; then
  add_cmd 'ctest --output-on-failure'
fi

if [[ -f "$dir/meson.build" ]]; then
  add_cmd 'meson test'
fi

if [[ -f "$dir/WORKSPACE" || -f "$dir/WORKSPACE.bazel" || -f "$dir/MODULE.bazel" ]]; then
  add_cmd 'bazel test //...'
fi

if [[ -f "$dir/dune-project" ]]; then
  add_cmd 'dune runtest'
fi

if [[ -f "$dir/elm.json" ]]; then
  add_cmd 'elm-test'
fi

if has_root_glob '*.nimble'; then
  add_cmd 'nimble test'
fi

if [[ -f "$dir/dub.json" || -f "$dir/dub.sdl" ]]; then
  add_cmd 'dub test'
fi

if [[ -f "$dir/Makefile.PL" || -f "$dir/Build.PL" || -f "$dir/cpanfile" ]]; then
  add_cmd 'prove -l'
fi

if [[ -f "$dir/DESCRIPTION" ]] && grep -qE '^Package:' "$dir/DESCRIPTION"; then
  add_cmd "Rscript -e 'testthat::test_local()'"
fi

justfile=""
[[ -f "$dir/justfile" ]] && justfile="$dir/justfile"
[[ -f "$dir/Justfile" ]] && justfile="$dir/Justfile"
if [[ -n "$justfile" ]] && grep -qE '^test:' "$justfile"; then
  add_cmd 'just test'
fi

for tf in Taskfile.yml Taskfile.yaml Taskfile.dist.yml; do
  if [[ -f "$dir/$tf" ]] && grep -qE '^[[:space:]]*test:' "$dir/$tf"; then
    add_cmd 'task test'
    break
  fi
done

# "${arr[*]}" joins on the first IFS character only, so " && " would collapse to " ".
if [[ ${#cmds[@]} -gt 0 ]]; then
  out="${cmds[0]}"
  i=1
  while [[ $i -lt ${#cmds[@]} ]]; do
    out="$out && ${cmds[$i]}"
    i=$((i + 1))
  done
  printf '%s\n' "$out"
fi

exit 0
