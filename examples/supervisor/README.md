# Reference supervisor (Claude Agent SDK)

For the engineer embedding loop-spec 7.x in a Python app on the Claude Agent SDK.
When you finish this page you can run one `loop-spec cycle` to completion under a
supervisor process that drives every step and question itself, with no person in
the loop.

**This is a reference supervisor, not a supported product surface.** Nothing here
is imported by loop-spec, and it carries no compatibility guarantee across
releases. **It has not been run live**: this repository has no Claude Agent SDK
credentials, so `supervisor.py` is grounded from the installed package's source
and the SDK docs, not from a real run's output.

## What it does

`supervisor.py` runs `loop-spec cycle` as a subprocess and reads the last
`LOOP_SPEC_NEXT` line (the protocol `skills/loop-spec/SKILL.md` documents) off its
stdout, then acts on it in a loop:

| `LOOP_SPEC_NEXT` kind | What the supervisor does |
|---|---|
| `step`, `kind: "role"` | `loop_spec.sdk_runner.run_step_sdk` runs it through the SDK and writes the result; then `loop-spec submit --step ... --dispatch ...` |
| `step`, `kind: "lead"` | `run_lead_step` runs the same `query()` call with the same `output_format`/`structured_output` contract, but `can_use_tool` answers `AskUserQuestion` instead of denying it; then `loop-spec submit --step ...` |
| `step`, `kind: "external"` | stops and prints the step path; there is no worker to dispatch automatically |
| `question` | `answer_by_policy` answers with the question's own default, else its first option, then `loop-spec answer --scope run` |
| `result` | prints the terminal result and exits 0 (`status: completed`) or 1 |

`run_step_sdk`'s own `policy` always denies `AskUserQuestion` for a role step (a
worker has no human); the supervisor's `run_lead_step` uses a different
`can_use_tool` for lead steps, since those are meant to interact with one.

## Run it

Prerequisites: Python 3.10 or later, `pip install claude-agent-sdk==0.2.157`
(bundles Claude Code CLI 2.1.277), provider auth in the environment
(`ANTHROPIC_API_KEY`, or Bedrock/Vertex/Foundry env vars), and `git`. DELIVER also
needs `gh auth status` and an `origin` remote.

```bash
mkdir -p /tmp/demo-app && git -C /tmp/demo-app init -q
ANTHROPIC_API_KEY=... python3 examples/supervisor/supervisor.py \
  --project-root /tmp/demo-app \
  --request "a Python CLI that prints the n-th Fibonacci number, with tests" \
  --model haiku
```

Resume a run that stopped (an `external` step, or a crash) instead of starting a
new one. Find the slug with
`skills/loop-spec/program/loop-spec status --project-root /tmp/demo-app` (it lists
every run known for that project), or read it from a prior run's own
`LOOP_SPEC_NEXT` output:

```bash
python3 examples/supervisor/supervisor.py --project-root /tmp/demo-app --slug a-python-cli-that-prints
```

Success looks like `loop-spec`'s own phase and event lines, interleaved with this
script's own `submit`/`answer` calls, ending in one JSON object with `status`,
`outcome`, `reason`, and `phaseReached`; exit code 0 means `status` was
`"completed"`.

## What this example does not do

- It never answers a free-text question with no default and no options; that
  raises, since a fixed policy has nothing sensible to say. A real supervisor
  puts its own logic in `answer_by_policy`.
- It never dispatches an `external`-kind step; that phase needs a person or
  another tool to produce the product.
- The `updated_input`/`answers` shape `run_lead_step` returns for
  `AskUserQuestion` is confirmed against
  [docs.claude.com/en/agent-sdk/user-input](https://docs.claude.com/en/agent-sdk/user-input)
  ("Handle approvals and user input"), not against a real run of this file.
