#!/usr/bin/env bash
# Probe directory for known test-file markers and print the test command.
#
# Usage: detect-test-cmd.sh [<directory>]
#   <directory>  Directory to probe (default: current working directory)
#
# Priority order (first match wins):
#   Makefile with test: target -> make test
#   package.json                -> npm test
#   Cargo.toml                  -> cargo test
#   pyproject.toml + uv.lock    -> uv run pytest
#   pyproject.toml + poetry.lock -> poetry run pytest
#   pyproject/setup + .venv     -> .venv/bin/python -m pytest
#   other pyproject/setup       -> python -m pytest
#   go.mod                      -> go test ./...
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
fi

exit 0
