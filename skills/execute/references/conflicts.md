# EXECUTE conflict detection (reference)

Extracted verbatim from `skills/execute/SKILL.md` Step 2; the SKILL stub points here.
Apply as written on every EXECUTE entry (first entry from PLAN and any re-entry
after VERIFY routes back).

Contents: Step 2a sidecar/PLAN.md parse and `task-progress.sh` seed · 2b synthetic
blockedBy · 2c exclusion list · 2d conflict table and rulings · 2e same-shape collapse.

### Step 2 - Pre-task file-conflict detection

Run on **every EXECUTE entry**: both the first entry from PLAN and any re-entry triggered by VERIFY routing back after a code-review HARD-GATE failure (which may add remediation tasks).

**Workspace mode note:** Conflict detection logic is unchanged. In workspace mode, task `files[]` are workspace-relative paths of the form `<repo>/<path>` (e.g., `frontend/src/app.ts`). Because each task targets exactly one repo, file paths from different repos are disjoint by their repo prefix -- cross-repo overlaps are naturally impossible. The synthetic `blockedBy` edge logic of Step 2b still applies within a single repo's tasks.

#### Step 2a - Read planned tasks (sidecar first, PLAN.md fallback)

PLAN Step 6 persists the gate-validated `tasks[]` as machine-readable JSON at
`feature.json.artifacts.tasks` (`.loop-spec/features/{slug}/tasks.json`). Prefer it — it is
the exact structure the PLAN gates validated, so nothing needs to be re-derived from
markdown prose:

```bash
tasks_sidecar="$(jq -r '.artifacts.tasks // ""' .loop-spec/features/{slug}/feature.json)"
if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]] \
   && bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" tasks "$tasks_sidecar"; then
  echo "[EXECUTE] task source: sidecar ($tasks_sidecar)"
else
  echo "[EXECUTE] task source: PLAN.md parse (sidecar missing or failed artifact-lint)"
fi
```

When the sidecar is readable, seed `mergedSet` from already-published ids so a resumed
cycle does not re-dispatch completed work. A missing or empty `status` is pending.

```bash
mergedSet=()
if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] && mergedSet+=("$id")
  done < <(bash "${CLAUDE_SKILL_DIR}/../../lib/task-progress.sh" done "$tasks_sidecar")
fi
```

After any successful publication onto `feat/{slug}`, persist that fact:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/task-progress.sh" mark-done \
  ".loop-spec/features/{slug}/tasks.json" "{taskId}"
```

A mark-done failure (sidecar missing, unknown id) is a warning, not an integration
failure — the commit is already on the branch. If every planned id is already in
`mergedSet` and `pendingRemediationTasks` is empty, skip to Phase exit (VERIFY).

When using the sidecar, cross-check its task ids against the `### task-` headings in
PLAN.md: an id set mismatch means PLAN.md was revised after the sidecar was written —
log one line naming the mismatched ids and fall back to the PLAN.md parse below
(PLAN.md is the reviewed artifact; it wins).

**Fallback — parse PLAN.md directly** (sidecar missing, stale, or flagged; also the path
for features planned before the sidecar existed): parse every task block from
`docs/loop-spec/features/{slug}/PLAN.md`. Each task block must contain:
- `id` (e.g., `task-001`)
- `files[]` — list of files the task modifies
- `blockedBy[]` — explicit dependency edges declared in PLAN.md (may be empty)
- `verifyCommand` — shell command to assert correctness
- `acceptanceCriteria[]` — list of acceptance criteria strings
- `readFirst[]` — concrete files the implementer must read before starting (from the planner's `read_first` list; may be empty)
- `specPath` — per-task spec file path when the planner wrote one for a complex task, else `null`
- `brief` — short description of the task for agent prompts

On re-entry from VERIFY, the lead also reads any remediation tasks injected by the verifier or code-reviewer. These are persisted at `feature.json.pendingRemediationTasks[]` (VERIFY appends to this array via `lib/feature-write.sh append` before its `TeamDelete`, so the tasks survive the verify team's teardown). Read them with:

```bash
remediation_tasks=$(jq -r '.pendingRemediationTasks // []' .loop-spec/features/{slug}/feature.json)
```

**Normalize every remediation task to full shape BEFORE it joins the task set** — producers
(resume redirection, ITERATE execute-gaps, VERIFY test-regression) write full-shape tasks,
but a partial one from an older feature.json or a missed field must not reach Step 4, where
the task guard hook DENYs it (`blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`
required). Synthesize the missing fields: `blockedBy` → `[]`, `files` → `[]`,
`acceptanceCriteria` → `[subject]`, `verifyCommand` → `feature.commands.test` (a remediation
task with NO verify command at all is malformed — drop it with a one-line warning rather than
registering an unverifiable task).

Include these tasks in the full task set before computing conflict edges. After tasks are registered (TaskCreate or workflow dispatch), clear the array:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$feature_dir" pendingRemediationTasks "[]"
```

#### Step 2b - Compute synthetic blockedBy edges

For each pair of tasks `(A, B)` where both are still pending (missing `status`
counts as pending; skip any id already in `mergedSet`) and `id(A) < id(B)`:

1. Compute `overlap = A.files ∩ B.files`.
2. If `overlap` is empty: no synthetic edge.
3. If `overlap` is non-empty: check whether every file in `overlap` is matched by at least one glob in the exclusion list (see Step 2c). If any file is NOT excluded: add a synthetic `blockedBy` edge `B.blockedBy += [A.id]`.

This recompute runs fresh on every EXECUTE entry to prevent stale conflict data from earlier passes from affecting remediation tasks.

#### Step 2c - Exclusion list

The default exclusion list is **empty** — all file overlaps are flagged by default.

Projects configure exclusions via either source (both are unioned):

- `feature.json.fileConflictExcludeGlobs[]` — per-feature overrides, set directly in `feature.json`.
- `.loop-spec/file-conflict-exclude.txt` — one glob per line, repo-wide, in the gitignored state directory.

Load both sources at the start of Step 2b:

```bash
feature_globs=$(jq -r '.fileConflictExcludeGlobs // [] | .[]' .loop-spec/features/{slug}/feature.json)
repo_globs=""
if [[ -f .loop-spec/file-conflict-exclude.txt ]]; then
  repo_globs=$(grep -v '^#' .loop-spec/file-conflict-exclude.txt | grep -v '^$')
fi
all_exclude_globs=$(printf '%s\n%s' "$feature_globs" "$repo_globs" | grep -v '^$')
```

A file is excluded if it matches any glob in `all_exclude_globs` (use `fnmatch`-compatible matching).

#### Step 2d - Conflict table and rulings

Emit a machine-readable conflict table before Task 1. The table is the probe;
a ruling after it is still a model judgment.

```bash
mkdir -p ".loop-spec/features/{slug}/dispatch"
if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]]; then
  bash "${CLAUDE_SKILL_DIR}/../../lib/plan-conflicts.sh" table "$tasks_sidecar" \
    > ".loop-spec/features/{slug}/dispatch/conflict-table.json"
fi
```

Read `rows`. Zero is a clean scan (the table still exists). For each pair or
interface row, classify the conflict text:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/execute-stop.sh" classify "<overlap or interface summary>"
```

`stop=true` pauses EXECUTE (cycle-resume-escalation contract). `stop=false
reason=ruling` records the ruling and continues. Substitute the conflict as the
question, the call you made as the answer, and why you made it as the rationale:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$fdir" execute \
  "task-003 and task-007 both write lib/foo.sh" \
  "task-007 rebases onto task-003; no plan change" \
  "the overlap is one function and the order is already in blockedBy" \
  ruling
```

Autonomous mode never waits on a reversible question. Pass `--plan-broken` only
when the operator has declared the plan itself broken.

#### Step 2e - Same-shape collapse

Collapse same-shape members before any rung forms a wave. Fail-closed: no
`batchGroup` hint, a `blockedBy` edge out of the group, mismatched
`verifyCommand`, or overlapping files keeps one-task-one-dispatch.

```bash
if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]]; then
  bash "${CLAUDE_SKILL_DIR}/../../lib/task-batch.sh" collapse "$tasks_sidecar" \
    > ".loop-spec/features/{slug}/dispatch/tasks-collapsed.json"
fi
```

Use the collapsed array as the dispatch task list. A collapsed group keeps the
first member's id, unions `files[]`, and carries `memberIds[]`. Reviewers assert
every listed file appears in the diff.

