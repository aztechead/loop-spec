#!/usr/bin/env bash
# feature.json has one reader: lib/feature_read.py (launched by lib/feature-read.sh),
# whose key space is graph/schema.json's stateKey enum. Every other `jq ... feature.json`
# was its own untyped reader (docs/loop-spec/orchestrator-port-plan.md, WP3). This pin
# fails on a feature.json read anywhere under lib/ or hooks/ outside the two state
# modules, so a new reader cannot come back once a script is migrated.
#
# The allow-list below is a ratchet, not a permit: it names the scripts still to migrate
# and may only shrink. A listed script that no longer reads feature.json fails too, so
# the list is deleted from as the migration lands.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}

# Scripts still reading feature.json themselves, one per line. Delete a line when its
# script reads through lib/feature-read.sh; never add one.
STILL_TO_MIGRATE="$(cat <<'LIST'

LIST
)"

# A read is a code line (not a comment) that hands feature.json, or a variable holding
# its path, to jq, cat, python, or a file open. Existence checks and path assignments
# are not reads; the snapshot copy in phase-entry.sh is a copy, not a read.
readers() {
  grep -rnE '^[^#]*\b(jq|cat[[:space:]]|python3|open|json\.load|read_text|read_bytes)[^#]*(feature\.json|"\$fj"|\$\{?fj\b|\$\{?feature_json\b|\$\{?FEATURE_JSON\b|\$\{?FJ\b|\$\{?fjson\b)' \
    lib hooks --include='*.sh' --include='*.py' --exclude='*.test.sh' \
    | grep -vE '^lib/(feature_read|feature_write)\.py:' \
    | cut -d: -f1 | sort -u
}
offenders="$(readers)"
unexpected="$(comm -23 <(printf '%s\n' "$offenders" | sed '/^$/d') <(printf '%s\n' "$STILL_TO_MIGRATE" | sed '/^$/d' | sort -u))"
check "no reader outside the state modules and the ratchet list" "" "$(paste -sd' ' <<<"$unexpected")"
stale="$(comm -13 <(printf '%s\n' "$offenders" | sed '/^$/d') <(printf '%s\n' "$STILL_TO_MIGRATE" | sed '/^$/d' | sort -u))"
check "every ratchet entry still reads feature.json (delete the migrated ones)" "" "$(paste -sd' ' <<<"$stale")"
check "lib/feature_read.py reads the key space from graph/schema.json" "1" "$(grep -c 'graph", "schema.json"' lib/feature_read.py)"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
