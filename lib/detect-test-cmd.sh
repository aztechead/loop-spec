#!/usr/bin/env bash
# Probe directory for known test-file markers and print the test command.
#
# Usage: detect-test-cmd.sh [<directory>]
#   <directory>  Directory to probe (default: current working directory)
#
# Priority order (first match wins). Makefile with a `test:` target always
# outranks language-specific tools. The rest is a marker list, not a stack
# preference: this plugin must not assume the project is JS or Python.
#   Makefile with test: target -> make test
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
#
# Output: test command string on stdout (empty if no marker found).
# Exit: 0 in all cases.

dir="${1:-$PWD}"

if [[ -f "$dir/Makefile" ]] && grep -qE '^test:' "$dir/Makefile"; then
  printf 'make test\n'
elif [[ -f "$dir/package.json" ]]; then
  printf 'npm test\n'
elif [[ -f "$dir/Cargo.toml" ]]; then
  printf 'cargo test\n'
elif [[ -f "$dir/pyproject.toml" && -f "$dir/uv.lock" ]]; then
  printf 'uv run pytest\n'
elif [[ -f "$dir/pyproject.toml" && -f "$dir/poetry.lock" ]]; then
  printf 'poetry run pytest\n'
elif [[ -f "$dir/pyproject.toml" && -x "$dir/.venv/bin/python" ]]; then
  printf '.venv/bin/python -m pytest\n'
elif [[ -f "$dir/pyproject.toml" ]]; then
  printf 'python -m pytest\n'
elif [[ -f "$dir/setup.py" && -x "$dir/.venv/bin/python" ]]; then
  printf '.venv/bin/python -m pytest\n'
elif [[ -f "$dir/setup.py" ]]; then
  printf 'python -m pytest\n'
elif [[ -f "$dir/go.mod" ]]; then
  printf 'go test ./...\n'
elif [[ -f "$dir/project.clj" ]]; then
  printf 'lein test\n'
elif [[ -f "$dir/deps.edn" ]]; then
  printf 'clojure -M:test\n'
elif [[ -f "$dir/mix.exs" ]]; then
  printf 'mix test\n'
elif [[ -f "$dir/pom.xml" ]]; then
  printf 'mvn test\n'
elif [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]; then
  printf 'gradle test\n'
elif [[ -f "$dir/Gemfile" ]]; then
  printf 'bundle exec rake test\n'
elif [[ -f "$dir/composer.json" ]]; then
  printf 'composer test\n'
fi

exit 0
