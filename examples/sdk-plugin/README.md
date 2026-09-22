# loop-spec as a plugin in a Claude Agent SDK session

For a developer who wants to run loop-spec from Python on the Claude Agent SDK, the
same way Claude Code runs it. When you finish this page you can start any loop-spec
entry from a script, answer its questions from the terminal or by policy, and read
its terminal result.

[`run_loop_spec.py`](run_loop_spec.py) is a reference, not a supported product
surface. It uses only the Agent SDK's documented API
([code.claude.com/docs/en/agent-sdk](https://code.claude.com/docs/en/agent-sdk/))
and imports nothing from loop-spec.

## How it works

The script opens a `ClaudeSDKClient` session with loop-spec loaded as a local plugin
and sends the entry as a slash command, `/loop-spec:cycle <request>`. From there the
plugin's skill runs exactly as in Claude Code: the lead calls the `loop-spec`
launcher, dispatches each worker with the Agent tool, and asks questions with
`AskUserQuestion`.

| Agent SDK feature | What the script does with it |
|---|---|
| `plugins=[{"type": "local", "path": ...}]` | loads this repository as the `loop-spec` plugin |
| init `SystemMessage` | checks `slash_commands` lists `loop-spec:<entry>` before going on |
| `can_use_tool` | answers `AskUserQuestion` from the terminal, or with the first option under `--auto`; allows and logs every other tool |
| `permission_mode="acceptEdits"` | file edits in the project run without prompts |
| `setting_sources=["project"]` | loads the project's settings and `CLAUDE.md`, and keeps your personal `~/.claude` settings and hooks out of the run |
| `thinking={"type": "adaptive", "display": "summarized"}` | the lead's reasoning arrives as `ThinkingBlock`s |
| `forward_subagent_text=True` | workers' text and thinking arrive too, marked by `parent_tool_use_id` |
| `TaskStartedMessage`, `TaskNotificationMessage`, `TaskUpdatedMessage` | the lead runs workers as background tasks, so a turn can end while they work and a new turn starts when one finishes. The script keeps reading `receive_messages()` and stops when a turn ends with no task active and loop-spec's terminal result already printed, or after 60 quiet seconds with no task active |
| `resume=<session id>` | continues a session that stopped |
| `max_budget_usd` | optional spend ceiling |

The terminal result is found from the lead's own tool output: the launcher prints
`LOOP_SPEC_NEXT {"kind":"result","path":...}`, and the script reads that file.

## Structure

- `RunWatch` owns the only stateful decision: whether the session is finished and
  where the result is. Its interface is `observe(message) -> done`, `idle`, and
  `result_path`. [`test_run_loop_spec.py`](test_run_loop_spec.py) tests it through
  that interface, one case per message order a live session produced.
- Question answering is a seam with two adapters, `answer_from_terminal` and
  `answer_first_option`. A service that answers from a queue, chat, or policy
  engine adds a third adapter and passes it to `make_can_use_tool`.
- `render` is the one output adapter and stays a plain function. Replace it to send
  output elsewhere.

```bash
python3 -m unittest examples/sdk-plugin/test_run_loop_spec.py   # needs claude-agent-sdk
```

## Run it

Prerequisites: Python 3.10 or later, `pip install claude-agent-sdk`, `git`, and
`python3` >= 3.11 for the loop-spec program. DELIVER also needs `gh auth status`
and an `origin` remote.

Auth is the SDK's own, in the order the Claude Code docs give: cloud provider
variables, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`),
or a Claude subscription login (run `claude`, then `/login`). Agent SDK use counts
against a Pro, Max, Team, or Enterprise plan
([support article](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)).

```bash
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app \
  "Add a --json flag to the export command, verified by .venv/bin/python -m pytest -q tests/test_export.py"
```

Other entries:

```bash
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --entry micro "Rename retry_count to max_retries"
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --entry debug "tests/test_parser.py::test_unicode fails with UnicodeDecodeError"
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --entry revise 42
```

Unattended, add `--auto`. Every question is then answered with its first option;
for the requirements approval that is `approve`. Read a question's options before
relying on `--auto` for it: a blocked PLAN critic, for example, offers only
`spec gap`. Set loop-spec's
environment variables (`LOOP_SPEC_MODEL_CODE_REVIEWER=haiku`, ...) in the calling
environment; the session passes them to the program.

## Output

stdout carries the lead's text, turn by turn. stderr carries everything else,
prefixed: `[thinking]`, `[tool]`, `[worker]` and `[worker thinking]`, `[allow]` for
each approved tool call, `[question]`, `[task started]` and `[task completed]`, and
the program's own `[PHASE] ...` progress lines and `LOOP_SPEC_` markers as they appear
in tool results. The last stderr lines are the session id, turn count, cost, and the
terminal result's `status`, `result`, `reason`, `prUrl`, and `phaseReached`.

Exit code 0 means the result's `status` was `completed`, and 1 means another terminal
status. Exit code 2 means the session ended without a terminal result. Resume it:

```bash
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --resume <session id>
```

## Compared with the reference supervisor

[`../supervisor/`](../supervisor/README.md) drives the loop-spec program directly
and runs each step as its own SDK query through `loop_spec.sdk_runner`. Choose it
when your service must own every step, for example to route roles to different
infrastructure. Choose this script when you want loop-spec to behave as it does in
Claude Code, with one session and no dependency on loop-spec's Python.
