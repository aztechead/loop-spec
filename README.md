# loop-spec

For a developer installing loop-spec in Claude Code, or embedding it in a Python
app on the Claude Agent SDK. Use this guide to install it, run an entry, and read
a result.

Current version: 7.0.0

## Contents

- [What it is](#what-it-is)
- [Install](#install)
- [Use it in Claude Code](#use-it-in-claude-code)
- [How a run proceeds](#how-a-run-proceeds)
- [Configuration](#configuration)
- [Embedding on the Agent SDK](#embedding-on-the-agent-sdk)
- [Reading a result](#reading-a-result)
- [Docs map](#docs-map)
- [Tests](#tests)
- [License](#license)

## What it is

loop-spec turns a feature request into a verified pull request through six
program-checked phases: SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER. A model
does the judgment inside each phase; a small Python program checks the result
against that phase's postconditions before it advances, and refuses a claimed
exit the evidence does not support. Claude Code, driven interactively or with
`claude -p`, is the primary way to run it; the same program also runs unattended
under the Claude Agent SDK, with no Claude Code session at all.

## Install

Requirements: `git`, `python3` >= 3.11, and, for DELIVER, an authenticated GitHub
CLI (`gh auth status`) with an `origin` remote.

Claude Code plugin, from inside a session:

```
/plugin marketplace add aztechead/loop-spec
/plugin install loop-spec@loop-spec-marketplace
```

Agent Skills, for any other harness that reads a `skills/` tree:

```bash
npx skills add aztechead/loop-spec
```

## Use it in Claude Code

Each entry is a skill, invoked as `/loop-spec:<name> <argument>`:

| Entry | Argument | Does |
|---|---|---|
| `/loop-spec:cycle` | a request or spec file | run SPEC through DELIVER on a new feature |
| `/loop-spec:micro` | a small, well-defined change | the same six phases, in one autonomous pass |
| `/loop-spec:debug` | an error report or stack trace | reproduce it, find the cause, land a fix with a regression test |
| `/loop-spec:revise` | a PR number or URL | address reviewer feedback on an already-open PR |
| `/loop-spec:status` | nothing, or a slug | show a run's phase, open question or step, budget, and result |
| `/loop-spec:spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | a slug | resume just that phase of an existing run |

Every entry ends by reading one file (a step, a question, or the terminal
result) and reports back or asks you what it says. Headless, the same entries
run under `claude -p "/loop-spec:cycle <request>"`; a paused run prints a
question and exits, and the next `claude -p` invocation with the same slug
answers it and continues (`loop-spec answer`, in
[references/contract.md](skills/loop-spec/references/contract.md#questions)).

## How a run proceeds

SPEC and PLAN run in your session, asking approval questions as they go — SPEC
for the requirements revision, PLAN's critic pass for any Critical finding.
EXECUTE dispatches an implementer and a reviewer per task, each in its own git
worktree. VERIFY re-runs every criterion's evidence command in a clean checkout
it creates. ITERATE judges the integrated result against your original request,
not just the checklist, and can rewind SPEC, PLAN, EXECUTE, or VERIFY if it finds
a gap. DELIVER pushes the verified SHA and opens or updates one PR.

Run state is durable outside your repository, under `~/.loop-spec/` by default
(`LOOP_SPEC_HOME` to move it, or the plugin's own data directory on Claude Code) —
a killed or restarted session resumes from there instead of starting over.
Nothing is committed to your repository unless `commitArtifacts` is configured
(see below); the SPEC/PLAN/VERIFICATION documents a 6.x run committed are, by
default, rendered into the pull request body instead.

A worker's result file is the one exception: it is written to
`<project root>/.loop-spec/results/<slug>/`, not the state home, because Claude
Code's default permission mode refuses writes under `~/.claude`, where the state
home lives on that host, even with the Write tool allow-listed. `loop-spec`
excludes `.loop-spec/` from `git status` itself, via the repository's own
`.git/info/exclude`, so this is never committed either; `submit` reads a result
written somewhere else with `--result-file <path>`.

## Configuration

Everything below is optional. Project config lives in `.loop-spec/config.json`;
environment variables take precedence over it.

| Key or variable | Effect |
|---|---|
| `phases.<phase>` (config) | bind a phase to `"external"` instead of its default implementation |
| `roles.<role>` (config), `LOOP_SPEC_ROLE_<ROLE>` | bind a role to a skill other than the bundled default |
| `deliver.readiness` (config) | `"checks"` waits on required PR checks before DELIVER finishes |
| `commitArtifacts` (config) | `true` commits rendered SPEC/PLAN/VERIFICATION docs alongside the PR |
| `LOOP_SPEC_HOME` | state home root; default `~/.loop-spec` |
| `LOOP_SPEC_MODEL_<ROLE>` | model for a SPEC or PLAN lead step |
| `LOOP_SPEC_REWIND_BUDGET` | how many backward transitions one run may spend; default 2 |
| `LOOP_SPEC_STEP_RETRIES` | retries before a rejected product asks you to fix and re-enter or stop; default 3 |

The full contract — every field, exit, and environment variable, grounded in the
program's own source — is
[skills/loop-spec/references/contract.md](skills/loop-spec/references/contract.md#configuration-and-environment).

## Embedding on the Agent SDK

[`examples/supervisor/`](examples/supervisor/README.md) is a reference supervisor
that drives one `loop-spec cycle` to completion with no person in the loop,
dispatching each role step through `claude-agent-sdk` 0.2.157 (bundled CLI
2.1.277, Python >= 3.10). It is not a supported product surface, and it has not
been run live: this repository carries no Agent SDK credentials.

## Reading a result

A run's terminal result (schema 1, one JSON object) lands at
`<state home>/<repo id>/<slug>/result.json` and is mirrored to
`<repo id>/last-result.json`. The fields a 6.x consumer already reads keep their
names and meaning; `result` is new, with one of `converged`,
`converged-with-caveats`, `no-change`, `escalated`, `failed`, `paused`. `status`
is `completed`, `paused`, `escalated`, or `failed`; `converged` and
`workDelivered` are booleans; `prUrl` and `delivery` describe what DELIVER
published, when it ran. Full field list:
[references/contract.md](skills/loop-spec/references/contract.md#result).

## Docs map

| Doc | What it covers |
|---|---|
| [docs/loop-spec/ROADMAP-7.0.md](docs/loop-spec/ROADMAP-7.0.md) | why 7.x is shaped this way, milestone by milestone |
| [docs/loop-spec/phase-interface-7.0.md](docs/loop-spec/phase-interface-7.0.md) | the full route matrix and every postcondition's prose |
| [docs/loop-spec/migrating-6-to-7.md](docs/loop-spec/migrating-6-to-7.md) | how-to for a 6.x consumer moving to 7.x |
| [docs/loop-spec/live-runs-7.0.md](docs/loop-spec/live-runs-7.0.md) | which checklist case was shown by which recorded live run |
| [skills/loop-spec/references/contract.md](skills/loop-spec/references/contract.md) | the process contract: files, fields, exit codes, config, environment |
| [examples/supervisor/README.md](examples/supervisor/README.md) | the reference Agent SDK supervisor |
| [llms.txt](llms.txt) | entry map for a model reading this repository |

## Tests

```bash
cd skills/loop-spec/program && python3 -m unittest discover -s tests
```

These cover the program's deterministic Python only: state, contract, routing,
postconditions, schemas. A cycle's actual model-driven behavior is not unit
tested; it is shown by recorded live runs
([docs/loop-spec/live-runs-7.0.md](docs/loop-spec/live-runs-7.0.md)), not simulated.

## License

MIT.
