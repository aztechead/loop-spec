# Task brief: task-004

**Subject:** Integrate staging and stable identities into every producer route

## Files
- lib/graph/driver.py
- lib/phase-entry.sh
- lib/phase-exit.sh
- lib/cycle-preflight.sh
- lib/deliver.sh
- lib/cycle-result.sh
- graph/cycle.graph.json
- skills/spec/SKILL.md
- skills/spec-lite/SKILL.md
- skills/oneshot/SKILL.md
- skills/plan/SKILL.md
- agents/spec-writer.md
- agents/planner.md
- skills/shared/artifact-templates/SPEC.md.template
- skills/shared/artifact-templates/SPEC-oneshot.md.template
- tests/lib/cycle-driver.test.sh
- tests/lib/phase-entry.test.sh
- tests/lib/phase-exit.test.sh
- tests/lib/deliver.test.sh
- tests/lib/cycle-result.test.sh
- tests/lib/spec-intent.test.sh
- lib/graph/state.sh
- lib/graph/engine.py
- lib/graph/gate.sh
- lib/artifact-sink.sh
- lib/quality-loop-state.sh
- lib/iterate-judged.sh
- lib/execute_remediation.py
- lib/execute-step.sh
- lib/verify-gate.sh
- lib/verify-prepare.sh
- lib/checkpoint-pr.sh
- lib/revise-state.sh
- lib/feature-bootstrap.sh
- lib/feature-init.sh
- tests/lib/graph-state.test.sh
- tests/lib/graph-run.test.sh
- tests/lib/graph-gate.test.sh
- tests/lib/artifact-sink.test.sh
- tests/lib/quality-loop-state.test.sh
- tests/lib/execute-prepare.test.sh
- tests/lib/execute-step.test.sh
- tests/lib/verify-prepare.test.sh
- tests/lib/checkpoint-pr.test.sh
- tests/lib/revise-state.test.sh
- tests/lib/feature-init.test.sh
- tests/lib/publication-callers.test.sh
- tests/run-all.sh

- skills/quality-loop/SKILL.md
- lib/feature_write.py
- lib/feature-write.sh
- tests/lib/feature-write.test.sh
- docs/loop-spec/features/release-7-0/PLAN.md
- docs/loop-spec/features/release-7-0/SPEC.md

- lib/artifact_publication.py
- tests/lib/artifact-publication.test.sh

- lib/execute-prepare.sh

- lib/artifact_sink.py

## Interfaces
- Consumes: task-003
- Produces: All-route staging producers and generation-aware lifecycle consumers.

## Verify
rtk bash tests/lib/cycle-driver.test.sh && rtk bash tests/lib/phase-entry.test.sh && rtk bash tests/lib/phase-exit.test.sh && rtk bash tests/lib/deliver.test.sh && rtk bash tests/lib/cycle-result.test.sh && rtk bash tests/lib/spec-intent.test.sh && rtk bash tests/lib/publication-callers.test.sh && rtk bash tests/lib/graph-state.test.sh && rtk bash tests/lib/graph-run.test.sh && rtk bash tests/lib/graph-gate.test.sh && rtk bash tests/lib/artifact-sink.test.sh && rtk bash tests/lib/quality-loop-state.test.sh && rtk bash tests/lib/execute-prepare.test.sh && rtk bash tests/lib/execute-step.test.sh && rtk bash tests/lib/verify-prepare.test.sh && rtk bash tests/lib/checkpoint-pr.test.sh && rtk bash tests/lib/revise-state.test.sh && rtk bash tests/lib/feature-init.test.sh && rtk bash tests/lib/feature-write.test.sh && rtk bash tests/lib/artifact-publication.test.sh

## Acceptance criteria
1. cycle-driver.test.sh exercises new full/spec-lite/oneshot creation, spec ingest/write/fill, replacement by stable ID, route escalation and reordered criteria; all preserve owner/IDs and reject numeric positional aliases for v1.
2. phase-exit.test.sh starts before a generation change and proves subsequent exit cannot acknowledge work; cycle-driver/deliver/cycle-result fixtures reject migration-in-progress before any side effect and again before accepted state/result publication.
3. spec-intent.test.sh verifies byte-preserved Goals/Boundaries and unchanged specApproval through implementation-only writes; legacy completion remains supported with no new legacy writer selected at creation.
4. publication-callers.test.sh executes each enumerated state writer with a valid original ingress token and then with a stale token; valid writes succeed and stale writes leave state/artifact hashes and acknowledgements unchanged. It registers a source-callsite completeness check for feature-write shell calls, feature_write Python imports and direct phase-state publishers, so newly discovered callers fail the test until explicitly handled.
5. graph-state/graph-run/graph-gate tests prove graph transitions preserve the original node ingress token across subprocesses. Artifact-sink and quality-loop-state tests hold old read results across a migration and prove stale publication cannot overwrite current artifacts or mark findings clean.
6. cycle-driver.test.sh resumes an incomplete legacy fixture through SPEC/PLAN/EXECUTE/VERIFY/ITERATE and ordinary new-cycle fixtures remain runnable at this intermediate revision; no default v1 activation occurs.

## Brief
Integrate staging and stable identities into every producer route

## Global constraints (PLAN.md, verbatim; every one binds)
- Do not rewrite completed feature artifacts, approval hashes, or historical verification records to manufacture new provenance.
- Do not treat a copied PASS, a matching requirement ID, or a source citation as proof that a command ran successfully.
- Do not relax approved intent, maker/checker separation, existing mandatory gates, retry bounds, or exact-SHA delivery.
- Do not require a new third-party runtime dependency, daemon, database, persistent code map, or live model evaluation to use the feature.
- Do not silently migrate an active legacy cycle or silently fall back to legacy validation for an explicitly versioned but malformed new artifact.
- Do not merge or publish a release automatically as part of implementation.
- Keep Markdown specifications and PLAN authoritative; machine-readable inventories are derived views, not separately editable sources of intent.
- Separate product version, feature-state schema, and artifact-contract version. Change each only when its own compatibility contract requires it.
- Preserve current eligible short routes as well as the full cycle. The same requirement cannot acquire a different identity because its execution route changed.
- Unknown dependency or environment identity cannot be represented as verified current evidence.
- Record implementation choices outside Goals and Boundaries so better designs can replace them without changing the approved outcome.

## Environment (probed by the lead; do not re-check versions or auth)
rtk: rtk 0.48.0
bash: GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)

## Context rule
Everything that binds this task is in this brief and the files listed. Do not read SPEC.md, PLAN.md, PATTERNS.md, or EVIDENCE.md; ask the lead if a value is missing.
