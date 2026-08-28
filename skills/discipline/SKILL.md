---
name: discipline
description: Use when the user says "discipline on/off/status". Writes .loop-spec/discipline.conf. Do not use this to implement a feature; it only toggles the SessionStart gates.
argument-hint: "[on|off|status]"
---

# Discipline Skill

Invoked as `/loop-spec:discipline <subcommand>`.

## Subcommands

- `on` - Enable discipline mode for the current project.
- `off` - Disable discipline mode for the current project.
- `status` - Print the current discipline mode state.

## Inputs

- `subcommand`: one of `on`, `off`, `status`.
- Project root is `CLAUDE_PROJECT_DIR` or the current working directory.

## State file

All subcommands read and write `.loop-spec/discipline.conf` in the project root.

Format:

```
ENABLED=1
```

or

```
ENABLED=0
```

The `hooks/team/discipline-inject.sh` SessionStart hook reads this file. When `ENABLED=1` is present, the hook injects a 5-gate directive into the session context.

## Procedure

### on

1. Create `.loop-spec/` directory in the project root if it does not exist.
2. Write `ENABLED=1` to `.loop-spec/discipline.conf` (overwriting any previous content).
3. Report: "Discipline mode ON. The 5 behavioral gates will be injected at next session start."

### off

1. Write `ENABLED=0` to `.loop-spec/discipline.conf` (overwriting any previous content).
2. Report: "Discipline mode OFF. No directive will be injected at next session start."

### status

1. Read `.loop-spec/discipline.conf`.
2. If the file does not exist: report "Discipline mode: OFF (no conf file)."
3. If `ENABLED=1` is present: report "Discipline mode: ON."
4. Otherwise: report "Discipline mode: OFF."

## The 5 behavioral gates

The gate text (brainstorm-before-coding, verification-before-claims,
investigation-before-fixes, decision-gate, intent-gate) lives in the directive
`hooks/team/discipline-inject.sh` injects at SessionStart; this skill only flips the
switch and does not restate it.

## Kill switch

Setting `LOOP_SPEC_DISCIPLINE=0` in the environment disables the hook's injection entirely, regardless of the conf file state. This is a session-level override; it does not modify the conf file.

## Notes

- The conf file persists across shell sessions and restarts.
- Changes take effect at the next session start (the hook fires on SessionStart).
- The conf file is stored per-project; discipline state does not leak across projects.
