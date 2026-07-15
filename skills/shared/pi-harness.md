# pi harness adaptation (reference)

Applies when loop-spec runs under **pi** (https://pi.dev) instead of Claude Code:
`bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" detect` prints `pi` (equivalently,
`cycle-preflight.sh` reports `harness.name == "pi"` / `.loop-spec/runtime.json.harness
== "pi"`). loop-spec installs there as a pi package
(`pi install git:github.com/aztechead/loop-spec`): skills load through the Agent
Skills standard both harnesses share, `commands/loop-debug.md` loads as a prompt
template, and the bundled extension (`extensions/pi/loop-spec.ts`) bridges env and
hooks. This file is ADDITIVE — when the harness is `claude`, nothing here applies
and every skill runs exactly as written.

## Environment contract (who sets what)

The pi extension delivers, into every bash invocation (both by setting
`process.env` and by prepending an `export` line to each bash command — the
prepend guarantees delivery even if pi curates the child environment):
`LOOP_SPEC_HARNESS=pi`, `CLAUDE_PLUGIN_ROOT` (package root),
`CLAUDE_PROJECT_DIR` (session cwd), and `CLAUDE_SKILL_DIR` (directory of the
last SKILL.md read — under pi you enter a skill by reading its SKILL.md, so
that IS the active skill).

**Re-export rule (cross-skill reads):** the tracked `CLAUDE_SKILL_DIR` follows
the LAST SKILL.md you read. When a skill reads another skill's SKILL.md
mid-flow (the cycle reads phase skills; loop-debug points at debug) and you
then need a **skill-local** path (`${CLAUDE_SKILL_DIR}/references/...`,
`${CLAUDE_SKILL_DIR}/scripts/...`) of the skill you are still executing,
re-export the variable to that skill's directory first. Sibling paths like
`${CLAUDE_SKILL_DIR}/../../lib/...` are unaffected (all loop-spec skills are
siblings).

**Fallback rule (extension not loaded — e.g. skills pointed at via a settings
`skills` path):** before running any `${CLAUDE_SKILL_DIR}/...` command, export the
variable yourself — it is the directory of the SKILL.md you are currently
following, which you know because you read it:

```bash
export CLAUDE_SKILL_DIR="<absolute dir of the SKILL.md you are following>"
```

## Tool substitution table

| Claude Code tool | Under pi |
|---|---|
| Read / Write / Edit / Bash | `read` / `write` / `edit` / `bash` (same semantics) |
| Glob / Grep | `find` / `grep` (or bash equivalents) |
| Skill (invoke a skill) | read the target skill's `SKILL.md` (sibling dir under `skills/`) and follow it; users invoke via `/skill:<name>` |
| Agent (one-shot subagent) | DOES NOT EXIST → the **inline dispatch rule** below |
| Teams (named `Agent` spawns, SendMessage, TeamCreate/TeamDelete) | never — `teamsMode` is hard-gated to `none` under pi (`lib/teams-capability.sh`) |
| Workflow | never — hard-gated `false` (`lib/workflow-availability.sh`) |
| TaskCreate / TaskUpdate / TaskList / TaskGet | none — DAG and wave state live where they already durably live: PLAN.md task blocks + `feature.json`; no harness task list exists or is needed |
| AskUserQuestion | interactive (TUI): ask in plain chat text — lettered options, one question block, wait for the reply; autonomous: self-answer per `skills/shared/autonomous-mode.md`, unchanged |
| ToolSearch (deferred-tool rescue) | does not exist; nothing is deferred under pi — skip rescue steps entirely |
| EnterWorktree / ExitWorktree | no session-root switch exists. Cycle uses its clean in-place feature branch (`executionRootMode: "in-place"`) and never fakes a cwd change with `git worktree add`. |

## Inline dispatch rule (replaces every one-shot `Agent` call)

Under pi, every one-shot `Agent` dispatch a phase skill (or
`skills/shared/no-teams-fallback.md`) prescribes — subagent type
`loop-spec:<role>` carrying a prompt P — becomes: **the lead performs P itself,
inline**, after reading the role's charter (`agents/<role>.md`,
or the solo-critic / team-prompt brief the call referenced), and produces the SAME
artifact the call would have returned — gate-log transcripts, verdict JSON, review
findings, all unchanged in shape and location. Parallel fan-out collapses to a
sequential loop over the same prompts.

Role boundaries become self-discipline rather than process isolation: when acting
as challenger or critic, argue against the draft you just wrote honestly and record
the verdict before continuing; when acting as reviewer, evaluate against the
acceptance criteria, not against effort. The gates and artifacts do not change; the
recorded execution root is in-place because pi cannot switch the session cwd. DELIVER
uses the same explicit-path `lib/deliver.sh` controller. Only the dispatch mechanism does (the same
invariant `no-teams-fallback.md` maintains one level up).

Exception: EXECUTE does not use this rule directly — its ladder selects the
**inline rung** (`skills/shared/execute-inline.md`) or the **loop-fleet rung**
(`skills/shared/execute-loop-fleet.md` with `agent_cli = pi`); see the rung rule in
`skills/execute/SKILL.md` Step 3b.

## Graphify assistant integration

Register Graphify's pi-specific external skill separately:

```bash
graphify install --platform pi
```

`skills/shared/graphify-lifecycle.md` is authoritative. When cycle or map-codebase
requests Graphify, read the SKILL.md for pi's discovered external graphify skill;
do not look for it as a sibling of loop-spec. Follow it with `.` for a first build or
`. --update` for an existing graph. Graphify's semantic Agent fan-out follows the
inline dispatch rule above: process every chunk sequentially with the current pi model
and its existing authentication. Capture and restore loop-spec's `CLAUDE_SKILL_DIR`
before validation because reading Graphify's SKILL.md changes the active directory.
Embedded Graphify never asks corpus-narrowing or post-build exploration questions.

## Startup probes

Skip the cycle's model probe (Step 3.5) entirely — it exists to pre-flight `Agent`
dispatches, and there are none. Model policy failures surface loudly on the first
loop-fleet dispatch instead. Teams and Workflow probes need no special-casing: the
capability scripts return `none` / `false` under pi on their own.

## Model routing

There is no per-dispatch `model` parameter — all inline work runs on the session
model the user launched pi with. Loop-fleet rungs pass models to `pi` headless via
`--model`; the `LOOP_SPEC_MODEL_<ROLE>` overrides are still honored, but values
must be **pi model ids** (e.g. `claude-sonnet-4-5`), not Claude Code aliases —
`skills/shared/model-matrix.md` aliases like `sonnet`/`opus` mean nothing to pi.

## Both run modes (parity map)

| Claude Code | pi |
|---|---|
| interactive session | pi TUI (`pi`) |
| `claude -p` headless / autonomous mode | `pi --mode json "<prompt>"` (or `pi -p`, or the SDK's `createAgentSession()` from `@earendil-works/pi-coding-agent`) with `LOOP_SPEC_AUTONOMOUS=1` |
| loop-runner fleet spawning `claude -p` | same fleet spawning `pi --mode json` — the agent CLI is resolved by `bash lib/harness.sh cli` and passed to `loop.py --agent-cli pi` |
