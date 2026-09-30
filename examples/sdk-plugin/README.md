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
| `plugins=[{"type": "local", "path": ...}]` | loads this repository as the `loop-spec` plugin, and each `--plugin DIR` beside it. Each `--plugin` directory is also named in `LOOP_SPEC_PLUGIN_DIRS`, because a plugin loaded by path is in no registry the program can find it in |
| init `SystemMessage` | checks `slash_commands` lists `loop-spec:<entry>` before going on |
| `can_use_tool` | answers `AskUserQuestion` from stdin (a terminal or piped input), or with the first option under `--auto`; denies and interrupts when neither yields an answer; allows and logs every other tool |
| `permission_mode="acceptEdits"` | file edits in the project run without prompts |
| `setting_sources=["project"]` | loads the project's settings and `CLAUDE.md`, and keeps your personal `~/.claude` settings and hooks out of the run |
| `thinking={"type": "adaptive", "display": "summarized"}` | the lead's reasoning arrives as `ThinkingBlock`s |
| `forward_subagent_text=True` | workers' text and thinking arrive too, marked by `parent_tool_use_id` |
| `ClaudeSDKClient.set_model()` | a lead step (SPEC, PLAN, debug, revise, direct) runs in this session, so when its `LOOP_SPEC_NEXT` names a model (`LOOP_SPEC_MODEL_<ROLE>`, `roles.<role>.model`, or `LOOP_SPEC_PHASE_MODEL_<PHASE>`) the script switches the lead to it, and back to `--model` at the next step that is not a lead step with a model. `--model sonnet` with `LOOP_SPEC_PHASE_MODEL_SPEC=opus LOOP_SPEC_PHASE_MODEL_PLAN=opus` runs SPEC and PLAN on Opus and the rest of the lead on Sonnet. Each switch drops the lead's prompt cache, and the switch can land one API call after the marker. Effort cannot change mid-session, so a lead step's `effort` is not applied |
| `TaskStartedMessage`, `TaskNotificationMessage`, `TaskUpdatedMessage` | the lead runs workers as background tasks, so a turn can end while they work and a new turn starts when one finishes. The script keeps reading `receive_messages()` and stops when a turn ends with no task active and loop-spec's terminal result already printed, or after 60 quiet seconds with no task active |
| `resume=<session id>` | continues a session that stopped |
| `max_budget_usd` | optional spend ceiling |
| `env={...}` | `--phase-model PHASE=MODEL` and `--spec-approval` become `LOOP_SPEC_PHASE_MODEL_<PHASE>` and `LOOP_SPEC_SPEC_APPROVAL` in the session's environment, which the lead's `loop-spec` commands inherit |

The terminal result is found from the lead's own tool output: the launcher prints
`LOOP_SPEC_NEXT {"kind":"result","path":...}`, and the script reads that file.

## Structure

- `RunWatch` owns the only stateful decision: whether the session is finished and
  where the result is, plus the model the current lead step names. Its interface is
  `observe(message) -> done`, `idle`, `lead_model`, and
  `result_path`. [`test_run_loop_spec.py`](test_run_loop_spec.py) tests it through
  that interface, one case per message order a live session produced.
- Question answering is a seam with two adapters, `answer_from_stdin` and
  `answer_first_option`, chosen by `choose_answerer(--auto)`. An adapter returns
  the answer text, or None when it has none. A service that answers from a queue,
  chat, or policy engine adds a third adapter and passes it to `make_can_use_tool`.
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

Without `--auto`, each question is answered from stdin: type a number or a free
answer at the terminal, or pipe answer lines in. A number outside the options is
asked again. When stdin ends, the question is denied and the session stops; resume
it after arranging an answer. Only `--auto` answers for you: every question is then
answered with its first option, which for the requirements approval is `approve`. Read a question's options before
relying on `--auto` for it: a blocked PLAN critic, for example, offers only
`spec gap`. Set loop-spec's
environment variables (`LOOP_SPEC_MODEL_CODE_REVIEWER=haiku`, ...) in the calling
environment; the session passes them to the program.

`--spec-approval policy` answers only the requirements approval, the way 6.x's
default `auto` style skipped that gate; the SPEC interview and every other question
still come to you. A Sonnet lead with SPEC and PLAN on Opus:

```bash
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --model sonnet \
  --phase-model spec=opus --phase-model plan=opus --spec-approval policy \
  "Add a --json flag to the export command, verified by .venv/bin/python -m pytest -q tests/test_export.py"
```

## Use your own plugin in a run

[`pr-helper/`](pr-helper/) is a small example plugin with one skill for each hook:

- `review-context` joins a role's method (`roles.<role>.with`). It records which review
  comments the role acted on as a `D-PR-HELPER` decision and reads its bundled
  `checklist.md` through `${CLAUDE_SKILL_DIR}`.
- `follow-up` acts on the delivered PR (`deliver.after`). It posts one status comment
  and never pushes.

Name them in the project's `.loop-spec/config.json`:

```json
{
  "roles": {"spec-writer": {"with": ["pr-helper:review-context"]},
            "reviser": {"with": ["pr-helper:review-context"]}},
  "deliver": {"after": ["pr-helper:follow-up"]}
}
```

Then load the plugin with `--plugin`:

```bash
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --auto \
  --plugin examples/sdk-plugin/pr-helper "Add septuple(x) to calc returning 7*x, with a test"
```

The spec-writer's and the reviser's prompts carry the skill after their method, with
the checklist's path resolved. When DELIVER opens a PR, the result lists
`pr-helper:follow-up` under `after`, and the lead invokes it on the PR before the
session ends; the final summary prints `after`. Swap in your own plugin the same way.
A skill that pushes, replies to threads, or loops on the PR belongs in
`deliver.after`, never in a role.

## Output

stdout carries the lead's text, turn by turn. stderr carries everything else,
prefixed: `[thinking]`, `[tool]`, `[worker]` and `[worker thinking]`, `[allow]` for
each approved tool call, `[question]`, `[task started]` and `[task completed]`, and
the program's own `[PHASE] ...` progress lines and `LOOP_SPEC_` markers as they appear
in tool results. The last stderr lines are the session id, turn count, cost, and the
terminal result's `status`, `result`, `reason`, `prUrl`, `phaseReached`, and `after`.

Exit code 0 means the result's `status` was `completed`, and 1 means another terminal
status. Exit code 2 means the session ended without a terminal result: an SDK error
(its reason is printed), a question with no answer, or no follow-up turn within 60
seconds. Resume it:

```bash
python3 examples/sdk-plugin/run_loop_spec.py --project-root ~/src/my-app --resume <session id>
```

## Compared with the reference supervisor

[`../supervisor/`](../supervisor/README.md) drives the loop-spec program directly
and runs each step as its own SDK query through `loop_spec.sdk_runner`. Choose it
when your service must own every step, for example to route roles to different
infrastructure. Choose this script when you want loop-spec to behave as it does in
Claude Code, with one session and no dependency on loop-spec's Python.
