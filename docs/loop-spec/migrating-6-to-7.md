# Migrating a 6.9 setup to loop-spec 7

How-to for a person or agent that runs loop-spec 6.9 today, in Claude Code or from a
script, and wants the same work running on 7.x. Follow the sections in order; each
ends with a check you can run. Sections 1 to 5 apply to everyone. Section 6 is for a
script or service that drove 6.9 itself, and section 7 is for unattended runs. Why
7.x is shaped this way is in [ROADMAP-7.0.md](ROADMAP-7.0.md); the full
surface-by-surface mapping is [migration-inventory-7.0.md](migration-inventory-7.0.md).

Applies to 7.0.2. Every name, flag, and path below is the shipped one.

## Before you start

- 7.x runs on Claude Code (interactive or `claude -p`) and on the Claude Agent SDK.
  The opencode, Google ADK, and Codex trees are gone. Another agent can install the
  skills with `npx skills add`, but only Claude Code and the SDK are tested.
- Finish or abandon any 6.9 run in flight. 7.x does not read a 6.9 `feature.json`.
- Keep the 6.9 plugin installed until the check at the end of section 4 passes. The
  `6.x` branch stays available for rollback.
- The requirements are `git`, `python3` >= 3.11, and, for DELIVER, an authenticated
  `gh` with an `origin` remote. Nothing else is installed.

## 1. Install and find the launcher

In Claude Code:

```
/plugin marketplace add aztechead/loop-spec
/plugin install loop-spec@loop-spec-marketplace
```

For a skills-only install: `npx skills add aztechead/loop-spec`. 7.x ships no hook,
no agents, and no MCP config.

The skills call one launcher, `skills/loop-spec/program/loop-spec`. It is not put on
`PATH`. A script calls it by path, either from a checkout of this repository pinned to
a release tag or from the installed plugin
(`ls ~/.claude/plugins/cache/loop-spec-marketplace/loop-spec/*/skills/loop-spec/program/loop-spec`).
This page writes it as `$LS`:

```bash
LS=/path/to/loop-spec/skills/loop-spec/program/loop-spec
"$LS" --version
```

Check: `"$LS" status --project-root <repo>` prints `no loop-spec state for <repo>`,
or one slug per line if a 7.x run already exists there.

## 2. Move your invocations

| You ran in 6.9 | Run in 7.x |
|---|---|
| `/loop-spec:cycle <text or spec file>` | `/loop-spec:cycle <text or spec file>`, unchanged |
| `/loop-spec:spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | same names; each checks its preconditions against state and refuses to run out of order |
| `/loop-spec:debug` | unchanged |
| `/loop-spec:micro` | `/loop-spec:micro`; the `on`, `off`, and `status` modes are gone |
| `/loop-spec:intake <file>` | `/loop-spec:cycle <file>` |
| `/loop-spec:pause` | nothing to run; every run resumes from state, and `status` shows the pending question |
| `/loop-spec:revise <pr>` | `/loop-spec:revise <n-or-url>`. It compacts the PR's review gaps into SPEC and PLAN and runs the cycle forward. EXECUTE reviews the PR's existing commits once before its own tasks |
| `/loop-spec:status` | unchanged |
| `/loop-spec:auto`, `oneshot`, `spec-lite` | removed; name the entry you want, `micro` for a small change |
| `assess`, `sentinel`, `watch`, `retro`, `rules`, `forensics`, `walkthrough`, `quality-loop`, `checking-gates`, `specifying-gates`, `onboard`, `settings`, `rollback`, `loop-runner` | removed; see the inventory for what, if anything, replaces each |

From a script, the same entries are launcher subcommands, each with
`--project-root <repo>`: `"$LS" cycle` and `micro` take `--request <text>` or
`--request-file <path>`, `debug` takes `--request`, `revise` takes `--pr <n-or-url>`,
and `status` and the phase entries take `--slug`. Section 6 covers what to do with
their output.

Check: each entry you still use appears in the table's right column.

## 3. Move your environment variables into config or flags

Most `LOOP_SPEC_*` variables are gone. What remains is optional project config in
`.loop-spec/config.json` in the consumer repository, a few environment variables, and
entry flags. An empty config is valid:

```json
{
  "phases": {},
  "roles": {}
}
```

`prepare` is no longer a config key. PLAN's own product carries a `prepare` command,
written by the planner and applied before every baseline capture and re-verification.

| 6.9 variable | 7.x |
|---|---|
| `LOOP_SPEC_MODEL_<ROLE>` | kept: sets the model for every dispatch of that role (`SPEC_WRITER`, `CODE_REVIEWER`, ...), overriding `roles.<role>.model` in config |
| `LOOP_SPEC_CMD_PREPARE`, `LOOP_SPEC_CMD_TEST`, `_LINT`, `_TYPECHECK` | removed; PLAN names each task's `verify` command and the plan's `prepare` command. Nothing is detected from manifests |
| `LOOP_SPEC_ARTIFACTS_IN_PR` | nothing; the rendered documents go into the PR body and the state home, never into a commit (a docs commit after VERIFY would deliver a head VERIFY never saw) |
| `LOOP_SPEC_NON_INTERACTIVE` | nothing; a question ends the entry with a `question` file to answer (section 6) |
| `LOOP_SPEC_AUTONOMOUS` | `--answer-policy default` at entry, or `--scope run` on any answer |
| `LOOP_SPEC_ITERATE_MAX_ITERATIONS` | `LOOP_SPEC_REWIND_BUDGET` (the shared T1 budget's limit; default 2) |
| `LOOP_SPEC_REDO_MAX`, `LOOP_SPEC_RALPH_THRESHOLD` | `LOOP_SPEC_STEP_RETRIES` (per-phase retry limit; default 3) |
| `LOOP_SPEC_CHECKS_*`, `LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS` | `deliver.readiness`/`deliver.base` in config; no configurable timeout in this release |
| `LOOP_SPEC_WORKTREES`, `LOOP_SPEC_WORKTREE_DIR` | removed; worktrees live in the state home |
| `LOOP_SPEC_CREDENTIAL_REFRESH_*` | removed; DELIVER checks credentials before its first push and exits `delivery blocked` if they fail |
| `LOOP_SPEC_HARNESS`, `LOOP_SPEC_TEAMS_MODE`, `LOOP_SPEC_EXECUTE_WORKFLOW`, every `*_GUARD` | removed |

Anything not listed here is in the inventory's environment table, each with its fate.

Commands the program runs are now checked for form. PLAN `verify` and `prepare`, a
debug reproduction, and VERIFY evidence run as argv with no shell. A command using
`&&`, a pipe, a redirect, `$VAR`, or an unquoted glob is rejected before it runs,
with a reason naming the task. If your requests dictate verify commands, write one
plain command each (`.venv/bin/python -m pytest -q tests/test_x.py`, not
`cd tests && pytest`). The rules are under "Commands" in
[phase-interface-7.0.md](phase-interface-7.0.md).

Check: `grep -rho 'LOOP_SPEC_[A-Z_]*' your-harness/ | sort -u` lists only names in the
environment table of
[contract.md](../../skills/loop-spec/references/contract.md#configuration-and-environment)
or the markers in section 6.

## 4. Move the state you read

| 6.9 location | 7.x location |
|---|---|
| `docs/loop-spec/features/<slug>/feature.json` | `<state home>/<repo id>/<slug>/state.json`, program-written only |
| `docs/loop-spec/features/<slug>/*.md` | rendered into the PR body and kept in the state home; never committed |
| `.loop-spec/last-result.json` | `<state home>/<repo id>/last-result.json`, shared by every slug for that repository |
| `.loop-spec/events.jsonl` | `<state home>/<repo id>/<slug>/events.jsonl` |
| `refs/loop-spec/state/<slug>` | not available in 7.0 |

The state home resolves in this order: `--state-home`, else `$LOOP_SPEC_HOME`, else
`~/.loop-spec/`. The Claude Code skills pass `--state-home ${CLAUDE_PLUGIN_DATA}`,
which is a directory under `~/.claude/plugins/data/` (`ls -d ~/.claude/plugins/data/loop-spec*`).
A script that inspects or answers a run started in Claude Code must pass that same
path as `--state-home`. With the default it looks in `~/.loop-spec/` and finds
nothing.

`.loop-spec/` still appears in your repository, for a different reason. It holds only
workers' result files, under `.loop-spec/results/<slug>/`, because Claude Code's
default permission mode refuses writes under `~/.claude`. The program adds
`.loop-spec/` to `.git/info/exclude`, so it never shows in `git status` and is never
committed.

Check: after one `micro` run, `state.json` and `last-result.json` exist under the
state home and `git status` in the consumer repository is clean.

## 5. Update your result consumer

The terminal result keeps schema 1: every existing field keeps its name and meaning,
and the object allows extra fields. One field is added, `result`, with one of
`converged`, `converged-with-caveats`, `no-change`, `escalated`, `failed`, `paused`.
Read `result` for the 7.x classification and keep reading `converged` for what 6.9
meant by it. `status` is `completed`, `paused`, `escalated`, or `failed`. A `paused`
result is not mirrored to `last-result.json`, since the run can still resume.

Field list: [contract.md, Result](../../skills/loop-spec/references/contract.md#result).
Real results from recorded runs are under [live-runs/7.0/](live-runs/7.0/).

Check: your consumer parses
[live-runs/7.0/e2e-workspace-7.0.2/result.json](live-runs/7.0/e2e-workspace-7.0.2/result.json)
and does not fail on a field it does not know.

## 6. If a script or service drove 6.9

In 6.9 a harness intercepted `AskUserQuestion` or set `LOOP_SPEC_NON_INTERACTIVE`. In
7.x every launcher call runs until the next point that needs something from outside,
prints what that is, and exits 0. A non-zero exit is an error, and stderr carries the
message and a `repair:` hint.

Drive a run with this loop:

1. Start it: `"$LS" cycle --project-root <repo> --request "<text>"` (add
   `--state-home <dir>` and `--answer-policy default` as needed).
2. Read every line of stdout that starts with `LOOP_SPEC_NEXT `, in order. Each is
   followed by JSON: `{"kind": "step"|"question"|"result", "path": ..., "slug": ...}`.
   Keep the `slug`; every later call needs `--slug`.
3. For each `step`, open `path` (`step.json`) and complete it:
   - `kind: "role"`: run a fresh worker on `prompt` verbatim, with `model` when the
     step names one. The worker writes its JSON result to `resultPath`. Then run
     `"$LS" submit --project-root <repo> --slug <slug> --step <stepAttemptId> --dispatch <stepAttemptId>`.
   - `kind: "lead"`: do the work in your own session and write the result to
     `resultPath`, then submit without `--dispatch`.
   - `kind: "external"`: a person or another tool produces the product; nothing can
     be automated here.
4. For a `question`, open `path` (`question.json`), choose a value from `options`
   (or `defaultValue`), and run
   `"$LS" answer --project-root <repo> --slug <slug> --question <questionId> --answer <value>`.
   Add `--scope run` to let the default policy answer every later question that has
   a default.
5. Each `submit` and `answer` prints the next `LOOP_SPEC_NEXT` lines. Repeat from
   step 2 until the kind is `result`, then read `result.json` at `path`.

Three behaviors break a "read the last line" driver:

- An EXECUTE wave issues up to `LOOP_SPEC_EXECUTE_WIDTH` steps at once (default 3),
  one `LOOP_SPEC_NEXT` line each. Dispatch all of them.
- Every call re-announces each step that is still open, including steps you already
  dispatched and have not submitted yet. Track the `stepAttemptId`s you have
  dispatched and skip them; submitting one step twice is refused with
  `a different result was already submitted`. A submit inside EXECUTE can instead
  print `LOOP_SPEC_WAIT {"open": [...]}` and no `LOOP_SPEC_NEXT`; keep submitting the
  steps you hold.
- A submit can answer `unattested` with a new `LOOP_SPEC_NEXT` for the same step.
  The stdout line before it names a new dispatch name, `<stepAttemptId>-<n>`. Run a
  fresh worker on the same prompt and submit with `--dispatch` set to that name.
  This happens only under a Claude Code host, which attests its own dispatches.

The other stdout markers are `LOOP_SPEC_PHASE_START`, `LOOP_SPEC_PHASE_END`,
`LOOP_SPEC_QUESTION` (new in 7.x), and `LOOP_SPEC_RESULT`, all unchanged in form and
all also written to `events.jsonl`. Progress lines (`[PLAN] ...`) go to stderr;
`LOOP_SPEC_CONSOLE_STREAM=stdout` moves them, and `LOOP_SPEC_CONSOLE_EVENTS=0`
silences them.

[examples/supervisor/supervisor.py](../../examples/supervisor/supervisor.py)
implements this loop on the Agent SDK. It is a reference, not a supported surface.

Check: your driver completes a run whose plan has two independent tasks. That is the
case that issues two `LOOP_SPEC_NEXT` lines together.

## 7. If you run unattended

There are two paths. Pick by where the worker sessions run.

**Headless Claude Code.** Run the skill under `claude -p` with a permission mode that
allows edits (the recorded runs use `--permission-mode bypassPermissions`), and tell
the lead in the prompt to pass `--answer-policy default`:

```bash
claude -p "/loop-spec:cycle <request> [Operator: this is a headless run; pass --answer-policy default on the loop-spec cycle command.]" \
  --permission-mode bypassPermissions --output-format stream-json --verbose
```

The lead then auto-approves every question that has a default, including the
requirements approval. A question with no default still stops the run. Answer it
with `"$LS" answer` (section 6, with the plugin's `--state-home`), then continue with
`claude -p --resume <session id> "The question was answered; continue the run."`.
`--output-format stream-json --verbose` puts the lead's text, thinking, and tool
calls on stdout. This path is the one the recorded live runs use.

**Agent SDK.** Two reference scripts, both run live on 7.0.2 with a Claude
subscription login. Auth is the SDK's own: a subscription login,
`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`, `ANTHROPIC_API_KEY`, or a cloud
provider's variables. The program never switches an interactive user to the SDK.

- [examples/sdk-plugin/](../../examples/sdk-plugin/README.md) loads loop-spec as a
  local plugin in one SDK session and sends `/loop-spec:<entry>`, so the run behaves
  as it does under `claude -p`. `--auto` answers questions with their first option.
  Start here.
- [examples/supervisor/](../../examples/supervisor/README.md) is the section 6 loop
  on the SDK: it drives the launcher and runs each step as its own SDK query.

Issue-to-PR wiring is no longer shipped; compose it around either script.

Check: one headless run on a scratch repository ends with a `result.json` whose
`status` is `completed` and a PR at the verified head, with no prompt answered by
hand.

## Roll back

Reinstall the 6.9 plugin from the `6.x` branch. That changes the installed tool only.
6.9 ignores the 7.x state home, so leave it in place if a run may resume later. Work
7.x delivered is ordinary git history: feature branches, pushed commits, and PRs stay
where they are. Inspect `git branch`, the remote, and open PRs before deciding what
to keep. The rendered SPEC and VERIFICATION documents are not in the repository; read
them from the PR body or the state home.
