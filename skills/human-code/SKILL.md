---
name: human-code
description: Use when the user says "human-code on/off/status/probe". Writes .loop-spec/human-code.conf. Default ON: match house style, comments carry why, docs stay true in the same diff. Do not use this to implement a feature; it only toggles the SessionStart injector.
argument-hint: "[on|off|status|probe]"
---

# Human Code Skill

Invoked as `/loop-spec:human-code <subcommand>`.

Code-for-humans mode is **ON by default**. It covers both halves of what a person needs
from code: reading it, and running it. Code is read far more often than it is
written, and generated code fails its reader in a recognisable way: it is correct,
and it looks nothing like the code around it. Different naming, a different error
idiom, a docstring on every function in a module that has none, a comment above
every line restating the line. This mode makes the assistant read the neighbors
first, match what it finds, and spend its comment budget on why.

The same switch covers the markdown. Documents are the half of the output a person
reads when the code is not enough, and they fail their reader in their own way: a link
that goes nowhere, a path the tree no longer holds, a command nobody can run, a page
that restates code it will outlive. Code-for-humans mode makes both halves the
deliverable (canonical text: `skills/shared/human-docs.md`).

This skill only flips the persistent state; the directives themselves are injected at
session start by `hooks/team/human-code-inject.sh`, and every code-producing
dispatch names the contract (`skills/shared/human-code.md`) and the probes.

## Subcommands

- `on` - Force code-for-humans mode ON for the current project (also the default when no conf file exists).
- `off` - Disable code-for-humans mode for the current project.
- `status` - Print the current mode state.
- `probe [path ...]` - Report the measured conventions for the given paths (or the current directory) without changing any state.

## Inputs

- `subcommand`: one of `on`, `off`, `status`, `probe`.
- Project root is `CLAUDE_PROJECT_DIR` or the current working directory.

## State file

`on`, `off`, and `status` read and write `.loop-spec/human-code.conf` in the project root.

Format:

```
ENABLED=1
```

or

```
ENABLED=0
```

The `hooks/team/human-code-inject.sh` SessionStart hook reads this file. **Absence of
the file means code-for-humans mode is ON** (the default). Only an explicit `ENABLED=0`
suppresses injection.

## Procedure

### on

1. Create `.loop-spec/` in the project root if it does not exist.
2. Write `ENABLED=1` to `.loop-spec/human-code.conf` (overwriting any previous content).
3. Report: "Code-for-humans mode ON. Generated code will match the conventions of the files it lands in."

### off

1. Create `.loop-spec/` in the project root if it does not exist.
2. Write `ENABLED=0` to `.loop-spec/human-code.conf` (overwriting any previous content).
3. Report: "Code-for-humans mode OFF. The assistant will not receive the house-style directive at session start."

### status

1. Read `.loop-spec/human-code.conf`.
2. If the file does not exist: report "Code-for-humans mode: ON (default, no conf file)."
3. If `ENABLED=0` is present: report "Code-for-humans mode: OFF."
4. Otherwise: report "Code-for-humans mode: ON."

### probe

1. Run `bash "${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" probe <paths>` (default `.` when no path is given).
2. Report the fact lines verbatim. Each carries its own evidence; do not paraphrase or round them.
3. Exit 1 with `sample=none` means the convention is **undemonstrated**, not absent — say so rather than filling the gap with a default.
4. Run `bash "${CLAUDE_SKILL_DIR}/../../lib/failure-tells.sh" scan <code paths>` for the failure path, and report its findings the same way.
5. When any path is markdown, also run `bash "${CLAUDE_SKILL_DIR}/../../lib/doc-tells.sh" scan <markdown paths>` and report its findings the same way.

## Probes

The deterministic probes backing this mode — `house-style.sh probe` / `house-style.sh compare`,
`comment-tells.sh`, `failure-tells.sh` (the operate half), and `doc-tells.sh` (the markdown
half) — are documented once, with their exit codes and carve-outs, in
`skills/shared/human-code.md` and `skills/shared/human-docs.md`. This skill does not restate
them. VERIFY's `code-reviewer` runs all of them over the feature diff; a deviation a probe
can demonstrate is an **Important** (blocking) finding, while a convention you believe in
but cannot show in the probe output is taste and stays **Minor**.

## Kill switch

Setting `LOOP_SPEC_HUMAN_CODE=0` in the environment disables the hook's injection
entirely, regardless of the conf file state. This is a session-level override; it does
not modify the conf file. The dispatch-rung copies of the directive are unaffected —
they travel in the prompt, where a session-level switch does not reach.

## Notes

- The conf file persists across shell sessions and restarts, per project.
- Changes take effect at the next session start (the hook fires on SessionStart).
- Complements [simplicity mode](../simplicity/SKILL.md): the ladder governs how much code
  exists, `skills/shared/design-for-change.md` governs where its boundaries sit, and this
  mode governs how the code and its documents read. The `simplicity:` shortcut marker the ladder requires is an
  explicit carve-out here and is never counted against a file's comment budget.
