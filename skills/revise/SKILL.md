---
name: revise
description: "Address reviewer feedback on an already-open pull request. Use when a human or bot left PR review comments to resolve. Not for starting new work (use cycle) or fixing a bug found outside review (use debug)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" revise --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --pr "{pr}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{pr}` is the pull request number or URL whose review feedback to address.

Then read the last stdout line, `LOOP_SPEC_NEXT {"kind": ..., "path": ..., "slug": ...}`,
open the file at `path`, and act on it. Pass `--slug <slug from LOOP_SPEC_NEXT>` on
every `submit` and `answer` below (both require it, and this line is the only place
a stub is told the run's slug):

- `step`: check `kind` in `step.json`:
  - `lead`: do the work the prompt describes yourself, in this session (you may use
    AskUserQuestion); write the JSON result to `resultPath` (temp file then rename);
    then run
    `"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" submit --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug <slug from LOOP_SPEC_NEXT> --step <stepAttemptId>`
    (no `--dispatch`) and repeat from "read the last stdout line".
  - `role`: dispatch a fresh worker with the `Agent` tool: name = the step attempt id
    (`stepAttemptId`), prompt = the step's prompt verbatim (the program checks that
    the worker's transcript opens with this exact prompt and ends with the result
    digest; any rewording, prefix, or summary makes the step `unattested`, and an
    unattested review does not count), subagent_type `general-purpose`, model only
    when the step carries `model`; then run
    `"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" submit --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug <slug from LOOP_SPEC_NEXT> --step <stepAttemptId> --dispatch <stepAttemptId>`
    (`--dispatch` is the same name you gave the Agent) and repeat from "read the last
    stdout line". Never add your own instructions to a worker; if a step must be
    redone, submit what you have and let the program re-issue it with the reason.
  - `external`: a person or another tool produces the product, not you. Stop, print
    the step path and its prompt, and tell the user an external implementation owns
    this phase; the operator submits with
    `loop-spec submit --step <id> --slug <slug from LOOP_SPEC_NEXT>` once the product
    exists.
- `question`: ask the user the question in `question.json` (with `AskUserQuestion`), then run
  `"${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" answer --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug <slug from LOOP_SPEC_NEXT> --question <id> --answer "<text>"`
  and repeat. If you have no way to ask the user (no AskUserQuestion tool, or a
  headless run), stop and print the question file path and its text; the operator
  answers with `loop-spec answer ...` and re-runs this entry with `--slug <slug>` and
  no request to resume.
- `result`: report the result file to the user in the chat shape. Stop.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
