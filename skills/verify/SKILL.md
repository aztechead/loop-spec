---
name: verify
description: VERIFY phase - acceptance gate, code-review HARD-GATE via the verify team (explicit, implicit, or no-teams dispatch), evidence commit, and map-codebase refresh. Cycle-internal - invoked by /loop-spec:cycle against the active feature's state; not for ad-hoc invocation on a bare user request (start via /loop-spec:cycle).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# VERIFY Phase

Invoked when feature.json currentPhase == "verify".

> **No-teams fallback:** if `.loop-spec/runtime.json.teamsAvailable == false`, do NOT
> call `TeamCreate`/`TeamDelete`/`SendMessage` (they throw). Run verifier and
> code-reviewer as sequential one-shot `Agent` calls with the same agent types, models,
> and prompt templates, per `skills/shared/no-teams-fallback.md`. The acceptance gate and
> code-review HARD-GATE semantics are unchanged.

> **Implicit-team harness:** if `.loop-spec/runtime.json.teamsMode == "implicit"` (CC >= 2.1.178),
> do NOT call `TeamCreate`/`TeamDelete` (they were removed and throw). Probe
> `lib/implicit-team-model.sh spawn-kind --teams-mode implicit --selector <feature.models.role>`
> per teammate. `named`: `Agent({name, description, subagent_type, prompt})` with no
> `model` key, then `SendMessage` for follow-up. `oneshot`: nameless Agent with the
> alias so routing binds; rework re-dispatches per `skills/shared/no-teams-fallback.md`.
> Per `skills/shared/implicit-team-mode.md`. The acceptance gate and code-review
> HARD-GATE semantics are unchanged.

> **Autonomous mode** (`feature.json.autonomous == true`): no escalation in this phase
> may wait on a human, and `warnings[]` is an audit record, never the handler
> (`skills/shared/autonomous-mode.md`, continuation ladder). Gate failures route through
> the existing autonomous machinery: acceptance and code-review findings become
> `pendingRemediationTasks[]` consumed by EXECUTE re-entry (the Ralph remediation loop),
> exactly as written below. The acceptance gate, code-review HARD-GATE, and test-tamper
> scan are safety gates and are NEVER self-answered past — they are satisfied by
> remediation, not skipped.

## Inputs

- `feature_path` (path to `.loop-spec/features/{slug}/feature.json`)
- `spec_path`, `plan_path`
- `branch`, `baseSha`
- `slug`

## Procedure

VERIFY enforces `skills/shared/verification-grounding.md`: repository grounding and
executed validation are separate mandatory gates. Neither a green command nor a refreshed
codebase map substitutes for post-change `file:line` evidence tied to each criterion.

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

### Step 2 - TeamCreate verify team

Create the verify team with verifier and code-reviewer as parallel teammates:

Start both teammate objects without `model`. Add the key only when the matching
`feature.models.<role>` value is an Agent alias; omit it for `inherit`.

```
TeamCreate({
  name: "loop-spec-verify-{slug}",
  teammates: [
    {
      name: "verifier-1",
      subagent_type: "loop-spec:verifier"
    },
    {
      name: "code-reviewer-1",
      subagent_type: "loop-spec:code-reviewer"
    }
  ]
})
```

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = "loop-spec-verify-{slug}"`
- `currentTeammates = ["verifier-1", "code-reviewer-1"]`

### Step 3 - Acceptance gate (workflow path or fallback)

Read `.loop-spec/runtime.json`. If `workflowsAvailable=true`, dispatch:

**Workspace mode:** do not use the workflow path. A workspace root may not be a Git
repository and each participating repository has its own base SHA. Use the verifier
fallback with the per-repository contract in `references/workspace-mode.md`.

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/acceptance-verify.js",
  args: {
    criteria: <SPEC Good Enough bullets normalized by order to GE-001, GE-002, ... and matched to their PLAN.md verify commands>,
    baseSha: feature.baseSha,
    repositoryRoot: <absolute current repository root>,
    specPath: <absolute spec_path>,
    planPath: <absolute plan_path>,
  }
})
```

Persist `feature.json.activeWorkflow` before the call; clear after.
Result shape: `{criteria: [{id, verdict, repositoryEvidence, evidence, testSuiteStatus, refutes, upheld}], allPass}`.
Skill writes VERIFICATION.md from this structure (one section per criterion).
For each criterion, combine its exact `implementation: ...` and `integration: ...`
entries into the canonical artifact row:
`- criterion: <GE-NNN> | implementation: ... | integration: ...`.
An empty `repositoryEvidence`, evidence without concrete `file:line` implementation and
integration references (or an explicit reason no separate integration site exists), or
an unsupported implementation assumption forces that criterion to `FAIL` before
`allPass` is evaluated.

Test-regression remediation routing is preserved by reading
`criteria[].testSuiteStatus`: any `"FAIL"` → trigger the same remediation branch
that today's verifier triggers on `Test suite status: FAIL`.

If `workflowsAvailable=false`, fall through to the existing verifier-1 spawn
below.

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** emit one `dispatch` event per agent launched in this phase (verifier, code-reviewer, security-reviewer when dispatched) — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "verify" --data '{"role":"<role>","model":"<resolved selector>","rung":"<team|subagent|workflow>"}' || true`. One event per LAUNCH; `SendMessage` rework rounds do not re-emit.

### Step 4 - Spawn verifier-1

Send verifier-1 its work prompt via SendMessage:

Pass `VALIDATION_JSON` in the brief. The deterministic adapter is authoritative for the
repository-wide test/lint/typecheck regression status; the verifier owns criterion commands
and grounding and must not rerun the repository-wide commands independently.

**Single-repo mode (unchanged):**

```
SendMessage({
  to: "verifier-1",
  message: "Apply skills/shared/verification-grounding.md, then run every acceptance criterion's verify command from PLAN.md. Inspect git diff {baseSha}..HEAD and current files. Repository-wide validation already ran through lib/feature-validation.sh; record the supplied VALIDATION_JSON, report Test suite status PASS when its outcome is accepted (including explicitly labeled known baseline failures), and do not rerun those project commands. For every Good Enough criterion write exactly one VERIFICATION.md row: '- criterion: <id> | implementation: <repo-relative-file>:<line> - <what it proves> | integration: <repo-relative-file>:<line> - <what it proves>'; only use 'integration: none - <concrete reason>' when no separate integration site exists. Missing/mismatched grounding is FAIL even when the command passes. Gate ONLY on Good Enough; Exceptional is informational. When complete, SendMessage({to: 'lead', message: 'VERIFIER DONE: <ALL_PASS|FAIL> <Test suite status: PASS|FAIL|N/A> <summary>'})."
  // also include: slug, spec_path, plan_path, branch, baseSha,
  //   and VALIDATION_JSON from Step 1.75
})
```

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 4 - Spawn verifier-1").

### Step 5 - Code-review HARD-GATE (workflow path or fallback)

Read `.loop-spec/runtime.json`. If `workflowsAvailable=true`:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/code-review-dimensions.js",
  args: {
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

Pass `probe_dir` (the absolute `${CLAUDE_SKILL_DIR}/../../lib`) so the code-for-humans pass can measure the diff's conventions instead of judging them, and the over-engineering pass can locate duplication with `duplication-scan.sh` instead of eyeballing it — without it both degrade to reading neighbors and can only report Minor. Pass `spec_path` so the reviewer can check each SPEC Boundary / anti-goal against the diff (the "must never produce" behaviors most worth catching at a HARD gate), and echo the blocking-severity rule (Critical + Important block; Minor is recorded, backlogged, and never blocks) so the reviewer self-prioritizes blocking findings. Include `skills/shared/review-prompts/no-prejudge.md` (do not paste): never tell a reviewer what not to flag.

**Single-repo mode (unchanged):**

```
SendMessage({
  to: "code-reviewer-1",
  message: "Review the feature branch diff against SPEC.md and PLAN.md acceptance criteria. Check each SPEC '## Boundaries (what NOT to do)' anti-goal against the diff; flag any violation Critical. Rank findings by the fixed rule: Critical + Important block; Minor is recorded but never blocks. When complete, SendMessage({to: 'lead', message: 'CODE-REVIEWER DONE: <PASS|PASS_WITH_MINOR|BLOCK> <summary of findings>'})."
  // also include: slug, branch, baseSha, spec_path, plan_path,
  // and probe_dir = "${CLAUDE_SKILL_DIR}/../../lib" (absolute) so the over-engineering
  // and code-for-humans passes can run their probes; the reviewer's cwd is the repo,
  // not the plugin.
})
```

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 6 - Spawn code-reviewer-1").

### Step 7 - Acceptance gate

Wait for both `VERIFIER DONE` and `CODE-REVIEWER DONE` messages from teammates before proceeding.

Before trusting either the workflow result or `VERIFIER DONE`, run the deterministic
artifact gate. The linter derives `GE-001`, `GE-002`, and so on directly from SPEC's
ordered Good Enough bullets. In single-repo mode use the current repository root; in
workspace mode use the workspace root so evidence paths can include each repository's
relative path:

```bash
grounding_args=(--repo "${feature_workspace_root:-$(git rev-parse --show-toplevel)}")

bash "${CLAUDE_SKILL_DIR}/../../lib/verification-grounding-lint.sh" \
  "docs/loop-spec/features/${slug}/VERIFICATION.md" "${grounding_args[@]}" \
  --spec "$spec_path"
```

Exit 1 is a verifier `FAIL` regardless of the reported status or green commands. Preserve
the emitted `FLAG` lines as the failure evidence and route through the normal acceptance
remediation branch. This gate is mandatory when workflows are unavailable, which is the
normal OpenCode/ADK path; prompt compliance alone never clears VERIFY.

#### Remediation teardown (shared by every failing gate in Steps 7 and 7.5)

Every remediation task is FULL-SHAPE:

```json
{
  "id": "task-NNN+remediate-M",
  "subject": "Fix: {criterion or finding}",
  "files": ["...derived from failure"],
  "verifyCommand": "criterion's verify command",
  "acceptanceCriteria": ["criterion"],
  "blockedBy": [],
  "retries": 0
}
```

Partial-shape tasks get DENIED by the task guard when EXECUTE registers them. Then:

1. Append each remediation task to `feature.json.pendingRemediationTasks[]` via
   `lib/feature-write.sh append`. EXECUTE Step 2a reads this array alongside PLAN.md
   tasks on next entry. Using feature.json (not `TaskCreate` on the verify team) is
   critical: the verify team's task list is destroyed by the `TeamDelete` below, so
   any `TaskCreate` calls on it would be lost.
2. Append the fail entry to `gateHistory[]` via `lib/feature-write.sh`
   (`phase: verify`, `gate: <acceptance|code-review|live-verify>`, `result: fail`).
3. Discard code-reviewer output for this iteration when a verifier gate failed
   (it re-runs when VERIFY loops back after remediation).
4. Call `TeamDelete({name: "loop-spec-verify-{slug}"})`, then via
   `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.
5. Return to the cycle orchestrator. `lib/ralph-remediation.sh` is the graph's declared
   route probe for pending remediation (`graph/cycle.graph.json`): the recorded tasks —
   never this skill — select the rewind, and the probe's own threshold logic
   (`LOOP_SPEC_RALPH_THRESHOLD`) decides between the bounded remediation loop and the
   full EXECUTE team. The graph's loop edge re-enters VERIFY from Step 1 after
   remediation lands.

#### verifier-1 gate

**If verifier reports `ALL_PASS` AND `Test suite status: PASS` (or `N/A`):** proceed to code-reviewer gate below. `PASS` means Step 1.75 found no new repository-wide failures; VERIFICATION.md may list unchanged known baseline failures.

**If verifier reports `ALL_PASS` but `Test suite status: FAIL`:** a criterion-specific
command failed after Step 1.75 (repository-wide regressions already returned to EXECUTE
before team creation). Emit
`bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" verify_failure --phase verify --data '{"class":"suite-regression"}' || true`,
generate one remediation task (`subject = "Fix: test suite regression"`,
`verifyCommand = feature.commands.test`, `files = []` until diagnosed,
`acceptanceCriteria = ["test suite passes"]`), and run the **Remediation teardown**
(gate: `acceptance`).

**If verifier reports `FAIL`** (including any failed grounding gate: absent/stale
`repositoryEvidence`, an unsupported assumption, or repository evidence that
contradicts the implementation): emit the `'{"class":"acceptance"}'` failure event,
generate one remediation task per failed criterion, and run the **Remediation
teardown** (gate: `acceptance`).

#### code-reviewer-1 HARD-GATE

Use the `CODE-REVIEWER DONE` message already received from Step 6.

Fixed gate rule (single-tier operation): **BLOCK on Critical OR Important. PASS_WITH_MINOR proceeds; every Minor is backlogged below.**

**If BLOCK:** emit the `'{"class":"code-review"}'` failure event, generate one
remediation task per blocking finding, and run the **Remediation teardown**
(gate: `code-review`).

**If PASS or PASS_WITH_MINOR:**
- Append code-review section to VERIFICATION.md.
- **Backlog the deferred findings (they must not evaporate):** every Minor finding in a PASS_WITH_MINOR is appended to the project backlog:
  ```bash
  bash "${CLAUDE_SKILL_DIR}/../../lib/backlog.sh" add "{slug}" verify-deferred "{finding: file:line — claim}"
  ```
  Deferral means "not this feature", not "never" — the backlog is where `/loop-spec:cycle backlog` picks them up.
- Proceed to Step 8.

**Self-learning writer (repeat failures become rules):** whenever this step appends a `result: fail` entry to `gateHistory[]`, check whether the SAME criterion or finding already failed in a prior entry (same `gate`, matching criterion/finding text). On the second failure, record the lesson as a deterministic rule so future runs cannot repeat it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/rules.sh" add "VERIFY repeat-fail on '{criterion}' ({slug}): check this before EXECUTE completes" --check "{the criterion's verify command}"
```

One rule per repeated criterion (rules.sh add is idempotent). Do not write rules for first-time failures — one failure is remediation's job; a repeat is a pattern.

### Step 7.5 - Live-run verify rung (opt-in per repo; ROADMAP-3.0 C1)

Probe-before-assert extended past the suite: when the repo has configured a `verifyCommands` block in `.loop-spec/workflow.json`, launch the app, wait for readiness, and run the acceptance probes — the loop ends at "observed working", not "suite green". Runs ONLY after both Step 7 gates passed (a live probe against known-failing code wastes the launch).

```bash
LIVE_JSON="$(bash "${CLAUDE_SKILL_DIR}/../../lib/verify-live.sh" run \
  --evidence "docs/loop-spec/features/${slug}/EVIDENCE.md")"; LIVE_EC=$?
```

- **Unconfigured** (`configured: false`, exit 0): suite-only VERIFY, unchanged. NEVER guess a launch command here. If the user has not been offered configuration before, `bash "${CLAUDE_SKILL_DIR}/../../lib/verify-live.sh" detect .` may SUGGEST one — in interactive styles offer it once; in autonomous mode record a `decisions.sh` entry that the rung stayed off (suggestion included when detect found one) and move on.
- **Exit 0 with `allPass: true`:** append a "## Live verification" section to VERIFICATION.md listing each probe with its `EVID-NNN` id (the verifier cites evidence ids, never bare claims — the probe outputs are already in the EVIDENCE.md ledger).
- **Exit 1** (never became ready, or a probe failed): emit the `'{"class":"live-probe"}'` failure event, generate one remediation task per failed probe (`subject = "Fix: live probe failed — {probe cmd}"`, `verifyCommand` = the probe), and run the **Remediation teardown** (gate: `live-verify`).

### Step 7.6 - Verification-gap pass

Asks the one question the gates above do not: if the behavior this change produces broke where it is actually used, would any verification fail? Step 1.5 defends the tests that already exist; Step 3 checks that criteria carry verify commands; neither traces NEW behavior out to the sites that observe it.

Ground it in the probe before dispatching, so the reviewer reasons from a measured symbol search rather than recalling one:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/verification-gap-scan.sh" "$baseSha" HEAD || true
```

Exit 1 means no definition changed in a non-test file — record that and skip the pass. Otherwise dispatch one reviewer carrying `${CLAUDE_SKILL_DIR}/../../skills/shared/review-prompts/verification-gap.md` verbatim plus the probe output, on the same maker≠checker terms as Step 6 (never the agent that wrote the code).

Findings are **advisory in this release**: record them in VERIFICATION.md under `## Verification gaps` and append each to `.loop-spec/BACKLOG.md`. They do not block delivery. A gap class this new blocking a verified change would cost more than it catches until the false-positive rate is measured on real runs; promoting it to blocking is a tuning decision backed by telemetry, not a default.

### Step 7.65 - Plain-language pass (advisory)

Checks the prose this cycle produced against `skills/shared/plain-language.md` (the
contract, including which rules are machine-checked and which never will be).
Deterministic, never a model judgment:

```bash
lint="${CLAUDE_SKILL_DIR}/../../lib/plain-language-lint.sh"
bash "$lint" prose docs/loop-spec/features/"$slug"/*.md --max-flags 40 || true
bash "$lint" comments $(git diff --name-only "$baseSha" HEAD -- '*.sh' '*.py') --max-flags 20 || true
```

Findings are **advisory and stay advisory until the false-positive rate is measured**
(the linter flags roughly one line in six on this repo's own artifacts). Record the
counts per check in VERIFICATION.md under `## Plain language` and append only the flags
a human agrees with to `.loop-spec/BACKLOG.md` — never the raw list. A clean run is not
evidence the prose is good.

### Step 7.66 - Docs-for-humans pass

Asks whether the markdown this change leaves behind can be maintained and operated by a
person. `skills/shared/human-docs.md` is the contract; `lib/doc-tells.sh` is the corner of it
that is decidable from the text and the tree.

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/doc-tells.sh" diff "$baseSha" HEAD
```

Exit 0 means the documents this change touched carry no relative link without a target, no
inline-code path the tree no longer holds, and no shell command holding a placeholder the
prose never explains. Exit 1 lists each with `file:line` and is a gate failure: fix them
here and re-run until clean. Do not append `|| true` — that swallows the only signal this
pass has.

These findings are **fixable, not advisory**: every one names a file, a line, and a one-line
edit, so fix them here and re-run until clean rather than backlogging them. The escape hatch
is narrow and recorded: a finding that is one of the misfires the contract documents (a design
artifact naming a file this change deliberately does not create, a frozen record) is written
into VERIFICATION.md under `## Docs for humans` with the reason and does not block. Never
suppress the check itself.

The judgment half belongs to the code-reviewer (Step 6, pass 8.5): which document the change
made false, and whether a procedure a person must follow states its prerequisites, its
expected output, and what to do when a step fails.

### Step 7.7 - Project review layers (opt-in per repo)

Any layer the project declared in `.loop-spec/extensions.json` runs here, after the built-in gates:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/extension-points.sh" layers verify
```

Each emitted line names a layer and its `promptFile`. Dispatch one reviewer per layer with that file's contents, and record findings alongside the verification-gap findings. Extensions ADD only: a declared layer can never disable, reorder, or shadow a built-in gate, and `extension-points.sh validate` refuses a layer claiming a built-in gate id. No output, a missing file, or a malformed file means no extra layers and no error — this path fails open.

### Step 7.8 - Write the reviewer's guide

The change is verified; now make it reviewable. Follow `skills/walkthrough/SKILL.md` in `--write` mode to produce `docs/loop-spec/features/{slug}/REVIEW-ORDER.md`, then lint it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/review-trail.sh" lint \
  "docs/loop-spec/features/${slug}/REVIEW-ORDER.md" "$baseSha" HEAD
```

Fix every finding and re-run until clean. Record the artifact path in `feature.json` as `artifacts.reviewOrder` so DELIVER inlines it into the PR body.

This never gates delivery. If the trail cannot be produced or will not lint after a reasonable attempt, note it in VERIFICATION.md and continue — a verified change held back over prose costs the reviewer more time than the guide saves.

### Step 8 - TeamDelete verify team

```
TeamDelete({name: "loop-spec-verify-{slug}"})
```

Update `feature.json` via `lib/feature-write.sh`: `currentTeamName = null`, `currentTeammates = []`.

### Step 9 - map-codebase refresh

Resolve the automatic refresh policy first:

```bash
map_refresh="$(bash "${CLAUDE_SKILL_DIR}/../../lib/map-policy.sh" refresh)"
```

When it returns `skip`, print `codebase map refresh skipped by LOOP_SPEC_MAP_REFRESH=0`
and continue to Step 10 without invoking map-codebase. The override also applies to
greenfield runs; use it only when the caller accepts having no generated map.

**Single-repo mode (unchanged):**

The map-codebase skill owns the post-change map refresh and its commit. Do not duplicate that work here.

**Greenfield (`feature.json.greenfield == true`):** this is where the project's FIRST graph and FIRST codebase map get built (cycle Steps 5.4/5.5 deferred them — an empty repo grounds nothing). map-codebase Step 0 creates and commits the initial graph; invoke it with `--full` instead of incremental, since there are no existing domain docs to refresh.

Invoke the map-codebase skill for an incremental refresh:

```
Skill(loop-spec:map-codebase) with mode: "incremental", since_sha: feature.baseSha
```

Note: the map-codebase skill runs inside the feature worktree (cwd is already there). Any mapper subagents it spawns do NOT inherit the cwd and must receive an absolute repo path. Resolve it once and pass it through -- only in single-repo mode (workspace root may not be a git repo):

```bash
# Single mode only -- do NOT run this at a workspace root:
WORKTREE_ABS="$(git rev-parse --show-toplevel)"
# pass WORKTREE_ABS to each mapper subagent as its working directory
```

If map-codebase fails: log warning to `feature.json warnings[]` via `lib/feature-write.sh` and continue (non-blocking; map failure is not a release gate).

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 9 - map-codebase refresh").

### Step 10 - Commit VERIFICATION.md

Before committing, run the structural format gate — the iterate judge and
`lib/regression-scan.sh` parse VERIFICATION.md by its template sections:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" verification "docs/loop-spec/features/{slug}/VERIFICATION.md"
```

Exit 1 BLOCKS: fix VERIFICATION.md in place per the FLAG lines (the lead authored it;
`skills/shared/artifact-templates/VERIFICATION.md.template` is the shape) and re-run
until it prints `artifact-lint: ok`.

**Single-repo mode (unchanged):**

```bash
git add docs/loop-spec/features/{slug}/VERIFICATION.md
git commit -m "verify: NO_JIRA {slug}" -- docs/loop-spec/features/{slug}/VERIFICATION.md
```

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" tag post-verify
```

**Workspace mode (additive):** apply the workspace variant for this step verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 10 - Commit VERIFICATION.md").

### Step 11 - Update feature.json

Update `feature.json` via `lib/feature-write.sh` (nested `set`/`append` take dot paths directly, values JSON-quoted, never raw jq — `skills/shared/feature-state-schema.md` "Writing rules"):
- `completedPhases.append("verify")` — `feature-write.sh append "$fdir" completedPhases '"verify"'`
- `artifacts.verification = "docs/loop-spec/features/{slug}/VERIFICATION.md"` — `feature-write.sh set "$fdir" artifacts.verification '"docs/loop-spec/features/{slug}/VERIFICATION.md"'`

VERIFY's gates passing means the SPEC acceptance checklist is met; the graph's next
node (ITERATE) then judges the integrated result against the **original goal** and
decides whether to ship or loop back (see `skills/iterate/SKILL.md`).

### Step 12 - Return inside the active feature root

VERIFY does not push, open a PR, print a shipped summary, or leave the feature root.
Return to the cycle orchestrator; the graph declares VERIFY's successor. ITERATE may
rewind and add commits; only a terminal ITERATE verdict advances to DELIVER, which
owns the exact-SHA push, PR reconciliation, required checks, and readiness transition.

## Resume

If invoked with `feature.json currentPhase == "verify"`: check what completed (team created? verifier ran? acceptance gate? code-reviewer? map-codebase? verification commit?). Resume from first incomplete step.

On resume, if `currentTeamName` is non-null:
- In `explicit` teams mode only: call `TaskList({team: currentTeamName})`; if it errors (team not found), clear `currentTeamName` in `feature.json` and recreate the team via Step 2. In `implicit`/`none` modes skip the probe (modern `TaskList` takes no parameters; teammates never survive the session): clear `currentTeamName` and re-run Step 2's spawn path.
- If it succeeds (team still live): re-attach and resume from the last incomplete step.

If `currentTeamName` is null: recreate the verify team from Step 2 and replay.
