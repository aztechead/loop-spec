# VERIFY pre-team gates (reference)

Extracted verbatim from `skills/verify/SKILL.md` Steps 0–1.75; the SKILL stub points
here. Apply as written before creating the VERIFY team.

Contents: Step 0 advisory regression scan · Step 1 placeholder scan · Step 1.5
test-tamper scan · Step 1.75 `feature-validation.sh compare`.

### Step 0 - Regression gate (opt-in)

This scan re-runs every prior completed feature's test commands serially and is **advisory only** (it can never block VERIFY). Because that serial cost sits in front of the fail-fast marker scan and the parallel team, it is **off by default**; enable it with `LOOP_SPEC_REGRESSION_SCAN=1` — or let the repo's tuning overlay demand it: when suite regressions have recurred in this repo, `lib/tuning.sh` records `suite-regression` as a mandatory check and the scan runs regardless of the env opt-in (`skills/shared/tier-matrix.md` "Repo tuning overlay").

```bash
if [[ "${LOOP_SPEC_REGRESSION_SCAN:-0}" == "1" ]] \
   || bash "${CLAUDE_SKILL_DIR}/../../lib/tuning.sh" has-check suite-regression; then
  REGRESSION_JSON=$(bash "${CLAUDE_SKILL_DIR}/../../lib/regression-scan.sh" .)
else
  echo "Regression scan skipped (set LOOP_SPEC_REGRESSION_SCAN=1 to enable)"
fi
```

When enabled:

Parse the JSON output:

```bash
PRIOR_COUNT=$(echo "$REGRESSION_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('prior_features', [])))")
FAILED_COUNT=$(echo "$REGRESSION_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('failed_tests', [])))")
```

This gate is **advisory only**: a non-zero `failed_tests` count does NOT block VERIFY. Log the result to VERIFICATION.md:

```
Regression scan complete: {PRIOR_COUNT} prior features checked, {FAILED_COUNT} test failures (advisory)
```

If `regression-scan.sh` itself fails (exits non-zero or produces invalid JSON), log a warning and continue without blocking:

```
Warning: regression-scan.sh failed to run; skipping advisory regression gate
```

### Step 1 - Placeholder scan (no stub implementations)

Before spawning any teammates, scan the diff for placeholder/stub markers — the
code-level form of self-authored deferral (`skills/shared/no-deferral.md`): a TODO,
FIXME, `NotImplementedError`, or "not implemented" throw in an ADDED line means a
stub shipped where the design promised a full implementation.

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-scan-each.sh" \
  "${CLAUDE_SKILL_DIR}/../../lib/placeholder-scan.sh" \
  --feature-dir ".loop-spec/features/${slug}"
```

`lib/feature-scan-each.sh` walks every git target of the feature: the single-repo
toplevel, or each `workspace.repos[]` with that repo's `baseSha` and absolute
path. Do not pass top-level `{baseSha}` / `.` to the scan — those are empty in
workspace mode and the workspace root is not a git repository. Per-repo
invocation (`placeholder-scan.sh <base-sha> <repo-path>`) remains valid for a
known tree.

Exit 1 = signals found: VERIFY fails immediately. Print the listed `file:line: signal`
lines verbatim, and emit the failure class (`bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" verify_failure --phase verify --data '{"class":"marker"}' || true`).
Do not spawn verifier or code-reviewer until all markers are resolved.

Notes:
- Only ADDED lines are scanned (diff vs `{baseSha}`), so pre-existing markers in a
  not-green repo never fire — the scan reports what THIS feature introduced.
- Markdown/docs files are exempt: prose descriptions of markers are not stub code.
- The marker set and exemptions live in `lib/placeholder-scan.sh` (one home); do not
  re-derive them as inline grep pipelines here.

Rationale: placeholder markers are incomplete implementation; running acceptance
gates against incomplete code wastes agent effort, and a stub that survives to the
PR is deferred scope the model chose on its own.

### Step 1.5 - Test-tamper scan (anti-reward-hacking, fail-fast)

The implementer may have edited the very suite the acceptance gate is about to trust. Before spawning teammates, scan the diff for oracle tampering — deleted test files, newly-added skip/focus annotations (`.skip`, `.only`, `xit`, `@pytest.mark.skip`, `t.Skip`, ...), and `|| true` swallowing a test command's exit code:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-scan-each.sh" \
  "${CLAUDE_SKILL_DIR}/../../lib/test-tamper-scan.sh" \
  --feature-dir ".loop-spec/features/${slug}"
```

Same `--feature-dir` contract as Step 1. Do not pass top-level `{baseSha}` / `.`
in workspace mode.

Exit 1 = signals found: VERIFY fails immediately. Print the listed signals verbatim and emit the failure class (`bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" verify_failure --phase verify --data '{"class":"tamper"}' || true`). This is NOT auto-remediable by re-running EXECUTE with a generic brief — the remediation task must state the specific tampering (`subject = "Fix: restore tampered test — {signal}"`) so the implementer un-tampers rather than re-tampers. A legitimate skip (e.g. a platform-gated test) is the HUMAN's call: in `step`/`interactive` styles ask; in autonomous styles treat as tampering and remediate — a real platform gate will come back with justification in the task notes and can be accepted on the next pass by recording it in `warnings[]`.

### Step 1.75 - Prepared no-new-failures gate

Before creating the VERIFY team, run the shared feature-level adapter:

```bash
validation_rc=0
VALIDATION_JSON="$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-validation.sh" compare \
  ".loop-spec/features/${slug}")" || validation_rc=$?
```

It runs the persisted preparation command in every participating repository, then runs
test/lint/typecheck against the candidate. This is the only place the cycle's
repository-wide suite runs — an invariant, not a default: startup does not run it (the
baseline capture is opt-in), EXECUTE does not run it at any rung, and cycle resume does
not run it (it reads `tasks.json` for which ids are already `status=done` and continues
remaining work in the recorded phase). With no recorded baseline (the default, since
`LOOP_SPEC_STARTUP_BASELINE` is off) every failure blocks. With a captured baseline the
comparison is relative: exit 0 means no new failures, and pre-existing fingerprints may
remain and must be reported as known baseline failures rather than repaired. Exit 20 is a
real suite regression: emit `suite-regression`, append the normal
FULL-SHAPE remediation task, and return to the cycle orchestrator without spawning VERIFY
agents — the pending remediation state drives the graph's declared remediation route
(`graph/cycle.graph.json`). Exit 21 is environment/infrastructure failure: preserve the JSON
and logs, escalate, and do not mislabel setup repair as implementation work. Acceptance
criterion commands remain absolute pass/fail, and DELIVER's required GitHub checks remain
absolute green.
