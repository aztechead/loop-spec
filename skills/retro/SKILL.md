---
name: retro
description: Retrospective over accumulated loop telemetry - mine events.jsonl/result.json across features for repeated failure patterns (recurring iterate gaps, critique gates at round cap), turn them into rule candidates for the self-learning RULES.md loop, surface evidence-backed suggestions (modelTier headroom) and info (convergence rate, fleet cost). Report is read-only; "apply" writes the rule candidates. Deterministic thresholds, never model-judged.
argument-hint: '[report | apply] [--min-repeats N]'
---

# Retro Skill

Invoked as `/loop-spec:retro [report|apply] [--min-repeats N]`.

Closes the telemetry circuit: `lib/status.sh` measures, this skill turns the
measurements into permanent improvements. Every pattern detection is
deterministic (explicit thresholds in `lib/retro.sh`, default 3 repeats) — the
model never "judges" a pattern into existence. All mechanics live in
`lib/retro.sh`; this skill is the thin surface plus the RETRO.md artifact.

Finding kinds and what happens to them:

| kind | example | on `apply` |
|---|---|---|
| `rule-candidate` | PLAN was the iterate gap in 3+ features | appended to `.loop-spec/RULES.md` via `lib/rules.sh add` (idempotent — texts are count-free) |
| `suggestion` | first-pass convergence streak → `modelTier: mechanical` headroom | never auto-applied; shown for your call |
| `info` | convergence rate, shipped-with-gaps count, fleet cost | never applied |

## Procedure

### report (default)

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/retro.sh" report [--min-repeats N]
```

1. Print the output verbatim (do not paraphrase counts).
2. Append a dated section to `docs/loop-spec/RETRO.md` (create with a
   `# Retrospectives` heading if absent): the findings plus one line of context
   per rule candidate. Commit it when inside a git repo (`docs: retro <date>`);
   skip the commit silently when the tree is dirty with unrelated changes.
3. If there are rule candidates, end with: "apply with `/loop-spec:retro apply`".

### apply

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/retro.sh" apply [--min-repeats N]
```

Prints `added`/`exists` per rule candidate (idempotent — re-applying is safe).
After applying, remind: the rules are injected into every future session by the
self-learning hook; curate them with `/loop-spec:rules`. Update RETRO.md's
section for this date with which candidates were applied.

**Autonomous mode note:** interactive cycles only print the read-only candidate
count at completion — the human decides. Autonomous cycles auto-apply via
`lib/retro.sh auto` (kill switch `LOOP_SPEC_RETRO_AUTO_APPLY=0`), which is safe
because the appliable texts are a closed, versioned template set with
deterministic triggers that only ever tighten the loop; the model cannot author
or weaken a rule on this path. The human remains the curator of the FILE —
prune or reword rules any time with `/loop-spec:rules`.

## Interpreting findings

- **gap-plan/execute/spec-recurs** — where the iterate judge keeps rewinding.
  A high `plan` count = decomposition is the weak link; `spec` = interviews are
  under-scoping; `execute` = verifyCommands too weak to catch misses in-phase.
- **gate-cap-*** — the artifact reaching that critique gate repeatedly needs
  every round; strengthen what's produced upstream of it.
- **model-tier-headroom** — sustained first-pass convergence with no execute
  recurrence: cheaper models are not the bottleneck; consider `modelTier:
  mechanical` on low-risk tasks (`lib/model-tier.sh`).
- **shipped-with-gaps** — runs keep spending the iteration limit; drain the
  backlog and read `ITERATION.md` for what keeps being accepted.

## Volatile / ephemeral agents (containers, per-run CI)

Local telemetry (`.loop-spec/features/*/events.jsonl`, `result.json`) dies with
the workspace, and `.loop-spec/` is gitignored — a per-run container would give
retro a corpus of one, forever below threshold. Three mechanisms make retro
work anyway; all are automatic:

1. **Committed run digests.** The cycle's On-completion runs
   `lib/run-digest.sh append`, writing a compact per-run digest to
   `docs/loop-spec/telemetry/runs/{slug}.json` (committed + pushed on the
   feature branch, one file per slug so parallel agents never conflict in git).
   Retro mines local telemetry MERGED with these digests (local wins on slug
   collision; `LOOP_SPEC_RETRO_DIGEST_DIR` overrides the location) — a fresh
   clone sees the full corpus.
2. **Durable rules.** `retro apply` (and the cycle's first-run gitignore setup)
   adds the `!/.loop-spec/RULES.md` exception so applied rules survive via git
   instead of dying with the pod. Commit RULES.md after applying.
3. **Gated auto-apply in autonomous mode.** The cycle's On-completion runs
   `lib/retro.sh auto <feature_dir>`: interactive runs get a READ-ONLY
   candidate-count line (a human is present to decide); autonomous runs
   auto-apply the candidates and the cycle commits RULES.md, so an unattended
   fleet actually learns without anyone running `apply`. This is safe by
   construction: the applicable rule texts are a **closed template set inside
   `lib/retro.sh`** — the model never authors rule text on this path, the
   thresholds are deterministic, and every template only tightens discipline
   (a rule can make the loop stricter, never looser). Overrides:
   `LOOP_SPEC_RETRO_AUTO_APPLY=0` forces report-only everywhere, `=1` forces
   apply even interactively. Applying happens only at cycle completion — never
   mid-run.

The global rules layer (`~/.loop-spec/RULES.md`) is per-machine and does NOT
survive containers — in volatile fleets, keep everything in the project layer.

## Boundaries

Read-only except: RETRO.md (report), RULES.md + the `.gitignore` durability
exception (apply, explicit). No agents are dispatched; no dispatch telemetry
applies. Workspace mode: run from the workspace root; `--root` points anywhere
explicitly.
