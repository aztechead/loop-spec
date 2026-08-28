# EXECUTE rung 4 (workflow) and rung 5 (foreign claimants) (reference)

Extracted verbatim from `skills/execute/SKILL.md`; the SKILL stub points here. Apply
as written when Step 3b selects `workflow` or `foreign`.

Contents: Rung 4 workflow path (`activeWorkflow`, Workflow dispatch, consume
`{merged, blocked, escalation}`) · Rung 5 foreign claimants (handoff-port export/import).

#### Rung 4 - workflow path

Persist `feature.json.activeWorkflow` before calling Workflow (signature: `set <feature_dir> <dot_path> <value_json>`):

```bash
fdir=".loop-spec/features/{slug}"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" activeWorkflow "$(jq -n \
  --arg sp "${CLAUDE_SKILL_DIR}/../../lib/workflows/execute-dag.js" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{scriptPath: $sp, startedAt: $at}')"
```

Resume note: pass `doneTaskIds` from `task-progress.sh done` (Step 2a). The DAG
seeds `mergedSet` from those ids and dispatches only remaining work. After each
successful publication the merge agent persists `status=done` on the sidecar. Do
not rebuild remaining work from git history.

Dispatch:

```
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/execute-dag.js",
  args: {
    slug: feature.slug,
    featureWorktreeRoot: featureWorktreeRoot,
    featureBranch: "feat/{slug}",
    models: {
      implementer: feature.models.implementer,
      specComplianceReviewer: feature.models.specComplianceReviewer
    },
    maxParallelImplementers: maxParallelImplementers,
    maxRetriesPerTask: maxRetriesPerTask,
    reviewersEnabled: true,
    commands: feature.commands,
    skillDir: skillDir,
    // bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" resolve "$featureWorktreeRoot" task "{slug}" | jq -r '.path'
    taskWorktreeBase: taskWorktreeBase,
    tasks: <tasks[] array from Step 2a/2b>,
    doneTaskIds: <mergedSet from Step 2a — ids already status=done>
  }
})
```

Clear `activeWorkflow` after the call:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" activeWorkflow null
```

Consume the FROZEN return `{merged, blocked, escalation}`:

- **escalation non-null or blocked non-empty:** Pause EXECUTE. Print escalation reason and any blocked task ids with their reasons. Return control to the user (cycle-resume-escalation contract). Do not proceed to VERIFY. Reasons come from a fixed vocabulary (display only; do not pattern-match): `blocked[].reason` is one of `spec-compliance-block`, `retry-exhausted`, `commit-missing`, `zero-commit`; `escalation.reason` is `deadlock` or `rebase-conflict`.
- **clean (escalation null, blocked empty):** All tasks merged onto `feat/{slug}`. Skip Steps 4-10 (harness TaskList/TeamCreate are NOT used in this path). Proceed directly to the **Phase exit** section at the end of this skill.

Update `feature.json` after clean completion:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" mergeQueue "[]"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" currentTeammates "[]"
```

Then proceed to the **Phase exit** section.

---

#### Rung 5 - foreign claimants (opt-in)

Reached when Step 3b selects `rung == "foreign"` (`LOOP_SPEC_FOREIGN_CLAIMANTS=1` and a
handoff port adapter is reachable — `lib/execute-rung.sh`, `skills/shared/handoff-port.md`).
Each task in `tasks[]` from Step 3 becomes one claimable bundle instead of a `Task`/`Agent`
dispatch. The graph node dispatched is still `execute.worker` (`graph/cycle.graph.json`) —
width selects the rung, it never substitutes a different node or a different contract.

Offer every remaining task as a bundle and put it on the port (skip ids already in `mergedSet`):

```bash
fdir=".loop-spec/features/{slug}"
for task in <tasks[] array from Step 2a/2b>; do
  bash "${CLAUDE_SKILL_DIR}/../../lib/graph/handoff.sh" export \
    --feature-dir "$fdir" --node execute.worker --task "$task.id" \
    --verify "$task.verifyCommand" --brief "$task.brief" --files "$task.files" \
    --out "$WORK/bundle-$task.id.json"
  id="$(bash "${CLAUDE_SKILL_DIR}/../../lib/graph/port.sh" put "$WORK/bundle-$task.id.json" \
    | sed -n 's/^id=//p')"
  # record id alongside task.id, e.g. via feature.json.artifacts or an in-memory map
done
```

Bundle semantics are `skills/shared/handoff-port.md`:

- `--brief`/`--files` carry what to build and where the result belongs — a claimant
  sharing no session state would otherwise have only `inputs`+`verifyCommand`
  (`examples/foreign-claimant/` is a reference consumer that depends on both).
- `--task` makes the bundle id content-addressed from node + task + state hash, so
  tasks of the same EXECUTE never collide and re-export at the same state is
  idempotent.
- **No supervisor loop.** Claim → work → `complete` happens on infrastructure this
  session does not control; that is the point of the port. After `put`-ting the
  outstanding bundles, EXECUTE returns control like any `step`/`interactive` phase
  summary (see **Phase routing** below) — never a busy-wait. Re-invoking EXECUTE to
  collect results is the integrator's responsibility (cron, Routine, or the next
  cycle turn).

**Collecting a result on re-entry.** Each time EXECUTE is (re-)entered with tasks still
assigned to this rung, check every recorded id before re-offering it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/port.sh" get "$id" > "$WORK/instance-$id.json" 2>/dev/null \
  && jq -e 'true' "$WORK/instance-$id.json" >/dev/null 2>&1
```

`get` returns the bundle, not a completion flag — completion surfaces only through the
adapter's instance store (`result.json` alongside the bundle; `handoff-port.md`). For
every id whose result is available, merge it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/handoff.sh" import \
  --feature-dir "$fdir" --bundle "$WORK/bundle-$task.id.json"
```

`import` re-derives the state hash from the live `feature.json` and rejects a bundle
whose captured hash no longer matches (exit 1, left unmerged) — the same stale-return
rule `complete` enforces claimant-side. A rejected import leaves the task `pending`;
re-offer it as a fresh bundle. A merged import still needs `task.verifyCommand` re-run
against the integrated branch before the task counts as done, exactly as the subagent
rung does post-merge — never a degraded variant.

Tasks with no result yet keep EXECUTE returning control on re-entry (unchanged from the
above). Once every task assigned to this rung has merged or exhausted its retry budget,
continue to **Phase exit** like any other rung.

---

