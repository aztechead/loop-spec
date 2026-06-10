#!/usr/bin/env bash
# Tests for lib/migrate-schema-v3-to-v4.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/migrate-schema-v3-to-v4.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-migrate.$$"
trap 'rm -rf "$WORK"' EXIT

# Minimal v3 feature.json with currentPhase=discuss and perPhaseUsed present
V3_DISCUSS=$(cat <<'JSON'
{
  "schemaVersion": 3,
  "slug": "test-feature",
  "currentPhase": "discuss",
  "completedPhases": [],
  "retryBudget": {
    "perGate": 3,
    "perPhase": {"discuss": 3, "plan": 4, "execute": null, "verify": 4},
    "perGateUsed": {},
    "perPhaseUsed": {"discuss": 0, "plan": 0, "execute": 0, "verify": 0},
    "global": 30,
    "globalUsed": 0
  },
  "artifacts": {
    "spec": null,
    "plan": null
  }
}
JSON
)

# Minimal v3 feature.json with currentPhase=plan
V3_PLAN=$(cat <<'JSON'
{
  "schemaVersion": 3,
  "slug": "mid-flight-feature",
  "currentPhase": "plan",
  "completedPhases": ["discuss"],
  "retryBudget": {
    "perGate": 3,
    "perPhase": {"discuss": 3, "plan": 4, "execute": null, "verify": 4},
    "perGateUsed": {},
    "perPhaseUsed": {"discuss": 1, "plan": 0, "execute": 0, "verify": 0},
    "global": 30,
    "globalUsed": 0
  },
  "artifacts": {
    "spec": "docs/loop-spec/features/mid-flight-feature/SPEC.md",
    "plan": null
  }
}
JSON
)

# v3 feature.json missing perPhaseUsed entirely (older v3 subschema)
V3_NO_PERPHASEUSED=$(cat <<'JSON'
{
  "schemaVersion": 3,
  "slug": "old-feature",
  "currentPhase": "discuss",
  "completedPhases": [],
  "retryBudget": {
    "perGate": 3,
    "perPhase": {"discuss": 3, "plan": 4, "execute": null, "verify": 4},
    "perGateUsed": {},
    "global": 30,
    "globalUsed": 0
  },
  "artifacts": {
    "spec": null
  }
}
JSON
)

# Already-v4 feature.json
V4_EXISTING=$(cat <<'JSON'
{
  "schemaVersion": 4,
  "slug": "already-v4",
  "currentPhase": "spec",
  "completedPhases": [],
  "retryBudget": {
    "perGate": 3,
    "perPhase": {"spec": 1, "discuss": 3, "plan": 4, "execute": null, "verify": 4},
    "perGateUsed": {},
    "perPhaseUsed": {"spec": 0, "discuss": 0, "plan": 0, "execute": 0, "verify": 0},
    "global": 30,
    "globalUsed": 0
  },
  "artifacts": {
    "specInterview": null,
    "spec": null
  }
}
JSON
)

# --- Case A: v3 + currentPhase=discuss -> migrated to v4, currentPhase=discuss preserved ---
mkdir -p "$WORK/feat-a"
printf '%s\n' "$V3_DISCUSS" > "$WORK/feat-a/feature.json"

bash "$LIB" "$WORK/feat-a" >/dev/null

got_version=$(jq -r '.schemaVersion' "$WORK/feat-a/feature.json")
check "A: schemaVersion bumped to 4" "4" "$got_version"

got_phase=$(jq -r '.currentPhase' "$WORK/feat-a/feature.json")
check "A: currentPhase=discuss preserved (not rewound)" "discuss" "$got_phase"

got_spec_perphase=$(jq -r '.retryBudget.perPhase.spec' "$WORK/feat-a/feature.json")
check "A: retryBudget.perPhase.spec added" "3" "$got_spec_perphase"

got_spec_used=$(jq -r '.retryBudget.perPhaseUsed.spec' "$WORK/feat-a/feature.json")
check "A: retryBudget.perPhaseUsed.spec=0 added" "0" "$got_spec_used"

got_spec_interview=$(jq -r '.artifacts.specInterview' "$WORK/feat-a/feature.json")
check "A: artifacts.specInterview=null added" "null" "$got_spec_interview"

# --- Case B: v3 + currentPhase=plan -> migrated, currentPhase=plan preserved ---
mkdir -p "$WORK/feat-b"
printf '%s\n' "$V3_PLAN" > "$WORK/feat-b/feature.json"

bash "$LIB" "$WORK/feat-b" >/dev/null

got_version=$(jq -r '.schemaVersion' "$WORK/feat-b/feature.json")
check "B: schemaVersion bumped to 4" "4" "$got_version"

got_phase=$(jq -r '.currentPhase' "$WORK/feat-b/feature.json")
check "B: currentPhase=plan preserved (not rewound to spec)" "plan" "$got_phase"

got_spec_perphase=$(jq -r '.retryBudget.perPhase.spec' "$WORK/feat-b/feature.json")
check "B: retryBudget.perPhase.spec added" "3" "$got_spec_perphase"

got_spec_used=$(jq -r '.retryBudget.perPhaseUsed.spec' "$WORK/feat-b/feature.json")
check "B: retryBudget.perPhaseUsed.spec=0 added" "0" "$got_spec_used"

got_completed=$(jq -r '.completedPhases | length' "$WORK/feat-b/feature.json")
check "B: completedPhases preserved (length=1)" "1" "$got_completed"

# --- Case C: v3 with missing perPhaseUsed -> migrated, perPhaseUsed.spec=0 added ---
mkdir -p "$WORK/feat-c"
printf '%s\n' "$V3_NO_PERPHASEUSED" > "$WORK/feat-c/feature.json"

bash "$LIB" "$WORK/feat-c" >/dev/null

got_version=$(jq -r '.schemaVersion' "$WORK/feat-c/feature.json")
check "C: schemaVersion bumped to 4" "4" "$got_version"

got_spec_used=$(jq -r '.retryBudget.perPhaseUsed.spec' "$WORK/feat-c/feature.json")
check "C: retryBudget.perPhaseUsed.spec=0 added (was missing)" "0" "$got_spec_used"

got_spec_interview=$(jq -r '.artifacts.specInterview' "$WORK/feat-c/feature.json")
check "C: artifacts.specInterview=null added" "null" "$got_spec_interview"

# Verify it is valid JSON
jq . "$WORK/feat-c/feature.json" >/dev/null 2>&1 && check "C: output is valid JSON" "ok" "ok" || check "C: output is valid JSON" "ok" "INVALID"

# --- Case D: Idempotency - run twice, hashes must match ---
mkdir -p "$WORK/feat-d"
printf '%s\n' "$V3_DISCUSS" > "$WORK/feat-d/feature.json"

bash "$LIB" "$WORK/feat-d" >/dev/null
hash1=$(jq -cS . "$WORK/feat-d/feature.json" | md5 2>/dev/null || jq -cS . "$WORK/feat-d/feature.json" | md5sum | awk '{print $1}')

bash "$LIB" "$WORK/feat-d" >/dev/null
hash2=$(jq -cS . "$WORK/feat-d/feature.json" | md5 2>/dev/null || jq -cS . "$WORK/feat-d/feature.json" | md5sum | awk '{print $1}')

check "D: idempotency - two runs produce identical JSON" "$hash1" "$hash2"

# --- Case E: Already v4 - no-op, exit 0 ---
mkdir -p "$WORK/feat-e"
printf '%s\n' "$V4_EXISTING" > "$WORK/feat-e/feature.json"
orig_hash=$(jq -cS . "$WORK/feat-e/feature.json" | md5 2>/dev/null || jq -cS . "$WORK/feat-e/feature.json" | md5sum | awk '{print $1}')

exit_code=0
bash "$LIB" "$WORK/feat-e" >/dev/null 2>&1 || exit_code=$?
check "E: already-v4 exits 0 (no-op)" "0" "$exit_code"

after_hash=$(jq -cS . "$WORK/feat-e/feature.json" | md5 2>/dev/null || jq -cS . "$WORK/feat-e/feature.json" | md5sum | awk '{print $1}')
check "E: already-v4 does not modify feature.json" "$orig_hash" "$after_hash"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
