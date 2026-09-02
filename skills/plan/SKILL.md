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
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-entry.sh" plan --feature-dir "$feature_dir"
# fields=<the feature.json keys this phase consumes>  read=<each file to read>  FLAG on a missing ingress
```

`reentry` (ITERATE sent the cycle back for a `plan`-type gap): read `iterate.feedback`,
revise or add only the tasks that close it, keep `## User decisions (already made)`.

## 1. PATTERNS.md

Join a DISCUSS prefetch: check once whether PATTERNS.md exists
(`artifacts.patternsPrefetch == "in-flight"`: present → `"landed"`, missing →
`"timeout"`). Never `sleep` to join a background Agent (never sleep to poll) and
never AskUserQuestion as a wait. If PATTERNS.md exists, keep it. Else
`lib/gsd-ingest.sh patterns {slug} <target>` (`INGESTED` sets
`artifacts.patternsSource = "gsd-ingest"`). Else dispatch a one-shot `loop-spec:pattern-mapper`
Agent with absolute paths for SPEC.md, `docs/loop-spec/codebase/*.md`, and the target,
then stop; the planner's brief covers the last-resort fallback. Greenfield: PATTERNS.md
records the chosen stack's conventions instead of mined analogs.

## 2. Author PLAN.md

Spawn `planner-1` (`loop-spec:planner`, model `feature.models.planner`) and, in team
modes, warm up `challenger-1` with SPEC.md and the codebase maps meanwhile. The
planner brief carries: `slug`, `spec_path`, `patterns_path`, the codebase map paths,
`evidence_path`; the grounding rule (every external fact cites `EVID-NNN` or is an
`ASSUMPTION: ... | verify: ...`); "cite PATTERNS.md analogs in each task's steps";
"return tasks[] as JSON in your completion message; do not compute waves"; the
pre-submit self-check against `agents/planner.md` and a verbatim
`## Global constraints` section (or `- none`). Workspace mode adds: every task carries
`repo` (one repo per task), `files[]` are `<repo>/<path>`, cross-repo order is a
`blockedBy` edge. Greenfield adds: task-001 is the scaffold (structure, manifest, test
harness, a passing walking-skeleton test; `verifyCommand` is the stack's canonical test
command) and every other task is blocked by it.

With `workflowsAvailable` and `LOOP_SPEC_PLAN_MULTI_ANGLE=1`, the
`lib/workflows/plan-multi-angle.js` Workflow authors instead; log its angles to
`feature_dir/gate-logs/plan-multi-angle.json`.

When the planner reports, save its `tasks[]` JSON to `feature_dir/tasks.json` and run
the gates:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-exit.sh" plan --feature-dir "$feature_dir"
```

This is also the exit (step 4); feasibility and coverage run BEFORE the critique. Every
`FLAG` (format, `lib/acceptance-lint.sh`, unparseable verify command, missing
criterion, DAG cycle, workspace repo, uncovered decision or `### Good Enough` criterion,
`grounding-lint.sh"` claim) goes back to `planner-1` as a numbered list via `SendMessage`
(re-parse `tasks[]` from every revision). Retries are unbounded. A coverage-only or
lint-only failure never enters the critique.

## 3. Critique

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-mode.sh" plan --feature-dir "$feature_dir"
# critique=run|skip reentry=true|false reason=structural fast-path | maintenance | compact | security signal | ...
```

`skip`: log `plan critique skipped (<reason>)`. `run`: the challenger-only protocol
(`loop-spec:challenger`, topology `graph/critique.graph.json`) in
`skills/shared/critique-gate-protocol.md` with `phase=plan`, `gate=plan-critique`,
`artifact=PLAN.md`, author `planner-1`. Never spawn `advocate-1`. Phase deltas:
user-intent findings resolve as a question in interactive styles and, when autonomous,
as the more reversible reading recorded via
`bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" plan "<q>" "<a>" "more reversible"`
and in `## User decisions (already made)` suffixed `(assumed)`; `UNGROUNDED:` findings
get their probe run by you (`bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add ...`)
and fed to the planner with the `EVID-NNN`; re-run step 2's gate command after any
revision. Emit one `dispatch` event per agent launched and, per round,
`bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit "$feature_dir" gate_round --phase plan --data '{"gate":"plan-critique","round":N,"mode":"single-critic|delta"}' || true`.

**Pruning pass (advisory, skip under 60 lines):** ONE fresh reviewer with
`skills/shared/review-prompts/prose-pruning.md`, PLAN.md, and the template only. A cut
that breaks a gate is reverted. Declined proposals and `out-of-scope:` lines go to
`.loop-spec/BACKLOG.md`.

## 4. Exit

Run the gate command from step 2 once more on the final revision; it must print
`phase-exit: ok (plan)`. That records `artifacts.plan|patterns|tasks`, commits PLAN.md
and PATTERNS.md, tags `post-plan`, and closes the phase. In explicit teams mode
`TeamDelete` first. Return to the cycle; in `step`/`interactive` say
`PLAN complete. PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.`

## Resume

`artifacts.plan` null: start at step 1 or 2 by what exists. `currentGate.round > 0`:
resume the critique per the protocol. Otherwise run the gate command and continue from
its answer. Teammates never survive a session; spawn fresh.
