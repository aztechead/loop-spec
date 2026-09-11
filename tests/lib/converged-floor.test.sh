#!/usr/bin/env bash
# Tests for lib/converged-floor.sh — convergence cannot be claimed over unverified scope.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/converged-floor.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/converged-floor-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/SPEC.md" <<'EOF'
# Feature

## Success criteria

### Good Enough

- [ ] command exits 0
- [ ] output contains marker

### Exceptional

- [ ] blazing fast
EOF

cat > "$tmp/V.md" <<'EOF'
# Verification

## Repository grounding

- criterion: GE-001 | implementation: app.py:10 - exits 0 | integration: cli.py:3 - wired
- criterion: GE-002 | implementation: app.py:22 - marker | integration: none - single call site

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | command exits 0 | PASS | `run` -> 0 |
| 2 | output contains marker | PASS | `run` -> marker |
EOF

# Full coverage + all PASS -> floor holds.
bash "$LIB" "$tmp/SPEC.md" "$tmp/V.md" >/dev/null 2>&1
check "floor holds on full coverage (exit 0)" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V.md" 2>/dev/null)"
check "answer line reports criteria count" "$(grep -q 'converged-floor: ok (2 criteria verified)' <<<"$out" && echo 1 || echo 0)"

# Exceptional criteria are NOT floored (only Good Enough gates).
check "exceptional not required" "$(grep -q 'GE-003' <<<"$out" && echo 0 || echo 1)"

# Missing grounding row -> violation naming the GE id.
grep -v 'GE-002' "$tmp/V.md" > "$tmp/V-missing.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-missing.md" 2>/dev/null)"; rc=$?
check "missing row vetoes convergence (exit 1)" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "violation names the GE id" "$(grep -q 'FLOOR GE-002 has no grounding row' <<<"$out" && echo 1 || echo 0)"

# FAIL status in the acceptance table -> violation.
sed 's/| 2 | output contains marker | PASS |/| 2 | output contains marker | FAIL |/' "$tmp/V.md" > "$tmp/V-fail.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-fail.md" >/dev/null 2>&1
check "FAIL table row vetoes convergence" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# An empty Status cell (the oneshot skeleton before `verification run` observes the
# command) is a criterion nobody ran: a veto, never a pass (port audit 4, item 2).
sed 's/| 2 | output contains marker | PASS |/| 2 | output contains marker |  |/' "$tmp/V.md" > "$tmp/V-empty.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-empty.md" >/dev/null 2>&1
check "an empty Status cell vetoes convergence" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
# The driver's own FAIL row shape: `| GE-002 | ... | FAIL | `cmd` -> exit 1 |`.
sed 's/| 2 | output contains marker | PASS | `run` -> marker |/| GE-002 | output contains marker | FAIL | `run` -> exit 1 |/' "$tmp/V.md" > "$tmp/V-driver-fail.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-driver-fail.md" >/dev/null 2>&1
check "a driver-written FAIL row (exit code evidence) vetoes convergence" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
# FAIL as a substring elsewhere (evidence text) does not veto.
sed 's/`run` -> marker/`run` -> no FAILURES seen/' "$tmp/V.md" > "$tmp/V-text.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-text.md" >/dev/null 2>&1
check "FAIL substring in evidence cell is not a status" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Unreadable VERIFICATION.md with a Good Enough section -> fail closed.
bash "$LIB" "$tmp/SPEC.md" "$tmp/does-not-exist.md" >/dev/null 2>&1
check "missing VERIFICATION fails closed" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# A missing contract cannot justify convergence.
printf '# Feature\n\nno criteria here\n' > "$tmp/SPEC-none.md"
bash "$LIB" "$tmp/SPEC-none.md" "$tmp/does-not-exist.md" >/dev/null 2>&1
check "no Good Enough section fails closed" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Missing spec -> fail-open skip (nothing to floor).
bash "$LIB" "$tmp/no-spec.md" "$tmp/V.md" >/dev/null 2>&1
check "missing spec fails closed" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

for status in PENDING SKIP UNKNOWN; do
  sed "s/| 2 | output contains marker | PASS |/| 2 | output contains marker | $status |/" "$tmp/V.md" > "$tmp/V-pending.md"
  bash "$LIB" "$tmp/SPEC.md" "$tmp/V-pending.md" >/dev/null 2>&1
  check "$status acceptance cannot converge" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
done
grep -v '^| 2 |' "$tmp/V.md" > "$tmp/V-no-result.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-no-result.md" >/dev/null 2>&1
check "grounding without an acceptance result cannot converge" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# The verifier's real table shape (6.3.0 fastapi runs): a Result column after the verify
# command, PASS with a parenthetical, an escaped pipe inside a cell, and GE ids as keys.
cat > "$tmp/V-wide.md" <<'EOF'
# Verification

## Repository grounding

- criterion: GE-001 | implementation: app.py:10 - exits 0 | integration: cli.py:3 - wired
- criterion: GE-002 | implementation: app.py:22 - marker | integration: none - single call site

## Acceptance criteria

| # | Criterion | Verify command | Result |
| --- | --- | --- | --- |
| GE-001 | command exits 0 | `run \| grep -c ok` | PASS (12 passed) |
| GE-002 | output contains marker | `run` | **PASS** |
EOF
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-wide.md" 2>/dev/null)"; rc=$?
check "Result column found by header, PASS prefix and escaped pipe read (exit 0)" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
check "wide table answer line" "$(grep -q 'converged-floor: ok (2 criteria verified)' <<<"$out" && echo 1 || echo 0)"
sed 's/| PASS (12 passed) |/| FAIL (1 failed) |/' "$tmp/V-wide.md" > "$tmp/V-wide-fail.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-wide-fail.md" 2>/dev/null)"; rc=$?
check "FAIL prefix in the Result column vetoes" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "FAIL veto names the row key" "$(grep -q 'FLOOR acceptance table row still FAIL: GE-001' <<<"$out" && echo 1 || echo 0)"
# lib/iterate-judged.sh routes a floor veto to VERIFY or EXECUTE by this literal; the
# two files share it and neither may drift alone (port audit 1, F10).
check "the judge reads the same literal the floor emits" "$([[ "$(grep -c "still FAIL" "$REPO_ROOT/lib/iterate-judged.sh")" -ge 1 && "$(grep -c "row still FAIL" "$REPO_ROOT/lib/converged-floor.sh")" -ge 1 ]] && echo 1 || echo 0)"
printf '| GE-002 | dup | `run` | PASS |\n' >> "$tmp/V-wide.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-wide.md" 2>/dev/null)"
check "duplicate rows for one criterion veto with the count" "$(grep -q 'FLOOR GE-002 acceptance result is duplicate (2 acceptance rows' <<<"$out" && echo 1 || echo 0)"

# --shape: VERIFY's exit checks the grammar only; FAIL and N/A are readable results.
sed 's/| PASS (12 passed) |/| FAIL (1 failed) |/; s/| \*\*PASS\*\* |/| N\/A - no marker on this platform |/' "$tmp/V-wide.md" | grep -v '| dup |' > "$tmp/V-shape.md"
out="$(bash "$LIB" --shape "$tmp/SPEC.md" "$tmp/V-shape.md" 2>/dev/null)"; rc=$?
check "--shape accepts FAIL and N/A rows (exit 0)" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
check "--shape answer line" "$(grep -q 'converged-floor: shape ok (2 criteria)' <<<"$out" && echo 1 || echo 0)"
sed 's/| FAIL (1 failed) |/| passed |/' "$tmp/V-shape.md" > "$tmp/V-shape-bad.md"
out="$(bash "$LIB" --shape "$tmp/SPEC.md" "$tmp/V-shape-bad.md" 2>/dev/null)"; rc=$?
check "--shape rejects a status cell that does not begin with PASS/FAIL/N/A" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "--shape names the unreadable cell" "$(grep -q "FLOOR GE-001 acceptance result is unreadable (status cell 'passed' must begin with PASS, FAIL, BLOCKED, or N/A)" <<<"$out" && echo 1 || echo 0)"
grep -v '^| GE-002' "$tmp/V-shape.md" > "$tmp/V-shape-missing.md"
out="$(bash "$LIB" --shape "$tmp/SPEC.md" "$tmp/V-shape-missing.md" 2>/dev/null)"; rc=$?
check "--shape rejects a criterion with no row" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "--shape names the missing key" "$(grep -q 'FLOOR GE-002 acceptance result is missing (no acceptance row keyed GE-002 or 2)' <<<"$out" && echo 1 || echo 0)"
grep -v 'criterion: GE-002' "$tmp/V-shape.md" > "$tmp/V-shape-ungrounded.md"
bash "$LIB" --shape "$tmp/SPEC.md" "$tmp/V-shape-ungrounded.md" >/dev/null 2>&1
check "--shape leaves grounding rows to verification-grounding-lint (exit 0)" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Bad invocation.
bash "$LIB" "$tmp/SPEC.md" >/dev/null 2>&1
check "missing args exit 2" "$([[ $? -eq 2 ]] && echo 1 || echo 0)"


# BLOCKED is a status that cannot converge; PASS whose evidence says the check never
# ran is the live relabeling this floor now refuses.
sed 's/| 2 | output contains marker | PASS | `run` -> marker |/| 2 | output contains marker | BLOCKED | `run` -> gcloud reauth needed |/' "$tmp/V.md" > "$tmp/V-blocked.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-blocked.md" 2>/dev/null)"; rc=$?
check "BLOCKED row vetoes convergence" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "BLOCKED row names the operator" "$(grep -q 'BLOCKED (an operator must clear it' <<<"$out" && echo 1 || echo 0)"
sed 's/| 2 | output contains marker | PASS | `run` -> marker |/| 2 | output contains marker | PASS | plan invocation is blocked-not-failed by the reauth lock, an explicit SPEC allowance |/' "$tmp/V.md" > "$tmp/V-relabeled.md"
out="$(bash "$LIB" "$tmp/SPEC.md" "$tmp/V-relabeled.md" 2>/dev/null)"; rc=$?
check "PASS with blocked evidence vetoes convergence" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
check "PASS with blocked evidence says to mark it BLOCKED" "$(grep -q 'mark it BLOCKED' <<<"$out" && echo 1 || echo 0)"
sed 's/| 2 | output contains marker | PASS | `run` -> marker |/| 2 | output contains marker | PASS | `run` -> marker; the unblocked path is covered too |/' "$tmp/V.md" > "$tmp/V-word.md"
bash "$LIB" "$tmp/SPEC.md" "$tmp/V-word.md" >/dev/null 2>&1
check "the word unblocked in evidence is not a blocked check" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# --- task-008 v1 route: rows keyed GE-ID/SC-ID, eligibility via a real
# execution_observation.observe() record on both --shape and the full floor ---------
PYTHONPATH="$REPO_ROOT/lib" python3 - "$LIB" "$tmp" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

from execution_observation import observe

lib, tmp = sys.argv[1], Path(sys.argv[2]) / "v1"
tmp.mkdir()
fail = []

# simplicity: check()/git_repo() repeat tests/lib/verification-grounding-lint.test.sh's
# own v1 fixture helpers almost verbatim. Every suite in this tree keeps its fixture
# self-contained (no shared cross-file fixture library exists here to lift them into --
# see tests/lib/cycle-driver.test.sh's write_small_plan comment for the same call made
# once already), so this stays local rather than adding one for two callers.


def check(name, condition):
    if condition:
        print("PASS: " + name)
    else:
        print("FAIL: " + name)
        fail.append(name)


def git_repo():
    root = tmp / "repo"
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
# converged-floor.sh's v1 route (no --repo option, unlike verification-grounding-lint.sh)
# derives root from `git -C feature_dir rev-parse --show-toplevel`, so feature_dir must
# sit inside the repo the way a real feature.json always does.
fd = root / ".loop-spec" / "features" / "fixture"
fd.mkdir(parents=True)
(fd / "feature.json").write_text(json.dumps({
    "slug": "fixture", "currentPhase": "oneshot", "requirementsContract": contract,
    "artifactPublication": {"version": 1, "generation": 0, "evidenceEpoch": 0, "migration": None, "participantsVersion": 1},
}))
owner_line = json.dumps(owner, sort_keys=True, separators=(",", ":"))
empty_inputs = {"version": 1, "toolchains": [], "localInputs": [], "externalInputs": [], "sensitiveInputs": []}
checks = {"GE-001/SC-001": {"command": "exit 0", "executionInputs": empty_inputs},
          "GE-002/SC-001": {"command": "exit 0", "executionInputs": empty_inputs}}
spec_path = fd / "SPEC.md"
checks_line = json.dumps(checks, separators=(",", ":"))
spec_path.write_text(
    "---\nrequirements_version: 1\nrequirements_owner: %s\nscenario_checks: %s\n---\n"
    "# fixture\n\n### Good Enough\n\n"
    "- [ ] GE-001: First requirement.\n  - SC-001: First scenario.\n"
    "- [ ] GE-002: Second requirement.\n  - SC-001: Second scenario.\n" % (owner_line, checks_line))

from requirements import parse_spec
inventory = parse_spec(spec_path.read_text(), str(spec_path), contract)
revisions = {r["id"]: r["revision"] for r in inventory["requirements"]}
record1 = observe(fd, root, {"owner": owner, "requirement": "GE-001", "revision": revisions["GE-001"], "scenario": "SC-001"},
                   "exit 0", empty_inputs)
record2 = observe(fd, root, {"owner": owner, "requirement": "GE-002", "revision": revisions["GE-002"], "scenario": "SC-001"},
                   "exit 0", empty_inputs)
check("v1 setup: both scenarios observe PASS", record1["status"] == "PASS" and record2["status"] == "PASS")

verification = fd / "VERIFICATION.md"


def evidence_for(req, record):
    return "owner=repo/fixture revision=%s scenario=SC-001 `exit 0` -> exit 0 (execution:%s)" % (
        revisions[req], record["executionId"])


def write_verification(rows):
    body = "".join("| %s | text | %s | %s |\n" % row for row in rows)
    verification.write_text(
        "# fixture - Verification\n\n## Repository grounding\n\n"
        "- criterion: GE-001/SC-001 | implementation: tracked.txt:1 - proves it | integration: none - standalone check\n"
        "- criterion: GE-002/SC-001 | implementation: tracked.txt:1 - proves it | integration: none - standalone check\n\n"
        "## Acceptance criteria\n\n| # | Criterion | Status | Evidence |\n|---|---|---|---|\n" + body)


def run_floor(shape=False):
    args = [lib]
    if shape:
        args.append("--shape")
    args += [str(spec_path), str(verification), "--feature-dir", str(fd)]
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


write_verification([("GE-001/SC-001", "PASS", evidence_for("GE-001", record1)),
                     ("GE-002/SC-001", "PASS", evidence_for("GE-002", record2))])
result = run_floor()
check("v1: full coverage with fresh eligible records holds (exit 0)", result.returncode == 0)
check("v1: the answer line names both criteria" , "ok (2 criteria verified)" in result.stdout)
result = run_floor(shape=True)
check("v1: --shape also holds on the same fixture", result.returncode == 0)

# Uncovered scenario: drop GE-002's row entirely.
write_verification([("GE-001/SC-001", "PASS", evidence_for("GE-001", record1))])
result = run_floor()
check("v1: an uncovered required scenario vetoes convergence", result.returncode == 1)
check("v1: the veto names the missing scenario", "GE-002/SC-001 acceptance result is missing" in result.stdout)

# Stale record: rewrite GE-001's scenario text (changes its revision) without a fresh run.
write_verification([("GE-001/SC-001", "PASS", evidence_for("GE-001", record1)),
                     ("GE-002/SC-001", "PASS", evidence_for("GE-002", record2))])
spec_path.write_text(
    "---\nrequirements_version: 1\nrequirements_owner: %s\nscenario_checks: %s\n---\n"
    "# fixture\n\n### Good Enough\n\n"
    "- [ ] GE-001: First requirement.\n  - SC-001: First scenario, reworded.\n"
    "- [ ] GE-002: Second requirement.\n  - SC-001: Second scenario.\n" % (owner_line, checks_line))
result = run_floor()
check("v1: a stale record (changed revision) vetoes convergence on the full floor", result.returncode == 1)
check("v1: the veto names the stale execution", "not current evidence" in result.stdout)
result = run_floor(shape=True)
check("v1: --shape does not recheck freshness (still holds)", result.returncode == 0)

if fail:
    sys.exit(1)
PY
if [[ $? -eq 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
