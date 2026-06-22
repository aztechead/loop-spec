# Model Matrix

Maps each agent role to a fixed model ID. There is no model preset axis: model
selection is fixed and identical for every feature. Gate behavior, retry budgets,
and fan-out width remain tier-driven and orthogonal; see `tier-matrix.md`.

The concrete IDs are resolved once at cycle Step 5 into `feature.models.<role>`,
and every spawn passes `model: feature.models.<role>` explicitly. This file is the
source of truth that Step 5 mirrors.

## Resolution

- opus   -> `claude-opus-4-8`
- sonnet -> `claude-sonnet-4-6` (1M context flag enabled when available)

## Matrix

| Role family | Model |
|---|---|
| spec-writer, planner | claude-opus-4-8 |
| advocate, challenger | claude-opus-4-8 |
| spec-compliance-reviewer | claude-opus-4-8 |
| iterate-judge | claude-opus-4-8 |
| code-reviewer, verifier | claude-sonnet-4-6 |
| implementer | claude-sonnet-4-6 |
| mapper-*, pattern-mapper | claude-sonnet-4-6 |

## Design rules

- **Opus** runs the reasoning-heavy roles: spec/plan authoring (spec-writer,
  planner), the SPEC/PLAN critique gate (advocate, challenger), and the
  spec-compliance gate (spec-compliance-reviewer, the Ralph loop).
- **Sonnet** runs the high-throughput roles: implementation (implementer), code
  review (code-reviewer), acceptance verification (verifier), and codebase
  mapping (mapper-*, pattern-mapper).
- haiku is no longer used by any role.

## Dispatch rule

Phase skills read literal IDs from `feature.models.<role>` (resolved once at cycle
Step 5). They MUST NOT re-derive from this file per spawn. Pass the resolved model
on every spawn:

```
TeamCreate({
  name: "loop-spec-{phase}-{slug}",
  teammates: [
    { name: "implementer-1", subagent_type: "loop-spec:implementer", model: feature.models.implementer, prompt: "..." },
    // ... additional teammates
  ]
})
```

The one-shot `Agent({subagent_type, model, prompt})` form (reserved for Step 5.5b
background codebase mappers) also requires an explicit `model:` parameter.

Never rely on agent frontmatter default. Never omit the `model:` parameter.

## Standalone (no feature.json)

Skills invoked without a feature.json context use the same fixed map. There is no
`--preset` flag. `map-codebase` standalone spawns its mappers on
`claude-sonnet-4-6`.

## Unique model set

Two distinct model IDs are used across all roles: `claude-opus-4-8` and
`claude-sonnet-4-6`. The cycle startup health-check probes both.
