---
name: discuss
description: "Resolve design choices in SPEC.md and run the selected challenger review. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch
---

# DISCUSS

Use `feature_dir=.loop-spec/features/{slug}`. Relay any entry FLAG and return. Follow
`skills/shared/dispatch.md` for every agent dispatch.

SPEC defines requirements. DISCUSS locks the design and approach, records decisions,
and runs the challenger-only gate when selected. Read only the entry packet first:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin discuss --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[]
# .mode.grill .mode.oracle .mode.critique .mode.reentry .mode.budget .mode.remaining
```

The packet is the only ingress; reuse SPEC, decisions, evidence, and route scope.
Refresh `design-budget.sh` before an optional scan or redispatch. Budget is a soft
deadline: never silently pass an unresolved required finding after exhaustion.

## Resolve the design

Read SPEC's `unresolved_questions`. Ask any new intent gaps in one consolidated
checkpoint and record each answer with `decisions.sh add`; autonomous runs use the
recommended-answer contract in `skills/shared/autonomous-mode.md`. Each answer becomes
a requirement and a `### Good Enough` criterion. On reentry, read `iterate.feedback`,
refine only that gap, and do not restart the interview. Reopen Goal/Boundary only when
the driver says the human approved the rewind.

Read `skills/shared/approach-selection.md` and compare the requested method with one
evidence-backed alternative. This is the in-phase design evaluation. A passed SPEC
gate does not skip it. Human questioning is governed by `mode.grill`; `auto` is not
autonomous mode.
Evaluate the corner case and relevant design shape when the spec adds a component,
store, service boundary, or cache; apply `skills/shared/engineering-stances.md`.
`self-answer` follows the same obligations; `oracle=supervisor` uses **The supervised path**
to ask and record approval, while `oracle=self` records answers with
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add`; `skip` records only
the unresolved-question assumptions. Evaluate the design in every mode, but ask only
unresolved user-visible choices when `mode.grill` permits questions. Never AskUserQuestion as a wait.

Reuse SPEC's cited files and lines. Inspect only missing or changed evidence needed for
the unresolved design; follow entry points/callers only when that evidence is absent.
Probe external systems read-only before asserting facts; `<ledger>` is the evidence
file, `<claim>` the observed fact, `<command>` the probe actually run, and
`<probe output>` its observed result:

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/evidence.sh" add <ledger> "<claim>" "<command>" "<probe output>"
```

The decisions ledger is canonical; use it on resume. If `docs/loop-spec/features/{slug}/SPEC.md` exists,
edit its design decisions in place; Goal and Boundary remain unfrozen until PLAN.
Spawn `spec-writer-1` only when SPEC.md is missing, with absolute paths. Never spawn
`advocate-1`.

## PATTERNS

Do not prefetch or dispatch a second scan in DISCUSS. PLAN's planner owns the compact
PATTERNS scan, reusing the SPEC footprint and evidence.

## Critique and return

Before critique, run `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/phase-exit.sh" discuss
--feature-dir "$feature_dir" --check`; fix every reported FLAG before critique.
When ONESHOT promotes to full, expand the intent draft using the full SPEC template,
preserve Intent, and obtain the run-mode approval before PLAN freezes Goal/Boundary.
Use `skills/shared/critique-gate-protocol.md` and `graph/critique.graph.json` for
`phase=discuss`,
`gate=spec-critique`, and `artifact=SPEC.md`. `run` dispatches the challenger;
`lib/graph/probes/discuss-critique.sh` decides whether the gate may skip. Never spawn `advocate-1`;
the critique steps emit the `gate_round` events through the shared protocol.
`skip` logs `discuss critique skipped (<reason>)` only when the probe permits it. An
`UNGROUNDED:` finding gets a probe and EVID citation. A reviewer BLOCK or held exit
returns flags; substantive findings remain on the fix-list. When `critique revised`
reports `changed: false`, send a `DELTA-FINDINGS:` header followed by one
`unaddressed: <item>` line per unresolved fix.
`critique fail` answering `close`
ends the gate with SPEC as it stands and preserves residue. Never AskUserQuestion as a
wait. In explicit teams mode, TeamDelete before return. Return to the cycle; never run the exit yourself. The cycle runs artifact,
grounding, and oracle lints, including `grounding-lint.sh`, via
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/grounding-lint.sh"`, commits SPEC, and freezes
Goal/Boundary when PLAN begins.

On `step`/`interactive`, report `DISCUSS complete. SPEC at docs/loop-spec/features/{slug}/SPEC.md.`
Resume from gate logs or the digest; never re-ask answered questions.
