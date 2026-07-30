#!/usr/bin/env bash
# Resolve the four project command slots after auto-detection.
#
# Environment overrides are authoritative when PRESENT, including an explicitly
# empty value (which disables that command). This keeps single-repo, workspace,
# interactive, and autonomous command resolution identical.
#
# Usage:
#   project-commands.sh resolve \
#     --prepare "<detected>" --test "<detected>" \
#     --lint "<detected>" --typecheck "<detected>"
#
# Prints one JSON object with prepare/test/lint/typecheck string fields.
set -euo pipefail

[[ "${1:-}" == "resolve" ]] || {
  echo "usage: project-commands.sh resolve --prepare CMD --test CMD --lint CMD --typecheck CMD" >&2
  exit 2
}
shift

prepare=""
test_cmd=""
lint=""
typecheck=""
seen_prepare=0
seen_test=0
seen_lint=0
seen_typecheck=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare)
      [[ $# -ge 2 ]] || { echo "project-commands: --prepare requires a value" >&2; exit 2; }
      prepare="$2"; seen_prepare=1; shift 2
      ;;
    --test)
      [[ $# -ge 2 ]] || { echo "project-commands: --test requires a value" >&2; exit 2; }
      test_cmd="$2"; seen_test=1; shift 2
      ;;
    --lint)
      [[ $# -ge 2 ]] || { echo "project-commands: --lint requires a value" >&2; exit 2; }
      lint="$2"; seen_lint=1; shift 2
      ;;
    --typecheck)
      [[ $# -ge 2 ]] || { echo "project-commands: --typecheck requires a value" >&2; exit 2; }
      typecheck="$2"; seen_typecheck=1; shift 2
      ;;
    *)
      echo "project-commands: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

[[ "$seen_prepare" == 1 && "$seen_test" == 1 && "$seen_lint" == 1 && "$seen_typecheck" == 1 ]] || {
  echo "project-commands: all four command slots are required" >&2
  exit 2
}

if [[ -n "${LOOP_SPEC_CMD_PREPARE+x}" ]]; then prepare="$LOOP_SPEC_CMD_PREPARE"; fi
if [[ -n "${LOOP_SPEC_CMD_TEST+x}" ]]; then test_cmd="$LOOP_SPEC_CMD_TEST"; fi
if [[ -n "${LOOP_SPEC_CMD_LINT+x}" ]]; then lint="$LOOP_SPEC_CMD_LINT"; fi
if [[ -n "${LOOP_SPEC_CMD_TYPECHECK+x}" ]]; then typecheck="$LOOP_SPEC_CMD_TYPECHECK"; fi

jq -cn \
  --arg prepare "$prepare" \
  --arg test "$test_cmd" \
  --arg lint "$lint" \
  --arg typecheck "$typecheck" \
  '{prepare:$prepare,test:$test,lint:$lint,typecheck:$typecheck}'
