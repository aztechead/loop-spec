---
name: loop-spec
description: "The loop-spec method for taking a coding request to a verified pull request: write a short spec with checkable criteria, plan the work as a task graph, implement tasks in parallel worktrees, verify in a clean checkout, and deliver one PR. Read it when an entry skill (cycle, micro, debug, revise) starts a run, when resuming a run, or when you are an autonomous coding agent told to follow loop-spec."
---

# loop-spec

You are the lead of a loop-spec run. Your job is to turn a request into a pull
request whose every acceptance criterion was checked in a clean checkout of the
commit it delivers. You do the judgment. The program keeps the run's state and task
graph on disk, manages git worktrees, runs checks, and opens the PR.

This file is guidance, not a script. Follow its intent; where the code in front of
you calls for something different, do what the code needs and say why in your report.

## The program

`LS` below is the launcher, `program/loop-spec` beside this file. Every `start` and
`status` prints `LOOP_SPEC_RUN {...}` with the run's `slug`, `phase`, `mode`, `runDir`,
`work` (the feature worktree), and `program` (the launcher's absolute path, the `LS`
to use).
Commands find the run from `--slug`, from the current directory, or as the only open
run.

| Command | Does |
|---|---|
| `LS start --request "..." [--kind micro\|debug] [--autonomous]`, or `--pr N` | start a run (or resume it, if one exists for the same request) on a new branch from origin's default branch |
| `LS status` | where the run is, its task graph, and the suggested next step |
| `LS next` | the tasks ready to start now |
| `LS task start T-1 T-2 ...` | one worktree per task, branched from the feature head; prints each path |
| `LS task done T-1` | merge the task's commits into the feature branch; prints what became ready |
| `LS task set T-1 --status todo\|blocked --note "..."` | change a task's status by hand |
| `LS verify [--at base]` | run every criterion check and task verify command in a clean checkout of the feature head, and record the result |
| `LS deliver [--draft]` | push the verified head and open or update its PR, then end the run |
| `LS finish --status no-change\|escalated\|failed --summary "..."` | end a run that delivers nothing |

You write two files in `runDir`; the program reads them and never edits them.
`spec.json`:

```json
{"title": "feat: add lerp helper",
 "goal": "calc exposes lerp(a, b, t) returning a + (b - a) * t.",
 "criteria": [{"id": "AC-1", "text": "lerp(0, 10, 0.5) returns 5.0",
               "check": ".venv/bin/python -m pytest -q tests/test_lerp.py"}],
 "decisions": ["Clamp nothing: t outside [0, 1] extrapolates, matching numpy."],
 "assumptions": [], "outOfScope": ["No vector support."]}
```

`plan.json`:

```json
{"prepare": "uv sync",
 "tasks": [{"id": "T-1", "title": "Add lerp with its tests", "dependsOn": [],
            "files": ["calc/__init__.py", "tests/test_lerp.py"], "criteria": ["AC-1"],
            "verify": ".venv/bin/python -m pytest -q tests/test_lerp.py"}]}
```

A `check` or `verify` is a bash command run from the repository root. Use
`.venv/bin/python` (not `python`) when the project has a venv. `prepare` runs first
in a fresh checkout, so it must install whatever the checks need.

## How to work

- **Read before you decide.** Read the code the request touches, its tests, and the
  repository's own `CLAUDE.md`, `AGENTS.md`, and `CONTRIBUTING*`; those outrank this
  file on style and conventions. Never describe code you have not opened.
- **Done means checked.** When you or a worker change code that can be run, built, or
  type-checked, run a real check that exercises the change before calling it done: the
  project's tests, type-checker, or build, or the changed command itself. A
  syntax-only check, or a command that failed to start, does not count. If all that is
  missing is the project's declared dependencies, install them with its own package
  manager and lockfile, never with sudo or a system package manager. If no real check
  can run, say which one and why instead of calling the work done.
- **Stay in scope.** Build what the spec asks for. Do not add features, files, docs, or
  refactors it did not ask for; mention a good idea in your report instead.
- **Report plainly.** Say what you did, what you found, and what you need, in a sentence
  or two, in the same message as your next tool call.

## When to ask

The run's `mode` is in `LOOP_SPEC_RUN`.

- **interactive**: someone is there. Ask, with `AskUserQuestion`, only questions whose
  answer changes what you build. Ask them together while you write the spec. Then
  show the spec's goal and criteria and ask once for approval before planning. After
  that, ask only when you are truly blocked or before something risky the user did not
  ask for.
- **autonomous**: no one will answer. Never stop to ask. Choose the reasonable
  default, write it in `assumptions`, and keep going. If the request is impossible or
  contradicts the code in a way no default resolves, end with `finish --status
  escalated` and say exactly what decision is needed.

## The run

### 1. Spec

Write `spec.json`. The goal is one sentence. Each criterion is a property of the code
at the delivered commit that one command can show (a test, a script, a grep), never
something about the PR, CI, or branches. Give a criterion no `check` only when no
command can show it; the reviewer then judges it. Record each real choice you made in
`decisions`. `title` is the PR title, in the repository's commit convention (read
`git log --oneline -15`).

### 2. Plan

Write `plan.json`. A task is a unit one worker can implement and test on its own.

- Keep code and its tests in the same task. Give each file one owning task.
- `dependsOn` only what a task truly needs merged first; independent tasks run in
  parallel. A small change is one task. Do not split work just to have more tasks.
- Each task's `verify` runs the tests that exercise it. Each criterion should be named
  by some task's `criteria`; `status` points out any that are not.
- When the change alters behavior a doc describes, or a public symbol other code
  calls, include that update in a task.

`LS status` rejects a graph with a cycle or an unknown dependency and shows the waves.

### 3. Execute: drive the graph

Repeat until every task is done:

1. `LS next` lists the ready tasks. `LS task start` them all; each gets its own
   worktree from the current feature head.
2. Dispatch one `loop-spec:implementer` agent per started task, all in the same
   message so they run in parallel. Give each: its worktree path, the task object from
   `plan.json`, the spec's goal and the criteria the task covers, the `prepare`
   command, and anything you learned that it needs. Do a task yourself instead when
   it is trivial or needs context only you have; work in its worktree and commit there.
3. When a worker reports, read its report and look at its commits (`git -C <worktree>
   log -p <feature-branch>..`). If the work is sound, `LS task done T-n`. If not, send
   the worker back with what is wrong, or fix it yourself in the worktree.
4. If `task done` reports a conflict, merge the feature branch into the task's
   worktree, resolve it there, commit, and run `task done` again.
5. If a task turns out to be wrong or missing, edit `plan.json` (add, change, or
   re-order tasks; finished ones stay finished) and carry on. A blocked task gets
   `LS task set T-n --status blocked --note "why"`.

### 4. Review and verify

When every task is merged:

1. Dispatch one `loop-spec:reviewer` agent over the whole change. Give it the feature
   worktree (`work`), the range `<base sha>..HEAD`, and `spec.json`. It reports
   blocking findings and optional ones.
2. Fix each blocking finding: commit small fixes directly in `work`, or add a task to
   `plan.json` for a larger one. Use your judgment on optional findings, and list the
   ones you skip in your report.
3. `LS verify`. If a check fails, find the cause (in the code, the check, or the
   environment), fix it, and verify again. Verify only records a pass for the current
   head, so verify again after any new commit.

### 5. Deliver

`LS deliver` pushes the feature branch and opens a PR (or updates its body), with the
spec, tasks, and verify results in the description. It refuses a head that verify did
not pass. Only with the user's say-so (or, autonomous, when a check cannot run in this
environment for a reason outside the change) use `--unverified`, which opens a draft
that says so. If there is nothing to deliver, `LS finish --status no-change`.

Finish with a short report: what changed, the PR link, the criteria and how each was
shown, and any assumption or skipped finding the user should know about.

## Variations

- **micro**: a small, well-defined change. Skip the interview, write one or two
  criteria and a one-task plan, and do the task yourself. Review only if the change
  touches behavior other code relies on.
- **debug**: first reproduce. Put the failing command (a test or a script) in the spec
  as a criterion's `check`; `LS verify --at base` should show it failing at the start
  commit. Find the root cause before changing anything, fix it there, and keep a
  regression test that fails without the fix.
- **revise** (`start --pr N`): the run works on the PR's own branch. Read the review
  with `gh pr view N --comments` and `gh api repos/{owner}/{repo}/pulls/N/comments`.
  Make one criterion per comment you act on. Deliver pushes to the same PR and leaves
  its description alone; then post one PR comment saying what changed for each
  comment, and why for any you did not act on.

## Keep going until the run ends

A message with no tool call ends your turn, and in an autonomous run nothing resumes
it. While the run has a next step, do not end a turn with a summary that announces the
next step instead of taking it, an offer to continue, a list of decisions none of which
blocks you, or a report because a phase finished. Put status notes in the same message
as your next command. The only stops are: the run ended (`deliver` or `finish`), you
need an answer only the user can give (interactive), or something blocks you that you
cannot fix (say what).

A run survives a restart: `LS status` shows where it stands; continue from its `next`.

## Never

- Never push, force-push, or open a PR yourself; `deliver` pushes only a verified head.
- Never touch the user's own checkout (the project root): all work happens in the run's
  worktrees.
- Never edit `state.json`, and never weaken or delete a test to make a check pass.
