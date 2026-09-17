---
name: walkthrough
description: Use when handing a branch, PR, or feature to a human reviewer, or when the user says "walk me through this change". Writes REVIEW-ORDER.md. Do not use to implement the change or to address review comments (that's /loop-spec:revise).
argument-hint: '[<slug> | <base-ref>] [--write | --walk]'
---

# Walkthrough Skill

Invoked as `/loop-spec:walkthrough [slug|base-ref] [--write|--walk]`.

Write a review guide that explains the change's entry points, design concerns, and supporting files.
`lib/review-trail.sh` measures and checks the review order. You explain each stop.

## Modes

- `--write` (default in a cycle): produce `REVIEW-ORDER.md` and stop. This is what DELIVER
  consumes.
- `--walk`: present the trail conversationally, one concern at a time, and stay available
  for questions. This is the human-in-the-loop mode.

## Step 1 — Resolve the change

In a feature: the slug's branch against its base (`feature.json` holds `baseBranch` and
the branch name). Standalone: the base and head refs given, defaulting to the merge-base
of the current branch and the default branch.

## Step 2 — Measure the surface

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/review-trail.sh" surface <base> <head>
```

Each line is a fact you do not re-derive: the file, whether it is `core` or `peripheral`,
the anchor line of its first change, and its churn. When every file classifies peripheral
the script says so and promotes them all — a markdown-only or config-only change still
gets a trail.

## Step 3 — Group into concerns

A concern is a cohesive design intent — "the trust marking", "the budget ceiling", "the
config seam" — **not** a file and not a module. One file may appear under several
concerns; one concern may span several files.

- Lead with the entry point: the single highest-leverage stop for grasping the design
  intent. Everything else builds on it.
- Order stops inside a concern so each one makes sense given the ones before it. A
  reviewer must never meet a reference to something they have not seen.
- End with peripherals: tests, fixtures, config, docs. The lint enforces this.
- Target 2–5 concerns. One is fine — do not invent groupings. More than 7 is a signal the
  change is too large; write it anyway and say so.

Ground each concern in the actual change.
Read SPEC.md, when present, for intent and rejected alternatives before writing explanations.
Do not invent reasons that the artifacts do not support.

## Step 4 — Write the trail

Write `docs/loop-spec/features/{slug}/REVIEW-ORDER.md` (standalone: `REVIEW-ORDER.md` at
the repo root, or the path given). Framing first, anchor underneath:

```markdown
# Suggested review order

**Grounding gate on plan claims**

- decides cited vs assumed for every claim
  `lib/grounding-lint.sh:88`
- the ceiling that blocks silent growth
  `lib/grounding-lint.sh:142`

**Peripherals**

- fixture corpus for the sweep
  `tests/lib/grounding-lint.test.sh:1`
```

Rules the lint measures, so meet them deliberately:

- Include at least one stop for every `core` file.
- Framing is at most 15 words. It is a phrase, not a sentence, and never a paragraph.
- Every stop is a real `path:line` inside the change surface, and the line exists.
- No peripheral stop precedes the last core stop.

## Step 5 — Lint it

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/review-trail.sh" lint <trail-file> <base> <head>
```

Fix every finding and re-run until clean. `finding=uncovered` means a core file has no
stop — add one rather than deleting the file from your mental model of the change.

## Step 6 (`--walk` only) — Present it

One concern per message, complete: heading, one or two sentences of *why*, then its stops
as `path:line` with their framing. Do not drip-feed and do not ask questions mid-concern.
Paths stay CWD-relative with no leading `/` so they are clickable in an IDE terminal.

After the last concern, hand control back plainly: the reviewer can click through the
stops, ask about any of them, or say they are done. If they signal a decision — ship it,
rethink it, done reviewing — confirm what they mean before acting on it.

## Relationship to the cycle

- **VERIFY** has the diff and the spec, and is where the trail is written.
- **DELIVER** includes it in the PR body (`lib/pr-body.sh`); the artifact is committed with
  the rest of the feature's documentation.
- **`/loop-spec:revise`** re-runs this after fixing review feedback, so the second reviewer
  pass gets a trail of what changed since the first.

This guide does not gate delivery. DELIVER reports a missing or invalid guide and continues delivery.
