---
name: revise
description: "Address reviewer feedback on an already-open pull request. Use when a human or bot left PR review comments to resolve. Not for starting new work (use cycle) or fixing a bug found outside review (use debug)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${LOOP_SPEC_SKILL_DIR}/../loop-spec/program/loop-spec" revise --project-root "{project-root}" --pr "{pr}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{pr}` is the pull request number or URL whose review feedback to address.

Then read the last stdout line, `LOOP_SPEC_NEXT {"kind": ..., "path": ...}`, open the
file at `path`, and act on it:

- `step`: do what `step.json` says (dispatch the named role in the named directory with
  the composed prompt; the worker writes the result file it names), then run
  `"${LOOP_SPEC_SKILL_DIR}/../loop-spec/program/loop-spec" submit --project-root "{project-root}" --step <stepAttemptId> [--dispatch <name>]`
  and repeat from "read the last stdout line".
- `question`: ask the user the question in `question.json` (with `AskUserQuestion`), then run
  `... loop-spec answer --project-root "{project-root}" --question <id> --answer "<text>"`
  and repeat.
- `result`: report the result file to the user in the chat shape. Stop.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
