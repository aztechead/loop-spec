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

The directive realizes `skills/simplicity/SKILL.md`; that skill is the full reference. Dispatch
names this file rather than pasting it. The session-level copy lives in
`hooks/team/simplicity-inject.sh`.

## Compact directive (read this file; do not paste it into a prompt)

Dispatch names this file and the resolved probes. A SessionStart hook does not reach a
dispatched agent, so the prompt still says to Read this file.

> SIMPLICITY (ponytail laziness ladder — on by default). Write the shortest solution that
> actually works; the best code is the code never written. BEFORE writing code, stop at the
> first rung that holds: (1) does it need to exist at all? speculative = skip it (YAGNI) —
> and the layer nobody needed always looks justified while you write it, so count it
> afterwards: `bash <probe_dir>/indirection-scan.sh scan <your files>` names each small
> private helper you added that is called exactly once. Inline it, or say why the name
> earns its hop. It leaves decomposition alone (a long function with one caller is what
> functions are for), and stays silent on exported symbols and dead code;
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

## Rungs 1 and 2 are the two the prose could never enforce

Rungs 3–7 are decidable from the task alone: either the stdlib has it or it does not. The
first two are not, and each fails in its own way.

**Rung 1 (YAGNI)** fails at the moment of writing. A wrapper always looks like good
decomposition while you are producing it — that is why "no abstraction with one caller" has
been in this directive from the beginning and one-caller wrappers keep landing. The cost is
only visible afterwards, to a reader following three hops to reach four lines, and it is
only *countable* afterwards. `lib/indirection-scan.sh` counts it: small, private, added by
this change, called exactly once. All four conditions matter, because each alone is ordinary
good code — which is why the probe is silent on a long single-caller function
(decomposition, and the point of functions), on an exported symbol (callers it cannot see),
and on dead code (zero callers is a different finding).

## Rung 2 is the rung a fresh context cannot climb

Rung 1 can at least be counted from the changed files after writing, and rungs 3–7 can be
answered from the task and available platform. Rung 2 uniquely needs the rest of the tree: it
asks whether something already exists somewhere the run has never looked, and "search the tree
first" has been in this directive from the beginning while second copies kept shipping anyway.
A run that never opens the file holding the helper concludes, honestly, that it does not exist.

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
