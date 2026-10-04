# Phase 1: the spec

For the lead of a loop-spec run in SPEC. The job: write `spec.json` in `runDir`, a
statement of done that a command can check, and settle how this repository takes a
change.

## spec.json

Use this shape; the program reads these fields:

```json
{"title": "feat: add lerp helper",
 "goal": "calc exposes lerp(a, b, t) returning a + (b - a) * t.",
 "criteria": [{"id": "AC-1", "text": "lerp(0, 10, 0.5) returns 5.0",
               "check": ".venv/bin/python -m pytest -q tests/test_lerp.py"}],
 "decisions": ["Clamp nothing: t outside [0, 1] extrapolates, matching numpy."],
 "assumptions": [], "outOfScope": ["No vector support."]}
```

The goal is one sentence. Each criterion is a property of the code at the delivered
commit that one command can show (a test, a script, a grep), never something about the
PR, CI, or branches. Keep each check exactly as strict as its criterion, so it cannot
fail on a comment or a wording. Give a criterion no `check` only when no command can
show it; the reviewer then judges it. Record each real choice in `decisions`, and, in
an autonomous run, each default you chose in `assumptions`. At least one criterion
runs the real thing (the command, the endpoint, the script) the way a user would.

Illustrative criteria, for a request to add a `--ttl` option to a CLI:

| Criterion | Check | Why |
|---|---|---|
| A key set with `--ttl 1` is gone after it expires | `python -m pytest -q tests/test_ttl.py` (the test injects a clock) | good: the behavior, shown by a test that cannot flake |
| `kv set a 1 --ttl 5 && kv get a` prints `1` | `bash -c 'kv set a 1 --ttl 5 && kv get a \| grep -qx 1'` | good: the real command, as a user runs it |
| No file contains the word `sleep` | `! grep -r sleep .` | bad: it fails on a comment that says "instead of sleeping"; check the tests' clock instead |
| The PR passes CI | none | bad: about the PR, not the code; `feedback` reads CI |

## How this repository takes a change

`LS status` lists the rules files (`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING*`). Read them
for branch naming, PR title and commit message format, a PR template, a changelog
entry, and sign-off, and follow them for the rest of the run.

The branch and the PR title come from, in order: the user (the entry passed them as
`start --branch` and `--title`), then the repository's rules, then the defaults
(`feat/<slug>`, and the spec's `title`). For the rules, run `LS set --branch NAME
--title "..."` now, before anything is pushed. With no rule, `title` follows the commit
convention in `git log --oneline -15`.

## The check

In an interactive run, show the user the goal and criteria and ask once for approval;
revise until they approve. Then run `LS status`: it announces the end of SPEC and names
the next step.
