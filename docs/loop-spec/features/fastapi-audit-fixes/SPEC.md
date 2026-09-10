---
route: full
unresolved_questions: []
footprint:
  - graph/cycle.graph.json
  - lib/execute-prepare.sh
  - lib/execute-exit-gate.sh
  - lib/cycle-result.sh
  - .gitignore
  - skills/shared/autonomous-mode.md
  - skills/verify/SKILL.md
  - tests/lib/execute-prepare.test.sh
  - tests/lib/cycle-result.test.sh
  - tests/lib/graph-run.test.sh
---
# Address real-run audit findings in PR 94

For maintainers correcting the autonomous FastAPI run failures.
**Slug:** `fastapi-audit-fixes`
**Created:** 2026-09-10
**Tier:** maintenance
**Execution style:** auto

## Problem
VERIFY queued fixes that never executed. Early refusal telemetry lost autonomous mode, and launchers left untracked runtime files. An implementation-specific approved Goal also prevented a later safe design correction.
<decisions>
- **Use detected project commands?** → yes — autonomous run trusts detection; LOOP_SPEC_CMD_* still wins
- **Should autonomous runs bypass approved Goal and Boundary checks to repair implementation wording?** → No; preserve the immutable approval and distinguish outcomes from implementation choices before approval. — The supplied audit explicitly identifies this as intended safety behavior; fix the execution and telemetry bugs without weakening it.
- **How should the existing request be carried through unattended implementation?** → Proceed within the supplied audit scope using autonomous approval; do not label inferred decisions human approval. — The user explicitly requests fixing the findings and updating PR 94; no additional product choice is needed.
- **Prose review suggests removing the audience preface as outside the template.** → Keep the single audience line. — The repository human-docs contract asks each document to name its reader; the line serves that requirement without duplicating acceptance criteria.
</decisions>
## Goals
- Execute accepted VERIFY remediation before advancing; preserve queued work until durable registration and block completion while fixes remain.
- Report autonomous mode accurately when a run ends before feature creation and keep local launcher artifacts out of Git status.
- Explain the approved-intent limit and prevent avoidable implementation choices from becoming frozen goals; update PR 94 with verified fixes and remaining live-run limitations.
## Non-goals
- Deliver the audited FastAPI app or repeat a paid model run.
## Boundaries (what NOT to do)
- Never weaken approved Goal/Boundary checks, alter approval records to hide drift, or bypass the plugin repository dependency restriction.
- Never discard remediation on intake failure, claim queued work was executed, or describe offline checks as proof of live delivery.
## Constraints
- Use existing graph, task, and result interfaces with the shipped Bash/jq/Python dependencies.
## User-facing behavior
A review failure returns to execution with its tasks intact. Invalid intake fails visibly. An early autonomous refusal records the mode correctly. Session directories and launcher state stay ignored. Genuine intent changes still require a human decision.
## Success criteria
### Good Enough
- [ ] GE-001: Offline regression proves two VERIFY tasks route to EXECUTE before ITERATE, become dispatchable, and cannot be silently cleared or bypassed on registration failure or exit.
- [ ] GE-002: Offline regressions prove early autonomous terminal results and explicit non-autonomous results preserve their correct modes without feature state.
- [ ] GE-003: Git ignore checks cover sessions, launcher-result.json, and launcher.lock while source files remain visible.
- [ ] GE-004: Guidance separates outcome intent from implementation choices and retains hard failure for post-approval intent edits; existing intent regressions pass.
- [ ] GE-005: Full offline suite and required repository probes pass; fixes are committed and pushed to PR 94 with an accurate description and observed check state.
### Exceptional
- [ ] Offline transition coverage exercises remediation intake again after interruption without losing or duplicating tasks.
## Out of scope
- Unrelated runtime modernization and guarantees that every autonomous task can reach delivery.
## Grounding
- graph/cycle.graph.json:971 - VERIFY currently has a bad-spec route but no queued-remediation route.
- lib/execute-prepare.sh:82 - intake drops tasks without verify commands and clears pending work after registration failure.
- lib/execute-exit-gate.sh:26 - exit checks the sidecar rather than the pending queue.
- lib/cycle-result.sh:916 - feature-based terminal output defaults autonomous to false.
- lib/spec_intent.py:41 - post-approval intent edits fail regardless of mode.
- .gitignore:26 - current telemetry ignores omit launcher and session artifacts.
## Open questions
(none)
