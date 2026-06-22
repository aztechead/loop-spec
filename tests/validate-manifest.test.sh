#!/usr/bin/env bash
# Validates manifest/version consistency and guards against model-id drift.
# Catches the recurring failure where plugin.json, marketplace.json, and the
# CHANGELOG fall out of sync, or a retired model id lingers in shipped docs.
#
# Usage: bash tests/validate-manifest.test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# 1. plugin.json version == marketplace.json plugin version
PLUGIN_VER=$(jq -r '.version' .claude-plugin/plugin.json)
MARKET_VER=$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)
if [[ "$PLUGIN_VER" == "$MARKET_VER" ]]; then
  pass "plugin.json ($PLUGIN_VER) == marketplace.json ($MARKET_VER)"
else
  fail "version drift: plugin.json=$PLUGIN_VER marketplace.json=$MARKET_VER"
fi

# 2. CHANGELOG top version heading matches plugin.json version
# Accepts a semver prerelease suffix (e.g. 1.2.0-dev) for rolling main builds,
# which release tooling strips at release time.
CHANGELOG_VER=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?\]' CHANGELOG.md | tr -d '## []')
if [[ "$CHANGELOG_VER" == "$PLUGIN_VER" ]]; then
  pass "CHANGELOG top ([$CHANGELOG_VER]) == plugin.json ($PLUGIN_VER)"
else
  fail "CHANGELOG top version [$CHANGELOG_VER] != plugin.json $PLUGIN_VER"
fi

# 3. hooks.json is valid JSON
if jq -e . hooks/hooks.json >/dev/null 2>&1; then
  pass "hooks/hooks.json is valid JSON"
else
  fail "hooks/hooks.json is not valid JSON"
fi

# 4. No retired opus model id in shipped agents/skills/README (allow CHANGELOG history).
if grep -rn 'claude-opus-4-7' agents skills README.md 2>/dev/null | grep -v '/docs/loop-spec/' >/tmp/loop-spec-opus47.$$; then
  fail "retired claude-opus-4-7 referenced in shipped docs:"
  cat /tmp/loop-spec-opus47.$$
else
  pass "no retired claude-opus-4-7 in shipped agents/skills/README"
fi
rm -f /tmp/loop-spec-opus47.$$

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
