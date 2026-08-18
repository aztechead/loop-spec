#!/usr/bin/env bash
# Fast edit-loop gate. Selects registered suites coupled to the current worktree diff;
# pass a base ref to test the whole branch diff (for example, tests/run-unit.sh main).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

[[ $# -le 1 ]] || { echo "usage: tests/run-unit.sh [base_ref]" >&2; exit 2; }
BASE="${1:-HEAD}"
git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 \
  || { echo "run-unit.sh: base ref does not resolve: $BASE" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-run-unit-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CHANGED="$WORK/changed"
SELECTED="$WORK/selected"
git diff --name-only "$BASE" > "$CHANGED"
git ls-files --others --exclude-standard >> "$CHANGED"
sort -u "$CHANGED" -o "$CHANGED"

if [[ ! -s "$CHANGED" ]]; then
  echo "run-unit: no changed files relative to $BASE"
  exit 0
fi

add_suite() {
  local suite="$1"
  [[ -f "$suite" ]] || return 0
  grep -qxF "$suite" "$SELECTED" 2>/dev/null || printf '%s\n' "$suite" >> "$SELECTED"
}

coverage_paths=()
while IFS= read -r path; do
  case "$path" in
    *.test.sh) add_suite "$path" ;;
  esac
  add_suite "tests/${path%.*}.test.sh"
  add_suite "${path%.*}.test.sh"
  case "$path" in
    *.md|*.markdown) add_suite "tests/lib/doc-tells.test.sh" ;;
    lib/workflows/*.js) add_suite "tests/workflows/smoke.sh" ;;
    tests/run-all.sh|tests/run-unit.sh)
      add_suite "tests/all-tests-registered.test.sh"
      add_suite "tests/run-all.test.sh"
      ;;
  esac
  case "$path" in
    *.md|*.markdown|*.test.sh|tests/run-all.sh|tests/run-unit.sh) ;;
    *) coverage_paths+=("$path") ;;
  esac
done < "$CHANGED"

if (( ${#coverage_paths[@]} > 0 )); then
  covers="$(bash lib/surface.sh covers "${coverage_paths[@]}" 2>/dev/null || true)"
  while IFS=$'\t' read -r kind target suite; do
    [[ "$kind" == "covers" ]] && add_suite "$suite"
  done <<< "$covers"
fi

if [[ -s "$SELECTED" ]]; then
  echo "run-unit: $(wc -l < "$SELECTED" | tr -d ' ') mapped suite(s) for $(wc -l < "$CHANGED" | tr -d ' ') changed file(s)"
  RUN_ALL_PROFILE=selected RUN_ALL_ONLY_PATHS="$(cat "$SELECTED")" \
    bash "$SCRIPT_DIR/run-all.sh"
else
  echo "run-unit: no registered suite names the changed files; running syntax and lint checks"
fi

while IFS= read -r path; do
  [[ -f "$path" ]] || continue
  case "$path" in
    *.sh) bash -n "$path" ;;
    *.py) python3 -m py_compile "$path" ;;
    *.mjs|*.cjs) command -v node >/dev/null 2>&1 && node --check "$path" ;;
  esac
done < "$CHANGED"

code_paths=()
doc_paths=()
while IFS= read -r path; do
  [[ -f "$path" ]] || continue
  case "$path" in
    *.sh|*.bash|*.py|*.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx) code_paths+=("$path") ;;
    *.md|*.markdown) doc_paths+=("$path") ;;
  esac
done < "$CHANGED"
if (( ${#code_paths[@]} > 0 )); then
  bash lib/comment-tells.sh scan "${code_paths[@]}"
  bash lib/failure-tells.sh scan "${code_paths[@]}"
fi
if (( ${#doc_paths[@]} > 0 )); then
  bash lib/doc-tells.sh scan "${doc_paths[@]}"
fi

echo "run-unit: changed-file gate passed"
