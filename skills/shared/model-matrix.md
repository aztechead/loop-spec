# Model routing

loop-spec is model-portable by default. Every role uses `inherit`, so the model
that launched the Claude Code, OpenCode, Codex, or ADK session can run the
complete cycle. No provider, model family, or premium tier is a prerequisite.

This follows the current host contracts:

- Claude Code: an omitted subagent model defaults to `inherit`; `inherit`
  uses the main conversation's model. Explicit aliases and full model IDs are
  also supported: https://code.claude.com/docs/en/sub-agents#choose-a-model
- OpenCode: a subagent with no model override uses the primary agent's model:
  https://opencode.ai/docs/agents/#model
- Codex: a custom agent with no `model` key inherits the parent session model:
  https://developers.openai.com/codex/subagents

The graph's `system1` and `system2` effort values do not select a model. They
change the phase guidance described in `skills/shared/dual-process.md`. Keeping
effort and model selection separate makes the graph mean the same thing in both
harnesses, regardless of which models either account exposes.

## Default map

| Role family | Default |
|---|---|
| spec-writer, planner | inherit |
| challenger, advocate | inherit |
| iterate-judge, code-reviewer | inherit |
| spec-compliance-reviewer, verifier | inherit |
| implementer | inherit |
| pattern-mapper | inherit |

`lib/feature-init.sh activate` writes this map to
`feature.models.<role>` before each phase. Claude dispatches add a `model` key
only for an Agent-compatible alias and omit it for `inherit`. OpenCode maps the
same logical dispatch to its generated agent and omits a per-call model, as
required by `skills/shared/opencode-harness.md`.
ADK resolves a role's model from its charter only when that names an ADK id and
otherwise inherits the mounted agent's model, as required by
`skills/shared/adk-harness.md`.
Codex maps the same logical dispatch to a generated custom agent and passes
`spawn_agent`'s optional `model` only when `feature.models.<role>` is a Codex
slug, as required by `skills/shared/codex-harness.md`.

## Resolution and overrides

Precedence stays:

1. a concrete task `model`, when the dispatch rung supports it;
2. `LOOP_SPEC_MODEL_<ROLE>`;
3. `LOOP_SPEC_PHASE_MODEL_<PHASE>`;
4. `inherit`.

For Claude Code, a role override may be `inherit` or a host alias such as
`sonnet`, `opus`, `haiku`, or `fable`. A full model ID is valid only as a phase
override consumed by a fresh CLI/SDK main-context launcher; its role agents omit
the model key and inherit that main model. `feature-init.sh` rejects a full ID in
a Claude role override because Agent cannot consume it. On the implicit-team
harness, a Claude alias is consumed only by a **nameless** Agent spawn; a named
teammate inherits the session even if the key is present
(`skills/shared/dispatch.md`). A selector is explicit
operator policy; loop-spec does not maintain a model-ID catalog or silently
translate one family into another.

`lib/model-tier.sh` is the one exception: `mechanical` on Claude Code resolves
to the cheapest Agent alias (`haiku`); every other tier and every other harness
still inherits. `upgrade haiku` on Claude Code is one step to `sonnet`.

The consuming surfaces differ and a selector valid for one is not valid for all:

| Surface | Accepts |
|---|---|
| `Agent({model:})` tool parameter | the four aliases only; `inherit` and full IDs are rejected — omit the key to inherit |
| named implicit-team `Agent({name})` | session model only — alias and frontmatter are ignored (`lib/implicit-team-model.sh`) |
| agent definition frontmatter (`agents/*.md`) | an alias or `inherit` |
| `claude --model` / SDK `model` option | an alias or a full model ID; never the literal `inherit` |

Supported phase suffixes are `SPEC`, `DISCUSS`, `PLAN`, `EXECUTE`, `VERIFY`,
`ITERATE`, and `DELIVER`. Supported role suffixes are `SPEC_WRITER`,
`PLANNER`, `ADVOCATE`, `CHALLENGER`, `SPEC_COMPLIANCE_REVIEWER`,
`ITERATE_JUDGE`, `CODE_REVIEWER`, `IMPLEMENTER`, `VERIFIER`,
and `PATTERN_MAPPER`.

For a fresh main-context phase, `feature.phaseModels.<phase>` supplies the
configured selector to a Claude CLI or SDK launcher. An unset entry remains
`null`, which inherits the launcher's model. Continuous mode cannot replace its
own main model, but role subagents still consume the activated map.

OpenCode routes native role models through generated-agent configuration, using
`provider/model` IDs. Configure those with
`opencode-install.sh install --model` or a project agent override. Unrouted
agents inherit the primary model. The OpenCode `task` tool has no per-call
`model` field, so `LOOP_SPEC_PHASE_MODEL_*` / non-implementer `LOOP_SPEC_MODEL_*`
are not forwarded on task dispatch. ADK role agents inherit the mounted app
model unless `dispatch_subagent` is given a native id; the ADK and OpenCode
loop-fleet rungs may receive a native implementer ID through
the `LOOP_SPEC_MODEL_<ROLE>` family with role `IMPLEMENTER`. Other OpenCode
role overrides reject native IDs because no shipped `task` dispatch consumes
them. Set a native selector only when the selected rung will consume it;
neither harness consumes Claude aliases.

Legacy task `modelTier` values remain accepted so old plans resume, but
`lib/model-tier.sh` resolves every tier to `inherit`. A plan that truly needs a
specific model must carry an explicit operator-approved `model` value.

## Dispatch rule

Claude phase skills read `feature.models.<role>` and pass it on each Agent spawn
**only when it is one of the four aliases and the spawn is nameless**. When it
resolves to `inherit` — the default — OMIT the `model` key entirely: the Agent
tool's `model` is an alias enum and rejects the literal string `inherit` with
`InputValidationError` (`skills/shared/dispatch.md` records the live
probe). Named implicit-team spawns also omit `model` and omit any alias: they are
in-process teammates that inherit the session (`lib/implicit-team-model.sh`).
The durable policy still shows in `feature.models.<role>`; the dispatch does not
restate it.
Under OpenCode, apply the native task mapping and omit the per-call model —
`LOOP_SPEC_PHASE_MODEL_*` is not a `task` parameter; pin roles with generated-agent
`--model` routes (`skills/shared/opencode-harness.md`). Under ADK, pass
`dispatch_subagent`'s optional `model` when `feature.models.<role>` is an ADK id
(`gemini-*` or `provider/model`); `inherit` and Claude aliases fall back to the
mounted app model (`skills/shared/adk-harness.md`). Under Codex, pass
`spawn_agent`'s optional `model` when `feature.models.<role>` is a Codex slug;
`inherit` and Claude aliases fall back to the custom agent file or parent
session model (`skills/shared/codex-harness.md`). Pin generated agents with
`codex-install.sh install --model`.

Standalone skills and agents also default to `inherit`. A user's chosen session
model is a complete supported configuration, not a degraded mode.
