---
name: plan
description: PLAN phase - pattern-mapper produces PATTERNS.md, the planner produces PLAN.md, deterministic gates run, then a challenger-only critique; updates feature.json. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# PLAN

You produce `PATTERNS.md` (analogs to mirror) and `PLAN.md` (a task DAG with verify
commands) under `docs/loop-spec/features/{slug}/`, plus the machine-readable
`feature_dir/tasks.json` EXECUTE consumes. Dispatch follows `skills/shared/dispatch.md`.
Your inputs are the entry packet and nothing else:

```bash
pb="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin plan --feature-dir "$feature_dir")"
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
Agent with absolute paths for SPEC.md and the target,
then stop; the planner's brief covers the last-resort fallback. Greenfield: PATTERNS.md
records the chosen stack's conventions instead of mined analogs.

## 2. Author PLAN.md

Read `skills/shared/approach-selection.md` and include it in the authoring brief on
every path below. Resolve evidence that challenges a settled design through the
existing decision path before accepting conflicting tasks.

Spawn `planner-1` (`loop-spec:planner`, model `feature.models.planner`) and, in team
modes, warm up `challenger-1` with SPEC.md meanwhile. The
planner brief carries: `slug`, `spec_path`, `patterns_path`,
`evidence_path`; the grounding rule (every external fact cites `EVID-NNN` or is an
`ASSUMPTION: ... | verify: ...`); the dependency-idiom rule (every dependency
`lib/doc-deps.sh scan` names on the task files needs a doc-backed `EVID-NNN` or an
`ASSUMPTION` in `## Grounding` — fetch current docs with any web tool available, or
return the need); "cite PATTERNS.md analogs in each task's steps";
"every task block carries the fields `lib/plan-tasks.sh` reads, including
`**BlockedBy:**`; do not compute waves"; the
pre-submit self-check against `agents/planner.md` and a verbatim
`## Global constraints` section (or `- none`). Workspace mode adds: every task carries
`repo` (one repo per task), `files[]` are `<repo>/<path>`, cross-repo order is a
`blockedBy` edge. Greenfield adds: task-001 is the scaffold (structure, manifest, the lockfile the
package manager writes next to it, test harness, a passing walking-skeleton test;
`verifyCommand` is the stack's canonical test command and never an install step, which
belongs to `commands.prepare`), every other task is blocked by it, and PLAN.md's `## System design` is filled
in full (the build-from-scratch and system-design stances,
`skills/shared/engineering-stances.md`; a refactor spec binds the refactor stance the
same way).

With `workflowsAvailable` and `LOOP_SPEC_PLAN_MULTI_ANGLE=1`, the
`lib/workflows/plan-multi-angle.js` Workflow authors instead; log its angles to
`feature_dir/gate-logs/plan-multi-angle.json`.

When the planner reports, derive `tasks.json` from PLAN.md and run the mechanical
gates. PLAN.md is the source; the completion message is a report, and a message that
arrives empty or stale never becomes the dispatch list:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/plan-tasks.sh" extract docs/loop-spec/features/{slug}/PLAN.md > "$feature_dir/tasks.json"
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-exit.sh" plan --feature-dir "$feature_dir"
```

A non-zero extract exit is a message on stderr (no task blocks, or an unreadable
plan): it is a fix-list item for the planner, never an empty `tasks.json`. The gate
command is also the exit (step 4). Every `FLAG` (format, `lib/acceptance-lint.sh`,
unparseable verify command, missing criterion, DAG cycle, workspace repo, uncovered
decision or `### Good Enough` criterion, `grounding-lint.sh"` claim, `doc-deps`
uncovered dependency, task ids that differ from PLAN.md) is a fix-list item. Keep the
lines verbatim; they join the critique findings below.

## 3. One review round

The planner sees ONE fix-list and revises ONCE. A field run spent an hour and fifty
dollars bouncing PLAN.md through a feasibility loop, then a critique loop, then the
feasibility loop again; mechanical FLAGs and critique findings now go to the planner
together, and the delta re-verify checks both.

`.mode.critique` from the entry call (`lib/phase-mode.sh plan` folded in; the fast-path
decision reads the plan you just wrote, so re-run
`bash "${CLAUDE_SKILL_DIR}/../../lib/phase-mode.sh" plan --feature-dir "$feature_dir"`
once PLAN.md exists). `skip`: log `plan critique skipped (<reason>)`; the fix-list is
the FLAG lines alone. `run`: the challenger-only protocol (`loop-spec:challenger`,
topology `graph/critique.graph.json`) in `skills/shared/critique-gate-protocol.md`
with `phase=plan`, `gate=plan-critique`, `artifact=PLAN.md`, author `planner-1`,
dispatched in the same response as the gate command (the findings pass reads PLAN.md,
not the gate's answer). Never spawn `advocate-1`. The protocol's fix-list is the
union: the FLAG lines verbatim, then the adjudicated findings. Never send the planner
the FLAG lines alone and the findings later: that FLAG-only round is the second loop
this section removed, and a run that took it paid a third planner dispatch. Phase deltas:
user-intent findings resolve as a question in interactive styles and, when autonomous,
as the more reversible reading recorded via
`bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" plan "<q>" "<a>" "more reversible"`
and in `## User decisions (already made)` suffixed `(assumed)`; `UNGROUNDED:` findings
get their probe run by you (`bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add ...`)
and fed to the planner with the `EVID-NNN`. When the revision lands, re-run step 2's
two commands before the delta re-verify, write the surviving FLAG lines to a file, and
pass it as `critique delta --flags`. Emit one `dispatch` event per agent launched;
the critique steps emit the `gate_round` events.

With `.mode.critique == skip` the same gate still bounds the FLAG loop: `critique open
--gate plan-critique --artifact <PLAN.md>` before the fix-list goes out, `critique fail`
with the FLAG lines as the fix-list (it runs `gate.sh next`); `rerun` sends the list,
`close` stops. After the revision, `critique revised`, step 2's two commands, then
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
step 2's two commands, return. No critique, no pruning; the driver bounds the REDOs
(`LOOP_SPEC_REDO_MAX`). In
`step`/`interactive` say `PLAN complete. PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.`

## Resume

`artifacts.plan` null: start at step 1 or 2 by what exists. An open `plan-critique`
gate: re-run step 2's two commands and resume the review round per the protocol with
the existing gate-logs. Otherwise run the gate command and continue from its answer. Teammates never survive a session; spawn fresh.
