# Reference supervisor (Claude Agent SDK)

For the engineer embedding loop-spec 7.x in a Python app on the Claude Agent SDK.
When you finish this page you can run one `loop-spec cycle` to completion under a
supervisor process that drives every step and question itself, with no person in
the loop.

**This is a reference supervisor, not a supported product surface.** Nothing here
is imported by loop-spec, and it carries no compatibility guarantee across
releases. It drives the program directly and imports `loop_spec.sdk_runner`, so it
suits a service that owns every step. To run loop-spec's own skills in an SDK
session instead, the way Claude Code does, start from
[../sdk-plugin/](../sdk-plugin/README.md).

Run live on 7.0.2 with `claude-agent-sdk` 0.2.157 (bundled CLI 2.1.277),
authenticated by a Claude subscription login: one cycle converged and delivered
PR live-7#8, with every step `controller-observed`
([live-runs-7.0.md](../../docs/loop-spec/live-runs-7.0.md)).

## What it does

`supervisor.py` runs `loop-spec cycle` as a subprocess and reads the last
`LOOP_SPEC_NEXT` line (the protocol `skills/loop-spec/SKILL.md` documents) off its
stdout, then acts on it in a loop:

| `LOOP_SPEC_NEXT` kind | What the supervisor does |
|---|---|
| `step`, `kind: "role"` | `loop_spec.sdk_runner.run_step_sdk` runs it through the SDK and writes the result; the worker's text and tool calls are printed to stderr; then `loop-spec submit --step ... --dispatch ...` |
| `step`, `kind: "lead"` | `run_lead_step` runs the same `query()` call with the same `output_format`/`structured_output` contract, but `can_use_tool` answers `AskUserQuestion` instead of denying it; then `loop-spec submit --step ...` |
| `step`, `kind: "external"` | stops and prints the step path; there is no worker to dispatch automatically |
| `question` | `answer_by_policy` answers with the question's own default, else its first option, then `loop-spec answer --scope run` |
| `result` | prints the terminal result and exits 0 (`status: completed`) or 1 |

An EXECUTE wave prints several `LOOP_SPEC_NEXT` lines at once, and every call
re-announces each step still open. `StepQueue` owns that bookkeeping: `add(stdout)`
after every launcher call, `take()` for the next line to act on, each step taken
once. [`test_supervisor.py`](test_supervisor.py) tests it through that interface
(`python3 -m unittest examples/supervisor/test_supervisor.py`; no SDK needed).

`run_step_sdk`'s own `policy` always denies `AskUserQuestion` for a role step (a
worker has no human); the supervisor's `run_lead_step` uses a different
`can_use_tool` for lead steps, since those are meant to interact with one.

## Run it

Prerequisites: Python 3.10 or later, `pip install claude-agent-sdk==0.2.157`
(bundles Claude Code CLI 2.1.277), and `git`. Auth is the SDK's own: a Claude
subscription login (run `claude`, then `/login`), `CLAUDE_CODE_OAUTH_TOKEN` from
`claude setup-token`, `ANTHROPIC_API_KEY`, or a cloud provider's variables. DELIVER
also needs `gh auth status` and an `origin` remote.

```bash
mkdir -p /tmp/demo-app && git -C /tmp/demo-app init -q
python3 examples/supervisor/supervisor.py \
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

stdout carries the program's markers (`LOOP_SPEC_PHASE_START`, `LOOP_SPEC_NEXT`,
`LOOP_SPEC_RESULT`) and ends in one JSON object with `status`, `outcome`, `reason`,
and `phaseReached`. stderr carries the program's `[PHASE]` progress lines as they
happen, and each role step's worker text. Exit code 0 means `status` was
`"completed"`.

## What this example does not do

- It never answers a free-text question with no default and no options; that
  raises, since a fixed policy has nothing sensible to say. A real supervisor
  puts its own logic in `answer_by_policy`.
- It never dispatches an `external`-kind step; that phase needs a person or
  another tool to produce the product.
- It does not show role-step thinking: `run_step_sdk` records worker text and tool
  names only. Lead steps stream text and thinking as they arrive.
