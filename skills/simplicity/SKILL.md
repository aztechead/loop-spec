---
name: simplicity
description: Toggle simplicity mode (the laziness ladder) on/off and set its intensity (lite/full/ultra) for the current project. Simplicity mode (default ON, full) makes the assistant climb the laziness ladder before writing code — YAGNI, reuse, stdlib, native, installed dep, one line, then minimum — so the cycle ships the shortest solution that actually works without cutting validation, error handling, security, or accessibility. Reads and writes .loop-spec/simplicity.conf to persist state across sessions. Ported from ponytail (https://github.com/DietrichGebert/ponytail).
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

## The laziness ladder

Lazy means efficient, not careless. Before writing any code, stop at the first
rung that holds:

1. **Does this need to exist at all?** Speculative need = skip it, say so in one line. (YAGNI)
2. **Already in this codebase?** A helper, util, type, or pattern that already lives here → reuse it. Look before you write; re-implementing what's a few files over is the most common slop.
3. **Stdlib does it?** Use it.
4. **Native platform feature covers it?** `<input type="date">` over a picker lib, CSS over JS, a DB constraint over app code.
5. **Already-installed dependency solves it?** Use it. Never add a new one for what a few lines can do (in loop-spec terms: no npm/pip/brew for shipped code).
6. **Can it be one line?** One line.
7. **Only then:** the minimum code that works.

The ladder runs *after* you understand the problem, not instead of it. Read the
task and the code it touches, trace the real flow end to end (use the graphify
code graph the design phases already query), then climb. Two rungs work → take
the higher one and move on.

**Bug fix = root cause, not symptom.** A report names a symptom. Before editing,
grep every caller of the function you're about to touch. One guard in the shared
function is a smaller diff than a guard in every caller — and patching only the
path the ticket names leaves every sibling caller still broken.

## Rules

- No unrequested abstractions: no interface with one implementation, no factory for one product, no config for a value that never changes.
- No boilerplate or scaffolding "for later" — later can scaffold for itself.
- Deletion over addition. Boring over clever. Fewest files possible.
- Shortest working diff wins — but only once you understand the problem. The smallest change in the wrong place isn't lazy, it's a second bug.
- Complex request? Ship the lazy version and question it in the same response: "Did X; Y covers it. Need full X? Say so." Never stall on an answer you can default.
- Two stdlib options the same size? Take the one that's correct on edge cases. Lazy means writing less code, not picking the flimsier algorithm.
- Mark deliberate simplifications with a `simplicity:` comment so a shortcut reads as intent, not ignorance. A shortcut with a known ceiling names the ceiling and the upgrade path: `# simplicity: global lock, per-account locks if throughput matters`. Harvest them any time with `grep -rnE '(#|//) ?simplicity:' .` — these are accepted shortcuts, distinct from the `TBD`/`FIXME`/`XXX` markers VERIFY blocks on.

## When NOT to be lazy

Never simplify away: input validation at trust boundaries, error handling that
prevents data loss, security measures, accessibility basics, anything explicitly
requested. User insists on the full version → build it, no re-arguing.

Never lazy about understanding the problem. The ladder shortens the solution,
never the reading. A small diff you don't understand is laziness dressed up as
efficiency that ships a confident wrong fix.

Lazy code without its check is unfinished. Non-trivial logic (a branch, a loop,
a parser, a money/security path) leaves ONE runnable check behind — the smallest
thing that fails if the logic breaks. Trivial one-liners need no test; YAGNI
applies to tests too.

## Intensity

| Level | What changes |
|-------|--------------|
| **lite** | Build what's asked, but name the lazier alternative in one line. User picks. |
| **full** | The ladder enforced. Stdlib and native first. Shortest diff, shortest explanation. Default. |
| **ultra** | YAGNI extremist. Deletion before addition. Ship the one-liner and challenge the rest of the requirement in the same breath. |

## Relationship to the cycle

Simplicity mode is the always-on backdrop; the cycle realizes it at specific gates:
- **PLAN / planner** climbs the ladder when shaping tasks — no speculative abstractions in the plan.
- **EXECUTE / implementer** already ships "minimum code, nothing speculative"; the ladder is the same discipline, named.
- **VERIFY / code-reviewer** runs the over-engineering pass (delete / stdlib / native / yagni / shrink) on the diff, tier-gated.

## Notes

- The conf file persists across sessions and is per-project; state does not leak across projects.
- Changes take effect at the next session start (the hook fires on SessionStart).
- Pairs with grill (lowers ambiguity first) and caveman (terse prose); simplicity governs what you build, not how you talk.
