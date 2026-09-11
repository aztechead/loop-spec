#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/verification-grounding-lint.sh"
WORK="${TMPDIR:-/tmp}/verification-grounding-lint-test-$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/tests" "$WORK/workspace/repo-a/src" "$WORK/workspace/repo-b/tests"
printf 'one\ntwo\nthree\n' > "$WORK/src/app.py"
printf 'test\n' > "$WORK/tests/app.test.py"
printf 'code\n' > "$WORK/workspace/repo-a/src/a.py"
printf 'test\n' > "$WORK/workspace/repo-b/tests/a.test.py"
cat > "$WORK/SPEC.md" <<'EOF'
## Success criteria
### Good Enough
- [ ] first criterion
### Exceptional
- [ ] stretch criterion
EOF

PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" artifact="$3"; shift 3
  local rc=0 output=""
  output="$(bash "$SCRIPT" "$artifact" "$@" 2>&1)" || rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS+1)); echo "PASS: $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $name (expected $expected, got $rc): $output"
  fi
}

cat > "$WORK/valid.md" <<'EOF'
# Verification

## Repository grounding
- criterion: SC-1 | implementation: src/app.py:2 - implements the behavior | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/no-integration.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/app.py:2 - implements the behavior | integration: none - standalone documentation contract has no runtime caller
EOF

cat > "$WORK/missing-criterion.md" <<'EOF'
## Repository grounding
- criterion: SC-2 | implementation: src/app.py:2 - implements the behavior | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/missing-file.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/missing.py:2 - invented reference | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/bad-line.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/app.py:99 - line is out of range | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/traversal.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: ../outside.py:1 - escapes the repository | integration: none - standalone behavior has no caller
EOF

cat > "$WORK/duplicate.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/app.py:1 - first row | integration: tests/app.test.py:1 - first integration
- criterion: SC-1 | implementation: src/app.py:2 - duplicate row | integration: tests/app.test.py:1 - duplicate integration
EOF

cat > "$WORK/workspace.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: repo-a/src/a.py:1 - implementation repository | integration: repo-b/tests/a.test.py:1 - integration repository
EOF

cat > "$WORK/wrapped.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/app.py:2 - implements the behavior
  | integration: tests/app.test.py:1 - exercises the behavior
EOF

cat > "$WORK/wrapped-bad.md" <<'EOF'
## Repository grounding
- criterion: SC-1 | implementation: src/app.py:2 - implements the behavior
  but never names an integration reference
EOF

printf '# Verification\n' > "$WORK/no-section.md"

echo "=== verification-grounding-lint.sh tests ==="
check "valid evidence passes" 0 "$WORK/valid.md" --repo "$WORK" --criterion SC-1
sed 's/SC-1/GE-001/' "$WORK/valid.md" > "$WORK/spec-derived.md"
check "Good Enough IDs derive from SPEC" 0 "$WORK/spec-derived.md" --repo "$WORK" --spec "$WORK/SPEC.md"
check "explicit no-integration reason passes" 0 "$WORK/no-integration.md" --repo "$WORK" --criterion SC-1
check "missing section fails" 1 "$WORK/no-section.md" --repo "$WORK" --criterion SC-1
check "missing expected criterion fails" 1 "$WORK/missing-criterion.md" --repo "$WORK" --criterion SC-1
check "missing cited file fails" 1 "$WORK/missing-file.md" --repo "$WORK" --criterion SC-1
check "out-of-range line fails" 1 "$WORK/bad-line.md" --repo "$WORK" --criterion SC-1
check "path traversal fails" 1 "$WORK/traversal.md" --repo "$WORK" --criterion SC-1
check "duplicate criterion fails" 1 "$WORK/duplicate.md" --repo "$WORK" --criterion SC-1
check "workspace-relative evidence passes" 0 "$WORK/workspace.md" --repo "$WORK/workspace" --criterion SC-1
check "wrapped row joins and passes" 0 "$WORK/wrapped.md" --repo "$WORK" --criterion SC-1
check "wrapped row still malformed fails" 1 "$WORK/wrapped-bad.md" --repo "$WORK" --criterion SC-1
check "missing artifact fails" 1 "$WORK/absent.md" --repo "$WORK" --criterion SC-1

out="$(bash "$SCRIPT" "$WORK/valid.md" --repo "$WORK" --criterion SC-1)"
if [[ "$out" == "verification-grounding-lint: ok" ]]; then
  PASS=$((PASS+1)); echo "PASS: success output is stable"
else
  FAIL=$((FAIL+1)); echo "FAIL: success output is stable"
fi

# A malformed row's flag carries the row grammar, so the verifier that wrote "- none"
# knows what to write instead.
cat > "$WORK/bare-none.md" <<'EOF'
# Verification

## Repository grounding

- none
EOF
malformed_out="$(bash "$SCRIPT" "$WORK/bare-none.md" --repo "$WORK" --criterion SC-1 2>&1 || true)"
if grep -q 'expected one row per Good Enough criterion, exactly `- criterion: GE-001 | implementation:' <<<"$malformed_out"; then
  PASS=$((PASS+1)); echo "PASS: malformed row flag names the expected row"
else
  FAIL=$((FAIL+1)); echo "FAIL: malformed row flag names the expected row: $malformed_out"
fi

# --- task-008 v1 route: rows recheck against a real execution_observation.observe()
# record, never the row's own claimed text. --------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V1_WORK="$(mktemp -d "${TMPDIR:-/tmp}/verification-grounding-lint-v1.XXXXXX")"
trap 'rm -rf "$WORK" "$V1_WORK"' EXIT
PYTHONPATH="$REPO_ROOT/lib" python3 - "$SCRIPT" "$V1_WORK" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

from execution_observation import observe

script, work = sys.argv[1], Path(sys.argv[2])
fail = []


def check(name, condition):
    if condition:
        print("PASS: " + name)
    else:
        print("FAIL: " + name)
        fail.append(name)


def git_repo():
    root = work / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "a@a.com"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "a"], cwd=root, check=True)
    (root / "tracked.txt").write_text("hello\n")
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run(["git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], cwd=root, check=True)
    return root


root = git_repo()
owner = {"repository": "repo", "feature": "fixture"}
contract = {"version": 1, "format": "v1", "owner": owner, "inventoryDigest": None,
            "nextRequirementId": 3, "issued": {}, "retired": [], "retiredScenarios": {}}
fd = work / "feature"
fd.mkdir()
(fd / "feature.json").write_text(json.dumps({
    "slug": "fixture", "currentPhase": "oneshot", "requirementsContract": contract,
    "artifactPublication": {"version": 1, "generation": 0, "evidenceEpoch": 0, "migration": None, "participantsVersion": 1},
}))

owner_line = json.dumps(owner, sort_keys=True, separators=(",", ":"))
empty_inputs = {"version": 1, "toolchains": [], "localInputs": [], "externalInputs": [], "sensitiveInputs": []}
checks = {"GE-001/SC-001": {"command": "exit 0", "executionInputs": empty_inputs}}
spec_path = fd / "SPEC.md"


def write_spec(scenario_text):
    checks_line = json.dumps(checks, separators=(",", ":"))
    spec_path.write_text(
        "---\nrequirements_version: 1\nrequirements_owner: %s\nscenario_checks: %s\n---\n"
        "# fixture\n\n### Good Enough\n\n- [ ] GE-001: First requirement.\n  - SC-001: %s\n"
        % (owner_line, checks_line, scenario_text))


write_spec("Observed result.")
binding = {"owner": owner, "requirement": "GE-001", "revision": None, "scenario": "SC-001"}
from requirements import parse_spec
inventory = parse_spec(spec_path.read_text(), str(spec_path), contract)
revision = inventory["requirements"][0]["revision"]
binding["revision"] = revision
record = observe(fd, root, binding, "exit 0", empty_inputs)
check("v1: a fresh command observes PASS", record["status"] == "PASS")
execution_id = record["executionId"]

verification = fd / "VERIFICATION.md"


def write_verification(key, status, evidence, grounding=True):
    grounding_row = ("- criterion: %s | implementation: tracked.txt:1 - proves it | "
                      "integration: none - standalone check\n" % key) if grounding else ""
    verification.write_text(
        "# fixture - Verification\n\n## Repository grounding\n\n%s\n"
        "## Acceptance criteria\n\n| # | Criterion | Status | Evidence |\n|---|---|---|---|\n"
        "| %s | First requirement. | %s | %s |\n" % (grounding_row, key, status, evidence))


def run_lint():
    return subprocess.run(["bash", script, str(verification), "--repo", str(root), "--spec", str(spec_path),
                            "--feature-dir", str(fd)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


evidence_ok = "owner=repo/fixture revision=%s scenario=SC-001 `exit 0` -> exit 0 (execution:%s)" % (revision, execution_id)
write_verification("GE-001/SC-001", "PASS", evidence_ok)
result = run_lint()
check("v1: a fresh eligible PASS row passes (exit 0)", result.returncode == 0)
check("v1: the answer line is stable", result.stdout.strip().endswith("verification-grounding-lint: ok"))

write_verification("1", "PASS", evidence_ok)
result = run_lint()
check("v1: a numeric alias row is refused (exit 1)", result.returncode == 1)
check("v1: the numeric alias flag names the reason", "numeric alias" in result.stdout)

write_verification("GE-999/SC-001", "PASS", evidence_ok)
result = run_lint()
check("v1: a row for an unknown scenario is refused", result.returncode == 1)
check("v1: the unknown-scenario flag says so", "not in the SPEC inventory" in result.stdout)

write_verification("GE-001/SC-001", "PASS", "no execution id here")
result = run_lint()
check("v1: a PASS row naming no execution id is refused", result.returncode == 1)
check("v1: the flag says no execution ID", "names no execution ID" in result.stdout)

write_verification("GE-001/SC-001", "PASS", "owner=repo/fixture revision=%s scenario=SC-001 `exit 0` -> exit 0 (execution:%s)" % (revision, "0" * 32))
result = run_lint()
check("v1: a PASS row naming a nonexistent execution id is refused", result.returncode == 1)
check("v1: the flag says no observation record", "no observation record" in result.stdout)

fail_record = observe(fd, root, dict(binding, requirement="GE-001"), "exit 1", empty_inputs)
check("v1 setup: the FAIL record is on record", fail_record["status"] == "FAIL")
write_verification("GE-001/SC-001", "PASS",
                    "owner=repo/fixture revision=%s scenario=SC-001 `exit 1` -> exit 1 (execution:%s)" % (revision, fail_record["executionId"]))
result = run_lint()
check("v1: a row claiming PASS whose record says FAIL is refused (fabricated PASS)", result.returncode == 1)
check("v1: the flag names the record status", "not current evidence" in result.stdout)

# Tamper with the output bytes: the recorded digest no longer matches.
write_verification("GE-001/SC-001", "PASS", evidence_ok)
output_path = fd / record["output"]["path"]
output_path.write_bytes(b"tampered")
result = run_lint()
check("v1: an altered output file is refused", result.returncode == 1)
output_path.write_bytes(b"")
result = run_lint()
check("v1: the altered-output row is eligible again once restored", result.returncode == 0)

write_verification("GE-001/SC-001", "PASS", evidence_ok, grounding=False)
result = run_lint()
check("v1: a missing grounding row for a covered scenario is refused", result.returncode == 1)
check("v1: the flag names the missing grounding row", "missing grounding row" in result.stdout)

verification.write_text("# fixture - Verification\n\n## Repository grounding\n\n"
                         "- criterion: GE-001/SC-001 | implementation: tracked.txt:1 - proves it | integration: none - standalone check\n\n"
                         "## Acceptance criteria\n\n| # | Criterion | Status | Evidence |\n|---|---|---|---|\n")
result = run_lint()
check("v1: an inventory scenario with no acceptance row is refused", result.returncode == 1)
check("v1: the flag names the missing acceptance row", "missing acceptance row" in result.stdout)

sys.exit(1 if fail else 0)
PY
if [[ $? -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
