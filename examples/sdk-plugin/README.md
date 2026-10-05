# loop-spec as a plugin in a Claude Agent SDK session

For a developer running loop-spec from Python on the Claude Agent SDK, for example as
the method an autonomous coding agent follows. When you finish this page you can start
any entry from a script, run it attended or unattended, and read its result.

[`run_loop_spec.py`](run_loop_spec.py) is a reference, not a supported product
surface. It uses only the Agent SDK's documented API
([code.claude.com/docs/en/agent-sdk](https://code.claude.com/docs/en/agent-sdk/)) and
imports nothing from loop-spec.

## How it works

The script opens a `ClaudeSDKClient` session with this repository loaded as a local
plugin and sends `/loop-spec:<entry> <request>`. With `--autonomous` it also sets
`LOOP_SPEC_MODE=autonomous` in the session's environment, which the loop-spec program
reads on every call, so the run never stops to ask. From there the plugin runs exactly
as in Claude Code: the lead follows the loop-spec skill, calls the
program, and dispatches the `loop-spec:implementer` and `loop-spec:reviewer` agents.

| Agent SDK feature | What the script does with it |
|---|---|
| `plugins=[{"type": "local", "path": ...}]` | loads loop-spec, and each `--plugin DIR` |
| init `SystemMessage` | checks `slash_commands` lists `loop-spec:<entry>` |
| `can_use_tool` | allows and logs every tool; with `--autonomous`, declines `AskUserQuestion` with "choose the reasonable default and continue", otherwise (attended or `--supervised`) answers it from stdin |
| `permission_mode="acceptEdits"`, `setting_sources=["project"]` | edits run without prompts; the project's settings and `CLAUDE.md` load, your personal `~/.claude` ones do not |
| `thinking={"type": "adaptive", "display": "summarized"}`, `forward_subagent_text=True` | the lead's and the agents' reasoning and text arrive on stderr |
| `receive_messages()` and task messages | workers run as background tasks, so a turn can end while they work; the script keeps reading until a turn ends with no task running and the result seen, or 60 quiet seconds pass |
| `resume=<session id>` | continues a session that stopped |
| `max_budget_usd` | optional spend ceiling |
| `set_model()` | with `--phase-model PHASE=MODEL`, switches the lead's model from PHASE on, read from the run's `events.jsonl`; a resumed session lands on the right model |

The run is over when the program prints `LOOP_SPEC_RESULT {...}` and then
`LOOP_SPEC_NEXT {"kind":"result","path":...}`, as 7.x did; the script reads the result
file that line names, or, when the lead's own command cut that line, the copy in the run's
directory.

## Run it

Prerequisites: Python 3.10 or later, `pip install claude-agent-sdk`, `git`, `python3`
>= 3.11, and for delivery `gh auth status` with an `origin` remote. Auth is the SDK's
own (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, a cloud provider's variables, or a
Claude subscription login).

```bash
# unattended: never stops to ask; records its defaults as assumptions
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --autonomous \
  --model opus --phase-model execute=sonnet \
  "Add a --json flag to the export command, verified by .venv/bin/python -m pytest -q tests/test_export.py"

# attended: questions are asked on stdin (a number picks an option; text is a free answer)
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --entry debug \
  "tests/test_parser.py::test_unicode fails with UnicodeDecodeError"

python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --entry revise --autonomous 42
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --resume <session id>
```

`--model opus --phase-model execute=sonnet` is the recommended setup: Opus writes the spec
and plan, where a wrong call costs the most, then Sonnet leads execution, verification,
the CI and review rounds, and later revisions. Switch once: the prompt cache is per
model, so each switch starts the new model's context cold, and switching back to Opus
for delivery costs more than running Opus throughout.

stdout carries the lead's text; stderr carries thinking, tool calls, worker output,
`LOOP_SPEC_*` lines, and per-turn cost, then the result's `status`, `summary`, `prUrl`,
and `verifiedSha`. Exit code 0 means `completed`, 1 another status, and 2 no result in
this session (resume it).

```bash
python3 -m unittest examples/sdk-plugin/test_run_loop_spec.py   # needs claude-agent-sdk
```
