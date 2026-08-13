---
name: human-code
description: Toggle code-for-humans mode on or off for the current project. Code-for-humans mode (default ON) makes the assistant read the surrounding code before writing any, match the house conventions it finds there — naming, error idiom, test structure, comment density — and spend comments on why rather than what, so generated code reads like the codebase it lands in instead of like generated code. Reads and writes .loop-spec/human-code.conf to persist state across sessions.
argument-hint: "[on|off|status|probe]"
---

# Human Code Skill

Invoked as `/loop-spec:human-code <subcommand>`.

Code-for-humans mode is **ON by default**. Code is read far more often than it is
written, and generated code fails its reader in a recognisable way: it is correct,
and it looks nothing like the code around it. Different naming, a different error
idiom, a docstring on every function in a module that has none, a comment above
every line restating the line. This mode makes the assistant read the neighbors
first, match what it finds, and spend its comment budget on why.

This skill only flips the persistent state; the directive itself is injected at
session start by `hooks/team/human-code-inject.sh`, and every code-producing
dispatch carries its own copy (canonical text: `skills/shared/human-code.md`).

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

## Probes

Two deterministic scripts back this mode, so "honor the existing conventions" is
measured rather than recalled:

- `"${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" probe <paths>` — comment density, doc-comment usage, indentation,
  naming case, quote style, and line length, sampled from the target files or (for a file
  that does not exist yet) from its future neighbors. Answers `unknown` when the evidence
  is too thin, and `sample=none` (exit 1) when nothing readable was found.
- `"${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" compare <files>` — names where each file
  deviates from its same-language neighbors: indent, naming, quotes, semicolons, module
  system. Unlike `probe`, the file is held out of its own baseline, which is what lets it
  report a deviation at all — pooled in, a file that breaks every convention around it
  reports as the convention. Exit 1 means deviations, exit 0 means it reads like its
  neighbors, `baseline=0 files` means there was nothing to compare against.
- `"${CLAUDE_SKILL_DIR}/../../lib/comment-tells.sh" scan <files>` / `... diff <base> [head]` — flags added
  comments that narrate the edit, narrate history, or restate the next line of code. Exit 1
  means findings, exit 0 means clean.

VERIFY's `code-reviewer` runs both over the feature diff; a deviation either probe can
demonstrate is an **Important** (blocking) finding, while a convention you believe in but
cannot show in the probe output is taste and stays **Minor**.

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
  mode governs how it reads. The `simplicity:` shortcut marker the ladder requires is an
  explicit carve-out here and is never counted against a file's comment budget.
