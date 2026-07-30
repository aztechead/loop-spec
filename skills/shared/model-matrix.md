# Model Matrix

Maps each agent role to its default model alias and defines optional per-phase
routing. There is no model preset axis. Gate behavior and fan-out width are
fixed (single-tier operation); see `tier-matrix.md`.

Immediately before every phase invocation, `lib/feature-init.sh activate` writes
the effective route into `feature.models.<role>`, and every spawn passes that
literal value. It also persists configured phase defaults in
`feature.phaseModels.<phase>`.

## Resolution

Dispatch values are harness **aliases**, not pinned IDs: the modern Agent tool's
`model` parameter is an alias enum (`sonnet | opus | haiku | ...`) and rejects
literal IDs like `claude-opus-4-8` with an InputValidationError. The alias
resolves to the harness's current model for that family (as of this writing:
opus -> claude-opus-4-8, sonnet -> claude-sonnet-4-6).

These aliases are a **Claude Code** surface. Under the pi harness there is no
per-dispatch model routing at all (inline work runs on the session model) and
loop-fleet dispatch takes pi model **ids**, not aliases — see
`skills/shared/pi-harness.md` "Model routing". Under opencode, per-role models
come from generated agent files (`provider/model` ids; default inherits the
session model); use `opencode-install.sh install --model` or native project agent
overrides for cross-provider routing. Loop-fleet dispatch takes opencode ids — see
`skills/shared/opencode-harness.md` "Model routing".

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

## Claude Code per-phase override

Set `LOOP_SPEC_PHASE_MODEL_<PHASE>` to make one alias the default for the phase's
main orchestrator and every subagent launched inside it:

```bash
LOOP_SPEC_PHASE_MODEL_SPEC=opus
LOOP_SPEC_PHASE_MODEL_DISCUSS=sonnet
LOOP_SPEC_PHASE_MODEL_PLAN=sonnet
LOOP_SPEC_PHASE_MODEL_EXECUTE=sonnet
LOOP_SPEC_PHASE_MODEL_VERIFY=opus
LOOP_SPEC_PHASE_MODEL_ITERATE=opus
LOOP_SPEC_PHASE_MODEL_DELIVER=sonnet
```

Supported phase suffixes are exactly `SPEC`, `DISCUSS`, `PLAN`, `EXECUTE`,
`VERIFY`, `ITERATE`, and `DELIVER`. Values are the same Claude Code Agent aliases:
`sonnet | opus | haiku | fable`. Empty/unset means no phase override. Any other
value fails startup/phase activation; there is no silent fallback.

The phase default reaches all phase gates because those reviewers consume the
same activated map:

- DISCUSS: spec-writer, pattern-mapper, advocate, challenger;
- PLAN: pattern-mapper, planner, advocate, challenger;
- EXECUTE: implementer and spec-compliance-reviewer on every supported rung;
- VERIFY: verifier, code-reviewer, and map-refresh agents;
- ITERATE: iterate-judge;
- SPEC: startup/codebase mapper agents; the interview itself is main-context;
- DELIVER: no role subagent currently launches.

For the main orchestrator, a running Claude session cannot change its own model.
Continuous mode therefore applies phase routing to subagents only. To change the
main model too, enable `LOOP_SPEC_PHASE_HANDOFF=1` and have the Claude CLI or Agent
SDK launcher start each fresh phase query with the alias in
`feature.phaseModels.<nextPhase>` (or resolve it directly with
`lib/feature-init.sh phase-model <phase>`). The bundled cloud SDK recipe does this.

## Claude Code per-role override

Under Claude Code, set `LOOP_SPEC_MODEL_<ROLE>` (SCREAMING_SNAKE of the JSON key)
to reroute a single role without editing `lib/feature-init.sh`:

```
LOOP_SPEC_MODEL_ITERATE_JUDGE=fable   # promote the judge to fable
LOOP_SPEC_MODEL_PLANNER=sonnet        # demote the planner to sonnet
```

**Allowed values:** `sonnet | opus | haiku | fable`. Any other value — including a
literal model ID like `claude-opus-4-8` — causes `feature-init.sh` to print a clear
error to stderr naming the offending var, the bad value, and the allowed enum, then
exit 1. No silent fallback.

**Precedence:** per-task `model`/`modelTier` where supported > explicit
`LOOP_SPEC_MODEL_<ROLE>` > explicit `LOOP_SPEC_PHASE_MODEL_<PHASE>` > canonical
role default. This makes a phase setting comprehensive without preventing a
single gate or implementer role from being promoted.

**Scope:** cycle activates the map immediately before every phase invocation,
including continuous in-process transitions and resumed phase handoffs. Phase
skills consume the activated values and never re-derive them.

Role suffixes (SCREAMING_SNAKE → JSON key):
`SPEC_WRITER` → `specWriter`, `PLANNER` → `planner`, `ADVOCATE` → `advocate`,
`CHALLENGER` → `challenger`, `SPEC_COMPLIANCE_REVIEWER` → `specComplianceReviewer`,
`ITERATE_JUDGE` → `iterateJudge`, `CODE_REVIEWER` → `codeReviewer`,
`IMPLEMENTER` → `implementer`, `VERIFIER` → `verifier`, `MAPPER` → `mapper`,
`PATTERN_MAPPER` → `patternMapper`.

## Dispatch rule

Phase skills read the activated alias from `feature.models.<role>`. They MUST NOT
re-derive from this file or read the environment per spawn. Pass the resolved
model on every spawn:

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

Never rely on agent frontmatter default. Never omit the `model:` parameter. The
explicit-team roster, implicit named-Agent path, no-teams one-shot fallback,
loop-fleet conversion, and Workflow arguments must all carry the activated value.

## Standalone (no feature.json)

Skills invoked without a feature.json context use the same fixed map. There is no
`--preset` flag. `map-codebase` standalone spawns its mappers on the `sonnet`
alias.

## Unique model set

The canonical set is `opus` and `sonnet`. Startup calls
`lib/feature-init.sh all-models` and probes the complete effective union, so
phase/role routes to `haiku` or `fable` are also tested before work begins. The
24-hour cache is reused only when that exact sorted alias set matches.
