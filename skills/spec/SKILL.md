---
name: spec
description: "Write SPEC.md from repository evidence and recorded decisions. Resolve intent questions before approval. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# SPEC

Run in the main thread. Write `docs/loop-spec/features/{slug}/SPEC.md` in the existing
checkout; never create the feature directory here. Set `feature_dir=.loop-spec/features/{slug}`.
Read only the entry packet first:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin spec --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[] .mode.path .mode.oracle .mode.greenfield
# .mode.budget .mode.remaining .mode.exhausted .mode.budgetReason
```

Relay a FLAG and return. The budget is cumulative and soft: bound scans by route
scope, reuse existing evidence, and refresh `design-budget.sh` before optional work.

## Scout

`skills/spec-lite/SKILL.md` runs first and cites the footprint; extend it, never
restart it. Read `skills/shared/approach-selection.md`, separating the requested
outcome and binding constraints from a suggested method. Read feature decisions and
the target area; follow entry points, imports, and callers until boundaries are
known. In workspace mode scan each repository separately and label repository findings.
For greenfield apply the build-from-scratch stance in
`skills/shared/engineering-stances.md`, including data, APIs, interfaces, and scale.
If the footprint still has an evidence gap, delegate one bounded scan that returns
`file:line` evidence; otherwise reuse the scout record.

Before an external-system claim, run a read-only probe and record `EVID-NNN`.
`<claim>`, `<command>`, and `<probe output>` mean the observed fact, probe actually
run, and output it returned; `<need>` is the documentation topic, and `<name>` the
dependency name:

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/evidence.sh" add "docs/loop-spec/features/{slug}/EVIDENCE.md" "<claim>" "<command>" "<probe output>"
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/doc-deps.sh" scan <scouted files>
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/docs-probe.sh" latest <name>
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/docs-probe.sh" docs <name> --topic "<need>"
```

Use `ASSUMPTION: <claim> | verify: <command>` when a probe is unavailable. Never use
a local catalog as a version source; use current documentation. Follow
`skills/shared/grounding-protocol.md`.

Write `footprint:` with every repository-relative changed or created file and its
scout citation. Include each file's existing test module, or mark it unchanged in
Implementation notes. `lib/graph/probes/oneshot.sh` selects ONESHOT only when there
are at most three files, no intent questions, and no security signal.

## Intent and draft

An intent gap is a user-visible choice repository evidence cannot settle. Investigate
first, then collect genuine gaps in one checkpoint with a recommendation, tradeoff,
and observable consequence. For examples of genuine intent gaps, read
`${LOOP_SPEC_SKILL_DIR}/references/interview-prompts.md`. The gate is an empty `unresolved_questions` list; never
use a score. Reuse prior answers.

`interview` is human-attended, including `execStyle: auto`; ask once with
`AskUserQuestion`. `self-answer` follows `skills/shared/autonomous-mode.md` and its
**The supervised path**: `oracle=supervisor` asks and records supervised approval;
`oracle=self` records the recommendation. Record each decision; escalate an unresolved
authorization boundary. `synthesize` derives the
draft without asking; `LOOP_SPEC_ANSWER_SPEC_CONFIRM=no` pauses with
`spec-confirmation-declined`. `ingest` preserves supplied requirements verbatim.
Never AskUserQuestion as a wait.

Record decisions with: `<question>` is the actual user choice, `<answer>` the resolved
choice, and `<reason>` its recorded rationale:

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<question>" "<answer>" "<reason>"
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" render "$feature_dir"
```

Follow `skills/shared/artifact-templates/SPEC.md.template`; keep valid frontmatter,
decisions, goals, boundaries, criteria, grounding, and open questions. Do not include
ambiguity scores or an interview transcript. Spec-lite owns the oneshot skeleton.
Write through `cycle-driver.sh spec write` when outside the feature checkout.

Keep the first draft concise; the rule is: Do not dispatch a prose-pruning reviewer.
Preserve
criteria, decisions, questions, and grounding. Never AskUserQuestion as a wait.

## Approval and return

Before approval, run the non-oracle checks:
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/artifact-lint.sh" spec "docs/loop-spec/features/{slug}/SPEC.md" --feature-dir "$feature_dir"`
and `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/grounding-lint.sh" "docs/loop-spec/features/{slug}/SPEC.md"`;
fix every reported FLAG. After the run-mode approval is recorded, run
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/phase-exit.sh" spec --feature-dir "$feature_dir" --check`.
Write Goal and Boundary as outcomes and constraints; put implementation choices below
them. In interview mode get human approval; in supervisor mode get the supervised
gate; in self/synthesize mode record the authorized recommendation without a human
wait. Record the result with `decisions.sh add`. Do not freeze here: the driver freezes
Goal and Boundary when PLAN begins after DISCUSS.
DISCUSS may change them and reports that change. Return to the cycle; never invoke a
successor or run the exit. `next --returned-from spec` runs `lib/phase-exit.sh spec`,
commits the artifact, or returns REDO with FLAG lines. In step mode report
`SPEC complete. SPEC.md at docs/loop-spec/features/{slug}/SPEC.md.`

On resume, read SPEC and the decisions ledger, reuse answers, and fix only unresolved
or flagged content; never restart the interview or re-grade a complete draft.
