---
name: refactor
description: "Restructures code without changing behavior with loop-spec: renames, extractions, moves, and migrations of callers to a new API, shown by checks that pass before and after. Use when the user asks to refactor, rename, move, dedupe, or migrate callers. Not for new behavior (cycle) or a reported failure (debug)."
argument-hint: "[--autonomous|--supervised] <error, stack trace, or failing test>"
---

Start (or resume) a loop-spec run from the repository. For a change across several
repositories cloned side by side in a directory that is not itself a repository, start
from that directory; when it has no `.loop-spec/workspace.json`, first write one listing
each clone the change spans: `{"repos": [{"name": "api", "path": "api"}, {"name": "web", "path": "web"}]}`.

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --kind refactor --request "{request}"

- `{request}`: the restructuring the user wants, in their words.
- Add `--branch NAME` and `--title "..."` when the user names the branch or the PR
  title for this change.
- Add `--autonomous` if no one can answer questions during this run (a headless or
  unattended run, or arguments that start with `--autonomous`). Add `--supervised` instead
  when the arguments start with `--supervised`.
- When the request is long or holds quotes, backticks, or `$`, write it to a file and
  pass `--request-file <path>` instead of `--request`.

Then follow `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` until the run ends.
