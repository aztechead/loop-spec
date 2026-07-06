# Design for change (seams, not speculation) — canonical prompt directive

Single source of truth for the design-for-change directive that every **design- and
code-producing phase dispatch** must carry, the structural companion to the laziness
ladder (`skills/shared/laziness-ladder.md`). The ladder governs how much code exists;
this directive governs where its boundaries sit. Enforced by
`tests/design-coverage.test.sh`, mirroring `tests/ponytail-coverage.test.sh`.

Relevant phases:
- **DISCUSS** — the design loop asks the corner question when shaping options (`skills/discuss/SKILL.md`).
- **SPEC/PLAN critique** — the challenger runs the corner test and coupling checks (`agents/challenger.md`).
- **PLAN / planner** — seams shape task boundaries (`agents/planner.md`).
- **EXECUTE / implementer** — every rung: team (`agents/implementer.md`,
  `skills/shared/team-prompts/implementer.md`), subagent (`skills/shared/execute-subagent.md`),
  loop-fleet (`lib/plan-to-loop.sh`), workflow (`lib/workflows/execute-dag.js`).
- **VERIFY / code-reviewer** — the design-for-change pass (`agents/code-reviewer.md`).
- **DEBUG** — the mandatory sibling sweep (`skills/debug/SKILL.md`, `commands/loop-debug.md`).

## The principles

1. **Design to an interface, not an implementation.** Consumers depend on the boundary;
   internals stay swappable without breaking callers. If you cannot say what a unit does
   without reading its internals, the boundary needs work.
2. **Separation of concerns.** One unit, one reason to change. Two concerns in one unit
   means every change to either risks the other.
3. **Dependency injection over deep construction.** A unit receives its collaborators
   (parameters, arguments, env) instead of constructing them internally — that is what
   keeps it testable in isolation. Bash analog: take paths and commands as args/env
   vars, never hardcode them deep in a function.
4. **Seams, not speculation.** Place boundaries where change is likely, so the next
   tweak — a new param, a new case, a new caller — is a local diff, not a shotgun edit.
   But never build the speculative implementation behind the seam: YAGNI still cuts
   artifacts (no interface with one hypothetical second implementation built out, no
   factory for one product, no config nobody sets); it never cuts a seam. A seam is a
   clean boundary and an injected dependency, and it costs nothing at ship time.
5. **The corner test.** Ask: "if this requirement changes, how many lines move?"
   Hundreds means the design is painted into a corner — fix the boundary, not the
   estimate.
6. **Clever is suspect.** If a solution reads clever, it is probably overcomplicated.
   Simplicity beats cleverness because code is read far more than it is written.
7. **The sibling sweep.** A confirmed root cause is rarely alone. After fixing it, sweep
   for the same mechanism elsewhere — callers of the fixed function, copy-pasted
   patterns, parallel code paths — and fix same-cause siblings in the same change. A
   different mechanism found during the sweep is a new bug, not a sibling: record it,
   do not fix it in this scope.

## Relationship to the laziness ladder

The two directives are complementary, not competing. The ladder's `yagni:` reflex cuts
speculative *artifacts*; it never cuts a *seam*. Cutting a seam (inlining a boundary,
hardcoding a dependency, merging two concerns to save a file) is not simplification —
it is borrowing against the next change. Conversely, a seam is not an excuse to build
what nobody asked for: the boundary ships, the speculation does not.

## Canonical compact directive (inline this verbatim into dispatch prompts)

> DESIGN FOR CHANGE (seams, not speculation — on by default). Design to an interface,
> not an implementation: consumers depend on the boundary, internals stay swappable.
> One unit, one reason to change. A unit receives its collaborators (params/args/env),
> never constructs them deep inside — that is what keeps it testable in isolation.
> Place boundaries where change is likely so the next tweak (new param, new case, new
> caller) is a local diff, not a shotgun edit — but never build the speculative
> implementation behind the seam: YAGNI cuts artifacts, never seams. Corner test: "if
> this requirement changes, how many lines move?" — hundreds means designed into a
> corner; fix the boundary. If a solution reads clever, it is probably overcomplicated;
> simplify. Bug fixes: one confirmed root cause is rarely alone — sweep for the same
> mechanism (callers, copy-pasted patterns, parallel paths) and fix same-cause siblings
> in the same change; a different mechanism is a new bug, not a sibling.
