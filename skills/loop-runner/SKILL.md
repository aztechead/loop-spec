---
name: loop-runner
description: >-
  Compile specs/goals into autonomous Claude Code loops and run them safely. The base
  layer for spec-driven and workflow automation: bridges "a spec written normally" to
  "loops execute it unattended." Use whenever the user wants Claude Code hands-off —
  "implement this spec", "keep going until tests pass", "break this down and execute",
  "babysit my PRs", overnight/cron/CI runs, agent fleets, orchestration, ralph or
  /goal-style loops, or worries about runaway agents and surprise bills. Also the base
  for building other workflow skills: derivatives should emit plans (plan/tasks.json)
  or call the library API, not reinvent guardrails. Three tested layers:
  compile_spec.py (spec → verified task plan), supervisor.py (plan → fleet in isolated
  worktrees with merge + halt policy), loop.py (bounded loop with verifier-integrity
  locking, budget/iteration/stall/timeout stops, durable state, result.json contract).
  Prefer this over any bespoke while-loop; regression suite in tests/.
---

# Loop Runner

## In loop-spec (read this first when invoked as a plugin skill)

This skill ships bundled inside the loop-spec plugin and is the engine of the
EXECUTE **loop-fleet rung** (`skills/shared/execute-loop-fleet.md`): PLAN.md
tasks are converted to a loop plan via `lib/plan-to-loop.sh` and run as a
supervised fleet with SPEC.md/PLAN.md integrity-protected. It is equally usable
standalone — "implement this spec", "keep going until tests pass", overnight
runs — exactly as documented below. When running from the plugin, reach the
scripts via `${CLAUDE_SKILL_DIR}/scripts/...` (e.g.
`python3 "${CLAUDE_SKILL_DIR}/scripts/loop.py" ...`); the relative
`scripts/...` paths below assume your cwd is the skill directory.

Stop being the thing inside the loop typing prompts. Write a spec the way you
normally would; compile it into loops; let the loops run with guardrails that
guarantee they halt; read a machine-readable result.

A loop is **cron plus a decision-maker in the body**. This skill is everything wrapped
around that decision so it converges instead of running off a cliff — and a compiler
so you don't hand-build the loops at all.

## The three layers

```
SPEC.md ──compile_spec.py──▶ plan/tasks.json ──supervisor.py──▶ fleet of loop.py runs
            (layer 2)             (contract)        (layer 3)        (layer 1)
```

| Layer | Script | In → Out | Job |
|---|---|---|---|
| 1 | `scripts/loop.py` | one task → `result.json` | Run one bounded loop: invoke `claude -p`, verify, measure progress, halt safely. |
| 2 | `scripts/compile_spec.py` | spec → `plan/tasks.json` | Decompose a spec into small verifiable tasks and **synthesize a verifier per task**. |
| 3 | `scripts/supervisor.py` | plan → `fleet-result.json` | Walk the dependency DAG, run each task's loop in an isolated git worktree, merge completed work, apply halt policy, enforce the fleet budget. |

Derivative skills plug in at the layer that fits: emit a plan and call the supervisor
(most spec/workflow skills), or import the library directly
(`from loop import LoopConfig, run_loop`) for a single embedded loop. Never scrape
stdout — read `result.json`.

## The spec-driven path (the main road)

```bash
# 1. Compile. One bounded, read-only claude invocation; output is validated
#    against the plan schema before it's written, with one self-correcting retry.
python3 scripts/compile_spec.py SPEC.md --fleet-budget 20

# 2. REVIEW THE PLAN — especially the verifiers. They are the contract; thirty
#    seconds here is worth more than any guardrail. --dry-run prints the schedule.
python3 scripts/supervisor.py --plan plan/tasks.json --dry-run

# 3. Run the fleet.
python3 scripts/supervisor.py --plan plan/tasks.json --parallel 2
```

The compiler's rules (embedded in its prompt): every acceptance criterion must be
covered by some task's verifier; criteria that aren't mechanically checkable get a
task whose *first step is to write the check*, with that check protected; anything
too ambiguous to verify lands in a `warnings` list for you instead of being invented.
The spec file itself is force-protected in every task, so no worker can edit the
requirements to match its work.

## The single-loop path

```bash
python3 scripts/loop.py \
  "Implement the rate limiter in src/limiter.py per SPEC.md. Add tests under \
   tests/test_limiter.py. Don't touch unrelated files." \
  --task-id rate-limiter \
  --verify "pytest tests/test_limiter.py -q" \
  --protected SPEC.md \
  --budget 4.00 --max-iterations 12 --commit
```

Also accepts `--config loop.json` (any `LoopConfig` field; CLI overrides), which is
how the supervisor — and your derivative skills — should drive it.

### Unattended resilience (CC >= 2.1.178/2.1.186)

Because the fleet runs headless and unsupervised, two optional flags harden each tick
against transient model failures — both on `loop.py` and `supervisor.py` (the supervisor
threads them into every loop's config):

- `--fallback-model <id>` — on overload or model-unavailable, the tick falls back to this
  model (`claude -p --fallback-model`) instead of dying, e.g. `--fallback-model claude-haiku-4-5-20251001`.
- `--retry-watchdog <n>` — sets `CLAUDE_CODE_RETRY_WATCHDOG` for the child, the recommended
  unattended retry mechanism (replaces relying on `CLAUDE_CODE_MAX_RETRIES`, capped at 15).

```bash
python3 scripts/supervisor.py --plan plan/tasks.json --parallel 2 \
  --fallback-model claude-haiku-4-5-20251001 --retry-watchdog 5
```

Both default off — behavior is unchanged unless you opt in.

## What makes a loop trustworthy here

**Verifier integrity (the trust anchor).** At start, the loop hashes every
`--protected` path *plus any path mentioned in the verify command itself* (test dirs,
scripts). After every agent run, before trusting any verdict, it re-hashes. If the
agent touched the exam, the run halts immediately with `halt_reason=verifier_integrity`
— which the supervisor treats as **fleet-fatal**, because nothing downstream of a
compromised verifier is trustworthy.

**Hard stops.** Iteration cap, wall-clock timeout, per-iteration `--max-turns` (so a
single tick can't eat the budget), and a cumulative dollar ceiling read from Claude
Code's own `total_cost_usd`. If Claude Code reports \$0 (common on subscription
plans), the loop says so loudly, marks `cost_reliable: false` in the result, and you
know the turn/iteration caps are your real spend bounds.

**Real progress, not motion.** Stall detection counts an iteration as progress only
if files changed *or the verifier failure changed* (failures are fingerprinted with
digits normalized, so the same error at a new line number still counts as stuck). An
agent churning files in circles halts just like a frozen one. Pass→fail flapping
halts as `verifier_thrash`.

**Memory across resets.** Fresh mode (default) is real ralph discipline: every
iteration re-anchors on the task + the latest verifier output + a `PROGRESS.md` the
agent is instructed to maintain — so context resets don't mean re-learning the
codebase each tick. `--mode continue` keeps one session via `--resume` instead.

**Observability and durability.** Every iteration's raw Claude Code output is kept
(`.loop/<task>/iter-NNN.raw.json`), every verifier run is saved in full, the agent's
own summary lands in history, and state survives crashes — rerun the same command to
resume; raise `--budget` to extend a budget-halted run; `--reset` to start clean.
`--commit` makes the work durable too (scoped: never commits `.loop/`).

## The result contract (what supervisors and derivative skills consume)

`.loop/<task-id>/result.json`, stable schema:

```json
{
  "task_id": "rate-limiter",
  "status": "complete | halted",
  "halt_reason": "complete | max_iterations | budget | timeout | no_progress |
                  verifier_thrash | verifier_integrity | agent_error",
  "iterations": 7, "cost_usd": 3.12, "cost_reliable": true, "total_turns": 41,
  "wall_clock_seconds": 812.4,
  "verifier": {"command": "...", "passed": true, "last_output_file": "...",
               "last_fail_fingerprint": null, "integrity_targets": ["..."]},
  "start_sha": "...", "end_sha": "...", "session_id": "...",
  "state_dir": ".loop/rate-limiter", "progress_notes": ".loop/rate-limiter/PROGRESS.md"
}
```

`halt_reason` is the policy switch: the supervisor retries stalls/thrash/agent-errors
(once, with the stall context appended so the retry doesn't repeat itself), never
retries budget/timeout halts (retrying a budget halt just re-spends it), skips
dependents of failed tasks, and kills the whole fleet on integrity violations.
Exit codes stay honest (0 only on verified completion) for cron/CI composition.

## Fleet semantics worth knowing

Each task runs on branch `loop/<id>` in its own worktree (created from base HEAD when
the task is scheduled), so workers can't collide. Completed branches are merged into
base — that's how dependents see their dependencies' work, which is why `deps` must
reflect real build-on relationships. A merge conflict means the plan called two tasks
independent when they weren't: the supervisor halts the fleet rather than letting a
model paper over it. Per-task budgets are clamped to the *remaining fleet budget*, so
N workers can't multiply your ceiling. The supervisor requires a clean tree to start
(worktrees branch from HEAD; uncommitted work would be invisible to every worker).

## Workflow when a user brings a spec or goal

1. **Compile, then read the plan with them.** The verifiers are where compilation
   succeeds or fails — check each one actually proves its criterion, and surface any
   `warnings` the compiler emitted as questions back to the user.
2. **Scope check the prompts.** Workers can't ask questions; each prompt must carry
   its spec excerpts and its don'ts.
3. **Start cheap.** First run of a new plan: low fleet budget, `--parallel 1`. Trust
   the verifiers before you scale.
4. **On failure, read `halt_reason`, not vibes.** `no_progress` → the task is
   under-specified or too big (split it); `budget` → under-budgeted or thrashing
   (read the iteration logs); `verifier_integrity` → inspect the diff with suspicion.
5. **Capture repeated work as skills.** The reusable unit inside a loop is a skill,
   not a prompt. Loops that call sharp named skills compound; loops that re-derive
   everything burn money.

## When NOT to loop

Single well-defined edits — just do them. Loops earn their cost when a task needs
several try→check→fix rounds or runs unattended. Never point a loop at something it
can't verify and can't undo.

## Testing (do this before trusting changes)

`bash tests/run_tests.sh` — offline regression suite (29 checks) using
`tests/fakeclaude`, covering every halt reason, integrity locking, resume,
config/library modes, plan validation, compilation, and a full supervisor
end-to-end with worktrees and merges. If you modify the harness for a derivative
skill, this suite is the floor.

## Deeper material

`references/patterns.md`: the loop lineage (ReAct → AutoGPT → ralph → /goal →
orchestration), verifier design, anchoring discipline, and failure modes.
`scripts/examples/`: babysit-PRs and nightly-cron recipes.

## Prerequisites

- Claude Code installed and authenticated (`claude` on PATH); the harness drives it
  via the verified headless interface (`claude -p --output-format json`).
- A git repo: required for the supervisor (worktrees/merges) and for loop.py's
  file-change stall detection and `--commit` (loop.py degrades gracefully without).
- Note: from June 15, 2026, `claude -p` / Agent SDK usage on subscription plans draws
  from a separate monthly Agent SDK credit — budget fleets accordingly, and watch for
  the `cost_reliable: false` flag.
