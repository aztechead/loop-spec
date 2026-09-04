#!/usr/bin/env bash
# Tests for lib/profile.sh (run profile: preset plus overrides, as env).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/profile.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/profile-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj/.loop-spec"
export CLAUDE_PROJECT_DIR="$WORK/proj"
unset LOOP_SPEC_PROFILE LOOP_SPEC_PROFILE_PRESET LOOP_SPEC_ORACLE LOOP_SPEC_AUTONOMOUS 2>/dev/null || true

# presets and show
check "presets lists the four" "autonomous cloud interactive supervised" "$(bash "$SCRIPT" presets | tr '\n' ' ' | sed 's/ $//')"
check "interactive preset is empty" "" "$(bash "$SCRIPT" show interactive)"
check "supervised sets the oracle" "LOOP_SPEC_ORACLE=supervisor" "$(bash "$SCRIPT" show supervised | grep ORACLE)"
check "cloud disables worktrees" "LOOP_SPEC_WORKTREES=0" "$(bash "$SCRIPT" show cloud | grep WORKTREES)"
ec=0; bash "$SCRIPT" show nope >/dev/null 2>&1 || ec=$?
check "show unknown preset exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" bogus >/dev/null 2>&1 || ec=$?
check "unknown op exits 2" "2" "$ec"

# no file, no preset variable: the empty profile, without reading anything
check "env with no file prints nothing" "" "$(bash "$SCRIPT" env)"
check "resolve with no file is the default" '{"preset":"interactive","source":"default","env":{}}' "$(bash "$SCRIPT" resolve)"
ec=0; bash "$SCRIPT" validate >/dev/null 2>&1 || ec=$?
check "validate with no file exits 0" "0" "$ec"

# file with preset and overrides
cat > "$WORK/proj/.loop-spec/profile.json" <<'JSON'
{ "preset": "autonomous", "env": { "LOOP_SPEC_ITERATE_MAX_ITERATIONS": "3" } }
JSON
check "env merges preset and override" "export LOOP_SPEC_AUTONOMOUS='1'
export LOOP_SPEC_ITERATE_MAX_ITERATIONS='3'
export LOOP_SPEC_NON_INTERACTIVE='1'
export LOOP_SPEC_ORACLE='self'" "$(bash "$SCRIPT" env)"
check "resolve names the file as source" "$WORK/proj/.loop-spec/profile.json" "$(bash "$SCRIPT" resolve | jq -r .source)"
check "resolve carries the override" "3" "$(bash "$SCRIPT" resolve | jq -r .env.LOOP_SPEC_ITERATE_MAX_ITERATIONS)"

# precedence: a variable already set in the environment is skipped (even when empty)
check "env skips a set variable" "" "$(LOOP_SPEC_ORACLE=supervisor bash "$SCRIPT" env | grep ORACLE || true)"
check "env skips an empty-but-set variable" "" "$(LOOP_SPEC_ORACLE= bash "$SCRIPT" env | grep ORACLE || true)"
check "--all prints a set variable anyway" "export LOOP_SPEC_ORACLE='self'" "$(LOOP_SPEC_ORACLE=supervisor bash "$SCRIPT" env --all | grep ORACLE)"

# override overrides a preset value
cat > "$WORK/proj/.loop-spec/profile.json" <<'JSON'
{ "preset": "supervised", "env": { "LOOP_SPEC_ORACLE": "self" } }
JSON
check "file env overrides the preset" "self" "$(bash "$SCRIPT" resolve | jq -r .env.LOOP_SPEC_ORACLE)"

# LOOP_SPEC_PROFILE_PRESET outranks the file's preset
check "preset variable outranks the file" "cloud" "$(LOOP_SPEC_PROFILE_PRESET=cloud bash "$SCRIPT" resolve | jq -r .preset)"
check "preset variable is the source" "LOOP_SPEC_PROFILE_PRESET" "$(LOOP_SPEC_PROFILE_PRESET=cloud bash "$SCRIPT" resolve | jq -r .source)"
rm "$WORK/proj/.loop-spec/profile.json"
check "preset variable alone works without a file" "1" "$(LOOP_SPEC_PROFILE_PRESET=autonomous bash "$SCRIPT" resolve | jq -r .env.LOOP_SPEC_AUTONOMOUS)"

# --file and LOOP_SPEC_PROFILE
printf '{"preset":"cloud"}' > "$WORK/elsewhere.json"
check "--file selects the file" "cloud" "$(bash "$SCRIPT" resolve --file "$WORK/elsewhere.json" | jq -r .preset)"
check "LOOP_SPEC_PROFILE selects the file" "cloud" "$(LOOP_SPEC_PROFILE="$WORK/elsewhere.json" bash "$SCRIPT" resolve | jq -r .preset)"

# validate fails closed on every malformed shape
printf '{"preset":"nope","env":{"FOO":"1","LOOP_SPEC_X":1},"extra":true}' > "$WORK/bad.json"
findings="$(bash "$SCRIPT" validate --file "$WORK/bad.json" 2>&1 >/dev/null)"; ec=$?
check "validate exits 1 on findings" "1" "$ec"
check "validate names the unknown preset" "yes" "$(grep -q "unknown preset 'nope'" <<<"$findings" && echo yes || echo no)"
check "validate names a non-LOOP_SPEC key" "yes" "$(grep -q "env key 'FOO'" <<<"$findings" && echo yes || echo no)"
check "validate names a non-string value" "yes" "$(grep -q "LOOP_SPEC_X' must be a string" <<<"$findings" && echo yes || echo no)"
check "validate names an unknown top-level key" "yes" "$(grep -q "unknown top-level key 'extra'" <<<"$findings" && echo yes || echo no)"
ec=0; bash "$SCRIPT" env --file "$WORK/bad.json" >/dev/null 2>&1 || ec=$?
check "env refuses an invalid file" "1" "$ec"
printf 'not json' > "$WORK/broken.json"
ec=0; bash "$SCRIPT" resolve --file "$WORK/broken.json" >/dev/null 2>&1 || ec=$?
check "resolve refuses a non-JSON file" "1" "$ec"

# eval safety: a value with a single quote survives the export line
printf '{"preset":"interactive","env":{"LOOP_SPEC_CMD_TEST":"echo '"'"'hi'"'"'"}}' > "$WORK/quote.json"
eval "$(bash "$SCRIPT" env --file "$WORK/quote.json")"
check "quoted value survives eval" "echo 'hi'" "${LOOP_SPEC_CMD_TEST:-}"

literal=$'echo $(touch should-not-exist) `false` *\nsecond line\n'
jq -n --arg value "$literal" '{env:{LOOP_SPEC_CMD_TEST:$value}}' > "$WORK/literal.json"
unset LOOP_SPEC_CMD_TEST
eval "$(bash "$SCRIPT" env --file "$WORK/literal.json")"
check "multiline command remains literal with its trailing newline" "$literal" "$LOOP_SPEC_CMD_TEST"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
