#!/usr/bin/env bash
# Tests for lib/supervisor/store.sh (dispatcher), store-mirror.sh specifics, and the
# call sites that persist through the port (feature-write.sh, phase-exit's contract is
# pinned by tests/supervisor-interface-coverage.test.sh, cycle-preflight open).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STORE="$REPO_ROOT/lib/supervisor/store.sh"
MIRROR="$REPO_ROOT/lib/supervisor/store-mirror.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-store.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj/.loop-spec/features/alpha" "$WORK/mirror"
export CLAUDE_PROJECT_DIR="$WORK/proj"
unset LOOP_SPEC_STORE LOOP_SPEC_STORE_DIR LOOP_SPEC_PROFILE_PRESET 2>/dev/null || true
export LOOP_SPEC_PROFILE="$WORK/none.json"
feat="$WORK/proj/.loop-spec/features/alpha"
printf '{"slug":"alpha","schemaVersion":7,"currentPhase":"spec"}' > "$feat/feature.json"

# dispatcher: default is the checkout adapter
check "default describe is local" "store=local reason=checkout-is-store" "$(bash "$STORE" describe)"
ec=0; bash "$STORE" nope >/dev/null 2>&1 || ec=$?
check "dispatcher rejects an unknown op" "2" "$ec"
ec=0; LOOP_SPEC_STORE="$WORK/missing.sh" bash "$STORE" describe >/dev/null 2>&1 || ec=$?
check "dispatcher refuses a missing adapter" "2" "$ec"
printf '#!/usr/bin/env bash\necho "store=custom reason=test"\n' > "$WORK/custom.sh"; chmod +x "$WORK/custom.sh"
check "dispatcher routes to LOOP_SPEC_STORE" "store=custom reason=test" "$(LOOP_SPEC_STORE="$WORK/custom.sh" bash "$STORE" describe)"

# the profile can select the adapter (project policy, no env needed)
printf '{"preset":"interactive","env":{"LOOP_SPEC_STORE":"%s"}}' "$WORK/custom.sh" > "$WORK/profile.json"
check "profile selects the adapter" "store=custom reason=test" "$(LOOP_SPEC_PROFILE="$WORK/profile.json" bash "$STORE" describe)"

# mirror adapter: needs its directory
ec=0; out="$(bash "$MIRROR" describe 2>&1)" || ec=$?
check "mirror without LOOP_SPEC_STORE_DIR exits 2" "2" "$ec"
check "mirror names the missing variable" "yes" "$(grep -q LOOP_SPEC_STORE_DIR <<<"$out" && echo yes || echo no)"

export LOOP_SPEC_STORE="$MIRROR" LOOP_SPEC_STORE_DIR="$WORK/mirror"
# persist keeps the previous mirror until the new copy is complete: after a
# persist the mirror has exactly one directory for the slug and no temp leftovers
bash "$STORE" persist "$feat" first >/dev/null
bash "$STORE" persist "$feat" second >/dev/null
check "mirror holds one copy, no temp dirs" "alpha" "$(ls "$WORK/mirror" | tr '\n' ' ' | sed 's/ $//')"
check "mirror copy matches" "spec" "$(jq -r .currentPhase "$WORK/mirror/alpha/feature.json")"

# feature-write.sh persists through the port on every write
bash "$REPO_ROOT/lib/feature-write.sh" set "$feat" currentPhase '"plan"' >/dev/null
check "feature-write persisted to the mirror" "plan" "$(jq -r .currentPhase "$WORK/mirror/alpha/feature.json")"
ec=0; LOOP_SPEC_STORE_DIR="$WORK/not-a-dir-file" bash -c 'touch "$LOOP_SPEC_STORE_DIR"; bash "$0" set "$1" currentPhase "\"x\""' "$REPO_ROOT/lib/feature-write.sh" "$feat" >/dev/null 2>&1 || ec=$?
check "feature-write fails loudly when the store cannot hold state" "2" "$ec"
check "feature.json still written before the persist failure" "x" "$(jq -r .currentPhase "$feat/feature.json")"

# cycle-preflight opens a slug the mirror holds but the checkout lacks
rm -rf "$feat"
( cd "$WORK/proj" && git init -q . 2>/dev/null && git commit -q --allow-empty -m init 2>/dev/null )
report="$(cd "$WORK/proj" && bash "$REPO_ROOT/lib/cycle-preflight.sh" run "$WORK/proj" 2>/dev/null)"
check "preflight restored the working copy from the mirror" "1" "$([[ -f "$feat/feature.json" ]] && echo 1 || echo 0)"
check "preflight reports the store" "mirror" "$(jq -r .store.name <<<"$report")"
check "preflight reports the profile" "interactive" "$(jq -r .profile.preset <<<"$report")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
