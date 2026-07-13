#!/usr/bin/env bash
# Structural lint for the bundled opencode plugin (extensions/opencode/loop-spec.ts).
#
# The plugin cannot be executed offline (it needs the opencode runtime), so
# this asserts the bridge CONTRACT textually — the same way
# tests/pi-extension.test.sh lints the pi extension:
#   - every bridged hook is registered (shell.env, tool.execute.after,
#     chat.message, event)
#   - every CC hook script the bridge claims to run actually exists and is
#     referenced by path
#   - the env vars the bash side depends on are all set
#   - imports are node builtins only (the lean-deps rule: loading the
#     plugin must never require an npm/bun install)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
EXT="extensions/opencode/loop-spec.ts"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

check "plugin file exists" "$([[ -f "$EXT" ]] && echo 1 || echo 0)"
# opencode plugins are named async-function exports, not default exports.
check "named plugin export" "$(grep -q 'export const LoopSpecPlugin' "$EXT" && echo 1 || echo 0)"

# Hooks the bridge contract requires (documented plugin API surface).
for hook in 'shell.env' 'tool.execute.after' 'chat.message'; do
  check "registers \"$hook\" hook" \
    "$(grep -q "\"$hook\": async" "$EXT" && echo 1 || echo 0)"
done
check "registers event hook" \
  "$(grep -q 'event: async' "$EXT" && echo 1 || echo 0)"

# Lifecycle events the event hook must branch on.
for ev in session.created session.idle; do
  check "handles $ev" \
    "$(grep -qF "\"$ev\"" "$EXT" && echo 1 || echo 0)"
done

# Native-surface couplings: the skill tool's result metadata carries the
# skill dir, and read args use filePath (opencode's parameter name).
check "tracks skill tool metadata.dir" \
  "$(grep -q 'metadata?.dir' "$EXT" && echo 1 || echo 0)"
check "read bridge uses filePath arg" \
  "$(grep -q 'filePath' "$EXT" && echo 1 || echo 0)"

# Bridged hook scripts: referenced in the plugin AND present on disk.
for script in \
  hooks/team/discipline-inject.sh \
  hooks/team/grill-inject.sh \
  hooks/team/simplicity-inject.sh \
  hooks/team/rules-inject.sh \
  hooks/team/micro-inject.sh \
  hooks/team/done-criteria.sh \
  hooks/team/session-end-learnings.sh; do
  check "bridges $script" \
    "$(grep -qF "$script" "$EXT" && [[ -f "$script" ]] && echo 1 || echo 0)"
done

# Env bridge: the bash side (lib/harness.sh, hooks, skill bodies) reads these.
for var in LOOP_SPEC_HARNESS CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR CLAUDE_SKILL_DIR; do
  check "sets env.$var" \
    "$(grep -q "env.$var" "$EXT" && echo 1 || echo 0)"
done
check "harness identity is opencode" \
  "$(grep -q 'LOOP_SPEC_HARNESS = "opencode"' "$EXT" && echo 1 || echo 0)"

# Symlinked installs (lib/opencode-install.sh) must still resolve
# ${CLAUDE_SKILL_DIR}/../../lib — the plugin realpaths tracked dirs.
check "realpaths symlinked paths" \
  "$(grep -q 'realpathSync' "$EXT" && echo 1 || echo 0)"

# Lean deps: node builtins only. Any non-"node:" import means the plugin
# would need an npm/bun install to load, which the packaging contract forbids.
bad_imports="$(grep -E '^\s*import .* from "' "$EXT" | grep -v 'from "node:' || true)"
check "imports are node builtins only" "$([[ -z "$bad_imports" ]] && echo 1 || echo 0)"
[[ -n "$bad_imports" ]] && echo "  offending imports: $bad_imports"

# Fail-open discipline: every handler body must swallow its own errors.
check "fail-open catch blocks present" \
  "$(grep -c 'catch' "$EXT" | awk '{print ($1 >= 6) ? 1 : 0}')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
