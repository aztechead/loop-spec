# Loop patterns

Read this when building orchestration loops (one loop supervising others), designing
verifiers, or debugging a loop that misbehaves. The SKILL.md covers the day-to-day; this
covers operating choices and failure modes.

Contents: loop types · orchestration · verifier design · context reset · failure modes.

## Loop types

- A task loop repeats work and verification for one task.
- Fresh mode resets context from the task, current verifier output, and progress notes.
- Continue mode resumes the same session.
- A supervisor schedules task loops, collects results, and applies retry or halt policy.
- A cron or CI job can invoke the supervisor on a schedule.

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
