# Autonomous Cloud Run Operations

This is a configurable production profile for loop-spec autonomous runs in a
GCP Cloud Run job or service. It does not infer policy from a fixed CPU or memory
size; operators select the controls below for each deployment shape.

## Resource policy

- Bound simultaneous Agent SDK queries per instance. The Agent SDK spawns a Claude
  Code subprocess and its tool process tree; parallel sessions multiply memory.
- Set Cloud Run service concurrency and job parallelism from measured per-run
  usage. A small instance may admit one run; a larger instance may admit more.
- Give concurrent runs separate control checkouts. One checkout supports one
  active full cycle because its branch, active pointer, and terminal pointer are
  deliberately singular.
- Use `LOOP_SPEC_WORKTREES=0` to avoid checkout/dependency duplication.
  EXECUTE remains serial but retains sequential one-shot subagents, protecting
  the phase orchestrator's context.
- Use `LOOP_SPEC_TEAMS_MODE=none`, `LOOP_SPEC_EXECUTE_LOOPS=0`,
  `LOOP_SPEC_EXECUTE_WORKFLOW=0`, and `LOOP_SPEC_PLAN_MULTI_ANGLE=0` when the
  deployment must prohibit persistent teams/fleets/workflows while retaining
  one-shot subagents.
- Set `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` for one enforceable cap across phase
  role agents. Any explicit cap selects bounded one-shot waves and disables
  teams, workflows, and fleets automatically.
- Use `LOOP_SPEC_PHASE_HANDOFF=1` to run one durable phase per main-agent
  invocation. A user or supervisor reissues the cycle command and resume
  detection starts the next phase in a fresh context.
- If worktrees stay enabled, leave `LOOP_SPEC_SHARE_DEPENDENCIES=1` so task
  worktrees link a matching successfully prepared `node_modules`.
- Set the Cloud Run task timeout above the SDK timeout. Keep enough margin for
  reconciliation; Cloud Run sends `SIGTERM` only 10 seconds before `SIGKILL`.
- Persist the control checkout or incrementally mirror `.loop-spec/active-run.json`
  and committed Git state. Local disk cannot survive an instance crash.

Conservative example policy. Every value is an operator input, not a hardware
assumption:

```bash
LOOP_SPEC_AUTONOMOUS=1
LOOP_SPEC_NON_INTERACTIVE=1
LOOP_SPEC_WORKTREES=0
LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS=1
LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=1
LOOP_SPEC_TEAMS_MODE=none
LOOP_SPEC_EXECUTE_LOOPS=0
LOOP_SPEC_EXECUTE_WORKFLOW=0
LOOP_SPEC_PLAN_MULTI_ANGLE=0
LOOP_SPEC_PHASE_HANDOFF=1
LOOP_SPEC_SHARE_DEPENDENCIES=1
LOOP_SPEC_PREPARE_TIMEOUT_SECS=1200
LOOP_SPEC_PREPARE_IDLE_TIMEOUT_SECS=300
LOOP_SPEC_BASELINE_TIMEOUT_SECS=1800
LOOP_SPEC_BASELINE_IDLE_TIMEOUT_SECS=300
LOOP_SPEC_CHECKPOINT_EACH_PHASE=1
```

The same controls can be scoped to one CLI invocation:

```bash
LOOP_SPEC_WORKTREES=0 \
LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=1 \
LOOP_SPEC_PHASE_HANDOFF=1 \
claude -p "/loop-spec:cycle autonomous phase:fresh ${TASK_PROMPT}"
```

## SDK policy

Use all four independent bounds:

1. `max_turns` bounds tool-use round trips.
2. `max_budget_usd` bounds estimated model spend.
3. `effort` controls reasoning/tool-call volume; choose it from workload evals.
4. An outer wall timeout bounds the SDK subprocess and local tools.

With phase handoffs, `max_turns`, `max_budget_usd`, and the SDK timeout apply to
each fresh phase query. Bound the whole job separately with
`MAX_PHASE_INVOCATIONS`, the Cloud Run task timeout, and a controller-level
cumulative spend policy.

Also configure a fallback model, partial-message streaming, an stderr callback,
and a finite SDK stdout buffer. The stream is observability, not the terminal
contract; `.loop-spec/last-result.json` remains authoritative.

```python
import asyncio
import json
import os
import signal
import subprocess
from pathlib import Path

from claude_agent_sdk import ClaudeAgentOptions, query

ROOT = Path(os.environ["REPO_ROOT"]).resolve()
PLUGIN = Path(os.environ["LOOP_SPEC_PLUGIN"]).resolve()
CYCLE_TIMEOUT_SECONDS = int(os.environ.get("CYCLE_TIMEOUT_SECONDS", "10800"))
MAX_PHASE_INVOCATIONS = int(os.environ.get("MAX_PHASE_INVOCATIONS", "12"))


def optional_int(name: str) -> int | None:
    return int(os.environ[name]) if os.environ.get(name) else None


def optional_float(name: str) -> float | None:
    return float(os.environ[name]) if os.environ.get(name) else None


async def run() -> None:
    option_overrides = {}
    if (value := optional_int("CLAUDE_MAX_TURNS")) is not None:
        option_overrides["max_turns"] = value
    if (value := optional_float("CLAUDE_MAX_BUDGET_USD")) is not None:
        option_overrides["max_budget_usd"] = value
    if (value := os.environ.get("CLAUDE_EFFORT")):
        option_overrides["effort"] = value
    if (value := os.environ.get("CLAUDE_MODEL")):
        option_overrides["model"] = value
    if (value := os.environ.get("CLAUDE_FALLBACK_MODEL")):
        option_overrides["fallback_model"] = value

    for _ in range(MAX_PHASE_INVOCATIONS):
        options = ClaudeAgentOptions(
            plugins=[{"type": "local", "path": str(PLUGIN)}],
            setting_sources=["project"],
            permission_mode=os.environ.get("CLAUDE_PERMISSION_MODE", "acceptEdits"),
            cwd=str(ROOT),
            include_partial_messages=True,
            max_buffer_size=int(os.environ.get(
                "CLAUDE_MAX_BUFFER_BYTES", str(8 * 1024 * 1024)
            )),
            stderr=lambda line: print(line, flush=True),
            env=dict(os.environ),
            **option_overrides,
        )
        phase_token = (
            " phase:fresh"
            if os.environ.get("LOOP_SPEC_PHASE_HANDOFF") == "1"
            else ""
        )
        prompt = (
            "/loop-spec:cycle autonomous"
            + phase_token
            + " "
            + os.environ["TASK_PROMPT"]
        )
        async with asyncio.timeout(CYCLE_TIMEOUT_SECONDS):
            async for message in query(prompt=prompt, options=options):
                print(message, flush=True)

        result = json.loads(
            (ROOT / ".loop-spec" / "last-result.json").read_text()
        )
        if not (
            result.get("status") == "paused"
            and result.get("reason") == "phase-handoff"
        ):
            return
    raise RuntimeError("MAX_PHASE_INVOCATIONS exhausted before a terminal cycle result")


def reconcile(reason: str) -> None:
    subprocess.run(
        [
            "bash",
            str(PLUGIN / "lib" / "cycle-reconcile.sh"),
            "--result-root",
            str(ROOT),
            "--reason",
            reason,
        ],
        cwd=ROOT,
        timeout=8,
        check=False,
    )


async def main() -> None:
    loop = asyncio.get_running_loop()
    stopping = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopping.set)
    task = asyncio.create_task(run())
    stop = asyncio.create_task(stopping.wait())
    try:
        done, _ = await asyncio.wait(
            {task, stop}, return_when=asyncio.FIRST_COMPLETED
        )
        if stop in done:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            reconcile("Cloud Run termination signal")
        else:
            stop.cancel()
            await task
    except Exception as exc:
        reconcile(f"Agent SDK terminated: {type(exc).__name__}: {exc}")
        raise
    finally:
        stop.cancel()


asyncio.run(main())
```

## Supervisor contract

The in-container handler covers ordinary exceptions, SDK termination, and
Cloud Run's `SIGTERM` grace window. It cannot cover `SIGKILL`, OOM termination,
host loss, or a fatal signal that prevents Python from running.

The durable job controller must therefore:

1. Record the job/run ID and repository storage location before starting Cloud
   Run.
2. Observe Cloud Run completion out of band.
3. If no durable terminal result exists, restore/mount the control checkout and
   run:

```bash
bash /path/to/loop-spec/lib/cycle-reconcile.sh \
  --result-root /path/to/repo \
  --reason "Cloud Run task ended without a terminal result"
```

4. Read `.loop-spec/last-result.json`, not stdout, to decide whether to retry.

`cycle-reconcile.sh` uses `active-run.json` to locate the latest durable feature
state, pushes committed progress, creates or reuses a draft checkpoint PR, and
writes a failed terminal result. If death occurred before feature initialization,
it still writes an `interrupted` full-cycle result from the startup pointer.

## Deployment questions

Answer these before treating the runner as production-safe:

- Is this a Cloud Run Job or a request-serving Service? A multi-hour coding task
  should normally be a Job.
- Where do the Git checkout and `active-run.json` survive instance death?
- Who invokes reconciliation after OOM, `SIGKILL`, or infrastructure loss?
- What measured per-run memory/CPU envelope and concurrency limit apply to this
  deployment size?
- What are the task timeout, inner SDK timeout, turn cap, and spend cap?
- Which setup/test commands may legitimately be silent for more than five
  minutes, and what explicit timeout do they need?
- Are shared `node_modules` treated as immutable during EXECUTE? If not, disable
  sharing.
- Is phase checkpoint pushing acceptable for every autonomous run, including
  the early spec-only draft PR?
- Should the supervisor relaunch every phase automatically, or leave each
  `phase-handoff` result for an explicit user re-invocation?
