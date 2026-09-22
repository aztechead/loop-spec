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

Each is a thin stub that calls this package's launcher: `skills/loop-spec/program/loop-spec`.

## Where run state lives

State is durable, not conversational: it survives between invocations under
`<state-home>/<repo-id>/<slug>/`, where `<state-home>` is `--state-home`, else
`LOOP_SPEC_HOME`, else `~/.loop-spec/`, and `<repo-id>` identifies the repository. Only
the program writes `state.json`; nothing else should edit it.

## The `LOOP_SPEC_NEXT` protocol

Every controller entry ends its stdout with one line,
`LOOP_SPEC_NEXT {"kind": "step"|"question"|"result", "path": "<file>"}`. Open the file at
`path` and act on it:

- `step`: check `kind` in `step.json`:
  - `lead`: do the work the prompt describes yourself, in this session (you may use
    AskUserQuestion); write the JSON result to `resultPath` (temp file then rename);
    then submit with no `--dispatch`.
  - `role`: dispatch a fresh worker with the `Agent` tool: name = the step attempt id,
    prompt = the step's prompt verbatim, subagent_type `general-purpose`, model only
    when the step carries `model`.
  - `external`: dispatch the named role in the named directory with the composed
    prompt; the worker writes the result file it names.

  Then run
  `loop-spec submit --project-root "{project-root}" --step <stepAttemptId> [--dispatch <name>]`
  and repeat from "read the last stdout line".
- `question`: ask the user the question in `question.json` (with `AskUserQuestion`), then
  run `loop-spec answer --project-root "{project-root}" --question <id> --answer "<text>"`
  and repeat. If you have no way to ask the user (no AskUserQuestion tool, or a
  headless run), stop and print the question file path and its text; the operator
  answers with `loop-spec answer ...` and re-runs this entry with `--slug <slug>` to
  resume.
- `result`: report the result file to the user in the chat shape. Stop.

## Checking a run

`skills/loop-spec/program/loop-spec status --project-root "{project-root}" [--slug "{slug}"]`
is read-only and always exits 0: with `--slug` it prints that run's phase, open
question/step, and result; without it, it lists the runs known for this repository.

## Sibling discovery

Installed siblings are discovered by their `manifest.toml` (`module`, `version`,
`knowledge`) and routed to the knowledge documents that file names, not by hardcoded
paths.
