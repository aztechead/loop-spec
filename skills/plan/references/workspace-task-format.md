# PLAN workspace-mode task-format rules (reference)

Extracted verbatim from `skills/plan/SKILL.md`; the SKILL stub points here. Apply as written.

## Workspace mode -- task-format rules

When `feature.workspace` is non-null (workspace mode), the following additional rules apply to every task the planner produces. These rules are additive; all existing task-format rules remain in force.

### repo field (required in workspace mode)

Every task MUST carry a `repo` field whose value matches exactly one `workspace.repos[].name` from `feature.json`. Omitting `repo` in workspace mode is an error caught by the feasibility gate.

In the PLAN.md task-block format, `repo` appears as a dedicated line alongside `**Files:**` and `**blockedBy:**`:

```
**repo:** frontend
```

In the planner's `tasks[]` JSON shape (returned in the completion message and passed to `TaskCreate` via task `metadata`), `repo` is a top-level string key:

```json
{"id": "task-001", "subject": "...", "repo": "frontend", "files": ["frontend/src/app.ts"], ...}
```

### One task, one repo

A single task MUST target exactly one repo. Work that spans multiple repos is expressed as multiple tasks connected by explicit `blockedBy` edges. The planner must never list files from more than one repo in a single task's `files[]`.

### workspace-relative file paths

In workspace mode `files[]` entries are workspace-relative and MUST begin with the repo name as the first path component (e.g., `frontend/src/app.ts`, not `src/app.ts`). Every file in a task must resolve -- via `lib/workspace.sh resolve-repo <workspace-root> <path>` -- to the same repo named in the task's `repo` field.

### Cross-repo blockedBy edges

When a change in one repo must precede a change in another repo, express this as two tasks: the upstream task (repo A) and the downstream task (repo B) with `blockedBy: [upstream-task-id]`. This is the only mechanism for cross-repo ordering.

### Ignored by lib helpers

`lib/plan-to-loop.sh`, `lib/dag-width.sh`, and `lib/plan-adherence.sh` ignore unknown task keys, so adding `repo` to task metadata requires no changes to those scripts.
