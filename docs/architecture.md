# loop-spec 8.x architecture

For a contributor changing loop-spec. This page says which part owns what, and why
the line between them sits where it does. The method itself is in
[skills/loop-spec/SKILL.md](../skills/loop-spec/SKILL.md); command details are in
`loop-spec --help`.

## The split

| Part | Owns | Lives in |
|---|---|---|
| The lead (the user's session, or an SDK agent) | every judgment: the spec, the plan, dispatching tasks, reading reports, fixing findings | runs the hub skill |
| The hub skill | the method, as guidance the lead follows | `skills/loop-spec/SKILL.md` |
| Entry skills | starting a run of one kind, then pointing at the hub | `skills/{cycle,micro,debug,revise,status}/SKILL.md` |
| Agents | one task's implementation (`implementer`, Sonnet) and the whole change's review (`reviewer`, Opus) | `agents/*.md` |
| The program | facts the lead should not re-derive: run state, the task graph, worktrees, merges, running checks, the PR | `skills/loop-spec/program/` |

The rule for moving something into the program: it must be deterministic and
repeated, or the lead would have to re-derive it from git every time (which tasks are
ready, where a task's worktree is, whether a verify ran on this head). Anything that
needs judgment (is this criterion good, is this finding blocking, should the plan
change) stays in the skill as guidance.

The program refuses only what would make the record false: a plan that is not a DAG,
a merge that conflicts, finishing a task with uncommitted work, and delivering a head
that verify did not pass (overridable with `--unverified`, which marks the PR draft and
says so). It never judges the model's work.

## Program modules

Each module has one reason to change:

| Module | Owns |
|---|---|
| `cli.py` | the command line: one function per subcommand, and what each prints |
| `runs.py` | a run's directory and files: `state.json` reads and writes, spec and plan reading, the derived phase, the result |
| `dag.py` | the task graph: its problems, ready tasks, waves |
| `git.py` | every `git` and `gh` subprocess call |
| `checks.py` | running a check command and keeping its output tail; which commands verify runs |
| `deliver.py` | the push, the PR, and its body |
| `log.py` | the two output channels (`log.stdout`, `log.stderr`); nothing calls `print` |

State is written only by `runs.Run.save` and `runs.Run.finish`. `spec.json` and
`plan.json` are the lead's files; the program reads them and never writes them. The
phase is derived from the files each time, never stored.

## Why worktrees inside the repository

A run's worktrees live under `<repo>/.loop-spec/runs/<slug>/`, kept out of
`git status` through the repository's own `info/exclude`. Inside the project
directory, Claude Code's default permissions let the lead and the agents write there
without a prompt, and nothing touches the user's own checkout. Each task gets its own
worktree branched from the feature head when it starts, so parallel tasks cannot step
on each other, and `task done` merges it (`--no-ff`) into the feature worktree.

## What 8.x deliberately leaves out

No phase controller, postcondition matrix, transcript attestation, digests binding
products to revisions, or program-issued steps. Those existed in 7.x to catch a model
that skipped or faked work; Opus 5.5 and Sonnet 5.5 verify their own work and report
plainly, and the one guard that matters (deliver only a verified head) stays. See
[docs/models/README.md](models/README.md) for the model behavior this rests on.
