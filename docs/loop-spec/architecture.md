# loop-spec 7.x architecture

For a contributor or reviewer who wants the shape of 7.x in five minutes. Full
detail: [ROADMAP-7.0.md](ROADMAP-7.0.md).

## The model

SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER (plus `debug` and `revise`) are
interfaces, not scripts. Each one's method is up to its implementation; its
product and the postconditions that product must satisfy are not (sections 2
and 4). A phase's JSON validating against its schema is necessary and never
sufficient: the program checks the claimed exit against the repository first.

## The program, by responsibility

Everything lives under `skills/loop-spec/program/loop_spec/`.

- **Entry and state machine**: `cli.py` (argparse, error boundary),
  `controller.py` (transitions a phase, writes a result).
- **The contract**: `contract.py` (runs one implementation), `external.py`
  (the placeholder, exit/postcondition tables), `defaults.py` (SPEC/PLAN's
  lead dispatch), `roles.py` (a role's prompt and schema).
- **Phase defaults**: `execute.py`, `verify.py`, `iterate.py`, `debug.py`,
  `revise.py` issue one role step at a time; `deliver.py` runs one pass.
- **Checking**: `postconditions.py` (the boundary check, route matrix),
  `budget.py` (the T1 rewind budget).
- **Handoffs**: `steps.py`, `questions.py`, `attest.py` (native transcript
  check), `sdk_runner.py` (a step through the Agent SDK).
- **Records and support**: `state.py`, `paths.py`, `ledger.py`, `result.py`,
  `events.py`, `baseline.py`, `repo.py`, `probes.py`, `schema.py`, `jsonio.py`,
  `ids.py`, `errors.py`, `render.py` (PR body, committed artifacts).

## Implementation kinds and the step seam

A phase is `default` (above) or `external` (a person or tool produces the
whole product; one step, then a wait). A `default` phase's steps can bind
individual *roles* to another skill without changing the contract (sections 5,
8). Either way a worker gets one `step.json` and reports back through
`submit`, never a payload the lead relays (section 9).

## Where state lives

A run's state, worktrees, checkouts, and result live under `<state home>`,
outside the consumer repository, keyed by repo identity and slug (section 12).
Nothing is committed by default; the PR body carries the summary instead.

## The two runners

The default hands a step to the lead, which runs it with the host's own Agent
tool: nothing beyond the standard library, so it is the interactive default.
`sdk_runner.py` has the program spawn the worker itself over
`claude-agent-sdk`, Claude-only with its own credentials, for an unattended
deployment (section 9, [runner-decision-7.0.md](runner-decision-7.0.md)).

## What is deliberately not there

No hooks, no per-harness adapters (opencode, ADK, Codex), no stored code map:
7.x targets Claude Code and the Agent SDK only
([migration-inventory-7.0.md](migration-inventory-7.0.md)).
