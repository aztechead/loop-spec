---
name: discuss
description: DISCUSS phase - conversational requirements gathering that refines SPEC.md, then a challenger-only critique (skipped when the spec is already gated). Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch
---

# DISCUSS

SPEC pinned the requirements; DISCUSS pins the design and approach, then has a
challenger critique the spec. `feature_dir` is `.loop-spec/features/{slug}`; the
spec is `docs/loop-spec/features/{slug}/SPEC.md`. Dispatch follows
`skills/shared/dispatch.md`. Your inputs are the entry packet and nothing else:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-entry.sh" discuss --feature-dir "$feature_dir"
# fields=<the feature.json keys this phase consumes>  read=<each file to read>  FLAG on a missing ingress
```

```bash
mode="$(bash "${CLAUDE_SKILL_DIR}/../../lib/phase-mode.sh" discuss --feature-dir "$feature_dir")"
# grill=run|self-answer|skip critique=run|skip reentry=true|false reason=...
```

## 1. Consume what SPEC left open

Read SPEC.md's `ambiguity_scores` frontmatter. Each entry in `unresolved_dimensions[]`
is an open ask that would otherwise ship unmet. **`auto` / `step` / `interactive`:** ask ONE targeted
`AskUserQuestion` for it before anything else; autonomous, `review-only`, and
non-interactive resolve it as an explicit, code-grounded assumption (`ASSUMPTION (<dimension>): <claim> | verify:
<command>`). Either way it becomes a concrete requirement with a testable
`### Good Enough` criterion and leaves the list (`gate_passed: true` once empty).

`reentry=true` (ITERATE sent the cycle back for a `spec`-type gap): read
`iterate.feedback`, refine SPEC.md toward the ORIGINAL goal (`feature_title`) for that
gap only, and do not restart the interview. `auto`/`review-only` do this without
questions.

## 2. Grill (by `grill`)

This is the in-phase grill. A human is attached unless the run is autonomous or
non-interactive; `execStyle: auto` is not autonomous mode, and `execStyle == "auto"` is none of those.
A passed SPEC gate does not skip the design loop. Ground in the code first: search the area, read entry points in full, follow callers
and imports to the integration points and ripple paths; those become the options in
your questions. Fan scanning out to subagents that return `file:line` evidence
(dispatch, then stop; never AskUserQuestion as a wait). Probe external systems read-only before asserting anything about
them (`bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add <ledger> "<claim>" "<command>" "<probe output>"`,
cite `EVID-NNN`, or write an ASSUMPTION; `skills/shared/grounding-protocol.md`).

- **`run`**: a one-question-at-a-time loop, structured multiple-choice with tradeoffs.
  **`auto`:** MUST grill. Cap at 5 rounds, then proceed. **`step` / `interactive`:** MUST grill.
  No cap; keep going until design and approach are locked. Ask the corner question once
  per design shape: "what is the most likely next change here, and does this shape
  absorb it as a local diff?" and offer the seam that fixes a broad ripple
  (`skills/shared/design-for-change.md`). At least the corner question plus two
  design-shape questions even when nothing is unresolved.
- **`self-answer`** (autonomous): the same obligations, answered by you from the code,
  each recorded with `bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" discuss "<q>" "<a>" "<why>"`.
- **`skip`** (`review-only` or non-interactive): only the unresolved-dimension
  assumptions above.

Save the transcript to `feature_dir/discuss-transcript.md`. If `docs/loop-spec/features/{slug}/SPEC.md` exists,
edit it in place: resolved dimensions, design decisions, boundaries under
`## Boundaries (what NOT to do)`. Preserve `ambiguity_scores` except the dimensions you
resolved. Spawn `spec-writer-1` (`loop-spec:spec-writer`) only when SPEC.md is missing
entirely. Never spawn `advocate-1`.

**PATTERNS.md prefetch (background, best effort).** Unless greenfield, workspace mode,
`bootstrapPendingDomains` non-empty, PATTERNS.md already present, or
`LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` set, fire ONE background `Agent`
(`subagent_type: "loop-spec:pattern-mapper"`, `description: "Prefetch PATTERNS.md: {slug}"`,
absolute paths for SPEC.md, `docs/loop-spec/codebase/*.md`, and the output; "STOP without
writing if PATTERNS.md already exists; do not commit; reply DONE: patterns"), set
`artifacts.patternsPrefetch = "in-flight"`, and do not wait. GSD ingest first:
`lib/gsd-ingest.sh patterns {slug} <target>` printing `INGESTED` sets
`artifacts.patterns` and `artifacts.patternsSource = "gsd-ingest"` and skips the prefetch.

## 3. Critique (by `critique`)

`skip` (`lib/graph/probes/discuss-critique.sh` answered skip: spec already gated, or
maintenance profile, never on a security signal or re-entry): log
`discuss critique skipped (<reason>)`. `run`: the challenger-only protocol
(`loop-spec:challenger`, topology `graph/critique.graph.json`) in
`skills/shared/critique-gate-protocol.md` with `phase=discuss`, `gate=spec-critique`,
`artifact=SPEC.md`, author = you (or `spec-writer-1` when spawned). Phase deltas: a
finding that depends on user intent is a question in `grill=run` and otherwise the more
reversible reading, recorded via `decisions.sh add`; an `UNGROUNDED:` finding gets its
probe run by you, appended to the evidence ledger, and cited in the fix; hash SPEC.md
before and after a revision and skip the delta re-verify when nothing changed. Emit
one `dispatch` event per agent launched and, per round,
`bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit "$feature_dir" gate_round --phase discuss --data '{"gate":"spec-critique","round":N,"mode":"single-critic|delta"}' || true`.

## 4. Exit

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-exit.sh" discuss --feature-dir "$feature_dir"
```

- `FLAG` lines: format flags follow `skills/shared/artifact-templates/SPEC.md.template`;
  `grounding-lint.sh"` flags cite a ledger entry or become an ASSUMPTION. Fix SPEC.md in place and
  run the command again; lint-only failures never re-open the critique.
- `phase-exit: NEED map-codebase <domains>` (exit 3): the background mappers from cycle
  start have not landed. Do not sleep, do not poll: run
  `Skill(loop-spec:map-codebase) args: --domain <csv>` synchronously, then run the exit
  command again.
- `phase-exit: ok (discuss)`: SPEC.md and the codebase map are committed, the phase is
  closed. In explicit teams mode `TeamDelete` first. Return to the cycle; in
  `step`/`interactive` say `DISCUSS complete. SPEC at docs/loop-spec/features/{slug}/SPEC.md.`

## Resume

`currentGate.round > 0`: resume the critique per the protocol with `gate-logs/`
inlined. Otherwise read the transcript (never re-ask answered questions) and continue
from the first incomplete step. Recreate teammates fresh; none survive a session.
