#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/project-commands.sh"
PASS=0
FAIL=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $label (expected '$expected', got '$actual')"
  fi
}

run_resolve() {
  env -u LOOP_SPEC_CMD_PREPARE -u LOOP_SPEC_CMD_TEST \
    -u LOOP_SPEC_CMD_LINT -u LOOP_SPEC_CMD_TYPECHECK \
    "$@" bash "$SCRIPT" resolve \
      --prepare "detected prepare" \
      --test "detected test" \
      --lint "detected lint" \
      --typecheck "detected typecheck"
}

out="$(run_resolve)"
check "detected prepare retained" "detected prepare" "$(jq -r '.prepare' <<<"$out")"
check "detected test retained" "detected test" "$(jq -r '.test' <<<"$out")"
check "detected lint retained" "detected lint" "$(jq -r '.lint' <<<"$out")"
check "detected typecheck retained" "detected typecheck" "$(jq -r '.typecheck' <<<"$out")"

out="$(run_resolve \
  LOOP_SPEC_CMD_PREPARE="pinned prepare" \
  LOOP_SPEC_CMD_TEST="pinned test" \
  LOOP_SPEC_CMD_LINT="pinned lint" \
  LOOP_SPEC_CMD_TYPECHECK="pinned typecheck")"
check "prepare override wins" "pinned prepare" "$(jq -r '.prepare' <<<"$out")"
check "test override wins" "pinned test" "$(jq -r '.test' <<<"$out")"
check "lint override wins" "pinned lint" "$(jq -r '.lint' <<<"$out")"
check "typecheck override wins" "pinned typecheck" "$(jq -r '.typecheck' <<<"$out")"

out="$(run_resolve \
  LOOP_SPEC_CMD_PREPARE= \
  LOOP_SPEC_CMD_TEST= \
  LOOP_SPEC_CMD_LINT= \
  LOOP_SPEC_CMD_TYPECHECK=)"
check "empty prepare disables" "" "$(jq -r '.prepare' <<<"$out")"
check "empty test disables" "" "$(jq -r '.test' <<<"$out")"
check "empty lint disables" "" "$(jq -r '.lint' <<<"$out")"
check "empty typecheck disables" "" "$(jq -r '.typecheck' <<<"$out")"

rc=0
bash "$SCRIPT" resolve --prepare p --test t --lint l >/dev/null 2>&1 || rc=$?
check "missing slot rejected" "2" "$rc"

rc=0
bash "$SCRIPT" resolve --prepare p --test t --lint l --typecheck y --bogus z >/dev/null 2>&1 || rc=$?
check "unknown argument rejected" "2" "$rc"

# --- what fills the slots: a declared target outranks a bare binary ----------------
# A container without ruff turned the derived `ruff check .` into exit 127 and reported
# the whole verification gate as infra_error, while the same repository's `make lint`
# was installed all along (lib/graph/driver.py detect_commands).
WORK="${TMPDIR:-/tmp}/loop-spec-project-commands.$$"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/make" "$WORK/just" "$WORK/task" "$WORK/tox" "$WORK/node" "$WORK/bare" "$WORK/none"
printf 'lint:\n\truff check .\n\ntypecheck:\n\tmypy .\n' > "$WORK/make/Makefile"
printf '[tool.ruff]\n[tool.mypy]\n' > "$WORK/make/pyproject.toml"
printf '{"scripts":{"lint":"eslint .","typecheck":"tsc --noEmit"}}\n' > "$WORK/node/package.json"
: > "$WORK/node/pnpm-lock.yaml"
printf '[tool.ruff]\n[tool.mypy]\n' > "$WORK/bare/pyproject.toml"
printf 'lint:\n    ruff check .\n' > "$WORK/just/justfile"
printf 'version: "3"\ntasks:\n  lint:\n    cmds:\n      - ruff check .\n' > "$WORK/task/Taskfile.yml"
printf '[testenv:lint]\ncommands = ruff check .\n' > "$WORK/tox/tox.ini"

detected="$(python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import driver
print(json.dumps({d.rsplit("/", 1)[1]: driver.detect_commands(d) for d in sys.argv[2:]}))
' "$ROOT/lib/graph" "$WORK/make" "$WORK/just" "$WORK/task" "$WORK/tox" "$WORK/node" "$WORK/bare" "$WORK/none")"

check "make lint outranks the bare linter" "make lint" "$(jq -r '.make.lint' <<<"$detected")"
check "make typecheck outranks the bare checker" "make typecheck" "$(jq -r '.make.typecheck' <<<"$detected")"
check "a justfile target is a declared target" "just lint" "$(jq -r '.just.lint' <<<"$detected")"
check "a Taskfile task is a declared target" "task lint" "$(jq -r '.task.lint' <<<"$detected")"
check "a tox env is a declared target" "tox -e lint" "$(jq -r '.tox.lint' <<<"$detected")"
check "a package script resolves through the declared manager" "pnpm run lint" "$(jq -r '.node.lint' <<<"$detected")"
check "a typecheck script resolves the same way" "pnpm run typecheck" "$(jq -r '.node.typecheck' <<<"$detected")"
check "no target keeps the bare-linter fallback" "ruff check ." "$(jq -r '.bare.lint' <<<"$detected")"
check "no target keeps the bare-checker fallback" "mypy ." "$(jq -r '.bare.typecheck' <<<"$detected")"
check "no signal leaves the lint slot empty" "" "$(jq -r '.none.lint' <<<"$detected")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
