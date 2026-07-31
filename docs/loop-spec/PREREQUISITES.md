# Prerequisites

## Base runtime

Every harness requires `bash >= 4`, `git`, `jq >= 1.5`, and `python3 >= 3.6`.
`lib/runtime-preflight.sh` checks jq before cycle, auto, debug, micro, and OpenCode
installer paths use it, so a missing or old binary fails once with installation guidance
instead of producing mid-run command errors.

## Graphify assistant skill

Graphify is the one hard external assistant dependency. Install its Python 3.10+ package, then
register the platform-specific assistant skill:

```bash
uv tool install graphifyy
graphify install                         # Claude Code
graphify install --platform pi           # pi
graphify install --platform opencode     # OpenCode
```

Restart the harness after registration. loop-spec invokes the external skill through
`skills/shared/graphify-lifecycle.md`; it does not use Graphify's headless provider
backend for construction. Semantic extraction therefore runs through the current host
assistant and inherits its authentication. On GCP Agent Platform/Vertex deployments,
that means the harness's attached service account, Workload Identity, or other ADC
configuration remains the authentication boundary; no separate Gemini or Anthropic API
key is required by loop-spec. Graphify's local AST extraction still handles code.

The lifecycle fails closed if the skill cannot be loaded, semantic chunks are skipped,
or outputs fail validation. `LOOP_SPEC_REQUIRE_GRAPHIFY=0` is the explicit degraded
Glob/Grep escape hatch.

## CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

The cycle skill's agent-teams mode requires the experimental agent teams feature to be enabled in Claude Code.

### Required environment variable

```bash
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

Set this before launching `claude` or add it to the `env` section of your `.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### Minimum Claude Code version

> **Agent teams are an accelerator, not a hard requirement.** When the flag is
> unset (or its tools are unavailable), the cycle still runs end-to-end on the
> no-teams fallback (one-shot `Agent` dispatch; EXECUTE uses the loop-fleet or
> subagent rung). Graphify remains the only hard assistant startup requirement; the base
> runtime dependencies above are also mandatory.

### Two harness generations (the cycle auto-detects)

The agent-teams tool surface changed in Claude Code **2.1.178**. The cycle
resolves which generation is live with `lib/teams-capability.sh` and records the
result in `.loop-spec/runtime.json.teamsMode`:

| `teamsMode` | When | How teammates are created |
|---|---|---|
| `none` | flag unset / not `1` | No team — one-shot `Agent` calls (`skills/shared/no-teams-fallback.md`) |
| `explicit` | flag=1 **and** CC `< 2.1.178` | Per-phase `TeamCreate` / `TeamDelete` roster |
| `implicit` | flag=1 **and** CC `>= 2.1.178` | One implicit team; teammates spawned via `Agent({name})`, **no `TeamCreate`/`TeamDelete`** (`skills/shared/implicit-team-mode.md`) |

Force the mode with `LOOP_SPEC_TEAMS_MODE=none|explicit|implicit` (testing / constrained environments).
Setting `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` forces `teamsMode=none` and runs
one-shot role agents in bounded waves so the operator's concurrency cap is
enforceable.

### Minimum Claude Code version

v2.1.32 or later. On **CC >= 2.1.178** the `TeamCreate` / `TeamDelete` tools no
longer exist — setting the flag is all that is needed; the cycle uses the
implicit-team model automatically. Check your current version:

```bash
claude --version
```

### Required harness capabilities

The cycle's team path assumes the harness supports:

- **Named teammates** — `Agent({name})` (implicit model, CC >= 2.1.178) **or** `TeamCreate` / `TeamDelete` (explicit model, CC < 2.1.178)
- **TaskCreate / TaskUpdate / TaskGet / TaskList** - including `metadata` round-trip and `owner` release
- **SendMessage** - lead-to-teammate and teammate-to-teammate messaging
- **Concurrent `TaskUpdate` serialization** - only one of N concurrent self-claims for the same task id succeeds

These are exercised by the live `tests/smoke.sh` matrix. Startup deterministically gates
on the harness, opt-in flag, and known Claude Code generation; an unknown version fails
safe to `teamsMode == "none"`. The packaged implementer and reviewer grants include the
task-list and messaging tools above. Any unavailable or disabled team path degrades to
one-shot subagent waves at every DAG width.

## Optional hardening — constraining which models roles may use

loop-spec passes an explicit `model:` on every spawn, resolved from
`feature.models.<role>`, so off-policy models never appear under normal operation.

**Claude Code permission rules cannot enforce this.** A `Tool(specifier)` rule only
matches when the tool implements a permission matcher for that specifier, and the
`Agent` tool does not: it has no `ruleContentField`, so `Agent(model:...)` parses
without error and then matches nothing. A deny rule written that way is silently inert.
(A bare `Agent` deny rule is matched — but it blocks *every* subagent, which disables
loop-spec entirely.) `Agent(<type>,<type>)` is a real form, but its content is a list of
**agent types**, not models, and it is read by tool narrowing rather than deny rules.

Enforce the model policy where it is actually checked instead:

1. **Pin the routes.** Set `LOOP_SPEC_PHASE_MODEL_<PHASE>` and/or `LOOP_SPEC_MODEL_<ROLE>`
   in the deployment environment. Both are validated against the alias enum
   (`sonnet | opus | haiku | fable`) and reject literal model IDs, and cycle activates
   the resolved map into `feature.models.<role>` before every phase.
2. **Constrain what the aliases resolve to.** Alias → concrete model is a harness/provider
   decision (`ANTHROPIC_MODEL`, Bedrock/Vertex model mappings, gateway policy). That layer
   is the only place a retired or off-policy model ID can be excluded outright.
3. **Verify the effective set.** Run
   `bash /path/to/loop-spec/lib/feature-init.sh all-models` in the deployment environment;
   it prints the exact sorted alias set after phase and role overrides, and exits non-zero
   with no output if any override is invalid. The cycle probes that same set before work
   begins and fails loud on any error.

## Optional — nested per-repo skills (workspace mode, CC >= 2.1.178)

In workspace (multi-repo) mode, a member repo may ship its own `.claude/skills`. CC
**>= 2.1.178** loads nested skills when you work on files there and, on a name clash
with a loop-spec skill, exposes the nested one as `<dir>:<name>` so both stay reachable.
No loop-spec configuration is required; just be aware that a member repo's skill named,
e.g., `verify` will appear as `<repo-dir>:verify` alongside `loop-spec:verify`.

## pi harness (pi.dev)

None of the above applies under pi: agent teams and the Workflow tool are Claude
Code surfaces, and `lib/teams-capability.sh` / `lib/workflow-availability.sh`
hard-gate them to `none` / `false` there regardless of environment variables.
pi prerequisites are just the base runtime (`bash >= 4`, `git`, `jq >= 1.5`,
`python3 >= 3.6`), graphify, and the `pi` CLI itself for the loop-fleet rung.
See the README "Running under pi" section and `skills/shared/pi-harness.md`.
