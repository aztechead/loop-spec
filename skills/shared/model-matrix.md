# Model Matrix

Maps each agent role to a fixed model ID. There is no model preset axis: model
selection is fixed and identical for every feature. Gate behavior, retry budgets,
and fan-out width are also fixed (single-tier operation); see `tier-matrix.md`.

The concrete IDs are resolved once at cycle Step 5 into `feature.models.<role>`,
and every spawn passes `model: feature.models.<role>` explicitly. This file is the
source of truth that Step 5 mirrors.

## Resolution

Dispatch values are harness **aliases**, not pinned IDs: the modern Agent tool's
`model` parameter is an alias enum (`sonnet | opus | haiku | ...`) and rejects
literal IDs like `claude-opus-4-8` with an InputValidationError. The alias
resolves to the harness's current model for that family (as of this writing:
opus -> claude-opus-4-8, sonnet -> claude-sonnet-4-6).

## Matrix

| Role family | Model |
|---|---|
| spec-writer, planner | opus |
| advocate, challenger | opus |
| spec-compliance-reviewer | opus |
| iterate-judge | opus |
| code-reviewer | opus |
| verifier | sonnet |
| implementer | sonnet |
| mapper-*, pattern-mapper | sonnet |

## Design rules

- **Opus** runs the reasoning-heavy roles: spec/plan authoring (spec-writer,
  planner), the SPEC/PLAN critique gate (advocate, challenger), and the
  spec-compliance gate (spec-compliance-reviewer, the Ralph loop), the ITERATE
  goal re-judge (iterate-judge), and the code-review HARD-GATE (code-reviewer):
  the checker is never weaker than the maker.
- **Sonnet** runs the high-throughput roles: implementation (implementer),
  acceptance verification (verifier, mechanical command execution), and codebase
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

The one-shot `Agent({description, subagent_type, model, prompt})` form (reserved for Step 5.5b
background codebase mappers) also requires an explicit `model:` parameter.

Never rely on agent frontmatter default. Never omit the `model:` parameter.

## Standalone (no feature.json)

Skills invoked without a feature.json context use the same fixed map. There is no
`--preset` flag. `map-codebase` standalone spawns its mappers on the `sonnet`
alias.

## Unique model set

Two distinct aliases are used across all roles: `opus` and `sonnet`. The cycle
startup health-check probes both.
