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
`previewDigest`. `apply` (task-011) will require that same digest again at
apply time and refuse if any source has changed underneath the approved
preview.

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

Once a transaction has published a marker (`apply`, task-011), `status`
instead reports that marker (`{id, previewDigest, phase, originalGeneration,
publishedHashes}`) plus whether its `migration-generations/<id>/` journal
directory is present.

## `apply`, `resume`, `rollback` (task-011)

These subcommands are registered now so the CLI contract is fixed, but this
revision refuses them:

```
$ bash lib/requirements-migrate.sh apply --feature-dir "$FEATURE_DIR" --preview preview.json --digest 1f2e...
requirements-migrate: apply is not implemented in this revision
(exit 2)
```

When implemented, `apply` will require `--preview PATH --digest SHA256`
matching a preview taken against still-current inputs; `resume` and
`rollback` will require `--transaction ID`. All three will validate,
preserve originals, and publish under the shared publication lock exactly as
`docs/loop-spec/features/release-7-0/SPEC.md` ("Migration preserves originals
and publishes under a transaction gate") describes; `lib/requirements_migrate.py`'s
module docstring fixes the durable journal/receipt schema
(`migration-generations/<transaction-id>/marker.json`, `<n>/original`,
`receipt.json`) that `apply`/`resume`/`rollback` will read and write.
