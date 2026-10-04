# loop-spec

For a developer installing loop-spec in Claude Code, or running it as the method an
autonomous coding agent follows on the Claude Agent SDK. Use this guide to install
it, start a run, and read the result.

Current version: 8.0.0

## What it is

loop-spec takes a coding request to a verified pull request:

1. **Spec**: a goal and acceptance criteria, each with a command that checks it.
2. **Plan**: the work as a task graph (a DAG): tasks, their dependencies, and the
   tests that check each one.
3. **Execute**: ready tasks run in parallel, each in its own git worktree, and are
   merged into the feature branch as they finish.
4. **Verify**: every check (the spec's, and the ones the repository's `CLAUDE.md` and
   `AGENTS.md` require) run in a clean checkout of the exact commit to be delivered.
5. **Iterate**: a correctness review and a simplification review of the whole verified
   change; a fix sends the run back to verify.
6. **Deliver**: one PR, with anything that moved on origin merged in first. Its
   description follows the repository's PR template, or, when there is none,
   HumanLayer's visual-pr format (a one-sentence why, what a reviewer should know, and a
   visual change outline), with the checked criteria folded below. The run then waits
   for the PR's checks, reads its review comments, and fixes what the change should,
   or answers, until CI passes and reviewers have asked for nothing new. A project can
   add its own review skill to this step.

These are 7.x's phases, and a run announces them exactly as 7.x did: a
`LOOP_SPEC_PHASE_START`/`LOOP_SPEC_PHASE_END` line on stdout per phase change, a
`[PHASE] ...` progress line on stderr, and a record in the run's `events.jsonl`, so
tools that monitor 7.x runs keep working.

The model does the judgment. The method is written as guidance in one skill,
[skills/loop-spec/SKILL.md](skills/loop-spec/SKILL.md), not as gates. A small
standard-library helper keeps the run's state and task graph on disk, manages the
worktrees, runs the checks, opens the PR, and reads its CI. It enforces one rule: only
a commit that passed verify, and contains everything on origin, is delivered, unless
you say otherwise.

It is tuned for Claude Opus 5.5 as the lead and reviewer and Claude Sonnet 5.5 as the
implementer; see [docs/models/README.md](docs/models/README.md).

## Install

Requirements: `git`, `python3` >= 3.11, and for delivery an authenticated GitHub CLI
(`gh auth status`) with an `origin` remote.

From inside Claude Code:

```
/plugin marketplace add aztechead/loop-spec
/plugin install loop-spec@loop-spec-marketplace
```

Coming from 7.x, or staying on it: [docs/migrating-7-to-8.md](docs/migrating-7-to-8.md).

## Use it

| Entry | Argument | Does |
|---|---|---|
| `/loop-spec:cycle` | a request or spec file | the full run, for a feature or change |
| `/loop-spec:micro` | a small, well-defined change | the same run, short: one task, no interview |
| `/loop-spec:debug` | an error, stack trace, or failing test | reproduce at the start commit, fix the cause, keep a regression test |
| `/loop-spec:revise` | a PR number or URL | address its review comments on the PR's own branch |
| `/loop-spec:status` | nothing, or a run's slug | where runs stand |

```
/loop-spec:cycle Add a --json flag to the export command that prints one JSON object per row, with tests
/loop-spec:debug tests/test_parser.py::test_unicode fails with UnicodeDecodeError since 3f2a91c
/loop-spec:revise 42
```

Interactive runs ask the questions that change what gets built, and ask once for
approval of the spec. For a run no one attends, add `--autonomous` to the argument or
set `LOOP_SPEC_MODE=autonomous` in the environment: the run never stops to ask,
records the defaults it chose as assumptions in the spec, and ends with a result
either way.

An autonomous run keeps itself going the way `/goal` does: after each turn loop-spec's
Stop hook checks the run's record, and while the run is open it hands the lead the next
step. There is no turn limit; the run ends when it delivers, or when the lead judges it
blocked and ends it as escalated.

The branch name and PR title follow the repository's own rules in `CLAUDE.md`,
`AGENTS.md`, or `CONTRIBUTING*` (as do commit messages, a PR template, and a changelog
entry). To set them for one run, say so in the request ("on branch feature/KV-12,
titled ..."); that wins over the rules.

```bash
claude -p "/loop-spec:cycle --autonomous Add a --json flag to the export command" \
  --permission-mode acceptEdits --output-format stream-json --verbose > run.jsonl
```

A run is resumable: start the same request again, or run `/loop-spec:status` and
continue from its `next` line.

## Where a run lives

Everything for a run is in `<repo>/.loop-spec/runs/<slug>/`, which loop-spec keeps
out of `git status` through the repository's own exclude file:

| Path | What |
|---|---|
| `spec.json`, `plan.json` | the spec and task graph the lead wrote |
| `state.json` | what the program recorded: base, branch, task status, verify, PR |
| `work/` | the feature branch's worktree, where finished tasks are merged |
| `tasks/<id>/` | one worktree per task in progress |
| `verify/` | the clean checkout verify runs in |
| `result.json` | the final result; once it exists, the run is over |

Your own checkout is never touched. The result is one JSON object: `status`
(`completed`, `no-change`, `escalated`, `failed`), `summary`, `branch`, `prUrl`, and
`verifiedSha`. The program also prints it as a `LOOP_SPEC_RESULT {...}` line.

## Configuration

Optional, in `<repo>/.loop-spec/config.json` (commit it if your team wants it shared):

| Key | Effect |
|---|---|
| `base` | the branch runs start from and PRs target; default origin's default branch |
| `branch` | the feature branch name, for repositories with a naming rule; `-2`, `-3` is added when taken |
| `branchPrefix` | prefix for the default branch name; default `feat/`, `fix/` for debug |
| `reviewers`, `labels` | set on a new PR (it is always assigned to you) |
| `feedback.skills` | skills (`plugin:skill`) the lead runs on the delivered PR, e.g. your own review triage; what they report is handled like review comments |
| `feedback.wait` | `false` to end runs at delivery without waiting for CI or review |

Models: the implementer and simplifier agents run on Sonnet and the reviewer on Opus,
all at medium effort, from their frontmatter in [agents/](agents/). The lead is your session, so run
it on Opus 5.5 for the best plans and reviews.

## On the Agent SDK

[examples/sdk-plugin/](examples/sdk-plugin/README.md) loads loop-spec as a local
plugin in a `ClaudeSDKClient` session and sends `/loop-spec:<entry>`, so an
autonomous coder follows the same method it would in Claude Code. It is a reference,
not a supported surface.

## Docs

| Doc | What it covers |
|---|---|
| [skills/loop-spec/SKILL.md](skills/loop-spec/SKILL.md) | the method itself, and every program command |
| [docs/architecture.md](docs/architecture.md) | how the skills, agents, and program fit together, for a contributor |
| [docs/models/README.md](docs/models/README.md) | what Claude Opus 5.5 and Sonnet 5.5 do differently, and what that means for loop-spec; the source Anthropic docs are copied beside it |
| [docs/migrating-7-to-8.md](docs/migrating-7-to-8.md) | moving from 7.x |
| [CHANGELOG.md](CHANGELOG.md) | what changed in each release |

## Tests

```bash
cd skills/loop-spec/program && python3 -m unittest discover -s tests
```

They cover the program's deterministic Python: the task graph, run state, and the
git flows (worktrees, merges, conflicts, verify, the delivery refusals) against
throwaway repositories. Model behavior is shown by live runs, not simulated.

## License

MIT. The visual-pr description format in
[skills/loop-spec/references/visual-pr/](skills/loop-spec/references/visual-pr/README.md)
is HumanLayer's, also MIT; its license is kept beside it.
