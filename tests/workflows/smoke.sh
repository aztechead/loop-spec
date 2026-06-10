#!/usr/bin/env bash
# Smoke test: syntax-check all workflow scripts after install hook runs.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Resolve a working node binary. Bare `node` may be an nvm shim that swallows
# --check in non-interactive shells; fall back to the explicit nvm v22 path.
NODE="node"
if ! command -v node >/dev/null 2>&1 || ! node --version >/dev/null 2>&1; then
  NVM_NODE="$HOME/.nvm/versions/node/v22.14.0/bin/node"
  if [[ -x "$NVM_NODE" ]]; then
    NODE="$NVM_NODE"
  fi
fi

# Workflow scripts are written in the Claude Code dynamic-workflow dialect:
# `export const meta` plus a script body the runtime wraps in an async function
# with injected globals (args, phase, agent, parallel) — so top-level `return`
# and `await` are legal there. Bare `node --check <file>.js` parses CommonJS
# module scope and rejects both `export` and `return`. Emulate the runtime
# wrapper: strip the leading `export ` keywords and wrap the body in an async
# function, then syntax-check the result as ESM (.mjs).
ESM_TMP="$(mktemp -d)"
trap 'rm -rf "$ESM_TMP"' EXIT
check_esm() {
  local src="$1"
  local tmp="$ESM_TMP/$(basename "${src%.js}").mjs"
  {
    echo 'async function __workflow__(args, phase, agent, parallel, output) {'
    sed 's/^export //' "$src"
    echo '}'
  } > "$tmp"
  "$NODE" --check "$tmp"
}

# Run install hook to inject snippets
bash hooks/install-bundled-workflows.sh > /dev/null

# Syntax check each script
fail=0
for s in map-codebase acceptance-verify code-review-dimensions plan-multi-angle execute-dag; do
  script="lib/workflows/${s}.js"
  if [[ ! -f "$script" ]]; then
    echo "FAIL: $script does not exist"
    fail=1
    continue
  fi
  if ! check_esm "$script" 2>&1; then
    echo "FAIL: $script syntax error"
    fail=1
  else
    echo "ok: $script"
  fi
done

# Verify bundled mirrors exist
for f in super-spec-codebase-audit.js super-spec-multi-angle-plan.js; do
  if [[ ! -e ".claude/workflows/$f" ]]; then
    echo "FAIL: .claude/workflows/$f missing"
    fail=1
  else
    echo "ok: .claude/workflows/$f"
  fi
done

# Idempotency: second hook run produces identical files
bash hooks/install-bundled-workflows.sh > /dev/null
for s in map-codebase acceptance-verify code-review-dimensions plan-multi-angle execute-dag; do
  if ! check_esm "lib/workflows/${s}.js" 2>&1; then
    echo "FAIL: $s broken after second install"
    fail=1
  fi
done
echo "ok: idempotent"

exit $fail
