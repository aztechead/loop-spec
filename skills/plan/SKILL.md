---
name: plan
description: "Run or resume the PLAN phase of an in-progress loop-spec run: turn an accepted spec into ordered, verifiable tasks. Use to redo or continue just the plan step of a run identified by --slug. Not for starting a new feature end to end (use cycle)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" plan --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug "{slug}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{slug}` identifies the run to resume; find it with the `status` entry if unknown.

Then read the last stdout line, `LOOP_SPEC_NEXT {"kind": ..., "path": ..., "slug": ...}`,
open the file at `path`, and act on it. Pass `--slug <slug from LOOP_SPEC_NEXT>` on
every `submit` and `answer` below (both require it, and this line is the only place
a stub is told the run's slug):

- `step`: check `kind` in `step.json`:
  - `lead`: do the work the prompt describes yourself, in this session (you may use
    AskUserQuestion); write the JSON result to `resultPath` (temp file then rename).
    `resultPath` is under the project's `.loop-spec/results/`, never under `~/.claude`
    (where the state home lives and a default permission mode refuses writes); if you
    wrote the result somewhere else, add `--result-file <path>` to the submit command
    below and the program reads it from there instead. Then run
    `"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" submit --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug <slug from LOOP_SPEC_NEXT> --step <stepAttemptId>`
    (no `--dispatch`) and repeat from "read the last stdout line".
  - `role`: dispatch a fresh worker with the `Agent` tool: name = the step attempt id
    (`stepAttemptId`), prompt = the step's prompt verbatim (the program checks that
    the worker's transcript opens with this exact prompt and ends with the result
    digest; any rewording, prefix, or summary makes the step `unattested`, and an
    unattested review does not count), subagent_type `general-purpose`, model only
    when the step carries `model`. The worker's prompt names its own `resultPath`,
    under the project's `.loop-spec/results/`, never under `~/.claude`; if the
    worker's result landed somewhere else, add `--result-file <path>` to the submit
    command below and the program reads it from there instead. Then run
    `"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" submit --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug <slug from LOOP_SPEC_NEXT> --step <stepAttemptId> --dispatch <stepAttemptId>`
    (`--dispatch` is the same name you gave the Agent) and repeat from "read the last
    stdout line". Never add your own instructions to a worker; if a step must be
    redone, submit what you have and let the program re-issue it with the reason.
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
- `result`: report the result file to the user in the chat shape. Stop.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
