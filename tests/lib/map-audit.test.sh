#!/usr/bin/env bash
# Tests for lib/map-audit.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/map-audit.sh"
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
rc=0; LOOP_SPEC_MAP_DIR=/nonexistent bash "$SCRIPT" budget >/dev/null 2>&1 || rc=$?
check "B: a missing map directory exits 2" "2" "$rc"

WORK="${TMPDIR:-/tmp}/loop-spec-map-audit.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/map" "$WORK/state" "$WORK/lib" "$WORK/skills"
cd "$WORK"
export LOOP_SPEC_MAP_DIR="map"
export LOOP_SPEC_MAP_INDEX="state/index.json"

printf 'real\n' > lib/present.sh
printf 'real\n' > skills/thing.md

cat > map/ARCH.md <<'EOF'
# Architecture

The orchestrator lives in lib/present.sh and the phase skill in skills/thing.md.
Feature state is written per slug under docs/loop-spec/features/{slug}/SPEC.md.
Every helper matches lib/*.sh by convention.
EOF
TODAY="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > state/index.json <<EOF
{"last_refreshed_at": {"arch": "$TODAY"}, "files": {"lib/present.sh": ["arch"]}}
EOF

rc=0; out="$(bash "$SCRIPT" budget)" || rc=$?
check "C: a small map is under budget" "0" "$rc"
contains "D: budget reports the measured total" "budget=under lines=5 ceiling=1000" "$out"
contains "E: budget reports per-document lines" "doc=map/ARCH.md lines=5" "$out"

rc=0; out="$(LOOP_SPEC_MAP_MAX_LINES=3 bash "$SCRIPT" budget)" || rc=$?
check "F: exceeding the ceiling is a finding" "1" "$rc"
contains "G: the over-budget finding names the ceiling" "finding=over-budget lines=5 ceiling=3" "$out"

rc=0; out="$(bash "$SCRIPT" sweep)" || rc=$?
check "H: a map citing only real paths sweeps clean" "0" "$rc"
contains "I: sweep reports how many claims it checked" "sweep=clean checked=2" "$out"
absent "J: placeholder paths are not treated as claims" "features/{slug}" "$out"
absent "K: globs are not treated as claims" "lib/*.sh" "$out"

printf 'The retired helper is at lib/deleted.sh today.\n' >> map/ARCH.md
rc=0; out="$(bash "$SCRIPT" sweep)" || rc=$?
check "L: a citation to a missing file is a finding" "1" "$rc"
contains "M: the stale-claim finding names path and source line" \
  "finding=stale-claim path=lib/deleted.sh" "$out"

# Source-pinned staleness (ported from BMAD's context.py sweep): a claim is suspect
# when the file it rests on changed AFTER the domain was refreshed. A whole-domain
# age check cannot see this — the map can be days old and still lie about a file
# that changed yesterday.
git init -q .
git config user.email t@example.com
git config user.name Test
git add -A
git commit -qm base
cat > map/ARCH.md <<'EOF'
# Architecture

The orchestrator lives in lib/present.sh.
EOF
cat > state/index.json <<'EOF'
{"last_refreshed_at": {"arch": "2020-01-01T00:00:00Z"}, "files": {}}
EOF
printf 'changed after the refresh\n' >> lib/present.sh
git add -A
git commit -qm "touch the cited source"
rc=0; out="$(bash "$SCRIPT" sweep)" || rc=$?
check "L2: a source that changed after the refresh is a finding" "1" "$rc"
contains "L3: the outdated finding names source and refresh dates" \
  "finding=outdated-claim path=lib/present.sh" "$out"
contains "L4: the outdated finding explains the comparison" "after arch was refreshed" "$out"
contains "L5: sweep counts missing and outdated separately" "missing=0 outdated=1" "$out"

# A source untouched since the refresh is not a finding.
cat > state/index.json <<EOF
{"last_refreshed_at": {"arch": "$(date -u +%Y-%m-%d)T23:59:59Z"}, "files": {}}
EOF
rc=0; out="$(bash "$SCRIPT" sweep)" || rc=$?
check "L6: a source older than the refresh sweeps clean" "0" "$rc"
contains "L7: clean sweep reports both counters" "missing=0 outdated=0" "$out"

# No refresh date for a domain means no basis to judge — never a false positive.
cat > state/index.json <<'EOF'
{"last_refreshed_at": {}, "files": {}}
EOF
rc=0; bash "$SCRIPT" sweep >/dev/null 2>&1 || rc=$?
check "L8: an unrefreshed domain yields no outdated findings" "0" "$rc"

cat > map/ARCH.md <<'EOF'
# Architecture

The orchestrator lives in lib/present.sh and the phase skill in skills/thing.md.
Feature state is written per slug under docs/loop-spec/features/{slug}/SPEC.md.
Every helper matches lib/*.sh by convention.
The retired helper is at lib/deleted.sh today.
EOF

# The append-only index leak: a deleted file keeps voting on domain staleness.
cat > state/index.json <<EOF
{"last_refreshed_at": {"arch": "$TODAY"},
 "files": {"lib/present.sh": ["arch"], "lib/removed.sh": ["arch"]}}
EOF
rc=0; out="$(bash "$SCRIPT" orphans)" || rc=$?
check "N: an index entry with no file is a finding" "1" "$rc"
contains "O: the orphan finding names the path" "finding=orphan-index-entry path=lib/removed.sh" "$out"
contains "P: orphans reports the index size it read" "orphans=1 indexed=2" "$out"

cat > state/index.json <<EOF
{"last_refreshed_at": {"arch": "$TODAY"}, "files": {"lib/present.sh": ["arch"]}}
EOF
rc=0; out="$(bash "$SCRIPT" orphans)" || rc=$?
check "Q: a clean index reports no findings" "0" "$rc"

rc=0; out="$(bash "$SCRIPT" staleness)" || rc=$?
check "R: a freshly refreshed domain is not stale" "0" "$rc"
contains "S: staleness reports the measured age" "domain=arch age_days=0" "$out"

cat > state/index.json <<EOF
{"last_refreshed_at": {"arch": "2020-01-01T00:00:00Z"}, "files": {}}
EOF
rc=0; out="$(bash "$SCRIPT" staleness)" || rc=$?
check "T: a domain past the age ceiling is a finding" "1" "$rc"
contains "U: the stale-domain finding names the domain" "finding=stale-domain domain=arch" "$out"

# The disagreement case: the prose knows it is stale, the machine state does not.
cat > map/CONCERNS.md <<'EOF'
# Concerns

> **STALE — pre-v1.0.0 snapshot.**

Nothing here has been re-derived since.
EOF
cat > state/index.json <<EOF
{"last_refreshed_at": {"arch": "$TODAY", "concerns": "$TODAY"}, "files": {}}
EOF
rc=0; out="$(bash "$SCRIPT" staleness)" || rc=$?
check "V: a doc declaring STALE while the index says fresh is a finding" "1" "$rc"
contains "W: the disagreement finding names the document" \
  "finding=trust-disagreement path=map/CONCERNS.md" "$out"

rm map/CONCERNS.md
cat > state/index.json <<EOF
{"last_refreshed_at": {"arch": "$TODAY"}, "files": {"lib/present.sh": ["arch"]}}
EOF

# audit runs every check in one pass.
rc=0; out="$(bash "$SCRIPT" audit)" || rc=$?
check "X: audit surfaces the outstanding stale claim" "1" "$rc"
contains "Y: audit includes the budget measurement" "budget=under" "$out"
contains "Z: audit includes the sweep measurement" "sweep=stale" "$out"
contains "AA: audit includes the orphan measurement" "orphans=0" "$out"
contains "AB: audit includes the staleness measurement" "staleness=checked" "$out"

# A missing index is unknown, never silently clean.
rm state/index.json
out="$(bash "$SCRIPT" orphans || true)"
contains "AC: a missing index reports unknown, not clean" "orphans=unknown" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
