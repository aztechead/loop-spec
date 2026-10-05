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

This file covers every run: the program, how to work, and each phase. A run of another
kind than `cycle` changes a few phases, as its own reference says, and a repository
without a PR template uses the bundled one. This is guidance, not a script: where the
code in front of you calls for something different, do what the code needs and say why
in your report.

## The program

`LS` below is the `program` path that `start` and `status` print in their
`LOOP_SPEC_RUN {...}` line, along with the run's `slug`, `kind`, `phase`, `mode`, `base`
(the commit the change sits on), `runDir`, `work` (the feature branch's worktree; with a `repos` object, see
[A run across repositories](#a-run-across-repositories)), and
`references` (the absolute path of the `references/` directory this file links to;
read a reference through it, since your shell is not in this file's directory).
Run it; there is no need to read it. Commands find the run from the current directory
or as the only open run; otherwise add `--slug <slug>` after the command.

It needs `git` and `python3` 3.11 or later; delivering needs `gh`, signed in, and an
`origin` remote. `task start`, `verify`, and `feedback` can run for minutes: give their
Bash calls a timeout to match (up to 10 minutes), or run them in the background when
the project's checks take longer.

| Command | Does |
|---|---|
| `LS status` | where the run is, every task's state, the repository's rules files, and the `next` step |
| `LS task start T-1 T-2 ...` | one worktree per task from the feature head, with `prepare` already run in it; prints one `LOOP_SPEC_TASK {...}` brief per task |
| `LS task done T-1` | merge the task's commits into the feature branch; prints the `next` step |
| `LS task set T-1 --status todo\|blocked --note "..."` | change a task's status by hand |
| `LS verify [--base]` | run every criterion check, task verify command, and repository check in a clean checkout of the feature head (or, with `--base`, of the base) |
| `LS sync` | merge whatever moved on origin (the base branch, or the feature branch itself) into `work` |
| `LS iterate [--caveats "..."]` | record that the verified head's whole-change review is done and addressed |
| `LS set [--repo NAME] --branch NAME --title "..."` | rename the feature branch (until it is pushed) or set the PR title; `--repo` sets them for one repository of a run across repositories |
| `LS deliver [--draft] [--unverified] [--comment-file F]` | push the verified head and open or update its PR (posting `F` as a comment) |
| `LS feedback` | wait for the PR's checks (up to 9 minutes per call), then read its review; ends the run when CI passes and reviewers have asked for nothing new, or shows what to address |
| `LS checkpoint [--push]` | commit work in progress in every worktree and list them; `--push` pushes their branches. For a run the host asked to wrap up |
| `LS finish --status completed\|no-change\|escalated\|failed --summary "..."` | end the run: `completed` after feedback skills find nothing, otherwise a run that delivers nothing |

Four kinds of check apply to a run. A criterion's `check` (in `spec.json`), a task's
`verify`, and the repository's `checks` (both in `plan.json`) all run in `LS verify`. CI
checks are the PR's, and `LS feedback` reads them.

The program derives the phase from the run's files and announces each change with
`LOOP_SPEC_PHASE_START`/`_END` lines, which monitoring tools read. Run `LS status`
after writing `spec.json` and after writing `plan.json`, so each phase is announced
when it ends. Do not pipe `LS` commands through `tail`, `head`, or `grep`: their output
is short, and a host reads those lines from it.

## How to work

- **Work in `work`.** Your shell starts in the user's own checkout, and a relative path
  written from there changes their files. Right after `start`, `cd` into `work` (the
  same code, on the feature branch) and read the code there.
- **No code before the plan.** Spec and Plan write only `spec.json` and `plan.json`.
  Code is written in task worktrees once `LS status` accepts the plan, and in `work` only
  for fixes from Verify on. A design you worked out goes into the spec's `decisions` and
  the tasks' briefs.
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
- **Prove it works.** Tests passing is necessary, not sufficient. A change you make
  yourself is done only when a real check that exercises it has passed; a syntax-only
  check, or a command that failed to start, does not count.
- **Keep decisions moving.** A reversible decision you can make from the code is yours
  to make: make it, record it, and keep going. When to ask is below.
- **Guard your context.** Hand implementation and broad reading to agents; keep your own
  context for judging their results.
- **Stay in scope, and report plainly.** Build what the spec asks; mention a good idea
  instead of building it. Put a sentence on what you did or found in the same message
  as your next command.

## When to ask

The run's `mode` is in `LOOP_SPEC_RUN`.

- **interactive**: someone is there. Interview while you write the spec: after reading
  the code, find each choice the request leaves open that changes what gets built: a
  format other code reads, stored data, behavior a user sees. Ask them all in one
  `AskUserQuestion`, your choice as the recommended option, even when your default is
  good: the person may know what the code does not. A request that settles every such
  choice needs no interview. Then ask once for approval of the criteria. After that,
  ask only when you are truly blocked or before something risky the user did not ask for.
- **autonomous**: no one will answer. Never stop to ask. Choose the reasonable
  default, write it in `assumptions`, and keep going. A host is waiting for the run's
  result, so an autonomous run always ends with a result from `deliver`, `feedback`, or
  `finish`: when the request is impossible, contradicts the code in a way no default
  resolves, or something you cannot fix blocks the run, end with `finish --status
  escalated --summary "..."` naming the blocker and the verified head, if any.
- **supervised**: a host relays your questions to a person. Interview as in interactive,
  without the approval of the criteria. After the spec, work as autonomous, except ask
  when you cannot go on without an answer or before a step that is hard to undo. If a
  question comes back unanswered, end your turn with a line saying `LOOP_SPEC_ASKING`.

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

Every phase ends on a check, and you loop on it until it passes:

| Phase | The work | The check, and the loop |
|---|---|---|
| 1. Spec | `spec.json`: a goal, and criteria a command can show; the repository's rules for branch, title, and PR | `LS status` checks `spec.json`; interactive, the user approves the criteria; revise until both pass |
| 2. Plan | `plan.json`: the task graph, `prepare`, and the repository's required `checks` | `LS status` validates the graph; fix it until it accepts |
| 3. Execute | start ready tasks, dispatch implementers in parallel, merge each sound one | you read each report and diff; send it back or fix it until it is sound |
| 4. Verify | `LS verify` in a clean checkout | a failure: find the cause, fix it, verify again |
| 5. Iterate | a reviewer and a simplifier on the whole change | fix blocking findings; any new commit goes back to verify; then `LS iterate` |
| 6. Deliver | `pr.md`, `LS deliver`, `LS feedback` | a failed check or a review item: fix, verify, deliver, feedback again, with no round limit |

A `cycle` run follows this as written. Other kinds change it; read yours before the
spec: [micro](references/micro.md), [debug](references/debug.md), or
[revise](references/revise.md).

## A run across repositories

When `LOOP_SPEC_RUN` has a `repos` object, the run changes several repositories that sit
side by side in a workspace (the directory holding `.loop-spec/workspace.json`). The
phases are the same; these points change:

- `work` holds one worktree per repository, at `work/<name>/`. Each `repos` entry gives
  that repository's `work`, `base`, `branch`, `prTemplate`, and `prMd`.
- When a repository's rules name its own branch or PR title format, set them for that
  repository: `LS set --repo <name> --branch NAME --title "..."`.
- Give every task a `"repo": "<name>"`. A task changes one repository; split a change
  that spans two into tasks, with `dependsOn` where one needs the other.
- Give every `checks` entry a `"repo"`. `prepare` is one command run in every repository,
  or an object with one command per repository name.
- A criterion's `check` runs from the directory holding all repositories, so write
  `cd api && ...`. A task's `verify` and a `checks` command run from their repository's
  root.
- Review each repository's change from its own `base`, with the `work` and `base` of its
  `repos` entry: `git -C <work> diff <base>..HEAD`.
- Write one PR description per repository that has commits, at its `prMd` path, following
  its `prTemplate`. Deliver opens one PR per changed repository and links each to the
  others; `feedback` reads all of them.

## 1. Spec

Write `spec.json` in `runDir`, a statement of done that a command can check, and settle
how this repository takes a change.

### spec.json

Use this shape. The program reads `title`, `goal`, and `criteria`; `decisions`,
`assumptions`, and `outOfScope` are for you, the reviewer, and the user:

```json
{"title": "feat: add lerp helper",
 "goal": "calc exposes lerp(a, b, t) returning a + (b - a) * t.",
 "criteria": [{"id": "AC-1", "text": "lerp(0, 10, 0.5) returns 5.0",
               "check": ".venv/bin/python -m pytest -q tests/test_lerp.py"}],
 "decisions": ["Clamp nothing: t outside [0, 1] extrapolates, matching numpy."],
 "assumptions": [], "outOfScope": ["No vector support."]}
```

The goal is one sentence. Each criterion is a property of the code at the delivered
commit that one command can show (a test, a script, a grep), never something about the
PR, CI, or branches. Keep each check exactly as strict as its criterion, so it cannot
fail on a comment or a wording. Give a criterion no `check` only when no command can
show it; the reviewer then judges it. Record each real choice in `decisions`, and, in
an autonomous or supervised run, each default you chose in `assumptions`. At least one
criterion runs the real thing (the command, the endpoint, the script) the way a user would.

Illustrative criteria, for a request to add a `--ttl` option to a CLI:

| Criterion | Check | Why |
|---|---|---|
| A key set with `--ttl 1` is gone after it expires | `python -m pytest -q tests/test_ttl.py` (the test injects a clock) | good: the behavior, shown by a test that cannot flake |
| `kv set a 1 --ttl 5 && kv get a` prints `1` | `bash -c 'kv set a 1 --ttl 5 && kv get a \| grep -qx 1'` | good: the real command, as a user runs it |
| No file contains the word `sleep` | `! grep -r sleep .` | bad: it fails on a comment that says "instead of sleeping"; check the tests' clock instead |
| The PR passes CI | none | bad: about the PR, not the code; `feedback` reads CI |

### How this repository takes a change

`LS status` lists the rules files (`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING*`). Read them
for branch naming, PR title and commit message format, a PR template, a changelog
entry, and sign-off, and follow them for the rest of the run.

The branch and the PR title come from, in order: the user (the entry passed them as
`start --branch` and `--title`), then the repository's rules, then the defaults
(`branch` or `branchPrefix` in `.loop-spec/config.json`, else `feat/<slug>`, or
`fix/<slug>` for a debug run; and the spec's `title`). For the rules, run `LS set
--branch NAME --title "..."` now, before anything is pushed. Do the same when the
request opens with context rather than the change (a URL, a ticket, a pasted bundle):
name the branch from the spec's title. With no rule, `title` follows the commit
convention in `git log --oneline -15`.

### The check

In an interactive run, show the user the goal and criteria and ask once for approval,
revising until they approve. Then run `LS status`. It checks `spec.json` and names each
problem: a missing goal, no criteria, a criterion without an `id` or `text`, a `check`
that is not a command string, or a duplicate id. Fix the file and run it again until it
reports the criteria; that run announces the end of SPEC.

## 2. Plan

Write `plan.json` in `runDir`, the task graph the program runs, and have `LS status`
accept it before any task starts.

### plan.json

Use this shape; the program reads these fields. This plan, for a spec with criteria
AC-1 to AC-3, runs T-1 and T-2 in parallel, then T-3 once both are merged:

```json
{"prepare": "uv sync",
 "checks": [{"command": "uv run ruff check", "source": "CLAUDE.md"},
            {"command": "uv run mypy calc", "source": "AGENTS.md"}],
 "tasks": [{"id": "T-1", "title": "Add lerp with its tests", "dependsOn": [],
            "files": ["calc/lerp.py", "tests/test_lerp.py"], "criteria": ["AC-1"],
            "verify": ".venv/bin/python -m pytest -q tests/test_lerp.py"},
           {"id": "T-2", "title": "Add clamp with its tests", "dependsOn": [],
            "files": ["calc/clamp.py", "tests/test_clamp.py"], "criteria": ["AC-2"],
            "verify": ".venv/bin/python -m pytest -q tests/test_clamp.py"},
           {"id": "T-3", "title": "Export both and document them", "dependsOn": ["T-1", "T-2"],
            "files": ["calc/__init__.py", "README.md"], "criteria": ["AC-3"],
            "verify": ".venv/bin/python -c 'from calc import lerp, clamp'"}]}
```

- `prepare` installs what the checks need into a fresh checkout (`.venv/bin/python`
  exists only after it). The program runs it in each task's worktree and before every
  verify. Leave it out when nothing needs installing.
- `checks` are the repository's own required checks. Read each rules file `LS status`
  lists and put every command they say a change must pass (lint, format, typecheck,
  tests, build) here, with the file it came from; write `[]` when they require none.
  When one fails at verify, the program runs it at the base too: output that is the
  same there is pre-existing and does not fail the run; new output does.
- Every `check`, `verify`, and `checks` command is a bash command run from the
  repository root.

### Tasks

A task is a unit one implementer can build and test on its own.

- Keep code and its tests in the same task. Give each file one owning task.
- `dependsOn` only what a task needs merged first; independent tasks run in parallel. A
  small change is one task; split work only where the parts are independent.
- Each task's `verify` runs the tests that exercise it, and every criterion is named in
  some task's `criteria`.
- When the change alters behavior a doc describes, or a public symbol other code calls,
  include that update in a task: migrate the callers, then remove what they no longer
  use.

### The check

Run `LS status`. It validates the graph and names each problem with what would fix it:
a missing or duplicate id, an unknown dependency, a cycle, or a task naming a criterion
the spec does not have. Fix `plan.json` and run it again until it accepts the plan. It
also names any criterion no task covers (add it to a task's `criteria`), and any two
tasks that can run at once but list the same file, which would conflict when merged
(give the file one owner, or make one task depend on the other). Its `next` line then
names the first tasks to start.

## 3. Execute the task graph

Get every task in `plan.json` built, checked, and merged into the feature branch,
running independent tasks in parallel.

Until every task is done:

1. Run `LS task start` with the tasks the `next` line names. Each gets a worktree with
   `prepare` already run, and a `LOOP_SPEC_TASK {...}` brief: `id`, `worktree`,
   `branch`, `from` (the commit it starts at), `task` (its entry in `plan.json`), the
   spec's `goal`, the `criteria` it covers, the repository's `checks`, and `prepared`
   (false when `prepare` failed there).
2. Dispatch one `loop-spec:implementer` agent per started task, all in one message so
   they run in parallel. Its prompt is the task's brief, plus the conventions you found
   (commit style, house rules) and anything else it needs from you, including any design
   you already worked out. Do a task yourself only when it is a few lines: work in its
   worktree, commit, and `LS task done` it.
3. While implementers run, end your turn with a line saying `LOOP_SPEC_WAITING`; their
   reports resume you.
4. When an implementer reports, read its report and its commits (`git -C <worktree>
   log -p <from>..`, with `from` from the brief). If the work is sound, `LS task done
   T-n`, which merges it and names the next step. If not, send it back with what is
   wrong, or fix it yourself in the worktree, and read it again.
5. If a task turns out wrong or missing, edit `plan.json` (finished tasks stay
   finished) and run `LS status` to validate it again. A task that cannot proceed gets
   `LS task set T-n --status blocked --note "..."`.

`LS task done` refuses uncommitted work and a merge that conflicts; it says which, and
how to fix it. When every task is done, its `next` line says to verify.

## 4 and 5. Verify, then review the whole change

Show every criterion and required check passing in a clean checkout of the feature
head, then have the whole change reviewed and simplified, and verified again after any
fix.

### Verify

Run `LS verify`. It runs every criterion's check, every task's `verify`, and every
repository check in a clean checkout of the feature head, and records a pass for that
head only.

When a check fails, find the cause (the code, the check, or the environment), fix it in
`work`, commit, and verify again. Repeat until it passes. Never weaken or delete a test
to make a check pass.

### Iterate

Once verify passes:

1. Dispatch, in one message, a `loop-spec:reviewer` (correctness, adversarially) and a
   `loop-spec:simplifier` (reuse, simplification, efficiency, altitude). Give both
   `work` and the range `<base>..HEAD`; give the reviewer the path of `spec.json` too.
2. Fix every blocking finding. Apply each simplifier cleanup that keeps the behavior the
   spec asks for and makes the change smaller or plainer; skip the rest. Commit small
   fixes in `work`, or add a task for a larger one, and list what you skipped in your
   report.
3. Any new commit sends the run back to verify: run `LS verify` again, and repeat until
   the verified head has nothing left to fix.
4. Run `LS iterate`, with `--caveats "..."` for anything you knowingly leave open,
   which the result carries.

## 6. Deliver, then see CI and review through

Open the PR for the verified, reviewed head, then answer its CI and its reviewers until
CI passes and nobody has asked for anything new.

### The description

Write the PR description to `pr.md` in `runDir`, following the template `LS status`
names on its `pr.md` line (`prTemplate` in `LOOP_SPEC_RUN`): the repository's own PR
template when it has one, else the visual-pr template,
[pr_description_template.md](references/visual-pr/pr_description_template.md): one
sentence on why, one to three reviewer notes, and a change outline in the views it
lists. `pr.md` becomes the PR's description when deliver opens the PR. Deliver adds
the criteria, and how verify showed each, in a folded section below it, and every later
deliver replaces only that section, so what anyone adds to the PR stays. A revise run
needs no `pr.md`.

### Deliver

Run `LS deliver`. It pushes the feature branch and opens the PR, or updates the one it
opened before. It refuses, and says why, when:

- there is no `pr.md`, or it still has lines of the template's `{...}` placeholders;
- `gh` is missing or not signed in (checked before anything is pushed);
- verify did not pass at this head: verify again;
- the head has no recorded review: review it and run `LS iterate`;
- origin has the feature branch with commits this run never had: that branch belongs to
  other work, so `LS set --branch NAME` and deliver again;
- origin moved: run `LS sync`, resolve any conflict in `work` keeping both sides' intent
  (`git commit --no-edit`), verify, and deliver again.

Use `--unverified`, which opens a draft that says so, only with the user's say-so, or,
in an autonomous run, when a check cannot run here for a reason outside the change. If
there is nothing to deliver, `LS finish --status no-change --summary "..."`. Only when
the user asked not to wait for CI, add `--no-feedback`, which ends the run at the PR.

### The feedback loop

Run `LS feedback`. It waits for the PR's checks, then shows each failed check's log and
each new review item (reviews, inline comments, conversation comments) once. Then:

- **Checks still running, or a requested review not in yet:** run it again.
- **CI passed and nothing new:** the run ends.
- **A failed check or a review item this change should address:** fix it in `work`,
  verify, deliver, and run `feedback` again.
- **A question, or a request you decline with a reason:** answer it in a comment with
  `deliver --comment-file F`, alongside your next fix or on its own; a comment posted
  with `gh` instead comes back from `feedback` as a new item.
- **A check that also fails on the base branch:** not this change's to fix; say so in a
  comment.
- **Feedback that cannot be satisfied** (it contradicts the spec, or needs a decision
  only the user can make): `LS finish --status escalated --summary "..."` naming what
  is needed.

There is no limit on rounds.

When the project's config names feedback skills (`feedback.skills` in
`.loop-spec/config.json`), `feedback` lists them once CI and review are clear. Invoke
each with the `Skill` tool and the PR URL, treat what it reports like review comments,
and when nothing is left, `LS finish --status completed --summary "..."`.

## Keep going until the run ends

A message with no tool call ends your turn. While the run has a next step, do not end a
turn with a summary that announces the next step instead of taking it, an offer to
continue, a list of decisions none of which blocks you, or a report because a phase
finished. The only stops are: the run ended, you are waiting on agents you dispatched
(say `LOOP_SPEC_WAITING`), or you need an answer only the user can give (interactive,
or supervised saying `LOOP_SPEC_ASKING`).

In an autonomous or supervised run, loop-spec's Stop hook holds this the way `/goal` holds a
condition: after each turn it checks the run's record, and while the run is open it
hands you the next step and you continue. There is no turn limit. When the record has
not changed for a few turns it says so; judge whether the run is blocked, and if it is,
end it with `finish --status escalated`. A run also survives a restart: `LS status`
shows its `next` step.

When a `next` line says the host asked the run to wrap up, stop starting new work,
commit what is finished, run `LS checkpoint --push`, and end with `LS finish --status
escalated --summary "..."` saying what is done and what is not.

The run's end removes its worktrees, `work` included, so run the command that ends it
from the project root (the workspace root in a run across repositories):
`cd <project> && LS deliver --slug <slug>` (or `feedback`,
`finish`). Finish with a short report: what changed, the PR link, how
each criterion was shown, CI's result, and any assumption or skipped finding the user
should know about.

## Never

- Never push, force-push, or open a PR yourself; `deliver` pushes only a verified head.
- Never change the user's own checkout (the project root); all work happens in the
  run's worktrees. `status` warns if files there change during a run.
- Never edit `state.json`, and never weaken or delete a test to make a check pass.
