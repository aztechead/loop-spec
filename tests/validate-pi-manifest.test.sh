#!/usr/bin/env bash
# Validate the pi package manifest (package.json `pi` key) that makes loop-spec
# installable as a pi (https://pi.dev) package alongside the Claude Code plugin.
#
# Guards the dual-harness contract:
#   - package.json stays valid JSON with the pi resource map intact
#   - the version stays in lockstep with .claude-plugin/plugin.json (one release
#     number across both harness manifests, same rule as marketplace.json)
#   - every declared pi resource path exists (a renamed skills/ dir or prompt
#     file would silently install an empty package)
#   - declared extensions are pi-shaped (default-export factory) and set the
#     LOOP_SPEC_HARNESS bridge env that lib/harness.sh detects
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

PKG="package.json"
PLUGIN=".claude-plugin/plugin.json"

check "package.json exists" "$([[ -f "$PKG" ]] && echo 1 || echo 0)"
check "package.json is valid JSON" "$(jq -e . "$PKG" >/dev/null 2>&1 && echo 1 || echo 0)"

# Identity: same package name as the plugin, discoverable in the pi gallery.
check "name is loop-spec" \
  "$([[ "$(jq -r '.name' "$PKG")" == "loop-spec" ]] && echo 1 || echo 0)"
check "keywords include pi-package" \
  "$(jq -e '.keywords | index("pi-package")' "$PKG" >/dev/null 2>&1 && echo 1 || echo 0)"

# One version number across both harness manifests.
pkg_ver="$(jq -r '.version // empty' "$PKG")"
plugin_ver="$(jq -r '.version // empty' "$PLUGIN")"
check "version matches plugin.json ($plugin_ver)" \
  "$([[ -n "$pkg_ver" && "$pkg_ver" == "$plugin_ver" ]] && echo 1 || echo 0)"

# Resource map: skills must be declared (they are the whole point of the package).
check "pi.skills declares ./skills" \
  "$(jq -e '.pi.skills | index("./skills")' "$PKG" >/dev/null 2>&1 && echo 1 || echo 0)"

# Every declared path exists. Globs are not used in this manifest on purpose:
# literal paths keep this existence lint honest.
for key in skills prompts extensions; do
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    check "pi.$key path exists: $p" "$([[ -e "$p" ]] && echo 1 || echo 0)"
  done < <(jq -r ".pi.$key // [] | .[]" "$PKG")
done

# Prompts double as Claude Code commands; pi needs frontmatter description
# (or first line) and $ARGUMENTS-style substitution both harnesses support.
while IFS= read -r p; do
  [[ -z "$p" || ! -f "$p" ]] && continue
  check "prompt $p has a description frontmatter" \
    "$(grep -q '^description:' "$p" && echo 1 || echo 0)"
done < <(jq -r '.pi.prompts // [] | .[]' "$PKG")

# Extensions (when declared) must be pi-loadable factories that set the
# harness bridge env; lib/harness.sh keys its pi answer off LOOP_SPEC_HARNESS.
while IFS= read -r p; do
  [[ -z "$p" || ! -f "$p" ]] && continue
  check "extension $p exports a default factory" \
    "$(grep -q 'export default' "$p" && echo 1 || echo 0)"
  check "extension $p sets LOOP_SPEC_HARNESS" \
    "$(grep -q 'LOOP_SPEC_HARNESS' "$p" && echo 1 || echo 0)"
done < <(jq -r '.pi.extensions // [] | .[]' "$PKG")

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
