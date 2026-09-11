# Requirements migration

For an operator migrating an incomplete pre-7 cycle to the v1 requirements
contract (`docs/loop-spec/requirements-format.md`).

## Prerequisites

- The cycle is incomplete: `feature.json`'s `currentPhase` is not `completed`.
- The cycle's `requirementsContract` is `legacy`, or absent (never bootstrapped).
  A feature already on `format: "v1"` has nothing to migrate.
- `feature.json`'s `artifactPublication.participantsVersion`, when present, is
  a version this runtime supports (currently `1`). A newer participant this
  runtime does not recognize is refused rather than guessed at.
- SPEC.md and PLAN.md are each at most 16 MiB.
- SPEC.md declares exactly one `### Good Enough` section using the plain
  legacy grammar (`- [ ] criterion text`, no `GE-`/`SC-` identities). A SPEC
  that already declares `requirements_version` is not a legacy candidate.
- `apply` additionally requires the cycle to have already been through one
  ordinary phase transition, so `feature.json`'s `artifactPublication` is
  initialized (`preview`/`status` do not require this).

## The 7.x legacy window

7.x keeps legacy readers working for the whole 7.x series so an incomplete
cycle started before this release can still finish under its original
contract; new cycles record v1 from creation. Migration is never automatic
and never required to keep working on an existing legacy cycle -- it exists
for an operator who wants that one cycle's requirements identity, revision
checks, and coverage gates to move onto the v1 contract before it finishes.

## Clean-source rule

Preview reads exactly the SPEC/PLAN/tasks.json bytes and feature-state fields
present when it runs, and writes nothing anywhere -- no repository file, no
`feature.json` change, no `migration-generations/` entry. Two preview calls
against the same inputs produce byte-identical JSON and the same
`previewDigest`. `apply` requires that same digest again and refuses if any
source has changed underneath the approved preview.

## Declared-input limits

- SPEC.md and PLAN.md: 16 MiB each, checked by file size before any byte is
  read.
- Requirement/scenario identities, revisions and the reconciled
  `requirementsContract` follow the same grammar and limits as
  `docs/loop-spec/requirements-format.md`.
- A criterion's proposed v1 scenario (`SC-001`) and any `scenario_checks`
  command come only from what the legacy SPEC already states explicitly --
  the frontmatter `criteria:` map or a backticked command inside the
  criterion's own line. Nothing is invented: a criterion with neither yields a
  scenario with no bound command, same as an unresolved coverage relation.

## `preview`

With `FEATURE_DIR` set to the cycle's own `.loop-spec/features/<the feature's
slug>` directory (the same directory every other `cycle-driver.sh`/
`artifact-publication.sh` command already takes as `--feature-dir`):

```bash
bash lib/requirements-migrate.sh preview --feature-dir "$FEATURE_DIR"
```

Prints one canonical JSON object: `sources` (a sha256 digest of every input
byte considered), `owner`, `proposedSpec.text`, `proposedPlan.text` plus its
`unresolved` relations, `proposedRequirementsContract`, the
`proposedArtifactPublication` delta, `historical.verification` (the existing
VERIFICATION.md's own path and digest -- never rewritten or replaced), and a
top-level `previewDigest`. Exit 0.

Success (trimmed):

```json
{"previewDigest": "1f2e...", "owner": {"repository": "…", "feature": "demo"},
 "proposedPlan": {"unresolved": []}, "historical": {"verification": null, "note": "…"}}
```

A criterion whose PLAN mapping is missing or points at a task PLAN does not
declare is reported instead of guessed:

```json
{"proposedPlan": {"unresolved": [
  {"file": "PLAN.md", "line": 21, "criterion": "The second check passes with `bash tests/second.sh`.",
   "tasks": ["task-999"], "reason": "dangling task reference"}]}}
```

Failure (exit 1, nothing written):

```
requirements-migrate: feature-dir .loop-spec/features/demo: migration refuses a completed cycle
requirements-migrate: docs/loop-spec/features/demo/SPEC.md:1: exceeds 16 MiB migration source limit
requirements-migrate: feature-dir .loop-spec/features/demo: requirementsContract is already v1; nothing to migrate
```

## `status`

```bash
bash lib/requirements-migrate.sh status --feature-dir "$FEATURE_DIR"
```

Reports the feature's current migration marker and journal, read-only.

```json
{"migration": "none"}
```

Once a transaction has published a marker (`apply`), `status` instead reports
that marker (`{id, previewDigest, phase, originalGeneration,
publishedHashes}`) plus whether its `migration-generations/<id>/` journal
directory is present and the journal's own recorded phase:

```json
{"migration": {"id": "639cb236-...", "previewDigest": "1f2e...", "phase": "staged",
                "originalGeneration": 0, "publishedHashes": {}},
 "journal": {"transactionDir": ".../migration-generations/639cb236-...",
             "present": true, "phase": "staged"}}
```

## `apply`

Requires a feature that has already been through at least one ordinary phase
transition (so `artifactPublication` is initialized -- any cycle migration is
offered for has already reached this point by the time task-009 activates it)
and the exact preview file and digest an operator reviewed:

```bash
bash lib/requirements-migrate.sh preview --feature-dir "$FEATURE_DIR" > preview.json
DIGEST="$(python3 -c 'import json,sys; print(json.load(open("preview.json"))["previewDigest"])')"
bash lib/requirements-migrate.sh apply --feature-dir "$FEATURE_DIR" --preview preview.json --digest "$DIGEST"
```

`apply` rechecks `preview.json` against a fresh preview of the feature's
*current* inputs under the same publication lock producers and phase
gates use. If anything changed since the operator reviewed `preview.json` --
an edited SPEC/PLAN byte, a feature-state field, or a stale `--digest` --
apply refuses before touching any artifact and names the differing key:

```
requirements-migrate: feature-dir .loop-spec/features/demo: proposedSpec changed since this preview was approved; take a fresh preview
requirements-migrate: --digest 000...0 does not match the preview file's own previewDigest 1f2e...
```

A completed cycle, an unsupported participant, or an already-staged/committed
migration (a concurrent or repeated `apply`) is refused the same way -- run
`status` and use `resume` instead:

```
requirements-migrate: feature-dir .loop-spec/features/demo: migration refuses a completed cycle
requirements-migrate: feature-dir .loop-spec/features/demo: migration m1 (phase=staged) is already staged; run status/resume
```

Success prints the transaction and its final phase:

```json
{"transaction": "639cb236-...", "phase": "committed"}
```

Under the hood, in order, each step durable before the next begins: preserve
`SPEC.md`, `PLAN.md`, `tasks.json` (if present) and `feature.json` byte-for-byte
0400 under `migration-generations/<transaction-id>/originals/`; publish the
migration marker into `feature.json`'s `artifactPublication.migration` and
advance `generation` (any reader holding an earlier token now fails its own
publish); replace `SPEC.md` then `PLAN.md` from the approved preview text;
publish the v1 `requirementsContract`, `evidenceEpoch + 1`, `generation + 1`
and clear the marker; write `receipt.json`. `specApproval` is never touched,
and a refused precheck writes nothing.

## `resume`

```bash
bash lib/requirements-migrate.sh resume --feature-dir "$FEATURE_DIR" --transaction 639cb236-...
```

Reads `migration-generations/<id>/marker.json`'s recorded phase and preview,
and finishes the same transaction from there -- no ID is ever reallocated.
Use it after any interruption (a killed process, a machine restart) reported
by `status`:

```bash
bash lib/requirements-migrate.sh status --feature-dir "$FEATURE_DIR"
# {"migration": {"id": "639cb236-...", "phase": "staged", ...},
#  "journal": {"present": true, "phase": "staged"}}
bash lib/requirements-migrate.sh resume --feature-dir "$FEATURE_DIR" --transaction 639cb236-...
# {"transaction": "639cb236-...", "phase": "committed", "resumed": true}
```

Replaying `resume` against an already-committed transaction is a no-op (exit
0, nothing written again):

```json
{"transaction": "639cb236-...", "phase": "committed", "resumed": false}
```

An unknown transaction ID, or one whose marker never became durable (a crash
before `feature.json` recorded it -- nothing authoritative changed), refuses
and directs the operator back to `apply`:

```
requirements-migrate: unknown migration transaction: 000...
requirements-migrate: transaction 639cb236-... never became durable; nothing to resume, re-run apply
```

## `rollback`

Restores a **committed** transaction's originals -- only while the migrated
files are still exactly what `apply` published:

```bash
bash lib/requirements-migrate.sh rollback --feature-dir "$FEATURE_DIR" --transaction 639cb236-...
# {"transaction": "639cb236-...", "phase": "rolled-back"}
```

This restores `SPEC.md`/`PLAN.md` to their pre-migration bytes and the
pre-migration `requirementsContract` verbatim (the format may go from `v1`
back to `legacy` -- an extraordinary, explicit recovery step, not an ordinary
write), while `generation` and `evidenceEpoch` both advance by exactly one
(never backward). It never fabricates historical observations: any evidence
recorded against the v1 contract stays exactly as recorded, just no longer
current once the contract reverts.

A later hand-edit to the migrated SPEC or PLAN refuses rollback with an
actionable conflict naming the file and both hashes, rather than silently
discarding the edit:

```
requirements-migrate: rollback refuses changed artifact(s) since migration: SPEC.md: expected dd8eb6..., found 9a1565...
```

A transaction that is not yet committed, or was already rolled back, refuses
and says so (`resume` it first, or there is nothing left to undo):

```
requirements-migrate: transaction 639cb236-... is not committed (phase=staged); resume it before rollback
requirements-migrate: transaction 639cb236-... was already rolled back; nothing to resume
```

## Recovering from an interruption during migration

While a migration transaction is staged or in progress,
`feature.json`'s `artifactPublication.migration` is non-null and every
ordinary consumer -- `phase-entry.sh`, `phase-exit.sh`, `deliver.sh`,
`cycle-result.sh`, VERIFY/ITERATE gates -- refuses to proceed until it clears:

```
$ bash lib/phase-entry.sh execute --feature-dir "$FEATURE_DIR"
FLAG [publication] active migration refuses ordinary publication
phase-entry: 1 flag(s) (execute)
```

Run `status` to see the transaction ID, then `resume` (finish it forward) or,
once it is committed, `rollback` (undo it). Never hand-edit a changed migrated
artifact or a generation counter; both commands validate recorded hashes
before touching anything.

## Failure injection (for tests)

`apply`, `resume` and `rollback` accept a `failure=callable(point)` argument
in Python, invoked at each durable boundary
(`backup|marker|spec|plan|state|receipt`), or honor
`LOOP_SPEC_MIGRATION_FAIL_AT=<point>` to raise at that boundary in a real
subprocess. Every point fires only after its own write is durable, so an
injected failure always leaves a transaction `resume` can finish -- never a
torn write.
