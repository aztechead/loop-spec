# Determinism audit — judgment-selected branches

Snapshot of every place a MODEL JUDGMENT still selects a code path, per the
"probes, not judgments" contributor rule (CLAUDE.md): a judgment that selects a
branch must become a deterministic probe with a test; judgment stays welcome
everywhere it is not selecting a branch. Ordered by how much still rides on prose.

## Converted to probes (done)

| Was | Now |
|---|---|
| "escalate if security-relevant" | `lib/security-signal.sh` — two-tier terms; weak terms (token/migration/deletion) need a second distinct term; the matched term + line is always reported |
| "set teamsAvailable if teammates seem capable" | `lib/teams-capability.sh` (version + flag gate) |
| harness identity | `lib/harness.sh entrypoint` stamp |
| EXECUTE rung choice | `lib/execute-rung.sh` (width + capability, logs its reason) |
| "done, with a few deferred items" | `lib/deferral-lint.sh` + `hooks/team/deferral-guard.sh` + the `deliver.sh` exit-3 gate — completion claims cannot carry self-authored deferral language |
| "the implementation is complete" (stubs) | `lib/placeholder-scan.sh` — added-line TODO/FIXME/NotImplemented markers fail VERIFY |
| oracle tampering | `lib/test-tamper-scan.sh` |
| artifact well-formedness at handoffs | `lib/artifact-lint.sh` |
| pre-existing vs introduced failures | `lib/verification-baseline.sh` |
| PR body composition and score formatting | `lib/pr-body.sh` (percentage table, GFM, frontmatter never leaks) |

## Remaining judgment-selected branches (probe candidates)

1. **SPEC ambiguity scores gate the design exit** (`skills/spec/SKILL.md`). The four
   clarity dimensions are model-authored numbers, and `ambiguity <= 0.20` selects
   pass/iterate. Probe candidate: a deterministic FLOOR cross-check — e.g.
   `acceptance_clarity` may not clear its minimum unless `### Good Enough` carries at
   least N `- [ ]` checkboxes and every requirement block has a Current/Target/
   Acceptance triple (artifact-lint already proves structure; the cross-check would
   bind score to structure). The score itself stays judgment; the probe would only
   catch a score the artifact cannot support.

2. **ITERATE judge verdict** (`skills/iterate/SKILL.md`): `converged == true` is a
   model judgment that ends the loop. Partially bounded today (fresh-context judge,
   immutable original goal, VERIFY must be green first). Probe candidate: converged
   requires zero unchecked Good Enough boxes in VERIFICATION.md rows — a mechanical
   floor under the judgment, same shape as the deferral gate.

3. **`gap.type` routing** (`skills/iterate/SKILL.md` Step 3): the judge's
   classification (`execute|plan|spec|discuss`) selects the rewind target. Probe
   candidate: validate the classification against required evidence fields (an
   `execute` gap must name a failing criterion/file; a `spec` gap must name the
   ambiguous requirement) and reject the verdict JSON otherwise — classification
   stays judgment, but an unevidenced classification cannot route.

4. **`/loop-spec:auto` task routing** (`lib/task-route.sh`): the router is
   deterministic, but its `ambiguity: low|medium|high` INPUT is model-declared.
   Probe candidate: deterministic floors from the request itself (contains a
   concrete error/stack → debug; names ≤2 files and a verb → micro candidate),
   with the model only able to escalate, never de-escalate, the floor.

5. **Critique-gate verdicts** (DISCUSS/PLAN single critic, VERIFY code review):
   PASS/FAIL is judgment by design (maker≠checker). Bounded by the gate ladder,
   delta re-verify, and blocking-severity rules; the remaining prose branch is the
   critic's severity assignment (Critical/Important/Minor selects blocking). Probe
   candidate: a severity rubric lint — findings whose text matches the objective
   patterns (data loss, auth bypass, spec-boundary violation) may not be filed Minor.

6. **Debug hypothesis verdicts** (`skills/debug/SKILL.md`): CONFIRMED/REFUTED per
   hypothesis is judgment; the red-repro-first rule is the existing floor (no fix
   without a failing reproduction). Residual risk is low because the oracle is a
   command exit code.

7. **Graphify grounding claims**: design phases cite graph queries, but whether a
   claim REQUIRED a citation is judged. `lib/grounding-lint.sh` and EVIDENCE.md ids
   bound this; the residual branch is the model deciding a fact is "not load-bearing".
   Probe candidate (TDAD-style): for any task whose files sit in the graph, require
   at least one `graphify path`/blast-radius citation in the plan's task block.

## Review cadence

Re-run this audit when a dogfooding report attributes a failure to a prose
decision (the last two probe conversions — deferral and placeholder — both came
from exactly that signal).
