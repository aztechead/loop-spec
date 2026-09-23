---
name: revise
description: "Address reviewer feedback on an already-open pull request. Use when a human or bot left PR review comments to resolve. Not for starting new work (use cycle) or fixing a bug found outside review (use debug)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" revise --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --pr "{pr}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{pr}` is the pull request number or URL whose review feedback to address.

Then read the last stdout line, `LOOP_SPEC_NEXT {"kind": ..., "path": ..., "slug": ...}`,
and act on it: open the file at `path`, except for a role step (below). A wave that issues several steps at once
prints several `LOOP_SPEC_NEXT` lines of kind `step`: dispatch every one of them in
the same `Agent` tool message so they run concurrently, each under its own
`stepAttemptId`, then submit each as it returns. `LOOP_SPEC_WAIT
{"open": ["<stepAttemptId>", ...]}` in place of `LOOP_SPEC_NEXT` means the run is
waiting on steps you already dispatched: submit them, do not start anything new.
Pass `--slug <slug from LOOP_SPEC_NEXT>` on
every `submit` and `answer` below (both require it, and this line is the only place
a stub is told the run's slug):

- `step`: act on the marker's `stepKind` (the same `kind` as in `step.json`):
  - `lead`: do the work the prompt describes yourself, in this session (you may use
    AskUserQuestion); write the JSON result to `resultPath` (temp file then rename).
    `resultPath` is under the project's `.loop-spec/results/`, never under `~/.claude`
    (where the state home lives and a default permission mode refuses writes); if you
    wrote the result somewhere else, add `--result-file <path>` to the submit command
    below and the program reads it from there instead. Then run
    `"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" submit --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug <slug from LOOP_SPEC_NEXT> --step <stepAttemptId>`
    (no `--dispatch`) and repeat from "read the last stdout line".
  - `role`: dispatch a fresh worker with the `Agent` tool: name = the step attempt id
    (`stepAttemptId`), prompt = the exact text of the file at the marker's
    `dispatchPath` (the step's `dispatchPrompt`; a role step needs nothing from
    `step.json`), else the step's `prompt` verbatim (the program checks that the worker's transcript opens
    with exactly that text, that the worker read the whole instruction file it names,
    and that it ends with the result digest; any rewording, prefix, or summary makes
    the step `unattested`, and an unattested review does not count), subagent_type
    `general-purpose`, model only
    when the marker's `model` is not null. The worker's prompt names its own `resultPath`,
    under the project's `.loop-spec/results/`, never under `~/.claude`; if the
    worker's result landed somewhere else, add `--result-file <path>` to the submit
    command below and the program reads it from there instead. Then run
    `"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" submit --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug <slug from LOOP_SPEC_NEXT> --step <stepAttemptId> --dispatch <stepAttemptId>`
    (`--dispatch` is the same name you gave the Agent) and repeat from "read the last
    stdout line". If submit answers that the step is unattested and names a new
    dispatch name, dispatch a fresh worker under that exact name with the same
    dispatch text verbatim and submit again with that `--dispatch`; never edit the result
    file. Never add your own instructions to a worker; if a step must be redone,
    submit what you have and let the program re-issue it with the reason.
  - `external`: a person or another tool produces the product, not you. Stop, print
    the step path and its prompt, and tell the user an external implementation owns
    this phase; the operator submits with
    `loop-spec submit --step <id> --slug <slug from LOOP_SPEC_NEXT>` once the product
    exists.
- `question`: You never answer a question yourself. A question is for the user
  (AskUserQuestion) or the operator; if you cannot ask, stop. Running `loop-spec
  answer` on your own judgment is forbidden. Ask the user the question in
  `question.json` (with `AskUserQuestion`), then run
  `"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" answer --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug <slug from LOOP_SPEC_NEXT> --question <id> --answer "<text>"`
  and repeat. If you have no way to ask the user (no AskUserQuestion tool, or a
  headless run), stop and print the question file path and its text; the operator
  answers with `loop-spec answer ...` and re-runs this entry with `--slug <slug>` and
  no request to resume.
  You never edit the project or dispatch a worker the program did not issue: a
  `fix-and-re-enter` option is the operator's fix, not yours.
- `result`: report the result file to the user in the chat shape. Stop.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
