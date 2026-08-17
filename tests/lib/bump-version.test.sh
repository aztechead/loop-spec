#!/usr/bin/env bash
# Tests for lib/bump-version.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/lib/bump-version.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/bump-version-test.$$"
trap 'rm -rf "$WORK"' EXIT

# A throwaway tree with the same four declaration sites as the real repo.
make_fixture() {
  local dir="$1" version="$2" readme_version="${3:-$2}"
  rm -rf "$dir"; mkdir -p "$dir/.claude-plugin" "$dir/lib"
  printf '{\n  "name": "loop-spec",\n  "version": "%s",\n  "keep": "me"\n}\n' "$version" \
    > "$dir/.claude-plugin/plugin.json"
  printf '{\n  "plugins": [\n    {\n      "name": "loop-spec",\n      "version": "%s"\n    }\n  ]\n}\n' "$version" \
    > "$dir/.claude-plugin/marketplace.json"
  printf '# loop-spec\n\nCurrent version: %s (renamed at v2.5.2).\n\nMore prose 1.0.0 here.\n' \
    "$readme_version" > "$dir/README.md"
  cp "$LIB" "$dir/lib/bump-version.sh"
}

# --- the real repo agrees with itself ---
real="$(bash "$LIB" --check)"
check "--check passes on the real repo" "0" "$?"
check "--check reports the manifest version" \
  "$(jq -r '.version' "$REPO/.claude-plugin/plugin.json")" "$real"

# --- argument validation ---
rc=0; bash "$LIB" >/dev/null 2>&1 || rc=$?
check "no argument exits 2" "2" "$rc"
rc=0; bash "$LIB" 2.25 >/dev/null 2>&1 || rc=$?
check "non-semver exits 2" "2" "$rc"
rc=0; bash "$LIB" v2.25.0 >/dev/null 2>&1 || rc=$?
check "leading v rejected" "2" "$rc"

# --- sets all four sites at once ---
FX="$WORK/fx"
make_fixture "$FX" "1.0.0"
bash "$FX/lib/bump-version.sh" 2.30.1 >/dev/null 2>&1
check "plugin.json set" "2.30.1" "$(jq -r '.version' "$FX/.claude-plugin/plugin.json")"
check "marketplace.json set" "2.30.1" "$(jq -r '.plugins[0].version' "$FX/.claude-plugin/marketplace.json")"
check "README prose set" "2.30.1" "$(grep -oE '^Current version: [0-9.]+' "$FX/README.md" | awk '{print $3}')"
check "other manifest keys untouched" "me" "$(jq -r '.keep' "$FX/.claude-plugin/plugin.json")"
check "unrelated README versions untouched" "1" "$(grep -c 'More prose 1.0.0 here' "$FX/README.md")"

# --- idempotent ---
bash "$FX/lib/bump-version.sh" 2.30.1 >/dev/null 2>&1
check "re-setting the same version exits 0" "0" "$?"

# --- --check catches drift, which is the whole point ---
FX2="$WORK/fx2"
make_fixture "$FX2" "2.0.0" "1.9.9"     # README left behind, the exact mistake
rc=0; out="$(bash "$FX2/lib/bump-version.sh" --check 2>&1)" || rc=$?
check "drifted README fails --check" "1" "$rc"
check "drift names the offending file" "1" "$(grep -c 'README.md is 1.9.9' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
