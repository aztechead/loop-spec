# loop-spec 8.x architecture

For a contributor changing loop-spec. This page says which part owns what, and why
the line between them sits where it does. The method itself is in
[skills/loop-spec/SKILL.md](../skills/loop-spec/SKILL.md); command details are in
`loop-spec --help`.

## The split

| Part | Owns | Lives in |
|---|---|---|
| The lead (the user's session, or an SDK agent) | every judgment: the spec, the plan, dispatching tasks, reading reports, fixing findings | runs the hub skill |
| The hub skill | the method, as guidance the lead follows: every phase in `SKILL.md`, and what only some runs need (a run kind's changes, the PR template) as references it links, which the program's `next` line names when the run needs them | `skills/loop-spec/SKILL.md`, `skills/loop-spec/references/` |
| Entry skills | starting a run of one kind, then pointing at the hub | `skills/{cycle,micro,debug,revise,status}/SKILL.md` |
| Agents | one task's implementation (`implementer`, Sonnet), the whole change's adversarial review (`reviewer`, Opus), and its cleanup review (`simplifier`, Sonnet) | `agents/*.md` |
| The Stop hook | keeping an autonomous run going until it has a result | `hooks/hooks.json`, `loop_spec/hook.py` |
| The program | facts the lead should not re-derive: run state, the task graph, worktrees, merges, running checks, the PR | `skills/loop-spec/program/` |

The rule for moving something into the program: it must be deterministic and
repeated, or the lead would have to re-derive it from git every time (which tasks are
ready, where a task's worktree is, whether a verify ran on this head). Anything that
needs judgment (is this criterion good, is this finding blocking, should the plan
change) stays in the skill as guidance.

The program refuses only what would make the record false: a spec without a goal or
usable criteria, a plan that is not a DAG or names a criterion the spec lacks, a merge
that conflicts, finishing a task with uncommitted work, delivering a head that verify
did not pass (overridable with `--unverified`, which marks the PR draft and says so),
a `pr.md` that still holds the template's placeholder lines, and delivering a head
that lacks commits origin has. It also checks `gh` before pushing, so a delivery that
cannot open its PR changes nothing. Each refusal names what to fix. Where a fact only
predicts trouble (two parallel tasks listing the same file), it warns instead. It
never judges the model's work. No loop has a cap: whether a loop should stop is a judgment, and the
lead records it with `finish`.

## Program modules

Each module has one reason to change:

| Module | Owns |
|---|---|
| `cli.py` | the command line: one function per subcommand, and what each prints |
| `runs.py` | a run's directory and files: `state.json` reads and writes, spec and plan reading, the derived phase, the result |
| `dag.py` | the task graph: its problems, and which tasks are ready or waiting |
| `git.py` | every `git` and `gh` subprocess call |
| `checks.py` | running a check command and keeping its output tail; which commands verify runs |
| `deliver.py` | the push, the PR, which template its description follows, and the folded verification below it |
| `remote.py` | what moved on origin, and merging it into the feature branch |
| `ci.py` | reading a PR's checks and a failed job's log |
| `review.py` | reading a PR's reviews and comments |
| `phases.py` | the phase stream monitors read: 7.x's `LOOP_SPEC_PHASE_*` markers, `[PHASE]` lines, `events.jsonl` records, and the result's `LOOP_SPEC_RESULT`/`LOOP_SPEC_NEXT` lines |
| `legacy.py` | what 7.x hosts read outside the repository: the state home, 7.x's repo id, the schema-1 result built from a run, and its copies there |
| `hook.py` | the Stop hook's decision: continue the run with its next step, or let the stop through |
| `log.py` | the two output channels (`log.stdout`, `log.stderr`); nothing calls `print` |

`state.json` is written only by `runs.Run.save`, and `result.json` only by `runs.Run.finish` (the run's copy) and `legacy.publish` (the state home's). `spec.json` and
`plan.json` are the lead's files; the program reads them and never writes them. The
phase is derived from the files each time; the only phase stored is the one the stream last announced, so it can announce each change once.

## Why worktrees inside the repository

A run's worktrees live under `<repo>/.loop-spec/runs/<slug>/`, kept out of
`git status` through the repository's own `info/exclude`. Inside the project
directory, Claude Code's default permissions let the lead and the agents write there
without a prompt, and nothing touches the user's own checkout. Each task gets its own
worktree branched from the feature head when it starts, so parallel tasks cannot step
on each other, and `task done` merges it (`--no-ff`) into the feature worktree.
`verify` runs in one more worktree, `verify/`, reset to exactly the head's tracked
files before each run (`checkout --force` and `clean -ffd`). Ignored files such as
installed dependencies survive between verifies, so `prepare` is incremental.

## The loops

Three loops run inside a run. Each has an objective exit and none has a cap; the lead
ends one it judges cannot finish with `finish --status escalated`:

- **Verify:** fix and verify again until every check passes at the current head.
- **Feedback:** after delivery, `feedback` waits for the PR's checks and reads its review;
  what the change should fix is fixed, verified, and delivered again, and the rest is
  answered, until CI passes and nothing new has come in.
- **The run itself (autonomous only):** the Stop hook works like `/goal`. After each
  turn it checks the run's record: a result means the condition is met and the turn
  ends; an open run gets its next step as the reason for another turn. It lets a turn
  end when the lead says it is waiting on agents (`LOOP_SPEC_WAITING`), the way `/goal`
  skips evaluation while background work runs, and notes when the record has not
  changed for a few turns. Claude Code's own block cap stops a lead that keeps
  answering without using a tool.

## What 8.x deliberately leaves out

No phase controller, postcondition matrix, transcript attestation, digests binding
products to revisions, or program-issued steps. Those existed in 7.x to catch a model
that skipped or faked work; Opus 5.5 and Sonnet 5.5 verify their own work and report
plainly, and the one guard that matters (deliver only a verified head) stays. See
[docs/models/README.md](models/README.md) for the model behavior this rests on.
