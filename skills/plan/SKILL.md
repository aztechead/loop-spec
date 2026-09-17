---
name: plan
description: "Create PATTERNS.md, PLAN.md, and tasks.json from the frozen SPEC. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# PLAN

Use the OKF 0.2 header and type contract in `skills/shared/okf-artifacts.md` for PLAN.md and PATTERNS.md.

Use `feature_dir=.loop-spec/features/{slug}`. Relay any entry FLAG and return. Follow
`skills/shared/dispatch.md` for every agent dispatch.

Create compact `PATTERNS.md` and authored `PLAN.md` under
`docs/loop-spec/features/{slug}/`; derive `tasks.json` from PLAN's task blocks. Read
only the entry packet first:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin plan --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[]
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
otherwise pass its absolute `patterns_path` and
`skills/shared/artifact-templates/PATTERNS.md.template` and
`skills/shared/artifact-templates/PLAN.md.template` to the planner. Do not prefetch,
dispatch a second scan, or poll for a teammate.

Spawn `planner-1` with `feature.models.planner`, absolute `spec_path`, `patterns_path`,
`evidence_path`, and absolute `template_path` for `PLAN.md.template`. Require authored
Markdown task blocks containing `**Files:**`, `**Verify:**`, `**Acceptance criteria:**`,
`**BlockedBy:**`, and `**read_first:**`; `lib/plan-tasks.sh extract` creates the JSON
sidecar. Include approach-selection, grounding, scale, TDD, relevant engineering
stances, and global constraints. Do not compute waves or duplicate task prose.

Then run:

```bash
tmp_tasks="$feature_dir/tasks.json.tmp"; if bash "${LOOP_SPEC_SKILL_DIR}/../../lib/plan-tasks.sh" extract docs/loop-spec/features/{slug}/PLAN.md > "$tmp_tasks"; then mv "$tmp_tasks" "$feature_dir/tasks.json"; else exit 1; fi
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/plan-conflicts.sh" edges "$feature_dir/tasks.json"
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

Read `skills/shared/engineering-directives.md`, `skills/shared/engineering-stances.md`,
and `skills/shared/approach-selection.md`. On a 4GB/1vCPU host use one planner/reviewer
at a time and compact artifacts. `lib/task-batch.sh` may merge safe linear tasks.
Report `PLAN complete. PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.` in step mode.
