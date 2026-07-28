#!/usr/bin/env bash
# Tests for lib/plugin-version.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/lib/plugin-version.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/plugin-version-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

run() { env -u LOOP_SPEC_VERSION "$@" bash "$LIB"; }

# The real manifest is the source of truth and must agree with it exactly.
manifest_version="$(jq -r '.version' "$REPO/.claude-plugin/plugin.json")"
check "reports the manifest version" "$manifest_version" "$(run)"
check "version is non-empty" "0" "$([[ -n "$manifest_version" ]] && echo 0 || echo 1)"

# Explicit override for vendored installs and for tests that pin a version.
check "override wins" "9.9.9" "$(env LOOP_SPEC_VERSION=9.9.9 bash "$LIB")"

# Never fail a cycle over a missing manifest — an unknown version is still a
# usable datum, an aborted terminal result is not.
cp "$LIB" "$WORK/plugin-version.sh"
check "missing manifest degrades to unknown" "unknown" "$(env -u LOOP_SPEC_VERSION bash "$WORK/plugin-version.sh")"

mkdir -p "$WORK/.claude-plugin"
printf 'not json at all\n' > "$WORK/.claude-plugin/plugin.json"
mkdir -p "$WORK/lib"
cp "$LIB" "$WORK/lib/plugin-version.sh"
check "unparseable manifest degrades to unknown" "unknown" "$(env -u LOOP_SPEC_VERSION bash "$WORK/lib/plugin-version.sh")"

printf '{"name":"loop-spec"}\n' > "$WORK/.claude-plugin/plugin.json"
check "manifest without version degrades to unknown" "unknown" "$(env -u LOOP_SPEC_VERSION bash "$WORK/lib/plugin-version.sh")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
