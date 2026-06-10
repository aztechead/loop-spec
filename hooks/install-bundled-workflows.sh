#!/usr/bin/env bash
# Mirror selected workflow scripts to .claude/workflows/ AND inject template
# snippets at // @inject:* markers. Idempotent.
set -euo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}"
LIB="$ROOT/lib/workflows"
TPL="$LIB/templates"
DEST="$ROOT/.claude/workflows"
mkdir -p "$DEST"

inject() {
  local script="$1"
  local tmp
  tmp="$(mktemp)"
  python3 - "$script" "$TPL/tier-params.snippet.js" "$TPL/schemas.snippet.js" > "$tmp" <<'PY'
import re, sys
script_path, tier_path, schemas_path = sys.argv[1:4]
with open(script_path) as f: src = f.read()
with open(tier_path)   as f: tier = f.read().rstrip() + "\n"
with open(schemas_path) as f: schemas = f.read().rstrip() + "\n"
src = re.sub(r"// @inject:tier-params\n(?:.*?// @inject:end\n)?",
             f"// @inject:tier-params\n{tier}// @inject:end\n", src, flags=re.S)
src = re.sub(r"// @inject:schemas\n(?:.*?// @inject:end\n)?",
             f"// @inject:schemas\n{schemas}// @inject:end\n", src, flags=re.S)
sys.stdout.write(src)
PY
  mv "$tmp" "$script"
}

for s in map-codebase acceptance-verify code-review-dimensions plan-multi-angle execute-dag; do
  src="$LIB/${s}.js"
  [[ -f "$src" ]] || continue
  inject "$src"
done

# Bundled slash-command mirrors
for pair in "code-review-dimensions:codebase-audit" "plan-multi-angle:multi-angle-plan"; do
  src_name="${pair%%:*}"
  dst_name="${pair##*:}"
  src="$LIB/${src_name}.js"
  dst="$DEST/super-spec-${dst_name}.js"
  [[ -f "$src" ]] || continue
  if [[ -L "$dst" || -f "$dst" ]]; then rm -f "$dst"; fi
  ln -s "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
done

echo "install-bundled-workflows: ok"
