# Model Matrix

Maps each agent role to a fixed model ID. There is no model preset axis: model
selection is fixed and identical for every feature. Gate behavior,
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

These aliases are a **Claude Code** surface. Under the pi harness there is no
per-dispatch model routing at all (inline work runs on the session model) and
loop-fleet dispatch takes pi model **ids**, not aliases — see
`skills/shared/pi-harness.md` "Model routing".

## Matrix

| Role family | Model |
|---|---|
| spec-writer, planner | opus |
| challenger | opus |
| iterate-judge | opus |
| code-reviewer | opus |
| advocate | sonnet |
| spec-compliance-reviewer | sonnet |
| verifier | sonnet |
| implementer | sonnet |
| mapper-*, pattern-mapper | sonnet |

## Design rules

- **Opus** runs the reasoning-heavy roles: spec/plan authoring (spec-writer,
  planner), the challenge side of the SPEC/PLAN critique gate (challenger), the
  ITERATE goal re-judge (iterate-judge), and the code-review HARD-GATE
  (code-reviewer).
- **Sonnet** runs the high-throughput and defense roles: the advocate side of the
  critique gate, per-task spec-compliance review (spec-compliance-reviewer),
  implementation (implementer), acceptance verification (verifier, mechanical
  command execution), and codebase mapping (mapper-*, pattern-mapper).
  - **advocate on sonnet:** the critique gate is asymmetric by design — the
    challenger (still opus) surfaces gaps; the advocate defends. A weaker defense
    biases the gate stricter, never looser, so sonnet cannot degrade final output.
    Since the single-critic default (`skills/shared/tier-matrix.md`, critique gate
    ladder) the advocate is dispatched only when a gate escalates to the paired
    debate; the strictness argument is unchanged.
  - **spec-compliance-reviewer on sonnet:** per-task diff-vs-task-spec check, the
    highest-volume opus dispatch. Checker == maker tier (sonnet implementer) still
    satisfies "the checker is never weaker than the maker", and three downstream
    gates backstop it: the mechanical acceptance verifier, the opus code-review
    HARD-GATE, and the opus iterate-judge scoring against the original goal.
- haiku is no longer used by any role.
- The harness alias enum also exposes `fable` (the Mythos-class tier above opus)
  where the account has access. The fixed map does not assign it; use a
  `LOOP_SPEC_MODEL_<ROLE>` env override (see below) to route a role there.
  The mid-tier execution gap is instead closed in-prompt by
  `skills/shared/execution-discipline.md` (evidence over recall), which every
  EXECUTE/VERIFY dispatch carries.

## Per-role override

Set `LOOP_SPEC_MODEL_<ROLE>` (SCREAMING_SNAKE of the JSON key) to reroute a single
role without editing `lib/feature-init.sh`:

```
LOOP_SPEC_MODEL_ITERATE_JUDGE=fable   # promote the judge to fable
LOOP_SPEC_MODEL_PLANNER=sonnet        # demote the planner to sonnet
```

**Allowed values:** `sonnet | opus | haiku | fable`. Any other value — including a
literal model ID like `claude-opus-4-8` — causes `feature-init.sh` to print a clear
error to stderr naming the offending var, the bad value, and the allowed enum, then
exit 1. No silent fallback.

**Precedence:** env override > canonical default. A per-task `model` pin or
`modelTier` in plan metadata still wins at task level and is unaffected by this
mechanism.

**Scope:** because cycle Step 5 (state init) and Step 5.9 (resume normalization)
both call `feature-init.sh models`, overrides resolve into `feature.models.<role>`
at that point and propagate to every downstream phase skill automatically — phase
skills need no changes.

Role suffixes (SCREAMING_SNAKE → JSON key):
`SPEC_WRITER` → `specWriter`, `PLANNER` → `planner`, `ADVOCATE` → `advocate`,
`CHALLENGER` → `challenger`, `SPEC_COMPLIANCE_REVIEWER` → `specComplianceReviewer`,
`ITERATE_JUDGE` → `iterateJudge`, `CODE_REVIEWER` → `codeReviewer`,
`IMPLEMENTER` → `implementer`, `VERIFIER` → `verifier`, `MAPPER` → `mapper`,
`PATTERN_MAPPER` → `patternMapper`.

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
