#!/usr/bin/env bash
# Release 7.0 readiness: pins the wiring task-012 owns rather than any single
# task's behavior (each task's own suite already covers that). An orphaned
# helper suite, a harness contract that stopped naming the protected paths, a
# short/full row shape that drifted apart, a grounding/floor gate that lost its
# --feature-dir, or a new failure-tells/comment-tells finding would each ship
# invisibly if only the per-task suites ran; this is what a release readiness
# check adds over them.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- (a) every 7.0 helper suite is registered in tests/run-all.sh -----------
run_all="$(cat tests/run-all.sh)"
for suite in \
  tests/lib/requirements.test.sh \
  tests/lib/artifact-publication.test.sh \
  tests/lib/publication-callers.test.sh \
  tests/lib/execution-inputs.test.sh \
  tests/lib/execution-observation.test.sh \
  tests/lib/final-candidate-observations.test.sh \
  tests/lib/requirements-migrate.test.sh \
  tests/lib/portability-scan.test.sh \
  tests/release-7-0-coverage.test.sh \
; do
  if grep -qF -- "$suite" <<<"$run_all"; then
    pass "tests/run-all.sh registers $suite"
  else
    fail "tests/run-all.sh does not register $suite (orphaned 7.0 helper suite)"
  fi
done

# --- (b) four-harness contract wiring ---------------------------------------
check_fixed_strings \
  $'skills/shared/claude-harness.md\t### Protected publication paths' \
  $'skills/shared/claude-harness.md\tobservations/**' \
  $'skills/shared/claude-harness.md\tpublication-generations/**' \
  $'skills/shared/claude-harness.md\tmigration-generations/**' \
  $'skills/shared/claude-harness.md\tprotected-path --path PATH --feature-dir DIR' \
  $'skills/shared/claude-harness.md\tnot a host an attacker' \
  $'skills/shared/opencode-harness.md\t### Protected publication paths' \
  $'skills/shared/opencode-harness.md\tobservations/**' \
  $'skills/shared/opencode-harness.md\tmigration-generations/**' \
  $'skills/shared/opencode-harness.md\tnot a host an attacker' \
  $'skills/shared/adk-harness.md\t### Protected publication paths' \
  $'skills/shared/adk-harness.md\tobservations/**' \
  $'skills/shared/adk-harness.md\tmigration-generations/**' \
  $'skills/shared/adk-harness.md\tnot a host an attacker' \
  $'skills/shared/codex-harness.md\t### Protected publication paths' \
  $'skills/shared/codex-harness.md\tobservations/**' \
  $'skills/shared/codex-harness.md\tmigration-generations/**' \
  $'skills/shared/codex-harness.md\tsupported-guarded-driver-path guarantee'

# --- (b) protected-path answers over a v1 fixture ---------------------------
# Build one v1-format feature the way a real cycle would: feature-init.sh's
# own skeleton (not a hand-typed feature.json that could drift from the real
# schema), patched onto the v1 contract.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
SLUG="demo-v1"
FD="$REPO/.loop-spec/features/$SLUG"
mkdir -p "$FD/observations" "$FD/publication-generations" "$FD/migration-generations" "$FD/publication-staging"
DOCS="$REPO/docs/loop-spec/features/$SLUG"
mkdir -p "$DOCS"
for f in SPEC PLAN VERIFICATION PATTERNS; do echo "# $f" > "$DOCS/$f.md"; done

bash lib/feature-init.sh skeleton --mode single \
  --slug "$SLUG" --now 1970-01-01T00:00:00Z --style auto --title "$SLUG" \
  --branch "feat/$SLUG" --base-sha 0000000000000000000000000000000000000000 \
  --base-branch main --worktree "" --prepare "" --test "" --lint "" --typecheck "" \
  | jq '.requirementsContract = {"version":1,"format":"v1","owner":{"repository":"r","feature":"'"$SLUG"'"},"inventoryDigest":null,"nextRequirementId":1,"issued":{},"retired":[],"retiredScenarios":{}}' \
  > "$FD/feature.json"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

check_protected() {
  local rel="$1" want="$2" got
  got="$(bash lib/harness.sh protected-path --path "$REPO/$rel" --feature-dir "$FD" 2>/dev/null)"
  if [[ "$got" == protected=$want* ]]; then
    pass "protected-path $rel => protected=$want"
  else
    fail "protected-path $rel => '$got', want protected=$want"
  fi
}
check_protected "docs/loop-spec/features/$SLUG/SPEC.md" yes
check_protected "docs/loop-spec/features/$SLUG/PLAN.md" yes
check_protected "docs/loop-spec/features/$SLUG/VERIFICATION.md" yes
check_protected ".loop-spec/features/$SLUG/feature.json" yes
check_protected ".loop-spec/features/$SLUG/observations/exec-1.json" yes
check_protected ".loop-spec/features/$SLUG/migration-generations/t1/marker.json" yes
check_protected ".loop-spec/features/$SLUG/publication-staging/spec-abc.md" no

# --- (b) short/full route row shapes carry identical owner/revision/scenario format
FULL_TPL="skills/shared/artifact-templates/VERIFICATION.md.template"
ONESHOT_TPL="skills/shared/artifact-templates/VERIFICATION-oneshot.md.template"
ROW_NEEDLE='| # | Criterion | Status | Evidence |'
GROUNDING_NEEDLE='- criterion: GE-001 | implementation: {path}:{line} - {what it proves} | integration: {path}:{line} - {what it proves}'
V1_NOTE_NEEDLE='cycle-driver.sh verification run keys each row
     GE-ID/SC-ID (never a document-position number) and writes its Status and Evidence'
for needle_name in ROW_NEEDLE GROUNDING_NEEDLE V1_NOTE_NEEDLE; do
  needle="${!needle_name}"
  if grep -qF -- "$needle" "$FULL_TPL" && grep -qF -- "$needle" "$ONESHOT_TPL"; then
    pass "full and oneshot VERIFICATION templates share the $needle_name row shape"
  else
    fail "full and oneshot VERIFICATION templates disagree on $needle_name"
  fi
done

# --- (b) verify/oneshot/iterate pass --feature-dir to the grounding/floor gates
check_gate_arg() {
  local node="$1" label="$2" want_flag="$3"
  local args
  args="$(python3 - "$node" "$label" <<'PY'
import json, sys
g = json.load(open("graph/cycle.graph.json"))
node, label = sys.argv[1], sys.argv[2]
for n in g["nodes"]:
    if n["id"] == node:
        for gate in n.get("egress", {}).get("gates", []):
            if gate.get("label") == label:
                print(" ".join(gate.get("args", [])))
PY
)"
  if [[ "$args" == *"$want_flag"* && "$args" == *'{featureDir}'* ]]; then
    pass "graph/cycle.graph.json $node/$label gate carries $want_flag {featureDir}"
  else
    fail "graph/cycle.graph.json $node/$label gate args ('$args') missing $want_flag {featureDir}"
  fi
}
check_gate_arg verify verification-grounding --feature-dir
check_gate_arg verify acceptance-table --feature-dir
check_gate_arg iterate converged-floor --feature-dir
oneshot_args="$(python3 - <<'PY'
import json
g = json.load(open("graph/cycle.graph.json"))
for n in g["nodes"]:
    if n["id"] == "oneshot":
        for gate in n.get("egress", {}).get("gates", []):
            print(" ".join(gate.get("args", [])))
PY
)"
if [[ "$oneshot_args" == *'{featureDir}'* ]]; then
  pass "graph/cycle.graph.json oneshot gate carries {featureDir}"
else
  fail "graph/cycle.graph.json oneshot gate lost {featureDir} ('$oneshot_args')"
fi

# --- (c) required source probes ---------------------------------------------
if out="$(bash lib/portability-scan.sh scan lib hooks tests extensions 2>&1)"; then
  pass "portability-scan is clean over lib hooks tests extensions"
else
  fail "portability-scan reported a finding: $out"
fi

# failure-tells and comment-tells are pre-existing, not-yet-fixed findings
# outside this task's scope (see git blame on each line); this ceiling makes
# sure no NEW one lands unnoticed. simplicity: raising either number requires
# naming the new file:line here, not just bumping the count.
scan_ceiling() {
  local tool="$1" ceiling="$2" out count
  out="$(bash "lib/$tool.sh" scan lib/*.py lib/*.sh hooks/*.sh 2>&1)"
  count="$(grep -oE "^$tool: [0-9]+ finding" <<<"$out" | grep -oE '[0-9]+')"
  [[ -n "$count" ]] || count=0
  if [[ "$count" -le "$ceiling" ]]; then
    pass "$tool: $count finding(s), at or under the pre-existing ceiling of $ceiling"
  else
    fail "$tool: $count finding(s) exceeds the pre-existing ceiling of $ceiling (new finding introduced): $out"
  fi
}
# simplicity: pre-existing findings not touched by task-012 --
#   lib/backlog.sh:219 (failure-tells, silent-exit)
#   hooks/codex-session-start.sh:21, lib/checkpoint-pr.sh:214, lib/cycle-result.sh:883 (comment-tells, echoes-code)
scan_ceiling failure-tells 1
scan_ceiling comment-tells 3

# --- (d) version declarations agree -----------------------------------------
if bash lib/bump-version.sh --check >/dev/null 2>&1; then
  pass "bump-version.sh --check exits 0 (declarations agree)"
else
  fail "bump-version.sh --check reported disagreeing version declarations"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
