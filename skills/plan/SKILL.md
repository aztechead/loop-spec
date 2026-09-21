---
name: plan
description: "Create PATTERNS.md, PLAN.md, and tasks.json from the frozen SPEC. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# PLAN

Use `feature_dir=.loop-spec/features/{slug}`. Relay any entry FLAG and return. Follow
`skills/shared/dispatch.md` for every agent dispatch.

Create compact `PATTERNS.md` and authored `PLAN.md` under
`docs/loop-spec/features/{slug}/`; derive `tasks.json` from PLAN's task blocks. Read
only the entry packet first:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin plan --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[]
# .planner.model .planner.subagentType .planner.promptFile .planner.brief
# .mode.critique .mode.reentry .mode.budget .mode.remaining .mode.exhausted
```

Reuse SPEC, decisions, evidence, and PATTERNS. Keep searches within route files and
criteria; refresh `design-budget.sh` before optional scans or redispatches. The budget
is a soft deadline, not permission to pass unresolved required findings.

On reentry, read `iterate.feedback`, revise only the named plan gap, and preserve
`## User decisions (already made)`. After PLAN exists, rerun
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/phase-mode.sh" plan --feature-dir "$feature_dir"`;
the entry fast-path is stale until this recomputation. For greenfield, task-001 creates
the scaffold, lockfile, test harness, and walking-skeleton test; every other task
depends on it. Workspace tasks carry one `repo` and workspace-relative paths.

## PATTERNS and PLAN

The planner owns the compact PATTERNS scan. Reuse an existing artifact when present;
otherwise use the absolute paths in the planner assignment. Do not prefetch,
dispatch a second scan, or poll for a teammate.

Immediately dispatch one `planner-1` through the active harness adapter using
`.planner.model`, `.planner.subagentType`, and the exact one-line prompt
`Read the planner assignment at <.planner.promptFile> and complete it.` The planner role contract
in the packet owns the task-block shape, approach selection, grounding,
scale, TDD, engineering stances, and global constraints. The coordinator only runs
`lib/plan-tasks.sh extract` after PLAN is authored; it never writes `tasks.json`.

Then run:

```bash
tmp_tasks="$feature_dir/tasks.json.tmp"; extract_err="$feature_dir/tasks.extract.err"
extract_failed=0
if bash "${LOOP_SPEC_SKILL_DIR}/../../lib/plan-tasks.sh" extract docs/loop-spec/features/{slug}/PLAN.md > "$tmp_tasks" 2>"$extract_err"; then
  mv "$tmp_tasks" "$feature_dir/tasks.json"
  rm -f "$extract_err"
else
  extract_failed=1
  printf 'FLAG [tasks] plan extraction failed; preserve this stderr for the revision:\n%s\n' "$(cat "$extract_err")" >&2
  rm -f "$tmp_tasks"
fi
if (( ! extract_failed )); then
  bash "${LOOP_SPEC_SKILL_DIR}/../../lib/plan-conflicts.sh" edges "$feature_dir/tasks.json"
fi
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/plan-render.sh" decisions --spec docs/loop-spec/features/{slug}/SPEC.md --plan docs/loop-spec/features/{slug}/PLAN.md
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/phase-exit.sh" plan --feature-dir "$feature_dir" --check
```

An extract failure is a fix-list item, never an empty tasks file. Keep every FLAG
verbatim. Criteria and decisions must be covered in PLAN; external claims need
`EVID-NNN` or `ASSUMPTION: ... | verify: ...`; dependency docs need evidence.
The phase also runs `lib/acceptance-lint.sh` before leaving PLAN. The exit runs
`grounding-lint.sh`; planning probes use
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/grounding-lint.sh"` and
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/evidence.sh" add`.

## One bounded review round

Use `skills/shared/critique-gate-protocol.md` and `graph/critique.graph.json` with
`phase=plan`,
`gate=plan-critique`, `artifact=PLAN.md`, and author `planner-1`. Run the gate after
mechanical checks. Send the planner one combined list of flags and critique findings;
the critique steps emit the `gate_round` events through the shared protocol.
allow one revision, then re-run extraction and gates. Never spawn `advocate-1`.
The critique never re-opens on a `REDO`; a final phase exit handles remaining flags.
The gate advances through `gate.sh next`. Do not dispatch a prose-pruning reviewer;
keep gate text and substantive findings. Never AskUserQuestion as a wait.

If `skip` has no FLAGs, return. Otherwise it logs `plan critique skipped (<reason>)`,
opens the shared gate, submits FLAGs through `critique fail`, and allows only the
configured bounded `rerun`/`revised`/`delta` sequence; it never loops unbounded.
Decisions use
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add`; an `UNGROUNDED:` finding
gets a probe and EVID citation. Preserve substantive findings;
declined proposals go to `.loop-spec/BACKLOG.md`. Return to the cycle; never run the
exit yourself. In explicit teams mode, TeamDelete first. Resume from gate logs and do
not repeat completed scans.

On a 4GB/1vCPU host use one planner/reviewer at a time and compact artifacts.
`lib/task-batch.sh` may merge safe linear tasks.
Report `PLAN complete. PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.` in step mode.
