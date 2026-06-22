---
name: onboard
description: Guided one-time setup for loop-spec's optional features. Asks a few multiple-choice questions and writes the chosen config files in place (.loop-spec/grill.conf, discipline.conf, workflow.json, RULES.md seed). Everything it configures can also be set manually; onboarding is a convenience, never a requirement.
allowed-tools: Bash Read Write AskUserQuestion
---

# Onboard Skill

Invoked as `/loop-spec:onboard`.

A short walkthrough of loop-spec's optional, opt-in/opt-out features. It asks a handful of
multiple-choice questions and writes the chosen config files to `.loop-spec/` in the current
project, confirming each write with its absolute path. Nothing here is required — the README
documents every setting for manual configuration; this just does it for you.

All writes target the **project** `.loop-spec/` directory. Onboarding never modifies global
user settings.

## Procedure

### Step 0 - Locate project

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
mkdir -p "${PROJECT_DIR}/.loop-spec"
```

If `.loop-spec/` already holds conf files, read them first and present current values as the
defaulted option so re-running onboarding is non-destructive.

### Step 1 - Grill mode

```
AskUserQuestion({
  header: "Grill mode",
  question: "Grill mode front-loads 2-4 sharp clarifying questions right after your initial prompt to lower ambiguity before work starts. It is ON by default. Keep it on?",
  options: ["On (recommended)", "Off"]
})
```

- "On": write `ENABLED=1` to `.loop-spec/grill.conf` (or leave absent — absence means on).
- "Off": write `ENABLED=0` to `.loop-spec/grill.conf`.

### Step 2 - Self-learning rules

```
AskUserQuestion({
  header: "Self-learning",
  question: "Self-learning rules carry lessons from past runs forward: each repeated mistake becomes a permanent rule in .loop-spec/RULES.md, injected into every session. Enable it?",
  options: ["On (recommended)", "Off"]
})
```

- "On": seed `.loop-spec/RULES.md` if absent via `bash "${CLAUDE_SKILL_DIR}/../../lib/rules.sh" path` (the file is created lazily on first `add`; optionally seed a starter rule). Leave `LOOP_SPEC_RULES` unset (on by default).
- "Off": tell the user to set `LOOP_SPEC_RULES=0` in their environment (session-level kill switch; onboarding does not edit shell profiles).

### Step 3 - Discipline mode

```
AskUserQuestion({
  header: "Discipline",
  question: "Discipline mode enforces five behavioral gates (brainstorm-before-coding, verification-before-claims, investigation-before-fixes, decision-gate, intent-gate). It is OFF by default. Enable it?",
  options: ["Off (default)", "On"]
})
```

- "On": write `ENABLED=1` to `.loop-spec/discipline.conf`.
- "Off": write `ENABLED=0` (or leave absent).

### Step 4 - Commit strategy

```
AskUserQuestion({
  header: "Commit cadence",
  question: "How should EXECUTE commit? Per-task (one commit per completed task, default) or at-end (tasks stage changes; one final commit closes the plan)?",
  options: ["Per-task (default)", "At-end"]
})
```

- "Per-task": ensure `.loop-spec/workflow.json` either omits `commitStrategy` or sets `"per-task"`.
- "At-end": write/merge `{"commitStrategy":"at-end"}` into `.loop-spec/workflow.json` (preserve any other keys with a python3/jq merge-write).

### Step 5 - EXECUTE acceleration (advisory only)

Do NOT write env vars to shell profiles. Print guidance:

```
For wider EXECUTE concurrency:
  export LOOP_SPEC_EXECUTE_LOOPS=1     # bounded headless loop fleet (needs the `claude` CLI)
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1   # persistent phase teams
  export LOOP_SPEC_EXECUTE_WORKFLOW=1  # opt into the Workflow DAG rung on very wide plans
Model selection is fixed (opus + sonnet); there is no preset to choose.
```

### Step 6 - Summary

Print every file written with its absolute path and the chosen value, e.g.:

```
Wrote:
  /abs/.loop-spec/grill.conf       (ENABLED=1)
  /abs/.loop-spec/discipline.conf  (ENABLED=0)
  /abs/.loop-spec/workflow.json    (commitStrategy=at-end)
Self-learning rules: ON (RULES.md grows as the loop learns)
Re-run /loop-spec:onboard any time; it is non-destructive.
```

## Non-interactive mode

When `LOOP_SPEC_NON_INTERACTIVE=1`, skip all `AskUserQuestion` calls and apply defaults:
grill on, rules on, discipline off, commit per-task. Write only what differs from absence-of-file
defaults (i.e., nothing unless overridden by `LOOP_SPEC_ANSWER_*` vars if present).

## Notes

- Idempotent and non-destructive: re-running reads current values and only rewrites on change.
- Everything here is also documented for manual setup in the README.
