---
name: loop-spec
description: "The loop-spec method for taking a coding request to a verified pull request: a spec with checkable acceptance criteria, a task graph (DAG) built in parallel git worktrees by implementer agents, a clean-checkout verify, an adversarial review, one PR, and its CI and review comments seen through. Use when an entry skill (cycle, micro, debug, revise) starts or resumes a run, or when an autonomous coding agent is told to follow loop-spec."
---

# loop-spec

You are the lead of a loop-spec run. Your job is to turn a request into a pull
request whose every acceptance criterion was checked in a clean checkout of the
commit it delivers, whose CI passes, and whose reviewers' requests are answered. You
do the judgment. The program keeps the run's state and task graph on disk, manages git
worktrees, runs checks, opens the PR, and reads its CI and review.

This file is the overview: the program, the workflow, and how to work. Each phase's
details are in its own reference, read when the run reaches that phase. This is
guidance, not a script: where the code in front of you calls for something different,
do what the code needs and say why in your report.

## The program

`LS` below is the `program` path that `start` and `status` print in their
`LOOP_SPEC_RUN {...}` line, along with the run's `slug`, `kind`, `phase`, `mode`, `base`
(the commit the change sits on), `runDir`, and `work` (the feature branch's worktree).
Run it; there is no need to read it. Commands find the run from the current directory
or as the only open run; otherwise add `--slug <slug>` after the command.

It needs `git` and `python3` 3.11 or later; delivering needs `gh`, signed in, and an
`origin` remote. `task start`, `verify`, and `feedback` can run for minutes: give their
Bash calls a timeout to match (up to 10 minutes), or run them in the background when
the project's checks take longer.

| Command | Does |
|---|---|
| `LS status` | where the run is, every task's state, the repository's rules files, and the `next` step with the reference for it |
| `LS task start T-1 T-2 ...` | one worktree per task from the feature head, with `prepare` already run in it; prints one `LOOP_SPEC_TASK {...}` brief per task |
| `LS task done T-1` | merge the task's commits into the feature branch; prints the `next` step |
| `LS task set T-1 --status todo\|blocked --note "..."` | change a task's status by hand |
| `LS verify [--base]` | run every criterion check, task verify command, and repository check in a clean checkout of the feature head (or, with `--base`, of the base) |
| `LS sync` | merge whatever moved on origin (the base branch, or the feature branch itself) into `work` |
| `LS iterate [--caveats "..."]` | record that the verified head's whole-change review is done and addressed |
| `LS set --branch NAME --title "..."` | rename the feature branch (until it is pushed) or set the PR title |
| `LS deliver [--draft] [--unverified] [--comment-file F] [--no-feedback]` | push the verified head and open or update its PR (posting `F` as a comment) |
| `LS feedback` | wait for the PR's checks (up to 9 minutes per call), then read its review; ends the run when CI passes and reviewers have asked for nothing new, or shows what to address |
| `LS finish --status completed\|no-change\|escalated\|failed --summary "..."` | end the run: `completed` after feedback skills find nothing, otherwise a run that delivers nothing |

The program derives the phase from the run's files and announces each change with
`LOOP_SPEC_PHASE_START`/`_END` lines, which monitoring tools read. Run `LS status`
after writing `spec.json` and after writing `plan.json`, so each phase is announced
when it ends.

## The workflow

Copy this checklist into your progress updates and check items off as each phase ends:

```
Run progress:
- [ ] 1. Spec: spec.json written (approved, if interactive); branch and title set
- [ ] 2. Plan: plan.json written; LS status accepts the graph
- [ ] 3. Execute: every task done and merged
- [ ] 4. Verify: LS verify passed at the current head
- [ ] 5. Iterate: review findings addressed and verified; LS iterate
- [ ] 6. Deliver: pr.md written; LS deliver; LS feedback until the run ends
```

Every phase ends on a check, and you loop on it until it passes. When you reach a phase,
read its reference in full; the `next` line names it too.

| Phase | The work | The check, and the loop | Read |
|---|---|---|---|
| 1. Spec | `spec.json`: a goal, and criteria a command can show; the repository's rules for branch, title, and PR | interactive: the user approves the criteria; revise until they do | [references/spec.md](references/spec.md) |
| 2. Plan | `plan.json`: the task graph, `prepare`, and the repository's required `checks` | `LS status` validates the graph; fix it until it accepts | [references/plan.md](references/plan.md) |
| 3. Execute | start ready tasks, dispatch implementers in parallel, merge each sound one | you read each report and diff; send it back or fix it until it is sound | [references/execute.md](references/execute.md) |
| 4. Verify | `LS verify` in a clean checkout | a failure: find the cause, fix it, verify again | [references/review.md](references/review.md) |
| 5. Iterate | a reviewer and a simplifier on the whole change | fix blocking findings; any new commit goes back to verify; then `LS iterate` | [references/review.md](references/review.md) |
| 6. Deliver | `pr.md`, `LS deliver`, `LS feedback` | a failed check or a review item: fix, verify, deliver, feedback again, with no round limit | [references/deliver.md](references/deliver.md) |

A `cycle` run follows this as written. Other kinds change it; read yours before the
spec: [micro](references/micro.md), [debug](references/debug.md), or
[revise](references/revise.md).

The PR description (`pr.md`) follows the repository's own PR template when it has one.
Without one, follow [pr_description_template.md](references/visual-pr/pr_description_template.md)
(one sentence on why, one to three reviewer notes, a change outline) and draw the
outline with [show-me.md](references/visual-pr/show-me.md). Read show-me.md whole; its
views are pseudocode, call trees, component trees, file trees, Mermaid diagrams,
`diff` blocks, and whole blocks. Keep to these text views; it also describes an HTML
artifact, which a PR body cannot hold.

## How to work

- **Work in `work`.** Your shell starts in the user's own checkout, and a relative path
  written from there changes their files. Right after `start`, `cd` into `work` (the
  same code, on the feature branch) and read and write the code there.
- **Read before you decide.** Read the code the request touches, its tests, and the
  rules files; they outrank this file on conventions. Never describe code you have not
  opened.
- **Settle the shape first.** For a change that adds types, APIs, or file formats, decide
  the data shapes and signatures before any code. When two designs are both plausible,
  compare them in a line each and record the choice in `decisions`.
- **Fix causes.** Trace a failure to its source before changing anything; a guard that
  hides a symptom is not a fix.
- **Subtract before you add.** Reuse what the code, the standard library, or an existing
  dependency provides. Prefer reshaping or deleting code to adding a layer; no
  abstraction with one caller, no option nothing uses.
- **Prove it works.** Tests passing is necessary, not sufficient: at least one
  criterion runs the real thing (the command, the endpoint, the script) the way a user
  would. A change you make yourself is done only when a real check that exercises it
  has passed; a syntax-only check, or a command that failed to start, does not count.
- **Keep decisions moving.** A reversible decision you can make from the code is yours
  to make: make it, record it, and keep going. Ask only about what is costly to undo.
- **Guard your context.** Hand implementation and broad reading to agents; keep your own
  context for judging their results.
- **Stay in scope, and report plainly.** Build what the spec asks; mention a good idea
  instead of building it. Put a sentence on what you did or found in the same message
  as your next command.

## When to ask

The run's `mode` is in `LOOP_SPEC_RUN`.

- **interactive**: someone is there. Ask, with `AskUserQuestion`, only questions whose
  answer changes what you build, together, while you write the spec, then ask once for
  approval of the criteria. After that, ask only when you are truly blocked or before
  something risky the user did not ask for.
- **autonomous**: no one will answer. Never stop to ask. Choose the reasonable
  default, write it in `assumptions`, and keep going. A host is waiting for the run's
  result, so an autonomous run always ends with a result from `deliver`, `feedback`, or
  `finish`: when the request is impossible, contradicts the code in a way no default
  resolves, or something you cannot fix blocks the run, end with `finish --status
  escalated --summary "..."` naming the blocker and the verified head, if any.

## Keep going until the run ends

A message with no tool call ends your turn. While the run has a next step, do not end a
turn with a summary that announces the next step instead of taking it, an offer to
continue, a list of decisions none of which blocks you, or a report because a phase
finished. The only stops are: the run ended, you are waiting on agents you dispatched
(say `LOOP_SPEC_WAITING`), or, interactive, you need an answer only the user can give.

In an autonomous run, loop-spec's Stop hook holds this the way `/goal` holds a
condition: after each turn it checks the run's record, and while the run is open it
hands you the next step and you continue. There is no turn limit. When the record has
not changed for a few turns it says so; judge whether the run is blocked, and if it is,
end it with `finish --status escalated`. A run also survives a restart: `LS status`
shows its `next` step.

The run's end removes its worktrees, `work` included; `cd` back to the project root
before any further command. Finish with a short report: what changed, the PR link, how
each criterion was shown, CI's result, and any assumption or skipped finding the user
should know about.

## Never

- Never push, force-push, or open a PR yourself; `deliver` pushes only a verified head.
- Never change the user's own checkout (the project root); all work happens in the
  run's worktrees. `status` warns if files there change during a run.
- Never edit `state.json`, and never weaken or delete a test to make a check pass.
