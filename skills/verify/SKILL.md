---
name: verify
description: VERIFY phase - acceptance gate, code-review HARD-GATE via TeamCreate, map-codebase refresh, branch finish (push + PR).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet
---

# VERIFY Phase

Invoked when feature.json currentPhase == "verify".

## Inputs

- `feature_path` (path to `.super-spec/features/{slug}/feature.json`)
- `spec_path`, `plan_path`
- `branch`, `baseSha`
- `slug`, `tier`

## Procedure

### Step 0 - Regression gate (opt-in)

This scan re-runs every prior completed feature's test commands serially and is **advisory only** (it can never block VERIFY). Because that serial cost sits in front of the fail-fast marker scan and the parallel team, it is **off by default**; enable it with `SUPER_SPEC_REGRESSION_SCAN=1`.

```bash
if [[ "${SUPER_SPEC_REGRESSION_SCAN:-0}" != "1" ]]; then
  echo "Regression scan skipped (set SUPER_SPEC_REGRESSION_SCAN=1 to enable)"
else
  REGRESSION_JSON=$(bash "${CLAUDE_SKILL_DIR}/../../lib/regression-scan.sh" .)
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

### Step 1 - Unresolved marker scan

Before spawning any teammates, scan source files on `branch` for unresolved markers:

```bash
git diff --diff-filter=ACMR {baseSha}..HEAD --name-only \
  | grep -E '\.(py|ts|js|go|rs|java|rb|sh)$' \
  | xargs grep -wn 'TBD\|FIXME\|XXX' 2>/dev/null || true
```

If any matches: VERIFY fails immediately. List each `file:line: match` to the user.
Do not spawn verifier or code-reviewer until all markers are resolved.

Notes:
- `--diff-filter=ACMR` excludes deleted files (avoids "no such file" errors on xargs)
- `.md` excluded from filter: prose descriptions of markers are not unresolved code
- `-w` (word boundary) avoids false positives on identifiers like `STBD`, `XXXL`

Rationale: unresolved markers indicate incomplete implementation; running acceptance
gates against incomplete code wastes agent budget.

### Step 2 - TeamCreate verify team

Create the verify team with verifier and code-reviewer as parallel teammates:

```
TeamCreate({
  name: "super-spec-verify-{slug}",
  teammates: [
    {
      name: "verifier-1",
      subagent_type: "super-spec:verifier",
      model: feature.models.verifier
    },
    {
      name: "code-reviewer-1",
      subagent_type: "super-spec:code-reviewer",
      model: feature.models.codeReviewer
    }
  ]
})
```

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = "super-spec-verify-{slug}"`
- `currentTeammates = ["verifier-1", "code-reviewer-1"]`

### Step 3 - Acceptance gate (workflow path or fallback)

Read `.super-spec/runtime.json`. If `workflowsAvailable=true`, dispatch:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/acceptance-verify.js",
  args: {
    tier: feature.tier,
    criteria: <parsed from PLAN.md acceptance section>,
  }
})
```

Persist `feature.json.activeWorkflow` before the call; clear after.
Result shape: `{criteria: [{id, verdict, evidence, testSuiteStatus, refutes, upheld}], allPass}`.
Skill writes VERIFICATION.md from this structure (one section per criterion).

Test-regression remediation routing is preserved by reading
`criteria[].testSuiteStatus`: any `"FAIL"` → trigger the same remediation branch
that today's verifier triggers on `Test suite status: FAIL`.

If `workflowsAvailable=false`, fall through to the existing verifier-1 spawn
below.

### Step 4 - Spawn verifier-1

Send verifier-1 its work prompt via SendMessage:

Resolve the test/lint/typecheck commands from `feature.json.commands` and pass them in the brief so the verifier (the authoritative test runner) never has to guess or report a false "no command found" FAIL.

```
SendMessage({
  to: "verifier-1",
  body: "Run every acceptance criterion's verify command from PLAN.md. Gate ONLY on the SPEC 'Good Enough' success criteria; report 'Exceptional' (stretch) criteria as informational, never as a FAIL. Write VERIFICATION.md to docs/super-spec/features/{slug}/VERIFICATION.md. When complete, SendMessage({to: 'lead', body: 'VERIFIER DONE: <ALL_PASS|FAIL> <Test suite status: PASS|FAIL|N/A> <summary>'})."
  // also include: slug, spec_path, plan_path, branch, baseSha, tier,
  //   and the resolved commands: test="<feature.commands.test>", lint="<feature.commands.lint>", typecheck="<feature.commands.typecheck>"
})
```

verifier-1 works independently. Lead waits for its completion signal.

### Step 5 - Code-review HARD-GATE (workflow path or fallback)

Read `.super-spec/runtime.json`. If `workflowsAvailable=true`:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/code-review-dimensions.js",
  args: {
    tier: feature.tier,
    baseSha: feature.baseSha,
  }
})
```

Result shape: `{findings: [{file, line, dimension, severity, claim, refuteVotes, upheld}], critical, important}`.

**Skill (not workflow) converts findings to pendingRemediationTasks[]** by
filtering `upheld=true` and mapping each to a remediation task. The existing
RALPH_THRESHOLD comparison logic (skill-side, unchanged) then decides
Ralph-loop vs full EXECUTE re-entry.

If `workflowsAvailable=false`, fall through to the existing code-reviewer-1
spawn below.

### Step 6 - Spawn code-reviewer-1

Send code-reviewer-1 its work prompt via SendMessage:

Pass `spec_path` so the reviewer can check each SPEC Boundary / anti-goal against the diff (the "must never produce" behaviors most worth catching at a HARD gate), and echo the tier-to-blocking-severity rule (from the HARD-GATE table below) so the reviewer self-prioritizes blocking findings.

```
SendMessage({
  to: "code-reviewer-1",
  body: "Review the feature branch diff against SPEC.md and PLAN.md acceptance criteria. Check each SPEC '## Boundaries (what NOT to do)' anti-goal against the diff; flag any violation Critical. Rank findings by the tier rule: quality/balanced => Critical+Important block; quick => Critical only. When complete, SendMessage({to: 'lead', body: 'CODE-REVIEWER DONE: <PASS|PASS_WITH_MINOR|BLOCK> <summary of findings>'})."
  // also include: slug, branch, baseSha, spec_path, plan_path, tier
})
```

code-reviewer-1 works independently in parallel with verifier-1. Lead waits for both.

### Step 7 - Acceptance gate

Wait for both `VERIFIER DONE` and `CODE-REVIEWER DONE` messages from teammates before proceeding.

#### verifier-1 gate

**If verifier reports `ALL_PASS` AND `Test suite status: PASS` (or `N/A`):** proceed to code-reviewer gate below.

**If verifier reports `ALL_PASS` but `Test suite status: FAIL`:**
- Generate a remediation task: `subject = "Fix: test suite regression"`, `verifyCommand = feature.commands.test`.
- Append the remediation task to `feature.json.pendingRemediationTasks[]` via `lib/feature-write.sh append`. EXECUTE Step 2a reads this array alongside PLAN.md tasks on next entry. Using feature.json (not `TaskCreate` on the verify team) is critical: the verify team's task list is destroyed by the `TeamDelete` later in this step, so any `TaskCreate` calls on it would be lost.
- Update `feature.json` via `lib/feature-write.sh`:
  - Increment `retryBudget.perPhaseUsed.verify` and `retryBudget.globalUsed`.
  - Append entry to `gateHistory[]` (`phase: verify`, `gate: acceptance`, `result: fail`).
  - Check budgets. If either `perPhaseUsed.verify >= retryBudget.perPhase.verify` or `globalUsed >= retryBudget.global`: pause and escalate to user.
  - Else: set `currentPhase = "execute"`.
- Call `TeamDelete({name: "super-spec-verify-{slug}"})`.
- Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.
- Discard code-reviewer output for this iteration (will re-run when verify loops back after remediation).
- Route to `super-spec:execute`.

**If verifier reports `FAIL`:**
- Discard code-reviewer output for this iteration.
- For each failed criterion, generate a remediation task:
  ```json
  {
    "id": "task-NNN+remediate-M",
    "subject": "Fix: {criterion}",
    "files": ["...derived from failure"],
    "verifyCommand": "criterion's verify command",
    "acceptanceCriteria": ["criterion"],
    "blockedBy": [],
    "retries": 0
  }
  ```
- Append each remediation task to `feature.json.pendingRemediationTasks[]` via `lib/feature-write.sh append`. EXECUTE Step 2a reads this array alongside PLAN.md tasks on next entry. Using feature.json (not `TaskCreate` on the verify team) is critical: the verify team's task list is destroyed by the `TeamDelete` later in this step.
- Update `feature.json` via `lib/feature-write.sh`:
  - Increment `retryBudget.perPhaseUsed.verify` and `retryBudget.globalUsed`.
  - Append entry to `gateHistory[]` (`phase: verify`, `gate: acceptance`, `result: fail`).
  - Check budgets. If exceeded: pause and escalate to user.
  - Else: set `currentPhase = "execute"`.
- Call `TeamDelete({name: "super-spec-verify-{slug}"})`.
- Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.
- Route to `super-spec:execute`. When execute completes, re-invoke verify from Step 1.

#### code-reviewer-1 HARD-GATE

Use the `CODE-REVIEWER DONE` message already received from Step 6.

| Tier | Gate behavior |
|------|---------------|
| quality / balanced | BLOCK on Critical OR Important. PASS_WITH_MINOR proceeds (Minor deferred). |
| quick | BLOCK on Critical only. Important + Minor deferred. |

**If BLOCK:**
- Generate one remediation task per blocking finding (same remediation task shape as verifier FAIL above).
- Append each remediation task to `feature.json.pendingRemediationTasks[]` via `lib/feature-write.sh append`. EXECUTE Step 2a reads this array alongside PLAN.md tasks on next entry.
- Update `feature.json` via `lib/feature-write.sh`:
  - Increment `retryBudget.perPhaseUsed.verify` and `retryBudget.globalUsed`.
  - Append entry to `gateHistory[]` (`phase: verify`, `gate: code-review`, `result: fail`).
  - Check budgets. If exceeded: pause and escalate to user.
  - Else: set `currentPhase = "execute"`.
- Call `TeamDelete({name: "super-spec-verify-{slug}"})`.
- Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.
- **Ralph remediation routing:** Check `pendingRemediationTasks.length` from `feature.json`.
  - `RALPH_THRESHOLD="${SUPER_SPEC_RALPH_THRESHOLD:-3}"` (default 3).
  - If `pendingRemediationTasks.length <= RALPH_THRESHOLD`: invoke `bash "${CLAUDE_SKILL_DIR}/../../lib/ralph-remediation.sh" "$feature_dir"` and use its output to drive the remediation loop instead of the full EXECUTE team. If `ralph-remediation.sh` exits 1 (max iterations reached), fall through to the full EXECUTE team path.
  - Else (task count exceeds threshold): route to `super-spec:execute` (existing behavior). When execute completes, re-invoke verify from Step 1.

**If PASS or PASS_WITH_MINOR:**
- Append code-review section to VERIFICATION.md.
- Proceed to Step 8.

### Step 8 - TeamDelete verify team

```
TeamDelete({name: "super-spec-verify-{slug}"})
```

Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.

### Step 9 - map-codebase refresh

Before invoking the map-codebase skill, run an incremental graphify update if graphify is available:

```bash
if command -v graphify >/dev/null 2>&1; then
  graphify update . || echo "Warning: 'graphify update .' failed; continuing without graph refresh" >&2
fi
```

Failure of the graphify call is non-blocking; log a warning and continue.

Invoke the map-codebase skill for an incremental refresh:

```
Skill(super-spec:map-codebase) with mode: "incremental", since_sha: feature.baseSha
```

Note: the map-codebase skill runs inside the feature worktree (cwd is already there). Any mapper subagents it spawns do NOT inherit the cwd and must receive an absolute repo path. Resolve it once and pass it through:

```bash
WORKTREE_ABS="$(git rev-parse --show-toplevel)"
# pass WORKTREE_ABS to each mapper subagent as its working directory
```

If map-codebase fails: log warning to `feature.json warnings[]` via `lib/feature-write.sh` and continue (non-blocking; map failure is not a release gate).

### Step 10 - Branch finish

Push and PR creation execute from inside the feature worktree (cwd is already on `feat/{slug}`), so no branch checkout is needed. If any branch-finish step delegates to a subagent, pass the worktree's absolute path explicitly (subagents do not inherit cwd).

```bash
# Push (runs from feature worktree; cwd is already on feat/{slug})
git push -u origin {feature.branch}

# PR body: SPEC.md Problem+Goals sections + VERIFICATION.md acceptance table
spec_summary=$(awk '/^## Problem/,/^## (Constraints|User-facing)/' docs/super-spec/features/{slug}/SPEC.md | head -100)
verify_table=$(awk '/^## Acceptance criteria/,/^## Verify command outputs/' docs/super-spec/features/{slug}/VERIFICATION.md)
pr_body="$(printf '## Spec summary\n\n%s\n\n## Verification\n\n%s\n' "$spec_summary" "$verify_table")"

# Use baseBranch from feature.json (feature.baseBranch), not hardcoded main
pr_url=$(gh pr create --base "${feature.baseBranch:-main}" --head {feature.branch} --title "feat: {feature_title}" --body "$pr_body")
```

### Step 11 - Commit VERIFICATION.md

```bash
git add docs/super-spec/features/{slug}/VERIFICATION.md
git commit -m "verify: NO_JIRA {slug} (PR: {pr_url})"
```

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" tag post-verify
```

### Step 12 - Update feature.json

Update `feature.json` via `lib/feature-write.sh`:
- `completedPhases.append("verify")`
- `currentPhase = "completed"`
- `artifacts.verification = "docs/super-spec/features/{slug}/VERIFICATION.md"`

### Step 13 - Exit feature worktree (schema-6 only)

If `feature.worktreePath` is present (schemaVersion 6), the session is currently inside the feature worktree. Return to the main checkout while leaving the worktree and branch intact for the open PR:

```
ExitWorktree({ action: "keep" })
```

The worktree is kept on disk until the PR merges. Do NOT auto-remove it. Removal is manual (or handled by a future cleanup skill) once the branch is confirmed merged.

Skip this step entirely for legacy features (schemaVersion <= 5, no `worktreePath` field). Those features run in-place and have nothing to exit.

### Step 14 - Summary

Print to user:
- Feature slug
- PR URL
- Commits added
- Files changed
- Token usage estimate
- Total elapsed time

## Resume

If invoked with `feature.json currentPhase == "verify"`: check what completed (team created? verifier ran? acceptance gate? code-reviewer? map-codebase? push? PR?). Resume from first incomplete step.

On resume, if `currentTeamName` is non-null:
- Call `TaskList({team: currentTeamName})`. If it errors (team not found): clear `currentTeamName` in `feature.json`, recreate team via Step 2.
- If it succeeds (team still live): re-attach and resume from the last incomplete step.

If `currentTeamName` is null: recreate the verify team from Step 2 and replay.
