---
name: discipline
description: Toggle discipline mode on or off for the current project. Reads and writes .super-spec/discipline.conf to persist state across sessions.
---

# Discipline Skill

Invoked as `/super-spec:discipline <subcommand>`.

## Subcommands

- `on` - Enable discipline mode for the current project.
- `off` - Disable discipline mode for the current project.
- `status` - Print the current discipline mode state.

## Inputs

- `subcommand`: one of `on`, `off`, `status`.
- Project root is `CLAUDE_PROJECT_DIR` or the current working directory.

## State file

All subcommands read and write `.super-spec/discipline.conf` in the project root.

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

1. Create `.super-spec/` directory in the project root if it does not exist.
2. Write `ENABLED=1` to `.super-spec/discipline.conf` (overwriting any previous content).
3. Report: "Discipline mode ON. The 5 behavioral gates will be injected at next session start."

### off

1. Write `ENABLED=0` to `.super-spec/discipline.conf` (overwriting any previous content).
2. Report: "Discipline mode OFF. No directive will be injected at next session start."

### status

1. Read `.super-spec/discipline.conf`.
2. If the file does not exist: report "Discipline mode: OFF (no conf file)."
3. If `ENABLED=1` is present: report "Discipline mode: ON."
4. Otherwise: report "Discipline mode: OFF."

## The 5 behavioral gates

When discipline mode is on, the following gates are active for the session:

1. **brainstorm-before-coding** - Confirm the approach has been discussed before writing code. Pause and plan first when not discussed.
2. **verification-before-claims** - Run the actual verification command and show its output before claiming work is done or passing. No "should work" claims without evidence.
3. **investigation-before-fixes** - Investigate root cause before proposing fixes when encountering bugs, errors, or test failures. No guessing.
4. **decision-gate** - Present a structured comparison with criteria and a recommendation when choosing between options or approaches.
5. **intent-gate** - Lock in the goal and audience before any creative or writing task. Validate output against those locked goals.

## Kill switch

Setting `SUPER_SPEC_DISCIPLINE=0` in the environment disables the hook's injection entirely, regardless of the conf file state. This is a session-level override; it does not modify the conf file.

## Notes

- The conf file persists across shell sessions and restarts.
- Changes take effect at the next session start (the hook fires on SessionStart).
- The conf file is stored per-project; discipline state does not leak across projects.
