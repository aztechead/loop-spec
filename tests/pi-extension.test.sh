#!/usr/bin/env bash
# Structural lint for the bundled pi extension (extensions/pi/loop-spec.ts).
#
# The extension cannot be executed offline (it needs the pi runtime), so this
# asserts the bridge CONTRACT textually — the same way harness-call-shapes
# lints skill tool calls:
#   - every bridged event handler is registered
#   - every CC hook script the bridge claims to run actually exists and is
#     referenced by path
#   - the three env vars the bash side depends on are all set
#   - imports are node builtins only (the lean-deps rule: loading the
#     extension must never require an npm install)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
EXT="extensions/pi/loop-spec.ts"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

check "extension file exists" "$([[ -f "$EXT" ]] && echo 1 || echo 0)"
check "default factory export" "$(grep -q 'export default function' "$EXT" && echo 1 || echo 0)"

# Event handlers the bridge contract requires.
for ev in session_start before_agent_start input tool_call session_shutdown; do
  check "registers $ev handler" \
    "$(grep -q "pi.on(\"$ev\"" "$EXT" && echo 1 || echo 0)"
done

# Bridged hook scripts: referenced in the extension AND present on disk.
for script in \
  hooks/team/discipline-inject.sh \
  hooks/team/grill-inject.sh \
  hooks/team/simplicity-inject.sh \
  hooks/team/rules-inject.sh \
  hooks/team/done-criteria.sh \
  hooks/team/session-end-learnings.sh; do
  check "bridges $script" \
    "$(grep -qF "$script" "$EXT" && [[ -f "$script" ]] && echo 1 || echo 0)"
done

# Env bridge: the bash side (lib/harness.sh, hooks, skill bodies) reads these.
for var in LOOP_SPEC_HARNESS CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR CLAUDE_SKILL_DIR; do
  check "sets process.env.$var" \
    "$(grep -q "process.env.$var" "$EXT" && echo 1 || echo 0)"
done

# Lean deps: node builtins only. Any non-"node:" import means the extension
# would need an npm install to load, which the packaging contract forbids.
bad_imports="$(grep -E '^\s*import .* from "' "$EXT" | grep -v 'from "node:' || true)"
check "imports are node builtins only" "$([[ -z "$bad_imports" ]] && echo 1 || echo 0)"
[[ -n "$bad_imports" ]] && echo "  offending imports: $bad_imports"

# Fail-open discipline: every handler body must swallow its own errors.
check "fail-open catch blocks present" \
  "$(grep -c 'catch' "$EXT" | awk '{print ($1 >= 5) ? 1 : 0}')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
