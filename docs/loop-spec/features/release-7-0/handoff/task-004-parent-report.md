# Task 004 parent implementation evidence

For the task reviewer assessing integration dependencies discovered during the caller sweep.

The parent owns PLAN/SPEC scope refinements and the artifact publication primitive/test extension. The implementer owns the remaining task files. No task 004 commit has been created.

## Scope and approved intent

The exact task scope and Verify command were updated consistently in PLAN, tasks.json, dispatch/prepare.json, and the task brief. Added dependencies are the quality-loop skill, existing feature writer Python/shell boundaries and writer test, publication primitive/test, execute-prepare outer ingress, and the plan/footprint documents themselves. The feature sidecar's completed task statuses were preserved.

SPEC Goals and Boundaries still hash to the recorded human approval, c5036f53b764d067317f2e6778afdfd0fe272dd623c6996d7694ebb875ddc4be. Only footprint metadata changed. Doc-tells reports four previously adjudicated future-module references on unchanged PLAN line 15: execution_inputs.py, execution_observation.py, requirements_migrate.py and requirements-migrate.sh. They are implementation-plan references, not stale shipped instructions or a reason to create placeholders.

## Primitive extension

capture_locked, publish_locked, recover_locked and artifact_paths accept an optional trusted external_roots argument. Only explicitly registered keys can resolve within these received roots. Token content cannot grant path authority, and the CLI exposes no external-root argument. Relative/symlink roots, paths outside the roots, and aliases of live feature state are rejected. External archival files may retain names such as state/feature.json.

A manifest entry with source:null expresses target absence. Deletion is journaled with after:null, and both publication and recovery fsync the containing directory. Existing per-file and transaction byte limits, file-count limits, shared locking, CAS, original hashes, modes and repeated-recovery handling remain in use. Prepared Git index bytes can therefore share the same file transaction as sink copies and document deletion/restoration. The sink controller must acquire Git's index lock after the publication/state locks and provide the trusted registrations; this primitive test does not claim the sink caller is already integrated.

## Red/green and probes

The new sink fixture failed first with TypeError: capture_locked() got an unexpected keyword argument 'external_roots'. A subsequent archival-name fixture failed with ValueError: state and internal paths cannot be artifacts before the narrow trusted external-name change.

Final `rtk bash tests/lib/artifact-publication.test.sh` passed all nine groups. The new groups exercise each replacement/state interruption, restore deleted documents and original index bytes, remove newly archived files, reject a stale external index without deleting docs, complete a successful deletion/archive/index publication, and reject unsafe roots and live-state aliases.

Indirection scan, duplication scan, house-style compare, comment-tells and failure-tells all pass for the two parent-owned source/test files. Git diff --check passes. The probe measured two-space indentation, matching the existing module.

Four-question review: reuse the existing journal rather than add a second coordinator; receive roots explicitly at the existing path-resolution seam; keep deletion as absent desired bytes rather than a parallel transaction implementation; retain the 16 MiB/file, 64 MiB/transaction and 256-file limits and streamed hashes. These are required sink behaviors, not speculative integrations. No new runtime dependency or configuration switch was added.
