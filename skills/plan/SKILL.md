---
name: plan
description: "Create PATTERNS.md, PLAN.md, and tasks.json. Check task structure and evidence, then run the selected challenger review. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# PLAN

You produce `PATTERNS.md` (analogs to mirror) and `PLAN.md` (a task DAG with verify
commands) under `docs/loop-spec/features/{slug}/`, plus the machine-readable
`feature_dir/tasks.json` EXECUTE consumes. Dispatch follows `skills/shared/dispatch.md`.
Your inputs are the entry packet and nothing else:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin plan --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[] (a missing ingress; relay and return)
# .mode.critique=run|skip .mode.reentry=true|false .mode.reason (structural fast-path | maintenance | compact | security signal | ...)
```

`.mode.reentry` (ITERATE sent the cycle back for a `plan`-type gap): read `iterate.feedback`,
revise or add only the tasks that close it, keep `## User decisions (already made)`.

## 1. PATTERNS.md

Join a DISCUSS prefetch: check once whether PATTERNS.md exists
(`artifacts.patternsPrefetch == "in-flight"`: present → `"landed"`, missing →
`"timeout"`). Never `sleep` to join a background Agent (never sleep to poll) and
never AskUserQuestion as a wait. If PATTERNS.md exists, keep it. Else
`lib/gsd-ingest.sh patterns {slug} <target>` (`INGESTED` sets
`artifacts.patternsSource = "gsd-ingest"`). Else dispatch a one-shot `loop-spec:pattern-mapper`
Agent with absolute paths for SPEC.md, the target, and
`${LOOP_SPEC_SKILL_DIR}/../shared/artifact-templates/PATTERNS.md.template` (a subagent
cannot resolve a plugin-relative path), then stop; the planner's brief covers the last-resort fallback. Greenfield: PATTERNS.md
records the chosen stack's conventions instead of mined analogs.

`<target>`/the Agent's target is always `<feature_dir>/publication-staging/PATTERNS.md`:
every new cycle's `requirementsContract` is v1 from creation, which makes
`docs/loop-spec/features/{slug}/PATTERNS.md` a protected path (`lib/harness.sh`;
`hooks/restrict-agent-paths.sh`) no agent may write directly. Land the staged draft
with `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" plan patterns --feature-dir "$feature_dir" --file <target>`,
which lints it (`lib/artifact-lint.sh patterns`) and publishes it under the phase's
held token; it prints the published path.

## 2. Author PLAN.md

Read `skills/shared/approach-selection.md` and include it in the authoring brief on
every path below. Resolve evidence that challenges a settled design through the
existing decision path before accepting conflicting tasks.

Spawn `planner-1` with role `loop-spec:planner` and model `feature.models.planner`.
In team modes, also start `challenger-1` with SPEC.md.
Include these fields and instructions in the planner brief:

- `slug`, `spec_path`, `patterns_path`, and `evidence_path`.
- `draft_path`: `<feature_dir>/publication-staging/PLAN.md` -- the planner writes
  there, never to `docs/loop-spec/features/{slug}/PLAN.md` directly (that path is
  protected once `requirementsContract.format` is v1, which every new cycle now is
  from creation; `agents/planner.md` names the same scope).
- `template_path`: the absolute `${LOOP_SPEC_SKILL_DIR}/../shared/artifact-templates/PLAN.md.template`.
  Require its exact shape, including `## Task DAG`, `**Files:**`, `**Verify:**`, and `**Acceptance criteria:**`.
- Every external fact must cite `EVID-NNN` or use `ASSUMPTION: ... | verify: ...`.
- Every dependency from `lib/doc-deps.sh scan` on task files needs documentation evidence in `## Grounding`.
  Use `EVID-NNN` or an `ASSUMPTION`. Fetch current documentation with an available web tool, or report the missing evidence.
- Cite PATTERNS.md analogs in each task's steps.
- Include every field that `lib/plan-tasks.sh` reads, including `**BlockedBy:**`. Do not compute waves.
- When SPEC.md's frontmatter declares `requirements_version: 1` (the default for
  every new cycle; a resumed pre-7 cycle stays legacy instead --
  `docs/loop-spec/requirements-format.md`), each task also carries
  `**Requirements:**` single-line JSON bullets
  (`{"owner":{...},"requirement":"GE-NNN","revision":"<sha256>","scenarios":["SC-NNN"]}`)
  or `**Obligations:**` naming `OBL-` ids from `## Constraints`, taken from
  `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/requirements.sh" inventory --spec <spec_path> --feature-dir "$feature_dir"`.
  Under a legacy contract, omit both.
- Check the draft against `agents/planner.md` before submission.
- Copy `## Global constraints` verbatim, or write `- none`.

In workspace mode, each task has one `repo`. Use `<repo>/<path>` in `files[]` and `blockedBy` edges for cross-repository ordering.

For greenfield work, task-001 creates the scaffold: structure, manifest, adjacent generated lockfile, test harness, and a passing walking-skeleton test.
Its `verifyCommand` must be the stack's test command. Put installation steps in `commands.prepare`.
Every other task depends on task-001.
Complete `## System design` using the build-from-scratch and system-design stances in `skills/shared/engineering-stances.md`.
For refactor specs, apply that file's refactor stance.

With `workflowsAvailable` and `LOOP_SPEC_PLAN_MULTI_ANGLE=1`, the
`lib/workflows/plan-multi-angle.js` Workflow authors instead; log its angles to
`feature_dir/gate-logs/plan-multi-angle.json`.

When the planner reports, land its staged PLAN.md, derive `tasks.json` from it, and
run the mechanical gates. PLAN.md is the source; the completion message is a report,
and a message that arrives empty or stale never becomes the dispatch list. Landing
goes through the driver so a protected `docs/loop-spec/features/{slug}/PLAN.md`
(every new cycle, once its v1 contract exists) is never written or redirected into
directly -- `plan write` lints and publishes it, and `plan tasks` extracts and
publishes `tasks.json` from the PUBLISHED PLAN.md under the same held token:

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" plan write --feature-dir "$feature_dir" --file "$feature_dir/publication-staging/PLAN.md"
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" plan tasks --feature-dir "$feature_dir"
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/plan-conflicts.sh" edges "$feature_dir/tasks.json"
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/phase-exit.sh" plan --feature-dir "$feature_dir"
```

`edges` adds missing dependencies to tasks.json when `interfaces.consumes`, `goal`, or `brief` names another task.
It rejects an edge that would create a dependency cycle with exit 1.
Send that failure to the planner as a finding.

A non-zero extract exit is a message on stderr (no task blocks, or an unreadable
plan): it is a fix-list item for the planner, never an empty `tasks.json`. The gate
command is also the exit (step 4). Every `FLAG` (format, `lib/acceptance-lint.sh`,
unparseable verify command, missing criterion, DAG cycle, workspace repo, uncovered
decision or `### Good Enough` criterion, `grounding-lint.sh"` claim, `doc-deps`
uncovered dependency, task ids that differ from PLAN.md) is a fix-list item. Keep the
lines verbatim; they join the critique findings below.

## 3. One review round

Send the planner one combined list of mechanical FLAGs and critique findings.
Allow one revision, then check both types of findings in the delta review.

`.mode.critique` from the entry call (`lib/phase-mode.sh plan` folded in; the fast-path
decision reads the plan you just wrote, so re-run
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/phase-mode.sh" plan --feature-dir "$feature_dir"`
once PLAN.md exists). `skip`: log `plan critique skipped (<reason>)`; the fix-list is
the FLAG lines alone. `run`: the challenger-only protocol (`loop-spec:challenger`,
topology `graph/critique.graph.json`) in `skills/shared/critique-gate-protocol.md`
with `phase=plan`, `gate=plan-critique`, `artifact=PLAN.md`, author `planner-1`,
dispatched in the same response as the gate command (the findings pass reads PLAN.md,
not the gate's answer). Never spawn `advocate-1`. The protocol's fix-list is the
union: the FLAG lines verbatim, then the adjudicated findings.
Never send the planner FLAGs and critique findings as separate revision rounds. Phase deltas:
user-intent findings resolve as a question in interactive styles and, when autonomous,
as the more reversible reading recorded via
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" plan "<q>" "<a>" "more reversible"`
and in `## User decisions (already made)` suffixed `(assumed)`; `UNGROUNDED:` findings
get their probe run by you (`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/evidence.sh" add ...`)
and fed to the planner with the `EVID-NNN`. When the revision lands, re-run step 2's
landing commands before the delta re-verify, write the surviving FLAG lines to a file, and
pass it as `critique delta --flags`. Emit one `dispatch` event per agent launched;
the critique steps emit the `gate_round` events.

With `.mode.critique == skip` the same gate still bounds the FLAG loop: `critique open
--gate plan-critique --artifact <PLAN.md>` before the fix-list goes out, `critique fail`
with the FLAG lines as the fix-list (it runs `gate.sh next`); `rerun` sends the list,
`close` stops. After the revision, `critique revised`, step 2's landing commands, then
`critique delta --flags <file>` with a one-line `DELTA-VERIFIED:` reply you write
yourself: no FLAG left means the gate is closed. On `close` (either mode) with FLAG
lines still open: skip the pruning pass and return to the cycle; its exit answers
`REDO` with the same lines and the driver bounds those retries (step 4).
Critique residue goes to `gate-logs/plan-critique-residue.md` only, and the phase
proceeds to the pruning pass. The critique never re-opens on a `REDO` (step 4).

**Pruning pass (advisory, skip under 60 lines):** ONE fresh reviewer
(a nameless Agent with no `subagent_type`, never a cycle role; `run_in_background:
false`; its tool result is the listing) with
`skills/shared/review-prompts/prose-pruning.md`, PLAN.md, and the template only. A cut
that breaks a gate is reverted. Declined proposals and `out-of-scope:` lines go to
`.loop-spec/BACKLOG.md`.

## 4. Exit

In explicit teams mode `TeamDelete` first. Return to the cycle. Its
`next --returned-from plan` runs the gate command from step 2 once more on the final
revision (`lib/phase-exit.sh plan`): ok records `artifacts.plan|patterns|tasks`,
commits PLAN.md and PATTERNS.md, tags `post-plan`, and closes the phase; a `FLAG`
answers `REDO` and you are invoked again: one planner dispatch with the FLAG lines,
step 2's landing commands, return. No critique, no pruning; the driver bounds the REDOs
(`LOOP_SPEC_REDO_MAX`). In
`step`/`interactive` say `PLAN complete. PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.`

## Resume

`artifacts.plan` null: start at step 1 or 2 by what exists. An open `plan-critique`
gate: re-run step 2's landing commands and resume the review round per the protocol with
the existing gate-logs. Otherwise run the gate command and continue from its answer. Teammates never survive a session; spawn fresh.
