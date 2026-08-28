---
name: simplicity
description: Use when the user says "simplicity on/off/status/lite/full/ultra". Writes .loop-spec/simplicity.conf. Default ON, full: stop at the first laziness-ladder rung. Do not use this to implement a feature; it only toggles the SessionStart injector.
argument-hint: "[on|off|status|lite|full|ultra]"
---

# Simplicity Skill

Invoked as `/loop-spec:simplicity <subcommand>`.

Simplicity mode is **ON by default at `full`**. It channels a lazy senior dev: the
best code is the code never written. Before writing code — in any phase of the
cycle and in ad-hoc work — the assistant climbs the laziness ladder and stops at
the first rung that holds, shipping the shortest solution that actually works.

This skill only flips the persistent state; the directive itself is injected at
session start by `hooks/team/simplicity-inject.sh`. The discipline is concept-
and-implementation ported from [ponytail](https://github.com/DietrichGebert/ponytail).

## Subcommands

- `on` - Force simplicity mode ON (the default when no conf file exists). Keeps the current level, or `full` if unset.
- `off` - Disable simplicity mode for the current project.
- `lite` | `full` | `ultra` - Turn it ON and pin the intensity level.
- `status` - Print the current mode and level.

## Inputs

- `subcommand`: one of `on`, `off`, `lite`, `full`, `ultra`, `status`.
- Project root is `CLAUDE_PROJECT_DIR` or the current working directory.

## State file

All subcommands read and write `.loop-spec/simplicity.conf` in the project root.

Format:

```
ENABLED=1
LEVEL=full
```

`ENABLED=0` disables the directive regardless of `LEVEL`.

## Procedure

### on
1. Create `.loop-spec/` if it does not exist.
2. Write `ENABLED=1` and preserve the existing `LEVEL` (default `full`) to `.loop-spec/simplicity.conf`.
3. Report: "Simplicity mode ON (level: <LEVEL>). The laziness ladder will be injected at next session start."

### off
1. Write `ENABLED=0` (preserving `LEVEL`) to `.loop-spec/simplicity.conf`.
2. Report: "Simplicity mode OFF. No ladder directive will be injected at next session start."

### lite | full | ultra
1. Create `.loop-spec/` if it does not exist.
2. Write `ENABLED=1` and `LEVEL=<chosen>`.
3. Report: "Simplicity mode ON (level: <chosen>)."

### status
1. Read `.loop-spec/simplicity.conf`.
2. No file: report "Simplicity mode: ON (default, level full — no conf file)."
3. `ENABLED=0`: report "Simplicity mode: OFF."
4. Else: report "Simplicity mode: ON (level: <LEVEL>)."

## Kill switch

`LOOP_SPEC_SIMPLICITY=0` in the environment disables the hook's injection
entirely, regardless of the conf file. Session-level override; does not modify
the conf file.

## The ladder itself

The full directive — the seven rungs, the rules (YAGNI cuts artifacts, never seams),
the never-simplify-away list, the `simplicity:` shortcut marker, and how each
code-producing phase carries it in its dispatch prompt — lives once in
`skills/shared/laziness-ladder.md` (enforced by `tests/ponytail-coverage.test.sh`).
This skill does not restate it.

## Intensity

| Level | What changes |
|-------|--------------|
| **lite** | Build what's asked, but name the lazier alternative in one line. User picks. |
| **full** | The ladder enforced. Stdlib and native first. Shortest diff, shortest explanation. Default. |
| **ultra** | YAGNI extremist. Deletion before addition. Ship the one-liner and challenge the rest of the requirement in the same breath. |

(The injected wording per level is in `hooks/team/simplicity-inject.sh`.)

## Notes

- The conf file persists across sessions and is per-project; state does not leak across projects.
- Changes take effect at the next session start (the hook fires on SessionStart).
- Pairs with grill (lowers ambiguity first) and caveman (terse prose); simplicity governs what you build, not how you talk.
