---
name: loop-spec
description: "The loop-spec method for taking a coding request to a verified pull request: write a short spec with checkable criteria, plan the work as a task graph, implement tasks in parallel worktrees, review, verify in a clean checkout, deliver one PR, and see its CI through. Read it when an entry skill (cycle, micro, debug, revise) starts a run, when resuming a run, or when you are an autonomous coding agent told to follow loop-spec."
---

# loop-spec

You are the lead of a loop-spec run. Your job is to turn a request into a pull
request whose every acceptance criterion was checked in a clean checkout of the
commit it delivers, whose CI passes, and whose reviewers' requests are answered. You
do the judgment. The program keeps the run's state and task graph on disk, manages git
worktrees, runs checks, opens the PR, and reads its CI and review.

This file is guidance, not a script. Follow its intent; where the code in front of
you calls for something different, do what the code needs and say why in your report.

## The program

`LS` below is the `program` path that `start` and `status` print in their
`LOOP_SPEC_RUN {...}` line, along with the run's `slug`, `phase`, `mode`, `base` (the
commit the change sits on), `runDir`, and `work` (the feature branch's worktree).
Commands find the run from the current directory or as the only open run; otherwise
add `--slug <slug>` after the command.

| Command | Does |
|---|---|
| `LS status` | where the run is, every task's state, the repository's rules files, and the `next` step |
| `LS task start T-1 T-2 ...` | one worktree per task from the feature head, with `prepare` already run in it; prints one `LOOP_SPEC_TASK {...}` brief per task |
| `LS task done T-1` | merge the task's commits into the feature branch; prints the `next` step |
| `LS task set T-1 --status todo\|blocked --note "..."` | change a task's status by hand |
| `LS verify [--base]` | run every criterion check, task verify command, and repository check in a clean checkout of the feature head (or, with `--base`, of the base) |
| `LS sync` | merge whatever moved on origin (the base branch, or the feature branch itself) into `work` |
| `LS set --branch NAME --title "..."` | rename the feature branch (until it is pushed) or set the PR title |
| `LS deliver [--draft] [--comment-file F] [--no-feedback]` | push the verified head and open or update its PR (posting `F` as a comment) |
| `LS feedback` | wait for the PR's checks (up to 9 minutes per call), then read its review; ends the run when CI passes and reviewers have asked for nothing new, or shows what to address |
| `LS finish --status no-change\|escalated\|failed --summary "..."` | end a run that delivers nothing |

The branch and the PR title come from, in order: the user (the entry passes them as
`start --branch` and `--title`), then the repository's rules (set with `LS set` in the
spec step), then the defaults (`feat/<slug>`, and the spec's `title`).

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
 "checks": [{"command": "uv run ruff check", "source": "CLAUDE.md"},
            {"command": "uv run mypy calc", "source": "AGENTS.md"}],
 "tasks": [{"id": "T-1", "title": "Add lerp with its tests", "dependsOn": [],
            "files": ["calc/__init__.py", "tests/test_lerp.py"], "criteria": ["AC-1"],
            "verify": ".venv/bin/python -m pytest -q tests/test_lerp.py"}]}
```

A `check`, `verify`, or `checks` command is a bash command run from the repository
root. `prepare` installs what they need into a fresh checkout (`.venv/bin/python` only
exists after it); the program runs it in each task's worktree and before every verify.
Leave it out when nothing needs installing.

`checks` are the repository's own required checks. `status` lists its rules files
(`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING*`, at any depth for the first two): read each
one and put every command they say a change must pass (lint, format, typecheck, tests,
build) in `checks`, with the file it came from; write `[]` when they require none.
Verify runs each one, and when one fails it runs it at the base too: a check that fails
the same way there is pre-existing and does not fail the run; new output does.

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
  answer changes what you build, together, while you write the spec. Then show the
  goal and criteria and ask once for approval before planning. After that, ask only
  when you are truly blocked or before something risky the user did not ask for.
- **autonomous**: no one will answer. Never stop to ask. Choose the reasonable
  default, write it in `assumptions`, and keep going. A host is waiting for the run's
  result, so an autonomous run always ends with a result from `deliver`, `feedback`, or
  `finish`: when the request is impossible, contradicts the code in a way no default
  resolves, or something you cannot fix blocks the run, end with `finish --status
  escalated --summary "..."` naming the blocker and the verified head, if any.

## The run

### 1. Spec

Write `spec.json`. The goal is one sentence. Each criterion is a property of the code
at the delivered commit that one command can show (a test, a script, a grep), never
something about the PR, CI, or branches; keep each check exactly as strict as the
criterion, so it cannot fail on a comment or a wording. Give a criterion no `check`
only when no command can show it; the reviewer then judges it. Record each real choice
in `decisions`.

Read the rules files for how this repository takes a change: branch naming, PR title
and commit message format, a PR template (`.github/pull_request_template.md` and its
variants), a changelog entry, sign-off. Follow them throughout. Unless the user named
them, set the branch and title they call for with `LS set` now, before anything is
pushed; with no rule, `title` in `spec.json` follows the commit convention (`git log
--oneline -15`). When the repository has a PR template, write the description it asks
for to `pr.md` in `runDir`; deliver uses it and appends the criteria and how verify
showed them.

### 2. Plan

Write `plan.json`. A task is a unit one worker can implement and test on its own.

- Keep code and its tests in the same task. Give each file one owning task.
- `dependsOn` only what a task truly needs merged first; independent tasks run in
  parallel. A small change is one task. Do not split work just to have more tasks.
- Each task's `verify` runs the tests that exercise it, and each criterion is named by
  some task's `criteria` (`status` points out any that are not).
- When the change alters behavior a doc describes, or a public symbol other code
  calls, include that update in a task: migrate the callers, then remove what they no
  longer use.

`LS status` rejects a graph with a cycle or an unknown dependency.

### 3. Execute: drive the graph

Until every task is done:

1. `LS task start` the tasks the `next` step names.
2. Dispatch one `loop-spec:implementer` agent per started task, all in one message so
   they run in parallel. Its prompt is the task's `LOOP_SPEC_TASK` brief, plus the
   conventions you found (commit style, house rules) and anything else it needs from
   you. Dispatch every task except a few-line change or one that needs context only you
   have; that one you do yourself, in `work` or in its worktree, commit, and `LS task
   done` it.
3. While agents run, end your turn with a line saying `LOOP_SPEC_WAITING`; their
   reports resume you.
4. When a worker reports, read its report and its commits (`git -C <worktree> log -p
   <from>..`, with `from` from the brief). If the work is sound, `LS task done T-n`. If
   not, send it back with what is wrong, or fix it yourself in the worktree.
5. If a task turns out wrong or missing, edit `plan.json` (finished tasks stay
   finished) and carry on. A blocked task gets `LS task set T-n --status blocked`.

### 4. Review, simplify, and verify

When every task is merged:

1. Dispatch, in one message, a `loop-spec:reviewer` (correctness, adversarially) and a
   `loop-spec:simplifier` (reuse, simplification, efficiency, altitude). Give both
   `work` and the range `<base>..HEAD`; give the reviewer the path of `spec.json` too.
2. Fix every blocking finding. Apply each simplifier cleanup that keeps the behavior the
   spec asks for and makes the change smaller or plainer; skip the rest. Commit small
   fixes directly in `work`, or add a task for a larger one, and list what you skipped
   in your report.
3. `LS verify`. If a check fails, find the cause (the code, the check, or the
   environment), fix it, and verify again. Verify records a pass only for the current
   head, so verify again after any new commit.

### 5. Deliver, then CI and review

1. `LS deliver` pushes the feature branch and opens a PR (or updates the one it opened
   before), with the spec, tasks, and verify results in the description. It refuses a
   head verify did not pass, and it refuses when origin moved: then `LS sync`, resolve
   any conflict in `work` keeping both sides' intent (`git commit --no-edit`), verify,
   and deliver again. Use `--unverified`, which opens a draft that says so, only with
   the user's say-so, or, autonomous, when a check cannot run here for a reason outside
   the change. If there is nothing to deliver, `LS finish --status no-change`.
2. `LS feedback` waits for the PR's checks, then reads its review: reviews, inline
   comments, and conversation comments from people and review bots, each shown once.
   Still running: run it again. When CI passes and reviewers have asked for nothing new,
   the run ends. Otherwise, for each failed check (its log is shown) and each review
   item, decide what it needs:
   - Something this change should do: fix it in `work`, verify, deliver, and run
     `feedback` again.
   - A question, or a request you decline with a reason: answer it in a comment, by
     `deliver --comment-file` with your next fix, or `gh pr comment` when there is none.
   - A check that also fails on the base branch is not this change's to fix: say so in
     a comment.
   There is no limit on rounds. If the feedback cannot be satisfied (it contradicts the
   spec, or needs a decision only the user can make), end the run with `finish --status
   escalated` naming what is needed.
3. When the project's config names feedback skills (`.loop-spec/config.json`,
   `feedback.skills`), `feedback` lists them once CI and review are clear: invoke each
   with the `Skill` tool and the PR URL, treat what it reports like review comments, and
   when nothing is left, `finish --status completed`.

The run's end removes its worktrees, `work` included; `cd` back to the project root
before any further command. Finish with a short report: what changed, the PR link, how
each criterion was shown, CI's result, and any assumption or skipped finding the user
should know about.

## Variations

- **micro**: a small, well-defined change. Skip the interview, write one or two
  criteria and a one-task plan, and do the task yourself. Review only if the change
  touches behavior other code relies on; skip the simplifier.
- **debug**: reproduce first. Put the failing command in the spec as a criterion's
  `check`; `LS verify --base` should show it failing on the base. Find the root cause
  before changing anything, fix it there, and keep a regression test that fails
  without the fix.
- **revise** (`start --pr N`): the run works on the PR's own branch. Read the review
  with `gh pr view N --comments` and `gh api repos/{owner}/{repo}/pulls/N/comments`, and
  make one criterion per comment you act on. Write a reply covering each comment (what
  changed, or why not) to a file in `runDir` and pass it as `deliver --comment-file`;
  deliver leaves the PR's description alone.

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

## Never

- Never push, force-push, or open a PR yourself; `deliver` pushes only a verified head.
- Never change the user's own checkout (the project root); all work happens in the
  run's worktrees. `status` warns if files there change during a run.
- Never edit `state.json`, and never weaken or delete a test to make a check pass.
