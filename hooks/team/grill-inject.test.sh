#!/usr/bin/env bash
# Test suite for hooks/team/grill-inject.sh
#
# Grill mode is DEFAULT ON, but self-scoped to loop-spec projects (a .loop-spec/
# dir must exist). Polarity vs discipline-inject is still inverted: with .loop-spec
# present, absent conf => inject; ENABLED=0 or kill switch => silent.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/grill-inject.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/grill-inject-test-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

# Shared assertion helpers (check_output / check_no_pattern / check_valid_json).
source "$(dirname "$0")/inject-test-lib.sh"

echo "=== grill-inject.sh tests ==="

# --- loop-spec project, no conf -> default ON ---
LS="$TMPDIR_TEST/proj"; mkdir -p "$LS/.loop-spec"
check_output "a: loop-spec project, absent conf -> hookSpecificOutput" 0 "hookSpecificOutput" CLAUDE_PROJECT_DIR="$LS"
check_output "b: default on -> GRILL MODE ACTIVE" 0 "GRILL MODE ACTIVE" CLAUDE_PROJECT_DIR="$LS"
check_valid_json "c: default on -> valid JSON" CLAUDE_PROJECT_DIR="$LS"

# --- self-scoping: NO .loop-spec dir -> silent (does not hijack other projects) ---
NOPROJ="$TMPDIR_TEST/noproj"; mkdir -p "$NOPROJ"
check_no_pattern "d: no .loop-spec dir -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$NOPROJ"

# --- ENABLED=1 -> still injects ---
ENA="$TMPDIR_TEST/enabled"; mkdir -p "$ENA/.loop-spec"; printf 'ENABLED=1\n' > "$ENA/.loop-spec/grill.conf"
check_output "e: ENABLED=1 -> injects" 0 "GRILL MODE ACTIVE" CLAUDE_PROJECT_DIR="$ENA"

# --- ENABLED=0 -> silent ---
DIS="$TMPDIR_TEST/disabled"; mkdir -p "$DIS/.loop-spec"; printf 'ENABLED=0\n' > "$DIS/.loop-spec/grill.conf"
check_no_pattern "f: ENABLED=0 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$DIS"

# --- kill switch -> silent even with .loop-spec + default ---
check_no_pattern "g: LOOP_SPEC_GRILL=0 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_GRILL=0

# --- autonomous mode -> silent (nobody to grill; SPEC self-answers instead) ---
check_no_pattern "h: LOOP_SPEC_AUTONOMOUS=1 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_AUTONOMOUS=1
check_valid_json "i: LOOP_SPEC_AUTONOMOUS=1 -> valid JSON" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_AUTONOMOUS=1
check_output "j: LOOP_SPEC_AUTONOMOUS=0 -> still injects" 0 "GRILL MODE ACTIVE" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_AUTONOMOUS=0

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
