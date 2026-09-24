# loop-spec 7.x architecture

For a contributor or reviewer who wants the shape of 7.x in five minutes. Full
detail: [ROADMAP-7.0.md](ROADMAP-7.0.md).

## The model

SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER (plus `debug` and `revise`) are
interfaces, not scripts. Each one's method is up to its implementation; its
product and the postconditions that product must satisfy are not (sections 2
and 4). A phase's JSON validating against its schema is necessary and never
sufficient: the program checks the claimed exit against the repository first.

## Core and plug-ins

7.x is a microkernel. A small core runs every run. Plug-ins add behaviour through a
contract the core checks, and the core finds each one through a registry. Everything
under `skills/loop-spec/program/loop_spec/` that is not a plug-in below is core. That
covers `controller.py` (the only place a phase transitions), `postconditions.py`,
`contract.py`, `state.py`, `steps.py`, `attest.py`, `questions.py`, `result.py`,
`events.py`, `ledger.py`, `paths.py`, and `entries.py`. It also covers the shared
services `repo.py`, `baseline.py`, `probes.py`, `schema.py`, `render.py`, `jsonio.py`,
`ids.py`, `errors.py`, and `log.py`, plus `defaults.py` and `external.py`, the core side
of the lead and external implementation kinds.

| Plug-in kind | Contract | Registry |
|---|---|---|
| Phase implementation | `context.json` in, `product.json` out, the route matrix's postconditions | `contract.resolve_implementation` chooses the default, an external tool, or a bound skill. `contract.DEFAULT_IMPLEMENTATIONS` names each default adapter (`execute.py`, `verify.py`, `iterate.py`, `debug.py`, `revise.py`, `route.py`, `deliver.py`, and the lead roles for SPEC, PLAN, and DIRECT) |
| Role | `roles/<name>/SKILL.md` + `schema.json` | the `roles/` directory (`roles.ROLE_NAMES`); `contract.resolve_role` binds another skill |
| Runner | `step.json` in, `submit` out | none: whichever process picks up `step.json` (the lead, or `sdk_runner.py`) |
| Entry | an entry name and what it takes (a request or a PR) | `entries.ENTRIES`; the CLI and `controller._ENTRY_START` read it, and the `router` role chooses among its routable entries |

The plug-in rule: a plug-in never imports another plug-in, and it returns the step
contract's types from `steps.py`. The core reads a plug-in's products, not its
private state. Two known deviations remain, as follow-ups:

- The controller still reads plug-in state:
  - `store.state["verify"]` (`_write_terminal_result`);
  - the shared `executeRuns` and `verifyRuns` records;
  - `debug.record_base_runs`, `debug.compact_products`, and `revise.gaps_from_pr`,
    called at entry.

  Fixing this means each phase publishes what the core reads through its product.
- The entry skill stubs (`skills/<entry>/SKILL.md`) each repeat the runner protocol.
  One protocol file that the stubs cite, or stubs generated from it, would remove the
  copies.

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
