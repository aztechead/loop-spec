---
name: grill
description: Toggle grill mode on or off for the current project. Grill mode (default ON) makes the assistant ask sharp disambiguation questions right after the initial prompt to lower ambiguity before acting. Reads and writes .loop-spec/grill.conf to persist state across sessions.
argument-hint: "[on|off|status]"
---

# Grill Skill

Invoked as `/loop-spec:grill <subcommand>`.

Grill mode is **ON by default**. Right after the user's opening request, the assistant runs one short "grill" pass — 2-4 sharp clarifying questions (structured multiple-choice where the answers are discernible) — to collapse the highest-leverage ambiguities before writing code, planning, or committing to an approach. Inside the loop-spec cycle, the SPEC phase Socratic interview is the in-cycle realization of this behavior.

This skill only flips the persistent state; the directive itself is injected at session start by `hooks/team/grill-inject.sh`.

## Subcommands

- `on` - Force grill mode ON for the current project (this is also the default when no conf file exists).
- `off` - Disable grill mode for the current project.
- `status` - Print the current grill mode state.

## Inputs

- `subcommand`: one of `on`, `off`, `status`.
- Project root is `CLAUDE_PROJECT_DIR` or the current working directory.

## State file

All subcommands read and write `.loop-spec/grill.conf` in the project root.

Format:

```
ENABLED=1
```

or

```
ENABLED=0
```

The `hooks/team/grill-inject.sh` SessionStart hook reads this file. **Absence of the file means grill mode is ON** (the default). Only an explicit `ENABLED=0` suppresses injection.

## Procedure

### on

1. Create `.loop-spec/` directory in the project root if it does not exist.
2. Write `ENABLED=1` to `.loop-spec/grill.conf` (overwriting any previous content).
3. Report: "Grill mode ON. Disambiguation questions will lead each new session's first substantive request."

### off

1. Create `.loop-spec/` directory in the project root if it does not exist.
2. Write `ENABLED=0` to `.loop-spec/grill.conf` (overwriting any previous content).
3. Report: "Grill mode OFF. The assistant will not auto-grill at session start."

### status

1. Read `.loop-spec/grill.conf`.
2. If the file does not exist: report "Grill mode: ON (default, no conf file)."
3. If `ENABLED=0` is present: report "Grill mode: OFF."
4. Otherwise: report "Grill mode: ON."

## Kill switch

Setting `LOOP_SPEC_GRILL=0` in the environment disables the hook's injection entirely, regardless of the conf file state. This is a session-level override; it does not modify the conf file.

## Notes

- The conf file persists across shell sessions and restarts.
- Changes take effect at the next session start (the hook fires on SessionStart).
- The conf file is stored per-project; grill state does not leak across projects.
- Grill mode complements [discipline mode](../discipline/SKILL.md): discipline is opt-in and enforces five behavioral gates; grill is on by default and front-loads disambiguation. They are independent toggles.
