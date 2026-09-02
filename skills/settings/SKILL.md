---
name: settings
description: Use when the user says "grill on/off", "discipline on/off", "simplicity lite/full/ultra/off", "human-code on/off/probe", or "loop-spec settings". Writes the per-project .loop-spec/<mode>.conf files the SessionStart hooks read. Do not use this to implement a feature; it only flips switches.
argument-hint: "<grill|discipline|simplicity|human-code> [on|off|status|lite|full|ultra|probe [paths]]"
---

# Settings

Four session-start directives, one switch each, all persisted as `ENABLED=0|1` in
`.loop-spec/<mode>.conf` under the project root (`CLAUDE_PROJECT_DIR` or the cwd). The
skill only flips the file; the directive text lives in the hook that injects it at the
next session start, and an environment kill switch overrides the file for one session
without modifying it.

| Mode | Default | Conf file | Hook | Kill switch | What it does |
|---|---|---|---|---|---|
| `grill` | ON | `grill.conf` | `hooks/team/grill-inject.sh` | `LOOP_SPEC_GRILL=0` | 2-4 sharp disambiguation questions right after the opening request. Inside the cycle, SPEC's interview continues the grill and DISCUSS still runs its design-shape clarifying loop unless the run is autonomous (`execStyle: auto` is not autonomous mode). |
| `discipline` | OFF | `discipline.conf` | `hooks/team/discipline-inject.sh` | `LOOP_SPEC_DISCIPLINE=0` | Five behavioral gates: brainstorm before coding, verification before claims, investigation before fixes, decision gate, intent gate. |
| `simplicity` | ON, `full` | `simplicity.conf` (also `LEVEL=lite|full|ultra`) | `hooks/team/simplicity-inject.sh` | `LOOP_SPEC_SIMPLICITY=0` | The laziness ladder (`skills/shared/laziness-ladder.md`): stop at the first rung that holds. `lite` names the lazier alternative and lets the user pick; `full` enforces the ladder; `ultra` deletes before adding and challenges the requirement. |
| `human-code` | ON | `human-code.conf` | `hooks/team/human-code-inject.sh` | `LOOP_SPEC_HUMAN_CODE=0` | Code and docs for the person who maintains them (`skills/shared/human-code.md`, `skills/shared/human-docs.md`): match the neighbors, comments carry why, fix the doc a change makes false in the same diff. |

Absence of a conf file means the default. Only an explicit `ENABLED=0` turns a
default-ON mode off. State is per project and persists across sessions; a change
takes effect at the next session start.

## Procedure

Invoked as `/loop-spec:settings <mode> <subcommand>`.

- **`on`**: `mkdir -p .loop-spec`, write `ENABLED=1` (simplicity keeps its `LEVEL`,
  default `full`). Report `<Mode> mode ON.` and, for simplicity, the level.
- **`off`**: write `ENABLED=0` (simplicity preserves `LEVEL`). Report `<Mode> mode OFF.`
- **`lite` | `full` | `ultra`** (simplicity only): write `ENABLED=1` and `LEVEL=<level>`.
  Report `Simplicity mode ON (level: <level>).`
- **`status`**: read the file. No file → `<Mode> mode: <default> (default, no conf
  file).` `ENABLED=0` → OFF; otherwise ON (simplicity adds the level).
- **`probe [paths]`** (human-code only, changes nothing): run
  `bash "${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" probe <paths>` (default `.`) for the
  measured conventions, `bash "${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" compare <changed files>`
  to demonstrate a deviation, `bash "${CLAUDE_SKILL_DIR}/../../lib/failure-tells.sh" scan <code paths>`, and, for
  markdown paths, `bash "${CLAUDE_SKILL_DIR}/../../lib/doc-tells.sh" scan <paths>`.
  Report the fact lines verbatim; `sample=none` means the convention is undemonstrated,
  not absent.

A mode or subcommand outside the table is an error naming the valid set.
`/loop-spec:onboard` writes the same files during setup.
