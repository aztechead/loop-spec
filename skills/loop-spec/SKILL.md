---
name: loop-spec
description: "Orientation and status for loop-spec 7.x: what the entries are, where run state lives, and how to read a step, question, or result file. Use when a sibling entry stub cannot find the program, or to check the state of a run. Not for running a phase; use the entry skills (cycle, spec, plan, execute, verify, iterate, deliver, debug, micro, revise, status)."
---

# loop-spec 7.x

## Entries

- `cycle` — run a full feature end to end (SPEC through DELIVER).
- `spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` — resume one phase of an
  existing run, identified by `--slug`.
- `debug` — reproduce and fix a specific failure.
- `micro` — make a small, well-defined change in one pass.
- `revise` — address reviewer feedback on an open pull request.
- `status` — show what a run is waiting on.

Each is a thin stub that calls this package's launcher via
`"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec"`.

## Where run state lives

State is durable, not conversational: it survives between invocations under
`<state-home>/<repo-id>/<slug>/`, where `<state-home>` is `--state-home`, else
`LOOP_SPEC_HOME`, else `~/.loop-spec/`, and `<repo-id>` identifies the repository. Only
the program writes `state.json`; nothing else should edit it.

## The `LOOP_SPEC_NEXT` protocol

Every controller entry ends its stdout with a `LOOP_SPEC_NEXT` line (or `LOOP_SPEC_WAIT`)
naming the next file to act on, the run's slug, and the launcher, state home and
project root every follow-up command takes. What to do with each kind of line is in
`${CLAUDE_SKILL_DIR}/references/runner.md`, the one copy every entry stub cites.

## Checking a run

`"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" status --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" [--slug "{slug}"]`
is read-only and always exits 0: with `--slug` it prints that run's phase, open
question/step (including the step's `kind`/`role`, or the question's text and
options), and result; without it, it lists the runs known for this repository.

## Sibling discovery

Each entry's `manifest.toml` names the package (`module`), its `version`, and, under
`knowledge`, the directory of process-contract reference documents
(`skills/loop-spec/references/`).
