---
name: discuss
description: "Resolve design choices in SPEC.md and run the selected challenger review. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch
---

# DISCUSS

SPEC defines the requirements. DISCUSS resolves the design and approach, then requests a challenger review when required.
Use `.loop-spec/features/{slug}` as `feature_dir` and `docs/loop-spec/features/{slug}/SPEC.md` as the spec.
Follow `skills/shared/dispatch.md` for dispatch. Read only the entry packet as input:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin discuss --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[] (a missing ingress; relay and return)
# .mode.grill=run|self-answer|skip .mode.oracle=supervisor|self .mode.critique=run|skip .mode.reentry=true|false .mode.reason
```

`grill`, `critique`, and `reentry` below are `.mode.*`; `phase-entry.sh` and
`phase-mode.sh` are the probes it folds, read once.

## 1. Consume what SPEC left open

Read SPEC.md's `unresolved_questions` list. Any new intent gaps are one consolidated
checkpoint, resolved through recorded decisions before implementation. Autonomous and
non-interactive runs use the recommended-answer contract in
`skills/shared/autonomous-mode.md`; an unresolved authorization boundary escalates.
Each resolution becomes a concrete requirement and a testable `### Good Enough`
criterion before it leaves the list.

When ONESHOT promoted this build (`route: full` with only an Intent section), expand
the draft into the full SPEC template while preserving that intent. Resolve concrete
questions and get the run's approval of the written Goal and Boundary per SPEC's
"Approval and exit" in `skills/spec/SKILL.md` before returning; the driver records the
freeze when the cycle enters PLAN. Promotion never grants human approval.

`reentry=true` (ITERATE sent the cycle back for a `spec`-type gap): read
`iterate.feedback`, refine SPEC.md toward the ORIGINAL goal (`feature_title`) for that
gap only, and do not restart the interview. When a human approved the rewind
(`step`/`interactive`), the driver has reopened Goal and Boundary: amend them for that
gap, record why, and PLAN freezes them again. `auto`/`review-only` do this without
questions and without a reopen: Goal and Boundary stay frozen there, so the refinement
lands in the other sections.

## 2. Grill (by `grill`)

Read `skills/shared/approach-selection.md` before locking the design. Compare the
requested method with an evidence-backed alternative and record the choice in the
existing decisions block. This applies even when `grill=skip`; it adds no interview.

This is the in-phase grill. A human is attached unless the run is autonomous or
non-interactive; `execStyle: auto` is not autonomous mode, and `execStyle == "auto"` is none of those.
A passed SPEC gate does not skip the design loop.
Search the feature area and read its entry points in full.
Follow callers and imports to identify integration points and affected code. Use those findings to form the design options.
Delegate scans to subagents that return `file:line` evidence.
Dispatch, then stop. Never AskUserQuestion as a wait.

Probe external systems with read-only commands before making factual claims about them.
Record results with `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/evidence.sh" add <ledger> "<claim>" "<command>" "<probe output>"`.
Cite `EVID-NNN`, or record an ASSUMPTION when a probe is unavailable (`skills/shared/grounding-protocol.md`).

- **`run`**: a one-question-at-a-time loop, structured multiple-choice with tradeoffs.
  **`auto`:** MUST grill. Cap at 5 rounds, then proceed. **`step` / `interactive`:** MUST grill.
  No cap; keep going until design and approach are locked. Ask the corner question once
  per design shape: "what is the most likely next change here, and does this shape
  absorb it as a local diff?" and offer the seam that fixes a broad ripple
  (`skills/shared/design-for-change.md`). At least the corner question plus two
  design-shape questions even when nothing is unresolved. When the spec adds a
  component, a store, a service boundary, or a cache (always under greenfield), the
  design-shape questions are the system-design stance's deliverables
  (`skills/shared/engineering-stances.md`): who owns each piece of state, how each data
  flow runs end to end, what the API looks like, what is cached and invalidated how.
- **`self-answer`** (autonomous): the same obligations. The mode line carries
  `oracle=supervisor` or `oracle=self` (`lib/supervisor/oracle.sh`); `oracle=supervisor`
  asks them through `AskUserQuestion` per `skills/shared/autonomous-mode.md`
  "The supervised path" and records answers as `supervised` (`phase-exit.sh` flags a
  named supervisor that was never asked); otherwise answered by you from the code,
  each recorded with `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" discuss "<q>" "<a>" "<why>"`.
- **`skip`** (`review-only` or non-interactive): only the unresolved-question
  assumptions above.

Save the transcript to `feature_dir/discuss-transcript.md`. If `docs/loop-spec/features/{slug}/SPEC.md` exists,
edit its design decisions in place. Goal and Boundary are not yet frozen: an answer
here that changes what the feature must do is written into them, with the reason in
the decisions ledger, and the DISCUSS gate shows the human that they changed. The
freeze lands when the cycle enters PLAN.
Record resolved questions and their reasons in the decisions ledger.
Spawn `spec-writer-1` (`loop-spec:spec-writer`) only when SPEC.md is missing.
Give it absolute `spec_path` and transcript paths. Agents share your current directory, but the exit gate reads the feature's checkout.
Use `$(git -C "$feature_dir" rev-parse --show-toplevel)/docs/loop-spec/features/{slug}/SPEC.md` for the spec.
Never spawn `advocate-1`.

**PATTERNS.md prefetch (background, best effort).** Unless greenfield, workspace mode,
PATTERNS.md already present, or
`LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` set, fire ONE background `Agent`
(`subagent_type: "loop-spec:pattern-mapper"`, `description: "Prefetch PATTERNS.md: {slug}"`,
absolute paths for SPEC.md, the output, and the template
`${LOOP_SPEC_SKILL_DIR}/../shared/artifact-templates/PATTERNS.md.template` — resolve the path before dispatch because the subagent has no `${LOOP_SPEC_SKILL_DIR}`;
"STOP without writing if PATTERNS.md already exists; do not commit; reply DONE:
patterns"), run
`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/feature-write.sh" set "$feature_dir" artifacts.patternsPrefetch '"in-flight"'`
(feature.json is never edited by hand; the forgery guard denies it), and do not wait
(do not sleep, do not poll; PLAN joins it). GSD ingest first:
`lib/gsd-ingest.sh patterns {slug} <target>` printing `INGESTED` sets
`artifacts.patterns` and `artifacts.patternsSource = "gsd-ingest"` and skips the prefetch.

## 3. Critique (by `critique`)

`skip` (`lib/graph/probes/discuss-critique.sh` answered skip: spec already gated by a
human or a supervisor, or maintenance profile; never on a security signal, a re-entry,
or a gate the autonomous run scored itself): log
`discuss critique skipped (<reason>)`. `run`: the challenger-only protocol
(`loop-spec:challenger`, topology `graph/critique.graph.json`) in
`skills/shared/critique-gate-protocol.md` with `phase=discuss`, `gate=spec-critique`,
`artifact=SPEC.md`, author = you (or `spec-writer-1` when spawned). Phase deltas: a
finding that depends on user intent is a question in `grill=run` and otherwise the more
reversible reading, recorded via `decisions.sh add`; an `UNGROUNDED:` finding gets its
probe run by you, appended to the evidence ledger, and cited in the fix; when
`critique revised` answers `changed: false`, skip only the challenger call and hand
`critique delta` a `DELTA-FINDINGS:` reply you write yourself, one `unaddressed: <item>`
line per fix-list item, so an author that answers without editing is counted, not
bounced; `critique fail` answering `close` ends the critique with SPEC.md as it stands
(residue in `gate-logs/spec-critique-residue.md` only). Emit one `dispatch` event per
agent launched; the critique steps emit the `gate_round` events.

## 4. Exit

In explicit teams mode `TeamDelete` first. Return to the cycle; never run the exit
yourself. The cycle's `next --returned-from discuss` runs `lib/phase-exit.sh discuss`
(`artifact-lint`, `grounding-lint.sh`, the oracle gate), commits SPEC.md, and closes the
phase, or answers `REDO` with the `FLAG` lines: format flags follow
`skills/shared/artifact-templates/SPEC.md.template`; `grounding-lint.sh"` flags cite a
ledger entry or become an ASSUMPTION. You are invoked again to fix SPEC.md in place and
return; lint-only failures never re-open the critique. In `step`/`interactive` say
`DISCUSS complete. SPEC at docs/loop-spec/features/{slug}/SPEC.md.`

## Resume

`currentGate.round > 0`: resume the critique per the protocol with `gate-logs/`
inlined. Otherwise read the transcript (never re-ask answered questions) and continue
from the first incomplete step. Recreate teammates fresh; none survive a session.
