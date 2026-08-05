#!/usr/bin/env bash
# Test suite for hooks/team/human-code-inject.sh
#
# Code-for-humans mode is DEFAULT ON, self-scoped to loop-spec projects (a
# .loop-spec/ dir must exist). Polarity matches grill-inject and
# simplicity-inject: with .loop-spec present, absent conf => inject; ENABLED=0
# or the kill switch => silent.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/human-code-inject.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/human-code-inject-test-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

# Shared assertion helpers (check_output / check_no_pattern / check_valid_json).
source "$(dirname "$0")/inject-test-lib.sh"

echo "=== human-code-inject.sh tests ==="

# --- loop-spec project, no conf -> default ON ---
LS="$TMPDIR_TEST/proj"; mkdir -p "$LS/.loop-spec"
check_output "a: loop-spec project, absent conf -> hookSpecificOutput" 0 "hookSpecificOutput" CLAUDE_PROJECT_DIR="$LS"
check_output "b: default on -> CODE FOR HUMANS MODE ACTIVE" 0 "CODE FOR HUMANS MODE ACTIVE" CLAUDE_PROJECT_DIR="$LS"
check_valid_json "c: default on -> valid JSON" CLAUDE_PROJECT_DIR="$LS"

# --- the directive carries its load-bearing rules, not just a title ---
check_output "d: names the convention rule" 0 "Read the neighbors" CLAUDE_PROJECT_DIR="$LS"
check_output "e: names the why-not-what rule" 0 "Comments carry WHY, never what" CLAUDE_PROJECT_DIR="$LS"
check_output "f: names the density rule" 0 "matches the file, not an absolute" CLAUDE_PROJECT_DIR="$LS"
check_output "g: points at the convention probe" 0 "house-style.sh probe" CLAUDE_PROJECT_DIR="$LS"
check_output "h: points at the tell scan" 0 "comment-tells.sh scan" CLAUDE_PROJECT_DIR="$LS"
check_output "i: carries the simplicity: carve-out" 0 "simplicity:" CLAUDE_PROJECT_DIR="$LS"
check_output "j: carries the file-header carve-out" 0 "file-header purpose blocks" CLAUDE_PROJECT_DIR="$LS"

# --- self-scoping: NO .loop-spec dir -> silent ---
NOPROJ="$TMPDIR_TEST/noproj"; mkdir -p "$NOPROJ"
check_no_pattern "k: no .loop-spec dir -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$NOPROJ"

# --- ENABLED=0 -> silent ---
DIS="$TMPDIR_TEST/disabled"; mkdir -p "$DIS/.loop-spec"; printf 'ENABLED=0\n' > "$DIS/.loop-spec/human-code.conf"
check_no_pattern "l: ENABLED=0 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$DIS"

# --- ENABLED=1 -> injects ---
ON="$TMPDIR_TEST/on"; mkdir -p "$ON/.loop-spec"; printf 'ENABLED=1\n' > "$ON/.loop-spec/human-code.conf"
check_output "m: ENABLED=1 -> injects" 0 "CODE FOR HUMANS MODE ACTIVE" CLAUDE_PROJECT_DIR="$ON"

# --- kill switch -> silent even with .loop-spec + default ---
check_no_pattern "n: LOOP_SPEC_HUMAN_CODE=0 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_HUMAN_CODE=0

# --- kill switch outranks an explicit ENABLED=1 ---
check_no_pattern "o: kill switch outranks ENABLED=1" 0 "additionalContext" CLAUDE_PROJECT_DIR="$ON" LOOP_SPEC_HUMAN_CODE=0

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
