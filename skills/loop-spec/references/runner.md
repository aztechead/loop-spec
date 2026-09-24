# Runner protocol

For the lead running a loop-spec entry stub (`skills/<entry>/SKILL.md`). This file
covers each line the program prints after the stub's own start command, and what
you do about it. Every stub cites this file, and it is the only copy of the protocol.

## The loop

1. Read the last stdout line.
2. Act on it as its marker and kind say below.
3. Every action ends with a `submit` or `answer` command, and those commands print a
   new last line. Go back to step 1. The only exceptions are `result`, `external`, a
   question you cannot ask, and a non-zero exit, where you stop.

## Markers

### `LOOP_SPEC_NEXT`

```
LOOP_SPEC_NEXT {"kind": ..., "path": ..., "slug": ..., "program": ..., "stateHome": ..., "projectRoot": ...}
```

| Field | Use |
|---|---|
| `kind` | `step`, `question` or `result`. It selects the section below. |
| `path` | The file to open. A role step is the exception (see `role`). |
| `slug` | Pass as `--slug <slug>` on every `submit` and `answer`. Both commands require it, and this marker is the only place a stub learns it. |
| `program`, `stateHome`, `projectRoot` | Fill `<program>`, `<stateHome>` and `<projectRoot>` in every command below. |
| `stepKind` | On a `step`: `lead`, `role` or `external`. It is the same `kind` as in `step.json`. |
| `stepAttemptId` | On a `step`: the step's id, for `--step`, and for a role step also the worker's name and `--dispatch`. |
| `dispatchPath` | On a role step with file transport: the file whose exact text is the worker's prompt. Absent otherwise. |
| `subagentType` | On a role step: `general-purpose`, or `loop-spec:worker-<level>` for a step with a configured effort. |
| `role` | On a `step`: the role name, or null. |
| `model` | On a `step`: the worker's model, or null for none. |
| `effort` | On a `step`: the configured effort, or null. `subagentType` already reflects it. |

Several `LOOP_SPEC_NEXT` lines of kind `step` at once mean a wave. Dispatch every one
of them in the same `Agent` tool message so they run concurrently, each under its own
`stepAttemptId`. Submit each one as it returns.

### `LOOP_SPEC_WAIT`

```
LOOP_SPEC_WAIT {"open": ["<stepAttemptId>", ...]}
```

This line takes the place of `LOOP_SPEC_NEXT`. The run is waiting on steps you
already dispatched. Submit them, and do not start anything new. The line also
carries `program`, `stateHome` and `projectRoot`.

## Commands

Submit a lead or external step:

```
"<program>" submit --project-root "<projectRoot>" --state-home "<stateHome>" --slug <slug from LOOP_SPEC_NEXT> --step <stepAttemptId>
```

Submit a role step. `--dispatch` is the name you gave the `Agent`:

```
"<program>" submit --project-root "<projectRoot>" --state-home "<stateHome>" --slug <slug from LOOP_SPEC_NEXT> --step <stepAttemptId> --dispatch <stepAttemptId>
```

Answer a question:

```
"<program>" answer --project-root "<projectRoot>" --state-home "<stateHome>" --slug <slug from LOOP_SPEC_NEXT> --question <id> --answer "<text>"
```

A result file belongs under the project's `.loop-spec/results/`. It never goes under
`~/.claude`, where the state home lives and a default permission mode refuses writes.
If a result landed somewhere else, add `--result-file <path>` to `submit`, and the
program reads it from there.

## `step`

### `lead`

1. Do the work the prompt describes yourself, in this session. You may use
   AskUserQuestion.
2. Write the JSON result to `resultPath`: write a temp file, then rename it.
3. Run the lead `submit` command, without `--dispatch`.

### `role`

1. Dispatch a fresh worker with the `Agent` tool:
   - name: the step attempt id (`stepAttemptId`);
   - prompt: the exact text of the file at the marker's `dispatchPath` (the step's
     `dispatchPrompt`). With no `dispatchPath`, the `prompt` in `step.json`, verbatim;
   - subagent_type: the marker's `subagentType`. The program checks the agent type
     that ran;
   - model: only when the marker's `model` is not null.
2. The worker's prompt names its own `resultPath`.
3. Run the role `submit` command.

The program checks three things about the worker's transcript: it opens with exactly
the dispatched text, the worker read the whole instruction file it names, and it ends
with the result digest. Any rewording, prefix or summary makes the step `unattested`,
and an unattested review does not count.

If `submit` answers that the step is unattested and names a new dispatch name,
dispatch a fresh worker under that exact name. Use the same `subagent_type` and the
same dispatch text verbatim, then submit again with that `--dispatch`.

### `external`

A person or another tool produces the product, not you. Stop. Print the step path and
its prompt, and tell the user that an external implementation owns this phase. The
operator submits with the lead `submit` command, using `--step <id>`, once the
product exists.

## `question`

You never answer a question yourself. A question is for the user or the operator.
Running `loop-spec answer` on your own judgment is forbidden.

1. Ask the user the question in `question.json` with `AskUserQuestion`.
2. Run the `answer` command with their answer.

If you have no way to ask the user (no AskUserQuestion tool, or a headless run),
stop. Print the question file path and its text. The operator answers with
`"<program>" answer --project-root "<projectRoot>" --state-home "<stateHome>" --slug <slug> --question <id> --answer "<text>"`
and re-runs the entry with `--slug <slug>` and no request to resume.

## `result`

Report the result file to the user in the chat shape. Stop.

## Rules

- Never answer a question yourself (see `question`).
- Never edit the result file.
- Never add your own instructions to a worker. If a step must be redone, submit what
  you have and let the program re-issue it with the reason.
- Never edit the project or dispatch a worker the program did not issue. A
  `fix-and-re-enter` option is the operator's fix, not yours.
- On a non-zero exit, report the program's output and stop.
