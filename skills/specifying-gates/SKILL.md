---
name: specifying-gates
description: Use when a user-gate task has requiresUserSpecification=true OR the checking-gates self-check concludes verification mechanics are ambiguous. Locks down verification mechanics through a short AskUserQuestion sequence and writes the answers back into the task's metadata via TaskUpdate. Does NOT run the verification itself.
---

# Specifying User-Thrown Gates

## When this skill runs

Exactly one of:

1. A user-gate task has `"requiresUserSpecification": true` in its `json:metadata` fence, OR
2. The agent ran the "do I know HOW?" self-check (see `skills/checking-gates/SKILL.md`) and concluded the verification mechanics are ambiguous (Path A routing), OR
3. The user manually invoked `Skill(loop-spec:specifying-gates)` for a specific task ID.

In all other cases -- where `verifyCommand` is concrete and every `acceptanceCriteria` entry has an observable proof -- the agent executes the gate directly and does NOT invoke this skill.

**Announce at start:** "I'm using the specifying-gates skill to lock down verification mechanics for Task N."

## CRITICAL -- what this skill does NOT do

- Does not run the verification command. Specification only.
- Does not close the task. It only enriches metadata; the agent returns to `skills/execute/SKILL.md` afterward.
- Does not re-run brainstorming. The design is already decided; only the HOW of one gate is missing.

## Input

The target task ID. Resolved from the command argument or from the currently in-progress user-gate task.

Load the task with `TaskGet` and parse the `json:metadata` fence from its description.

## The four questions

Use `AskUserQuestion` -- one question at a time. Never batch multiple questions into a single `AskUserQuestion` call.

### Q1 -- Observable outcome

```yaml
AskUserQuestion:
  question: "Gate: <task subject>. Use Other to type 1-5 concrete observable criteria, or choose an existing source. Each criterion must name the observable and its exact passing value, regex, or threshold."
  header: "Gate outcome"
  options:
    - label: "Copy from task's acceptanceCriteria"
      description: "Use the existing list (only if it's already concrete)"
    - label: "Stop - revise task"
      description: "Keep requiresUserSpecification and return control"
```

Store an Other free-text answer as a list of strings in `acceptanceCriteria`. Copy the task's existing list only when every entry names both an observable and its exact passing value, regex, or threshold. If either part is missing, repeat Q1 exactly so the follow-up remains inside the published call contract; do not paraphrase it. If the user stops, leave `requiresUserSpecification` in place and return control.

### Q2 -- Proof mechanism

```yaml
AskUserQuestion:
  question: "Use Other to paste the exact shell command that captures proof, or choose an existing mechanism. API and inspection checks must be expressed as executable commands."
  header: "Mechanism"
  options:
    - label: "Use task verifyCommand"
      description: "Keep the existing concrete command"
    - label: "Subagent with briefing"
      description: "Specify a subagent proof contract"
    - label: "Stop - revise task"
      description: "Keep requiresUserSpecification and return control"
```

Store an Other free-text answer as the exact shell-executable `verifyCommand`. Use the task's existing `verifyCommand` only when it is already concrete and shell-executable. If the user selects "Subagent with briefing", store `verifyCommand: "(subagent)"` and ask Q5 before proceeding to Q3. If the user stops, leave `requiresUserSpecification` in place and return control.

### Q3 -- Scope

```yaml
AskUserQuestion:
  question: "Run this once, or over multiple targets?"
  header: "Scope"
  options:
    - label: "Once"
      description: "Single execution, single target"
    - label: "Per instance / target"
      description: "Run identically across a list (e.g. all environments)"
    - label: "First on one, then on all"
      description: "Prove it on one target, then roll out to the rest -- the classic two-gate pattern"
    - label: "Custom"
      description: "Describe the rule in free text"
```

Store as `gateScope`: `"once"` | `"per-target"` | `"one-then-all"` | custom string.

### Q4 -- Failure policy

```yaml
AskUserQuestion:
  question: "If the gate fails, what happens?"
  header: "On failure"
  options:
    - label: "Stop the plan (Recommended)"
      description: "No further tasks until this gate passes"
    - label: "Reopen this task, continue others"
      description: "Mark in_progress, keep the plan moving elsewhere"
    - label: "Log and continue"
      description: "Record failure, proceed -- use only for informational gates"
```

Store as `failurePolicy`: `"stop-plan"` | `"reopen-continue"` | `"log-continue"`.

### Q5 (conditional) -- Subagent dispatch contract

Only when Q2 = "Subagent with briefing". Ask this before Q3.

```yaml
AskUserQuestion:
  question: "Use Other to paste the exact prompt / briefing the subagent should receive, or choose a source. This becomes the dispatch contract -- the agent cannot substitute a shorter version at runtime."
  header: "Briefing"
  options:
    - label: "Use instances/<tag>/seed-briefing.md"
      description: "Per-target briefing file already written by a plan task"
    - label: "Generate from task description"
      description: "Build the briefing from the task's Goal + Files + Acceptance Criteria"
    - label: "Stop - revise task"
      description: "Keep requiresUserSpecification and return control"
```

Store an Other free-text answer as the exact `dispatchBrief`. For a seed briefing, store its file path. For generation, build and store the full briefing from the task's Goal, Files, and Acceptance Criteria. If the user stops, leave `requiresUserSpecification` in place and return control.

## Writing back

After all questions are answered:

1. **Update the task description.** Rewrite the `json:metadata` fence with the new fields. Remove `requiresUserSpecification`. Keep all other existing fields. Call `TaskUpdate` with the full new description.

```json:metadata
{
  "files": [...],
  "verifyCommand": "<from Q2 -- the shell command, or '(subagent)' sentinel>",
  "acceptanceCriteria": ["<from Q1>", "..."],
  "userGate": true,
  "tags": ["user-gate"],
  "gateScope": "<from Q3>",
  "failurePolicy": "<from Q4>",
  "dispatchBrief": "<from Q5 if applicable>"
}
```

2. **Append a "Specification" section** to the human-readable part of the task description, above the `json:metadata` fence:

```markdown
### Specification (via Skill(loop-spec:specifying-gates) on <ISO-date>)

- **Outcome:** <Q1>
- **Mechanism:** <Q2>
- **Scope:** <Q3>
- **Failure policy:** <Q4>
- **Subagent brief:** <Q5 if applicable>
```

3. **Announce:** "Specification locked. Returning control to the execute skill to run the gate."

## What NOT to do in this skill

- Do NOT invoke `ExitPlanMode` or `EnterPlanMode`.
- Do NOT start the verification. The verification runs in `skills/execute/SKILL.md` after this skill exits.
- Do NOT ask more than 4-5 questions. If the user's answers feel insufficient, prefer one targeted follow-up over piling additional questions into the initial flow.
- Do NOT write anything to disk except via `TaskUpdate` on the task description. No side files.
- Do NOT batch multiple questions into a single `AskUserQuestion` call.

## Integration

- **Invoked from:** `skills/checking-gates/SKILL.md` (Path A routing, automatic), or `Skill(loop-spec:specifying-gates)` manual invocation.
- **Returns to:** `skills/execute/SKILL.md`. The agent reads the updated task and executes the now-concrete `verifyCommand` (or dispatches the subagent with `dispatchBrief`).
- **References:** `skills/shared/feature-state-schema.md` for the full metadata schema including all 9 optional gate fields.
