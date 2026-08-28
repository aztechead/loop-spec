#!/usr/bin/env bash
# Tests for lib/feature-bootstrap.sh (the deterministic tail of cycle Step 5).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/lib/feature-bootstrap.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-feature-bootstrap.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

make_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  echo hi > "$dir/f"
  git -C "$dir" add f
  git -C "$dir" commit -qm init
}

finalize() {
  local dir="$1"; shift
  bash "$LIB" finalize \
    --repo-root "$dir" --execution-root "$dir" \
    --slug demo --title "Demo feature" \
    --branch feat/demo --base-branch main --base-sha "$(git -C "$dir" rev-parse HEAD)" \
    --worktree "" --style balanced --profile standard \
    --autonomous 0 --greenfield 0 \
    --prepare "" --test "true" --lint "" --typecheck "" "$@"
}

# Case A: full run writes feature.json (profile threaded, baseline default null)
# and prints ONLY the test command on stdout.
make_repo "$WORK/a"
out=$(finalize "$WORK/a" 2>/dev/null)
rc=$?
check "A: exit 0" "0" "$rc"
check "A: stdout is exactly the test command" "true" "$out"
check "A: feature.json slug" "demo" \
  "$(jq -r '.slug' "$WORK/a/.loop-spec/features/demo/feature.json" 2>/dev/null || echo MISSING)"
check "A: executionProfile threaded" "standard" \
  "$(jq -r '.executionProfile' "$WORK/a/.loop-spec/features/demo/feature.json")"
check "A: baseline null when opt-in is off" "null" \
  "$(jq -r '.verificationBaseline' "$WORK/a/.loop-spec/features/demo/feature.json")"
check "A: autonomous flag not persisted when 0" "null" \
  "$(jq -r '.autonomous // "null"' "$WORK/a/.loop-spec/features/demo/feature.json")"

# Case B: autonomous/greenfield flags persist when set.
make_repo "$WORK/b"
finalize "$WORK/b" --autonomous 1 --greenfield 1 >/dev/null 2>&1
check "B: autonomous persisted" "true" \
  "$(jq -r '.autonomous' "$WORK/b/.loop-spec/features/demo/feature.json")"
check "B: greenfield persisted" "true" \
  "$(jq -r '.greenfield' "$WORK/b/.loop-spec/features/demo/feature.json")"

# Case C: staged pre-SPEC decisions migrate into the feature dir.
make_repo "$WORK/c"
mkdir -p "$WORK/c/.loop-spec/decisions-staging"
echo '{"id":"d1","decision":"assumed"}' \
  > "$WORK/c/.loop-spec/decisions-staging/decisions.jsonl"
finalize "$WORK/c" >/dev/null 2>&1
got="MISSING"
[[ -f "$WORK/c/.loop-spec/features/demo/decisions.jsonl" ]] && got="present"
check "C: staged decisions migrated" "present" "$got"

# Case D: a missing required flag is a usage error (exit 2), nothing written.
make_repo "$WORK/d"
rc=0
bash "$LIB" finalize --slug demo >/dev/null 2>&1 || rc=$?
check "D: missing flags exit 2" "2" "$rc"
got="absent"
[[ -e "$WORK/d/.loop-spec/features/demo/feature.json" ]] && got="written"
check "D: nothing written on usage error" "absent" "$got"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
