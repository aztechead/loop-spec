# Model routing

loop-spec is model-portable by default. Every role uses `inherit`, so the model
that launched the Claude Code or OpenCode session can run the complete cycle.
No provider, model family, or premium tier is a prerequisite.

This follows both current host contracts:

- Claude Code: an omitted subagent model defaults to `inherit`; `inherit`
  uses the main conversation's model. Explicit aliases and full model IDs are
  also supported: https://code.claude.com/docs/en/sub-agents#choose-a-model
- OpenCode: a subagent with no model override uses the primary agent's model:
  https://opencode.ai/docs/agents/#model

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
| mapper-*, pattern-mapper | inherit |

`lib/feature-init.sh activate` writes this map to
`feature.models.<role>` before each phase. Claude dispatches pass the value
explicitly. OpenCode maps the same logical dispatch to its generated agent and
omits a per-call model, as required by `skills/shared/opencode-harness.md`.
Pi performs inline dispatch and inherits its session model as described in
`skills/shared/pi-harness.md`.

## Resolution and overrides

Precedence stays:

1. a concrete task `model`, when the dispatch rung supports it;
2. `LOOP_SPEC_MODEL_<ROLE>`;
3. `LOOP_SPEC_PHASE_MODEL_<PHASE>`;
4. `inherit`.

For Claude Code, an explicit selector may be `inherit`, a host alias such as
`sonnet`, `opus`, `haiku`, or `fable`, or a full model ID accepted by the CLI.
A selector is explicit operator policy; loop-spec does not maintain a model-ID
catalog or silently translate one family into another.

The consuming surfaces differ and a selector valid for one is not valid for all:

| Surface | Accepts |
|---|---|
| `Agent({model:})` tool parameter | the four aliases only; `inherit` and full IDs are rejected — omit the key to inherit |
| agent definition frontmatter (`agents/*.md`) | an alias or `inherit` |
| `claude --model` / SDK `model` option | an alias or a full model ID; never the literal `inherit` |

Supported phase suffixes are `SPEC`, `DISCUSS`, `PLAN`, `EXECUTE`, `VERIFY`,
`ITERATE`, and `DELIVER`. Supported role suffixes are `SPEC_WRITER`,
`PLANNER`, `ADVOCATE`, `CHALLENGER`, `SPEC_COMPLIANCE_REVIEWER`,
`ITERATE_JUDGE`, `CODE_REVIEWER`, `IMPLEMENTER`, `VERIFIER`, `MAPPER`,
and `PATTERN_MAPPER`.

For a fresh main-context phase, `feature.phaseModels.<phase>` supplies the
configured selector to a Claude CLI or SDK launcher. An unset entry remains
`null`, which inherits the launcher's model. Continuous mode cannot replace its
own main model, but role subagents still consume the activated map.

OpenCode routes models through native generated-agent configuration, using
`provider/model` IDs. Configure those with
`opencode-install.sh install --model` or a project agent override. Unrouted
agents inherit the primary model. Pi performs inline work on its session model;
its loop-fleet may receive a pi model ID explicitly. Set a native selector only
when the selected rung will consume it; neither harness consumes Claude aliases.

Legacy task `modelTier` values remain accepted so old plans resume, but
`lib/model-tier.sh` resolves every tier to `inherit`. A plan that truly needs a
specific model must carry an explicit operator-approved `model` value.

## Dispatch rule

Claude phase skills read `feature.models.<role>` and pass it on each Agent spawn
**only when it is one of the four aliases**. When it resolves to `inherit` — the
default — OMIT the `model` key entirely: the Agent tool's `model` is an alias
enum and rejects the literal string `inherit` with `InputValidationError`
(`skills/shared/harness-call-contracts.md` records the live probe). The durable
policy still shows in `feature.models.<role>`; the dispatch does not restate it.
Under OpenCode, apply the native task mapping and omit the per-call model; under
pi, perform the role inline.

Standalone skills and agents also default to `inherit`. A user's chosen session
model is a complete supported configuration, not a degraded mode.
