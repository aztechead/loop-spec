#!/usr/bin/env bash
# Test suite for hooks/team/micro-inject.sh
#
# Micro mode is DEFAULT ON, self-scoped to loop-spec projects (a .loop-spec/
# dir must exist). With .loop-spec present, absent conf => inject; ENABLED=0,
# kill switch, or autonomous mode => silent. Mirrors grill-inject.test.sh.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/micro-inject.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/micro-inject-test-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

# Shared assertion helpers (check_output / check_no_pattern / check_valid_json).
source "$(dirname "$0")/inject-test-lib.sh"

echo "=== micro-inject.sh tests ==="

# --- loop-spec project, no conf -> default ON ---
LS="$TMPDIR_TEST/proj"; mkdir -p "$LS/.loop-spec"
check_output "a: loop-spec project, absent conf -> hookSpecificOutput" 0 "hookSpecificOutput" CLAUDE_PROJECT_DIR="$LS"
check_output "b: default on -> MICRO MODE ACTIVE" 0 "MICRO MODE ACTIVE" CLAUDE_PROJECT_DIR="$LS"
check_valid_json "c: default on -> valid JSON" CLAUDE_PROJECT_DIR="$LS"

# --- self-scoping: NO .loop-spec dir -> silent ---
NOPROJ="$TMPDIR_TEST/noproj"; mkdir -p "$NOPROJ"
check_no_pattern "d: no .loop-spec dir -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$NOPROJ"

# --- ENABLED=1 -> still injects ---
ENA="$TMPDIR_TEST/enabled"; mkdir -p "$ENA/.loop-spec"; printf 'ENABLED=1\n' > "$ENA/.loop-spec/micro.conf"
check_output "e: ENABLED=1 -> injects" 0 "MICRO MODE ACTIVE" CLAUDE_PROJECT_DIR="$ENA"

# --- ENABLED=0 -> silent ---
DIS="$TMPDIR_TEST/disabled"; mkdir -p "$DIS/.loop-spec"; printf 'ENABLED=0\n' > "$DIS/.loop-spec/micro.conf"
check_no_pattern "f: ENABLED=0 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$DIS"

# --- kill switch -> silent even with .loop-spec + default ---
check_no_pattern "g: LOOP_SPEC_MICRO=0 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_MICRO=0

# --- autonomous mode -> silent (cycle machinery owns the invariants) ---
check_no_pattern "h: LOOP_SPEC_AUTONOMOUS=1 -> silent" 0 "additionalContext" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_AUTONOMOUS=1
check_valid_json "i: LOOP_SPEC_AUTONOMOUS=1 -> valid JSON" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_AUTONOMOUS=1
check_output "j: LOOP_SPEC_AUTONOMOUS=0 -> still injects" 0 "MICRO MODE ACTIVE" CLAUDE_PROJECT_DIR="$LS" LOOP_SPEC_AUTONOMOUS=0

# --- directive carries a runnable ledger path (plugin-root resolved) ---
check_output "k: directive embeds adhoc-ledger.sh path" 0 "adhoc-ledger.sh" CLAUDE_PROJECT_DIR="$LS"
check_output "l: CLAUDE_PLUGIN_ROOT honored in path" 0 "/opt/fake-root/lib/adhoc-ledger.sh" CLAUDE_PROJECT_DIR="$LS" CLAUDE_PLUGIN_ROOT="/opt/fake-root"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
