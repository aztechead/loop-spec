# Prerequisites

## Base runtime

Every harness requires `bash >= 3.2`, `git`, `jq >= 1.5`, and `python3 >= 3.7`.
`lib/runtime-preflight.sh` checks jq before cycle, auto, debug, micro, and OpenCode
installer paths use it, so a missing or old binary fails once with installation guidance
instead of producing mid-run command errors.

## Claude Code

Claude Code v2.1.32 or later is required for the adapter. The cycle always uses
bounded one-shot Agent/session dispatch, regardless of optional team tools. Check
the installed version with `claude --version`.

### Bounded dispatch policy

The cycle records `teamsMode` in `.loop-spec/runtime.json`, but persistent teams
and Workflow fan-out are disabled by the resource policy. A finite
`LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` value is enforced by one-shot waves, including
values above one. This keeps the cap meaningful across SPEC, DISCUSS, PLAN, and
EXECUTE. `LOOP_SPEC_WORKTREES=0` clamps both resource caps to one in
`lib/resource-bounds.sh`.

| `teamsMode` | When | How teammates are created |
|---|---|---|
| `none` | bounded resource policy | One-shot `Agent` calls in serial or finite waves (`skills/shared/dispatch.md`) |

`LOOP_SPEC_TEAMS_MODE=none` is the only supported mode override. Positive team
mode values do not bypass the bounded policy.

### Required harness capabilities

One-shot dispatch uses the normal Agent/session child capability and the bounded
dispatch contract. Team tools, named teammates, task-list self-claims, and
teammate messaging are optional integrations; they are not prerequisites for the
bounded path. The live matrix in `tests/README.md` probes those optional tools when
available, while startup keeps the finite child cap enforceable without them.

## Optional hardening — constraining which models roles may use

loop-spec resolves every spawn from `feature.models.<role>`. It adds an explicit
Agent `model` key only for a supported alias and omits the key for `inherit`, so
the default follows the operator's session model without inventing a model ID.

**Claude Code permission rules cannot enforce this.** A `Tool(specifier)` rule only
matches when the tool implements a permission matcher for that specifier, and the
`Agent` tool does not: it has no `ruleContentField`, so `Agent(model:...)` parses
without error and then matches nothing. A deny rule written that way is silently inert.
(A bare `Agent` deny rule is matched — but it blocks *every* subagent, which disables
loop-spec entirely.) `Agent(<type>,<type>)` is a real form, but its content is a list of
**agent types**, not models, and it is read by tool narrowing rather than deny rules.

Enforce the model policy where it is actually checked instead:

1. **Pin the routes.** Set `LOOP_SPEC_PHASE_MODEL_<PHASE>` and/or `LOOP_SPEC_MODEL_<ROLE>`
   in the deployment environment. Both default to `inherit`. Claude role routes
   accept Agent aliases; a full ID belongs only to a fresh phase CLI/SDK launcher.
   On Claude Code implicit-team (named `Agent({name})` teammates), those aliases
   bind only on a nameless one-shot Agent (`lib/implicit-team-model.sh`).
   Cycle activates the consumable role map into `feature.models.<role>` before
   every phase and rejects a selector that its dispatch surface cannot use.
2. **Constrain explicit aliases.** Alias → concrete model is a harness/provider
   decision (`ANTHROPIC_MODEL`, Bedrock/Vertex model mappings, gateway policy). That layer
   is the only place a retired or off-policy model ID can be excluded outright.
3. **Verify the effective set.** Run
   `bash /path/to/loop-spec/lib/feature-init.sh all-models` in the deployment environment;
   it prints the exact sorted selector set after phase and role overrides, and exits non-zero
   with no output if any override is invalid. The cycle probes that same set before work
   begins and fails loud on any error.

## Optional — nested per-repo skills (workspace mode, CC >= 2.1.178)

In workspace (multi-repo) mode, a member repo may ship its own `.claude/skills`. CC
**>= 2.1.178** loads nested skills when you work on files there and, on a name clash
with a loop-spec skill, exposes the nested one as `<dir>:<name>` so both stay reachable.
No loop-spec configuration is required; just be aware that a member repo's skill named,
e.g., `verify` will appear as `<repo-dir>:verify` alongside `loop-spec:verify`.

## OpenCode, Codex, and ADK harnesses

None of the above applies there: agent teams and the Workflow tool are Claude
Code surfaces, and `lib/teams-capability.sh` / `lib/workflow-availability.sh`
hard-gate them to `none` / `false` there regardless of environment variables.
OpenCode prerequisites are the base runtime (`bash >= 3.2`, `git`, `jq >= 1.5`,
`python3 >= 3.7`) plus the `opencode` CLI for the loop-fleet rung. Codex
prerequisites are that same base runtime plus the `codex` CLI
(`codex exec --json`); install with `bash lib/codex-install.sh install` so
`LOOP_SPEC_HARNESS=codex` reaches every Bash subprocess. Codex `exec` defaults
to a read-only sandbox — work ticks pass `--sandbox workspace-write` and never
`--dangerously-bypass-approvals-and-sandbox`. ADK requires
Python >=3.10 and `python3 -m pip install 'google-adk>=2.7,<3'`, plus a mounted
agent (`bash lib/adk-install.sh install`); `install` and `check` reject a missing
package or any version outside that range. Its `adk` CLI runs loop-fleet ticks.
The ADK bridge uses the experimental upstream `LocalEnvironment`: file tools
enforce project containment, while Execute starts a shell in the project that
still inherits the operating-system user's host permissions. Run it in an
isolated container or under a restricted service account for untrusted code.
See `skills/shared/opencode-harness.md`, `skills/shared/codex-harness.md`, and
`skills/shared/adk-harness.md`.
