# Loop patterns and lineage

Read this when building orchestration loops (one loop supervising others), designing
verifiers, or debugging a loop that misbehaves. The SKILL.md covers the day-to-day; this
is the theory and the sharp edges.

## The lineage — know which "loop" someone means

The word *loop* hides at least five different things. When people argue about loops they
are usually talking past each other across these stages. Oldest to newest:

1. **The academic while-loop (ReAct, 2022).** The model reasons, calls a tool, reads the
   result, repeats until done. One model, one loop, a human watching. This is the
   primitive everything else is built on.
2. **AutoGPT (2023).** Gave the loop a goal and let it prompt itself. Became famous for
   spinning forever doing nothing — which is exactly why no-progress detection and
   iteration caps are non-negotiable.
3. **The ralph loop (2025).** Almost insultingly simple: pipe the same prompt file into
   the agent over and over. Its real innovation was *discipline* — every iteration resets
   context to a fixed set of anchor files instead of letting the conversation grow. This
   is `--mode fresh` in the harness. "Single-agent ralph is old hat" — but it's old hat
   because it *works*; it's the dependable base layer.
4. **`/goal`-style productized loops (2026).** Ralph plus a small validator model that
   confirms the task is actually done before stopping. This is `--judge` in the harness.
5. **Continuous orchestration (now).** The genuinely new layer. Four things changed:
   the loop became the unit of work (not the task); loops supervise other loops,
   concurrently and on a schedule; scheduling replaced the human kickoff (it runs on
   infrastructure time, not your attention); and durability became explicit, with
   git-backed state and crash recovery, because the loop must survive a restart.

`scripts/loop.py` gives you stages 3–4 directly and is the worker unit you compose to
build stage 5.

## Orchestration: loops supervising loops

A single `loop.py` run is one worker. Orchestration is a supervisor loop that dispatches
and oversees several of them — the "continuous orchestration loop that oversees other
threads." The pattern:

- **One job per worktree.** Give each worker its own git worktree so they can't collide
  on the same files. `git worktree add ../task-A -b task-A`.
- **Supervisor as a thin dispatcher.** The supervisor decides *what* loops to start and
  *whether* to keep them going; each worker decides *how* to do its task. Keep the
  supervisor's own logic mostly mechanical (read a queue, launch workers, collect exit
  codes, retry or escalate) — the intelligence lives in the workers.
- **Shared state in git, not memory.** Workers commit their progress; the supervisor
  reads the repo to see status. This is what makes the whole system survive a crash.

All of this is implemented in `scripts/supervisor.py` — worktree-per-task, lazy
branch creation from base HEAD, merge-on-complete (with conflict = fleet halt, because
a conflict means the plan's independence claim was false), and policy keyed on
`result.json.halt_reason` rather than exit-code scraping. Read it
before writing a custom supervisor; extend its policy table rather than replacing it.

## Designing a good verifier

The verifier is the most important line in the whole command. Properties of a good one:

- **Exits 0 only when truly done.** No false positives — a verifier that passes early
  makes the loop stop on broken work. Prefer `pytest -q && ruff check . && mypy .` over
  a single loose check.
- **Fast.** It runs every iteration. A 10-minute verifier dominates wall-clock.
  Scope it to the task (`pytest tests/test_thing.py`, not the whole suite) when you can.
- **Informative on failure.** Its stdout/stderr is fed back into the next prompt, so a
  verifier that prints *what* failed (assertion diffs, the failing file) steers the agent.
  A bare exit code teaches it nothing.
- **Deterministic.** Flaky verifiers cause the loop to thrash — passing, then failing,
  then passing — and never converge.

For tasks with no natural exit-0 check (refactors, docs, research), the compiler's
move is better than a judge alone: make the task's FIRST step writing the check (a
test, an assertion script), protect that check, then verify against it. `--judge`
remains useful as a second opinion — note it is shown the actual diff since loop
start, not just the verifier's say-so, precisely so it validates work rather than
rubber-stamping the verifier. Be honest with the user that unverifiable loops are
riskier.

One more verifier rule, enforced mechanically: the loop hashes the verifier's inputs
(protected paths + any on-disk path named in the verify command) and halts with
`verifier_integrity` if they change. Goodhart's law is not a prompt problem — "don't
edit the tests" in the prompt is a request; the integrity hash is a guarantee.

## Prompt-anchoring discipline (why `--mode fresh` resets context)

Letting one conversation grow across dozens of iterations causes context bloat: the
agent drowns in its own earlier output and quality drifts. Ralph's discipline — reset
to a fixed anchor (the task prompt + current verifier output) each tick — keeps every
iteration sharp. Use `--mode continue` only when carrying memory genuinely helps
(long multi-stage tasks).

## Failure modes to design against

- **The loop that won't stop.** The headline fear: a loop that never halts. Defended by
  the hard stops (iterations, timeout, stall) — never run a loop with all of them
  disabled.
- **The confident-mistake machine.** A loop with no verifier writes plausible-looking
  broken code fast. Always verify.
- **The spinner.** Agent "thinks" each iteration but changes nothing. No-progress
  detection catches it; keep `--no-progress` at a low single digit.
- **The false-green.** Verifier passes on incomplete work (e.g. tests that don't cover
  the requirement). Strengthen the verifier; add `--judge` for important runs.
- **The colliding fleet.** Multiple workers editing the same files. Isolate with git
  worktrees.

## The honest framing

"It's just a cron job with a hat on" is half right: the scheduling layer *is* cron, and
that's fine. What cron never had is a decision-maker in the body — a model that picks the
next action each tick rather than running a fixed script. The interesting engineering is
everything you wrap around that decision so it halts safely. That wrapper is this skill.

Reality check on the hype: agentic AI sits near the peak of inflated expectations, with
only a small fraction of organizations actually running agents in production. The gap
between the timeline and the receipts is real. Loops are useful and worth building — and
the boring guardrails are what separate a useful loop from a runaway one.
