#!/usr/bin/env bash
# bump-version.sh - Set the loop-spec version everywhere it is declared, at once.
#
# The version lives in four places that must agree: three manifests (the Claude
# Code plugin, the marketplace entry, the pi package) and one line of README
# prose. `tests/validate-manifest.test.sh` enforces the agreement, but only after
# a human has already forgotten one — this removes the class instead of catching it.
#
# Usage:
#   bump-version.sh <version>   set every declaration to <version>
#   bump-version.sh --check     print the current version; exit 1 if they disagree
#
# Exits non-zero on a malformed version or an unwritable file. Idempotent: setting
# the version that is already in place is a no-op that still exits 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PLUGIN="$ROOT/.claude-plugin/plugin.json"
MARKET="$ROOT/.claude-plugin/marketplace.json"
PACKAGE="$ROOT/package.json"
README="$ROOT/README.md"

read_current() {
  jq -r '.version // empty' "$PLUGIN" 2>/dev/null || true
}

check() {
  local pv mv kv rv status=0
  pv="$(jq -r '.version // empty' "$PLUGIN" 2>/dev/null || true)"
  mv="$(jq -r '.plugins[0].version // .version // empty' "$MARKET" 2>/dev/null || true)"
  kv="$(jq -r '.version // empty' "$PACKAGE" 2>/dev/null || true)"
  rv="$(grep -oE '^Current version: [0-9]+\.[0-9]+\.[0-9]+' "$README" 2>/dev/null | head -1 | awk '{print $3}')"
  for pair in "plugin.json:$pv" "marketplace.json:$mv" "package.json:$kv" "README.md:$rv"; do
    local name="${pair%%:*}" val="${pair#*:}"
    if [[ -z "$val" ]]; then
      echo "bump-version: no version found in $name" >&2; status=1
    elif [[ "$val" != "$pv" ]]; then
      echo "bump-version: $name is $val, plugin.json is $pv" >&2; status=1
    fi
  done
  [[ "$status" -eq 0 ]] && echo "$pv"
  return "$status"
}

case "${1:-}" in
  --check)
    check
    ;;
  "")
    echo "usage: bump-version.sh <version> | --check" >&2
    exit 2
    ;;
  *)
    version="$1"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "bump-version: '$version' is not a semantic version (X.Y.Z)" >&2
      exit 2
    }
    current="$(read_current)"

    for f in "$PLUGIN" "$MARKET" "$PACKAGE" "$README"; do
      [[ -w "$f" ]] || { echo "bump-version: cannot write $f" >&2; exit 1; }
    done

    # jq -S would reorder keys; edit the declaration line in place instead so the
    # manifests stay byte-identical apart from the version itself.
    python3 - "$version" "$PLUGIN" "$MARKET" "$PACKAGE" "$README" <<'PY'
import re
import sys

version, plugin, market, package, readme = sys.argv[1:6]

for path in (plugin, market, package):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    new, count = re.subn(r'("version"\s*:\s*")[0-9]+\.[0-9]+\.[0-9]+(")',
                         lambda m: m.group(1) + version + m.group(2), text)
    if count == 0:
        sys.exit("bump-version: no version declaration in {}".format(path))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)

with open(readme, encoding="utf-8") as fh:
    text = fh.read()
new, count = re.subn(r'(?m)^(Current version: )[0-9]+\.[0-9]+\.[0-9]+',
                     lambda m: m.group(1) + version, text)
if count == 0:
    sys.exit("bump-version: no 'Current version:' line in {}".format(readme))
with open(readme, "w", encoding="utf-8") as fh:
    fh.write(new)
PY

    if [[ "$current" == "$version" ]]; then
      echo "loop-spec already at $version (no change)"
    else
      echo "loop-spec ${current:-?} -> $version"
    fi
    echo "Remember: add a CHANGELOG entry for $version."
    ;;
esac
