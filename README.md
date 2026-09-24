# loop-spec

For a developer installing loop-spec in Claude Code, or embedding it in a Python
app on the Claude Agent SDK. Use this guide to install it, run an entry, and read
a result.

Current version: 7.3.0

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
| `/loop-spec:auto` | a request | pick the entry below that fits, or do a mechanical git or PR operation directly with no cycle |
| `/loop-spec:cycle` | a request or spec file | run SPEC through DELIVER on a new feature |
| `/loop-spec:micro` | a small, well-defined change | the same six phases, in one autonomous pass |
| `/loop-spec:debug` | an error report or stack trace | reproduce it, find the cause, land a fix with a regression test |
| `/loop-spec:revise` | a PR number or URL | address reviewer feedback on an already-open PR |
| `/loop-spec:status` | nothing, or a slug | show a run's phase, open question or step, budget, and result |
| `/loop-spec:spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | a slug | resume just that phase of an existing run |

Every entry ends by reading one file (a step, a question, or the terminal
result) and reports back or asks you what it says.

### Examples

```
/loop-spec:cycle Add a --json flag to the export command that prints one JSON object per row, with tests
/loop-spec:cycle docs/specs/rate-limiter.md
/loop-spec:micro Rename the retry_count config key to max_retries everywhere, keeping the old key as a deprecated alias
/loop-spec:debug tests/test_parser.py::test_unicode fails with UnicodeDecodeError on main since 3f2a91c
/loop-spec:revise 42
/loop-spec:auto resolve the merge conflicts on https://github.com/acme/api/pull/42 and push
/loop-spec:status
/loop-spec:verify add-a-json-flag-to-the-export-command
```

Name the verify command in the request when you know it, as one plain command:
`.venv/bin/python -m pytest -q tests/test_export.py`, not `cd tests && pytest`.
The program runs commands with no shell and rejects shell syntax before it runs
anything.

### Headless

The same entries run under `claude -p`. With `--output-format stream-json
--verbose`, the lead's text, thinking, and tool calls arrive on stdout, and the
program's `[PHASE]` progress lines appear in the Bash results it reads:

```bash
claude -p "/loop-spec:cycle <request> [Operator: this is a headless run; pass --answer-policy default on the loop-spec cycle command.]" \
  --permission-mode bypassPermissions --output-format stream-json --verbose > run.jsonl
```

`--answer-policy default` answers every question that has a default, including the
requirements approval. The skills do not add it themselves, so the prompt asks the
lead to. Without it, or for a question with no default, the run stops and the final
message names the question. Answer it with the launcher, passing the plugin's state
home, then resume the session:

```bash
LS=~/.claude/plugins/cache/loop-spec-marketplace/loop-spec/<version>/skills/loop-spec/program/loop-spec
"$LS" answer --project-root . --state-home ~/.claude/plugins/data/<loop-spec data dir> \
  --slug <slug> --question <questionId> --answer approve
claude -p --resume <session id> "The question was answered; continue the run." \
  --permission-mode bypassPermissions --output-format stream-json --verbose >> run.jsonl
```

`ls -d ~/.claude/plugins/data/loop-spec*` shows the data directory. Question
fields and scopes are in
[references/contract.md](skills/loop-spec/references/contract.md#questions).

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
Nothing is committed to your repository: the SPEC/PLAN/VERIFICATION documents a
6.x run committed are rendered into the pull request body instead, and the
delivered head is always the SHA VERIFY passed.

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
| `deliver.acceptRemotePaths` (config) | path globs, e.g. `["CHANGELOG.md"]`: accept a bot's commits on the PR branch that touch only these paths and none of the verified change |
| `LOOP_SPEC_HOME` | state home root; default `~/.loop-spec` |
| `LOOP_SPEC_MODEL_<ROLE>` | model for every dispatch of that role, e.g. `LOOP_SPEC_MODEL_CODE_REVIEWER=haiku` |
| `LOOP_SPEC_REWIND_BUDGET` | how many backward transitions one run may spend; default 2 |
| `LOOP_SPEC_STEP_RETRIES` | retries before a rejected product asks you to fix and re-enter or stop; default 3 |

### Run your own reviewer during VERIFY

Use this when your own review bot should review the change before loop-spec
delivers it, so its findings are fixed in the same run.

1. Write a project skill, `.claude/skills/<name>/SKILL.md`. Its body is a
   code-reviewer prompt that writes a result in the shape of
   [the code-reviewer schema](skills/loop-spec/roles/code-reviewer/schema.json).
2. In that body, have the reviewer run your bot when `inputs.rangeProbes` is
   non-empty. Only VERIFY's review fills it. A revised PR's adopted-range review
   also runs the bound skill, but with an empty `rangeProbes`.
3. Have the reviewer add each bot finding to `findings`, with its `location`,
   `severity`, and `cause`.
4. Bind the role in `.loop-spec/config.json` as `{"roles": {"code-reviewer": "<name>"}}`,
   or set `LOOP_SPEC_ROLE_CODE_REVIEWER=<name>`.

The bound skill also reviews every EXECUTE task, so keep the bot step conditional.
The program validates the skill's result against the bundled schema and routes your
bot's findings the same way as the default reviewer's.

The full contract — every field, exit, and environment variable, grounded in the
program's own source — is
[skills/loop-spec/references/contract.md](skills/loop-spec/references/contract.md#configuration-and-environment).

## Embedding on the Agent SDK

Two reference scripts, neither a supported product surface. Both authenticate the
way the SDK does, including a Claude subscription login.

- [`examples/sdk-plugin/`](examples/sdk-plugin/README.md) loads loop-spec as a
  local plugin in one `ClaudeSDKClient` session and sends `/loop-spec:<entry>`. The
  plugin then runs as it does in Claude Code. It answers questions through
  `can_use_tool` and streams the lead's text to stdout and its thinking, tool calls,
  and workers' output to stderr. Start here.
- [`examples/supervisor/`](examples/supervisor/README.md) drives the loop-spec
  program itself and runs each step as a separate SDK query through
  `loop_spec.sdk_runner`, for a service that must own every step.

Both are run live on 7.0.2; see
[live-runs-7.0.md](docs/loop-spec/live-runs-7.0.md).

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
