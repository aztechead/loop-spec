# Fan-out dispatch contract

Used by `map-codebase`, `verify`, `plan`, and `execute` skills to branch between workflow
and TeamCreate paths at fan-out points.

## Rule

```text
1. Read .loop-spec/runtime.json. Treat missing file as workflowsAvailable=false.
2. If workflowsAvailable=true:
   a. Resolve workflow params from skills/shared/tier-matrix.md "Workflow params" table by feature.tier.
   b. Dispatch Workflow({scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/<name>.js",
                         args: {tier, workflowParams, <skill-specific args>}}).
   c. The workflow returns a structured JSON result.
3. If workflowsAvailable=false:
   a. Run the current TeamCreate + Agent dispatch verbatim.
   b. Convert the result to the same JSON shape the workflow would have returned.
4. Skill code consuming the result is shape-identical in both branches.
```

## Persisted workflow state

When dispatching a workflow that may pause/resume, persist
`feature.json.activeWorkflow = {scriptPath, args, sessionId, runId, startedAt}`.
Cross-session resume re-dispatches with the same `scriptPath + args`; the old
`runId` is informational only and never used as a cache key after a session exit.

Clear `activeWorkflow` once the skill consumes the workflow result.
