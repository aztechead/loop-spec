# Laziness ladder (ponytail) — canonical prompt directive

Single source of truth for the ponytail simplicity directive that every **code-producing
phase dispatch** must carry, so the discipline is applied *every time* — not only on the
main thread (where `hooks/team/simplicity-inject.sh` injects it at SessionStart) but inside
each dispatched implementer/planner/reviewer, which a SessionStart hook does NOT reach.

Relevant phases (per `skills/simplicity/SKILL.md` "Relationship to the cycle"):
- **PLAN / planner** — `agents/planner.md` (ladder baked in; shapes tasks).
- **EXECUTE / implementer** — every rung: team (`agents/implementer.md`,
  `skills/shared/team-prompts/implementer.md`), subagent (`skills/shared/execute-subagent.md`),
  loop-fleet (`lib/plan-to-loop.sh`), workflow (`lib/workflows/execute-dag.js`).
- **VERIFY / code-reviewer** — `agents/code-reviewer.md` over-engineering pass.

The directive realizes `skills/simplicity/SKILL.md`; that skill is the full reference. Keep
the canonical compact text below in sync with the skill. The session-level copy lives in
`hooks/team/simplicity-inject.sh`.

## Canonical compact directive (inline this verbatim into dispatch prompts)

> SIMPLICITY (ponytail laziness ladder — on by default). Write the shortest solution that
> actually works; the best code is the code never written. BEFORE writing code, stop at the
> first rung that holds: (1) does it need to exist at all? speculative = skip it (YAGNI);
> (2) DRY — already in this codebase? reuse the existing helper/util/type/pattern, do not
> re-implement it: search the tree for it BEFORE you write, and check what you wrote after
> with `bash <probe_dir>/duplication-scan.sh scan <your files>`, which reports any block
> you duplicated and the file it already lives in — `duplicate=` for the same lines and
> `similar=` for the same lines with every name changed, which is the shape a copy-paste
> usually takes, so both count. Reuse means call it, or lift the shared
> part into one place both callers use — never a second copy that drifts; (3) stdlib does
> it? use it; (4) native platform feature covers it? use it; (5) an already-installed
> dependency solves it? use it, never add a new one for what a few lines do; (6) can it be
> one line? one line; (7) only then, the minimum code that works. The ladder runs AFTER you
> understand the problem, never instead of it. Bug fix = root cause, not symptom (fix the
> shared function once). NEVER cut input validation at trust boundaries, error handling that
> prevents data loss, security, accessibility, or anything the spec explicitly requires. A
> seam (a clean boundary, an injected dependency) is not bloat — cutting it is not
> simplification, and neither is collapsing two things that merely look alike: duplication
> is the same *reason to change* expressed twice, so leave alone what coincidentally
> resembles. Non-trivial logic leaves ONE runnable check behind. Mark deliberate shortcuts
> with a `simplicity:` comment naming the ceiling and upgrade path.

## Rung 2 is the rung a fresh context cannot climb

Rungs 1 and 3–7 are decidable from the task alone. Rung 2 is not: it asks whether something
already exists somewhere the run has never looked, and "search the tree first" has been in
this directive from the beginning while second copies kept shipping anyway. A run that never
opens the file holding the helper concludes, honestly, that it does not exist.

`lib/duplication-scan.sh` closes that gap the way `house-style.sh` closed "honor the
conventions": it measures the answer instead of asking for more diligence. `scan <files>`
compares the work against the rest of the tree and names the file each duplicated block
already lives in; `diff <base> [head]` reports only the clones the change itself introduced,
so a reviewer sees this author's duplication and not the repository's standing debt. Findings
are `file:line` and therefore blocking at VERIFY, on the same rule as the other probes: what
the probe demonstrates is Important, what you merely believe is taste.

It reports two kinds, and the second is the one that matters here. `duplicate=` is the same
lines verbatim. `similar=` is the same lines with every identifier and literal replaced —
the same code with all its names changed. That second shape is what a model actually
produces: writing `orders.ts` next to `users.ts` yields the same twelve lines with `user`
swapped for `order` throughout, and a verbatim matcher calls that clean. A DRY probe blind
to it would pass exactly the diffs it exists to catch, so the shape tier is the point rather
than a refinement of it — and it carries the wider window and the uniform-block rejection
that keep it from firing on ordinary language boilerplate.

The probe answers rung 2 only. Rung 1 (does this need to exist?) stays a judgment, and no
probe substitutes for understanding the problem first.

## Resolving the probe (`<probe_dir>`)

The probe ships inside the plugin; a dispatched agent's working directory is the target
repository, so a bare `lib/duplication-scan.sh` resolves to nothing. Every dispatch site
substitutes a real absolute path before the directive goes out, by the same mechanism it
uses for the code-for-humans probes (`skills/shared/human-code.md` holds the table). When
no path is available the sentence naming the probe drops out and the rung stands on its
own: search the tree before writing. The measurement is what makes duplication
*demonstrable*; the principle does not depend on it.

## Companion directives

The ladder governs how much code exists; `skills/shared/design-for-change.md` (seams, not
speculation) governs where its boundaries sit, and `skills/shared/human-code.md` (house
style over habit) governs how it reads. The three never conflict: YAGNI cuts speculative
artifacts, never seams, and never the legibility the next reader needs. Where DRY and the
house style appear to collide the resolution is fixed — matching the neighbors never
justifies a second copy of a helper this rung would reuse.
