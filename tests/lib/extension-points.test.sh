#!/usr/bin/env bash
# Tests for lib/extension-points.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/extension-points.sh"
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

contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected output to contain '$needle', got '$haystack')"; ((FAIL++)) || true
  fi
}

absent() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected output NOT to contain '$needle', got '$haystack')"; ((FAIL++)) || true
  fi
}

rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "A: no subcommand is a usage error" "2" "$rc"
rc=0; bash "$SCRIPT" instructions plan sideways >/dev/null 2>&1 || rc=$?
check "B: unknown instruction position is a usage error" "2" "$rc"

WORK="${TMPDIR:-/tmp}/loop-spec-extension-points.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.loop-spec/prompts" "$WORK/docs/context"
cd "$WORK"
export LOOP_SPEC_EXTENSIONS=".loop-spec/extensions.json"

# An absent file is the normal case, not an error: most projects declare nothing.
rc=0; out="$(bash "$SCRIPT" layers verify)" || rc=$?
check "C: no config emits no layers" "0" "$rc"
check "D: no config emits nothing" "" "$out"
rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "E: validate accepts an absent config" "0" "$rc"
contains "F: validate says why it passed" "extensions=none" "$out"

printf 'Check the domain invariants.\n' > .loop-spec/prompts/invariants.md
printf 'context\n' > docs/context/one.md
printf 'context\n' > docs/context/two.md
cat > .loop-spec/extensions.json <<'EOF'
{
  "schemaVersion": 1,
  "reviewLayers": [
    {"id": "domain-invariants", "name": "Domain invariants",
     "promptFile": ".loop-spec/prompts/invariants.md", "phase": "verify"},
    {"id": "plan-shape", "name": "Plan shape", "phase": "plan"},
    {"id": "retired", "name": "Retired layer", "phase": "verify", "enabled": false}
  ],
  "phaseInstructions": {
    "plan": {"prepend": ["Prefer the existing queue abstraction."], "append": ["Name the rollback step."]}
  },
  "persistentFacts": ["file:docs/context/*.md", "The staging database is read-only."]
}
EOF

out="$(bash "$SCRIPT" layers verify)"
contains "G: a declared layer is emitted for its phase" "layer=domain-invariants name=Domain invariants" "$out"
contains "H: the layer carries its prompt path" "prompt=.loop-spec/prompts/invariants.md" "$out"
absent "I: another phase's layer is not emitted" "plan-shape" "$out"
absent "J: a disabled layer is not emitted" "retired" "$out"

out="$(bash "$SCRIPT" layers plan)"
contains "K: layers are selected per phase" "layer=plan-shape" "$out"

out="$(bash "$SCRIPT" instructions plan prepend)"
check "L: prepend instructions are emitted verbatim" "Prefer the existing queue abstraction." "$out"
out="$(bash "$SCRIPT" instructions plan append)"
check "M: append instructions are emitted verbatim" "Name the rollback step." "$out"
out="$(bash "$SCRIPT" instructions verify prepend)"
check "N: a phase with no instructions emits nothing" "" "$out"

out="$(bash "$SCRIPT" facts)"
contains "O: glob facts resolve to real paths" "fact=file path=docs/context/one.md" "$out"
contains "P: every glob match is emitted" "fact=file path=docs/context/two.md" "$out"
contains "Q: literal facts pass through" "fact=literal text=The staging database is read-only." "$out"

rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "R: a well-formed config validates" "0" "$rc"
contains "S: validate reports what it accepted" "extensions=valid" "$out"

# The guardrail: extensions add, they never shadow a built-in gate.
cat > .loop-spec/extensions.json <<'EOF'
{"schemaVersion": 1, "reviewLayers": [{"id": "security", "name": "Mine", "phase": "verify"}]}
EOF
rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "T: claiming a built-in gate id fails validation" "1" "$rc"
contains "U: the protected-id finding names the id" "finding=protected-id id=security" "$out"

cat > .loop-spec/extensions.json <<'EOF'
{"schemaVersion": 1, "reviewLayers": [{"id": "test-tamper", "name": "Mine", "phase": "verify"}]}
EOF
rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "V: the tamper gate id is protected too" "1" "$rc"

cat > .loop-spec/extensions.json <<'EOF'
{"schemaVersion": 1, "reviewLayers": [{"id": "mine", "name": "Mine", "phase": "shipping"}]}
EOF
rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "W: an unknown phase fails validation" "1" "$rc"
contains "X: the unknown-phase finding names the phase" "finding=unknown-phase id=mine phase=shipping" "$out"

cat > .loop-spec/extensions.json <<'EOF'
{"schemaVersion": 1, "reviewLayers": [{"id": "mine", "name": "Mine", "promptFile": ".loop-spec/prompts/gone.md"}]}
EOF
rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "Y: a missing prompt file fails validation" "1" "$rc"
contains "Z: the missing-prompt finding names the path" "finding=missing-prompt id=mine" "$out"

cat > .loop-spec/extensions.json <<'EOF'
{"schemaVersion": 2, "reviewLayers": []}
EOF
rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "AA: an unsupported schema version fails validation" "1" "$rc"
contains "AB: the schema finding reports the value seen" "finding=schema-version value=2" "$out"

# A bounded number of layers: an unbounded list is a context budget nobody set.
cat > .loop-spec/extensions.json <<'EOF'
{"schemaVersion": 1, "reviewLayers": [
  {"id": "a", "name": "A"}, {"id": "b", "name": "B"}, {"id": "c", "name": "C"},
  {"id": "d", "name": "D"}, {"id": "e", "name": "E"}, {"id": "f", "name": "F"}
]}
EOF
rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "AC: more layers than the cap fails validation" "1" "$rc"
contains "AD: the cap finding reports the count" "finding=too-many-layers count=6" "$out"
out="$(bash "$SCRIPT" layers verify)"
check "AE: the read path emits no more than the cap" "5" "$(printf '%s\n' "$out" | grep -c '^layer=')"

# Malformed JSON must never block a phase -- the read paths fail open.
printf '{ this is not json' > .loop-spec/extensions.json
rc=0; out="$(bash "$SCRIPT" layers verify 2>/dev/null)" || rc=$?
check "AF: malformed config still exits 0 on the read path" "0" "$rc"
check "AG: malformed config yields no layers" "" "$out"
rc=0; out="$(bash "$SCRIPT" validate)" || rc=$?
check "AH: validate fails closed on malformed config" "1" "$rc"
contains "AI: the unparseable finding is explicit" "finding=unparseable" "$out"

# Authority never reads this file. The scripts that decide whether the loop may
# act without a human must not learn to consult a user-authored config.
ROOT="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
authority_leak=0
for script in trust.sh autonomous-chain.sh task-route.sh execute-rung.sh; do
  if grep -q "extension-points\|LOOP_SPEC_EXTENSIONS" "$ROOT/lib/$script" 2>/dev/null; then
    authority_leak=1
    echo "  authority script reads extensions: lib/$script"
  fi
done
check "AJ: no authority script reads the extensions file" "0" "$authority_leak"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
