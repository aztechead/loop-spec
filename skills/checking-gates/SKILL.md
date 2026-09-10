---
name: checking-gates
description: "Verify a user-gate task when the user or an enabled hook requests it. Report evidence from the specified check. Use /loop-spec:specifying-gates for unclear methods and /loop-spec:verify for the full VERIFY phase."
---

# Checking User-Thrown Gates

User-gate hooks are optional. Enabled hooks route user-gate tasks here.
Without those hooks, `skills/execute/SKILL.md` runs unchanged.

## When to invoke

Any one of:

1. An enabled hook routes a task whose `json:metadata` has `"userGate": true` or whose `tags` contains `"user-gate"`.
2. A hook fired stderr telling you to run `Skill(loop-spec:checking-gates)` for a task id.
3. The user manually invoked `Skill(loop-spec:checking-gates)` for a task id.

If none of these apply, return to the execute skill without running this skill.

**Announce at start:** "I'm using the checking-gates skill to verify Task N's acceptance criteria."

## The three-step process

### Step 1 -- Load and classify

1. `TaskGet <task-id>` -- read the full description.
2. Parse the `json:metadata` fence.
3. Classify:
   - `requiresUserSpecification: true` -- go to Step 2 Path A.
   - Concrete `verifyCommand` + every `acceptanceCriteria` names an observable (sensor, HTTP status, file, log line, entity) -- go to Step 2 Path B.
   - Vague criteria ("it works", "is fine", "as expected", "properly") or missing `verifyCommand` -- go to Step 2 Path A.

### Step 2 -- Route

**Path A -- HOW is ambiguous.** Invoke `Skill(loop-spec:specifying-gates)` for this task ID.
If you cannot invoke it, tell the user to run it. Stop until that skill defines the verification method.
When it returns, restart at Step 1.

**Path B -- HOW is clear.** Continue to Step 3.

### Step 3 -- Execute and post evidence

1. Run the `verifyCommand` (or dispatch the subagent with `dispatchBrief`). Capture exact output.
2. Map each `acceptanceCriteria` entry to an observable in the output.
3. Report one text block in this exact format. The hooks require the `AC:` and `PROVEN BY` markers:

   ```
   Gate: <task subject>
   AC: <criterion 1> PROVEN BY <command or excerpt of output>
   AC: <criterion 2> PROVEN BY <...>
   ...
   ```

4. If every criterion passed -- `TaskUpdate status=completed`.
5. If any criterion failed -- look up `failurePolicy`:
   - `"stop-plan"` -- leave the task `in_progress`, surface the failure to the user, stop.
   - `"reopen-continue"` -- leave the task `in_progress`, move to the next unblocked task.
   - `"log-continue"` -- post the failure inline, mark completed anyway, continue.

## Do-I-know-HOW self-check -- the short version

A criterion has a clear HOW when all three hold:

1. **Observable named** -- sensor entity, HTTP endpoint, file path, log pattern, entity ID. Not "state", not "result".
2. **Capture method named** -- the command, API call, subagent, or direct read that produces the observable.
3. **Pass/fail rule named** -- an exact value, regex, or threshold. Not "reasonable" or "correct".

If any of the three is missing for any criterion, HOW is NOT clear -- Path A.

If uncertain, use Path A. Do not invent a verification method.

## What NOT to do

- Do not modify the execute skill's behavior. Return control to the caller when done.
- Do NOT invoke `EnterPlanMode` or `ExitPlanMode`.
- Run the specified verification. If you think it is wrong, reopen the specification through `Skill(loop-spec:specifying-gates)`.
- Do NOT close the task if any criterion lacks concrete evidence. "Looks fine" is not evidence.

## Integration

- **Invoked from:** the `post-task-complete-revalidate.sh` hook (TaskCompleted event) or `stop-revalidate-user-gates.sh` hook (Stop event); or direct user invocation of `Skill(loop-spec:checking-gates)`.
- **May hand off to:** `Skill(loop-spec:specifying-gates)` (Path A).
- **Returns to:** `skills/execute/SKILL.md` (or wherever it was invoked from) after `TaskUpdate`.
- **References:** `skills/shared/feature-state-schema.md` for metadata schema; `TaskGet` and `TaskUpdate` harness tools for reading and writing task state.
