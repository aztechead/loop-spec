---
route: full
unresolved_questions: []
footprint:
  - lib/criteria-coverage.sh
  - lib/plan-tasks.sh
  - lib/plan-exit-gate.sh
  - lib/graph/driver.py
  - lib/verification-grounding-lint.sh
  - lib/converged-floor.sh
  - lib/artifact-lint.sh
  - lib/spec_intent.py
  - skills/shared/artifact-templates/SPEC.md.template
  - skills/shared/artifact-templates/SPEC-oneshot.md.template
  - skills/shared/artifact-templates/PLAN.md.template
  - skills/shared/feature-state-schema.md
  - skills/spec/SKILL.md
  - skills/spec-lite/SKILL.md
  - skills/plan/SKILL.md
  - agents/spec-writer.md
  - agents/planner.md
  - agents/verifier.md
  - graph/cycle.graph.json
  - tests/lib/criteria-coverage.test.sh
  - tests/lib/plan-tasks.test.sh
  - tests/lib/spec-intent.test.sh
  - tests/lib/cycle-driver.test.sh
  - tests/lib/verification-grounding-lint.test.sh
  - tests/lib/converged-floor.test.sh
  - tests/lib/phase-exit.test.sh
  - tests/verification-grounding-coverage.test.sh
  - tests/run-all.sh
  - docs/loop-spec/reliability.md
  - docs/loop-spec/7.x-roadmap.md
  - CHANGELOG.md
  - README.md
  - .claude-plugin/plugin.json
  - .claude-plugin/marketplace.json
  - .codex-plugin/plugin.json
---
# 7.0: stable requirements and verifiable coverage

For maintainers implementing the first release in the [7.x roadmap](../../7.x-roadmap.md).
The user approved Goals and Boundaries on September 10, 2026. Implementation is pending.

**Slug:** `release-7-0`
**Created:** 2026-09-10
**Tier:** full
**Execution style:** auto

## Problem

The coverage helper accepts criterion text without proving that a real task implements
it. Requirement identity also depends on checkbox position in several readers and
writers. Reordering requirements can therefore relabel evidence, while changing a
requirement does not provide an explicit revision boundary for verification.

<decisions>
- **Which release is being started?** → The 7.0 foundation on feat/7.x.x — The requested first new release follows the committed 7.x roadmap.
- **How long should existing incomplete cycles remain readable?** → Keep legacy readers through the 7.x series; new cycles use the new format — A bounded major-series compatibility window preserves existing work without adding legacy writers.
- **Which schema should version requirement artifacts?** → Prefer a separate artifact version; change feature-state schema only if its own shape requires it — Product release and feature-state schema are distinct contracts.
</decisions>

## Goals

- Give every required outcome a stable identity that survives document reordering, with a revision that changes when its behavior or acceptance scenarios change.
- Connect required outcomes and scenarios to real implementation tasks and observed verification evidence through deterministic gates.
- Make missing work, dangling references, and stale evidence visible before the cycle claims success.
- Introduce the new artifact contract for new cycles while preserving completed history and providing safe, explicit migration for incomplete legacy cycles.
- Deliver a tested 7.0.0 implementation across the four supported harness contracts, with documented compatibility and migration behavior.

## Non-goals

- Maintained capability specifications, concurrent capability-delta publication, and merge-triggered synchronization.
- Reusing prior verification results to skip execution, replacing the graph driver, or adding another review phase.
- Smaller installation profiles or context packets; those remain separately measured optimizations.

## Boundaries (what NOT to do)

- Do not rewrite completed feature artifacts, approval hashes, or historical verification records to manufacture new provenance.
- Do not treat a copied PASS, a matching requirement ID, or a source citation as proof that a command ran successfully.
- Do not relax approved intent, maker/checker separation, existing mandatory gates, retry bounds, or exact-SHA delivery.
- Do not require a new third-party runtime dependency, daemon, database, persistent code map, or live model evaluation to use the feature.
- Do not silently migrate an active legacy cycle or silently fall back to legacy validation for an explicitly versioned but malformed new artifact.
- Do not merge or publish a release automatically as part of implementation.

## Constraints

- Keep Markdown specifications and PLAN authoritative; machine-readable inventories are derived views, not separately editable sources of intent.
- Separate product version, feature-state schema, and artifact-contract version. Change each only when its own compatibility contract requires it.
- Preserve current eligible short routes as well as the full cycle. The same requirement cannot acquire a different identity because its execution route changed.
- Unknown dependency or environment identity cannot be represented as verified current evidence.
- Record implementation choices outside Goals and Boundaries so better designs can replace them without changing the approved outcome.

## User-facing behavior

A newly authored spec assigns identities to required outcomes and makes observable
acceptance scenarios explicit. Reordering a requirement keeps its identity and evidence
association. Changing its accepted behavior changes its revision and makes the old result
ineligible to prove the revised requirement.

PLAN reports the exact missing requirement or invalid task reference. Legitimate
many-to-many coverage is supported. Scaffolding and shared infrastructure cite supported
requirements or an explicit project obligation; authors do not invent product behavior
to satisfy the gate.

VERIFY records what was actually checked, which requirement revision and scenario it
addresses, and the examined code state. A failed or unexecuted check cannot be published
as a passing observation. Final convergence remains a judgment bounded by mechanical
evidence checks.

An operator can inspect a legacy migration preview before applying it. Ambiguous source
relationships stop migration with an actionable report.
Applying an approved preview is recoverable after interruption and can be
rolled back without losing the original artifacts.

## Success criteria

### Good Enough

- [ ] GE-001: New-format requirements retain their IDs when reordered; edits to behavior or acceptance scenarios change their revision, and duplicate, malformed, reused retired, or unknown IDs fail with an actionable diagnostic.
- [ ] GE-002: Every required outcome has explicit observable acceptance scenarios or an equivalent executable example; missing scenario coverage is detected, while stretch goals remain distinct from required outcomes.
- [ ] GE-003: PLAN egress rejects criterion text copied only into notes, mappings to nonexistent tasks, missing mappings, and mismatches with the dispatch plan; valid many-to-many mappings, multiline criteria, and supported infrastructure tasks pass.
- [ ] GE-004: New-format verification binds each required scenario to its requirement revision and observed execution record, including command, result, and examined code state; fabricated PASS text, unknown scenario IDs, missing observations, and changed requirements or code cannot satisfy the evidence gate.
- [ ] GE-005: Short and full routes use the same requirement identities and revision checks; VERIFY shape checks and ITERATE convergence exercise the new contract without accepting numeric positional aliases as new-format identities.
- [ ] GE-006: Completed legacy artifacts and approval records remain byte-for-byte unchanged; incomplete legacy cycles can finish under their original contract during the 7.x compatibility window, and unsupported or malformed new versions fail explicitly.
- [ ] GE-007: Migration provides a deterministic read-only preview, checks that approved source inputs still match before applying, stops on ambiguous mappings, preserves originals, resumes interrupted publication safely, is idempotent on replay, and supports rollback without manufacturing historical execution evidence.
- [ ] GE-008: All four harness contracts consume the same artifact format and gates; new typed state fields, if needed, are declared and validated rather than stored as untyped extensions.
- [ ] GE-009: Registered offline regressions exercise parsing, actual phase egress, stale evidence, legacy compatibility, migration interruption, and rollback; the complete offline gate passes and required source probes have no unresolved blocking findings.
- [ ] GE-010: Version declarations consistently identify 7.0.0 when implementation is ready, and release notes plus operator documentation explain the new format, migration, compatibility window, limitations, and recovery commands without claiming unmeasured cost or latency savings.

### Exceptional

- [ ] Comparative live evaluations later show fewer repair rounds and lower cost per verified delivery without worse completion or human intervention. These runs require separate authorization and are not a 7.0 offline acceptance gate.

## Out of scope

- The 7.1 capability lifecycle and 7.2 selective-rework experiment from the roadmap.
- Automatic migration of every historical feature directory or inference of new proof from old checkboxes.
- Changing runtime provider integrations beyond what the shared artifact contract requires.

## Implementation notes

The recommended implementation starts with one stdlib requirement parser shared by
coverage, driver writers, grounding, and convergence. Its placement and exact public
interface are PLAN decisions. Preserve the existing shell entry points where practical.
Explicit GE identities fit existing terminology; the artifact's owner plus the local ID
must identify a requirement unambiguously. The revision digest must cover scenario
semantics and exclude checkbox completion state; define normalization with tests.

Use a separately versioned artifact format unless DISCUSS finds a concrete need to
change feature-state schema 7. Keep immutable Goal/Boundary approval separate from
requirement revisions. Migration should create a new representation linked to preserved
originals rather than edit an old approval in place. Introduce no new legacy writers
for new cycles; maintain legacy readers through the 7.x series.

Extend the existing observed-command path for execution provenance. A clean HEAD alone
does not identify an uncommitted working tree: either capture a verifiable content
identity or require a clean examined revision at publication. DISCUSS must select the
mechanism, including untracked inputs, before the implementation plan is accepted.

The footprint names known consumers. A shared parser, migration command, their registered
tests, and format/migration documentation will be new files; PLAN must choose their names
and update this footprint before dispatch. Existing tests for each touched helper are
part of the change; spec-intent behavior is preserved and tested even if its implementation
needs no edit. Version files change together through the existing bump helper at release
readiness, not while the implementation remains incomplete.

## Grounding

- EVID-001: The existing coverage helper rejects missing text but accepts a dangling task mapping or unlinked notes; this is a helper-level reproduction, not a complete-cycle bypass.
- EVID-002: The driver, grounding gate, and convergence floor independently derive positional GE identities; the new parser must cover every reader and writer.
- EVID-003: Goal/Boundary approval is a separate immutable digest; migration must preserve that contract.
- EVID-004: The current feature-state contract accepts schema 7 and does not implement in-place schema migration; product release numbering cannot substitute for artifact versioning.

## Open questions

No unresolved outcome question.
The design below resolves the implementation questions for PLAN. Goals and Boundaries
remain the approved outcome; the implementation choices remain revisable against evidence.

## Design decisions

### One requirement reader, with an explicit format boundary

Add a stdlib module behind the existing shell interfaces. It returns a versioned
inventory with owner, requirement ID, revision, text, scenarios, retired identities,
and source locations. All driver writers, coverage checks, grounding, and convergence
use that inventory. The alternative, patching each positional parser independently,
would leave multiple definitions of identity and multiline parsing (EVID-002).

New specs declare `requirements_version: 1` and an explicit owner in frontmatter.
Use one-line JSON values for structured metadata, following the current unresolved
question reader. The owner is fixed when the cycle starts and includes repository
identity plus feature slug; a renamed file does not change the owner. Missing version
means legacy only when the cycle is recorded as legacy. An unknown, duplicate, malformed,
or removed declaration in a new-format cycle fails closed.

In the Good Enough section, each top-level checkbox starts with an explicit local
GE identity, followed by the requirement text. IDs are monotonically allocated and
never inferred from current order. Each requirement owns stable scenario identities
and observable scenario text. A command is associated with the scenario separately;
changing a command invalidates its execution evidence without inventing a new outcome.
The inventory sorts by identity when hashing so document reordering is harmless.

Define revisions as SHA-256 of a canonical JSON representation of the requirement's
text and its scenario identity/text pairs. Normalize line endings, checkbox state, and
prose line wrapping only; preserve executable examples byte-for-byte apart from line
endings. Ignore code-fenced examples when discovering headings and identities. Duplicate
sections and ambiguous parsing are errors. Tests fix these normalization rules.

Persist the issued/retired ID history in driver-owned, versioned feature state. The
spec is the authority for current behavior; the ledger only prevents identity reuse
and detects rollback or deletion of its version marker. Each acceptance of a changed
inventory reconciles that history under the existing state lock. No new standalone
database or independently editable requirement document is introduced.

### Coverage is a relation to the actual dispatch plan

Extend PLAN task blocks with explicit requirement/scenario references, parsed into
the existing tasks representation. For new-format cycles, validate references against
the current inventory and compare the derived task representation with what EXECUTE
will dispatch. A dangling reference, a missing required scenario, or a stale requirement
revision blocks PLAN. Notes and a disconnected coverage summary cannot satisfy it.

Supporting work references the outcomes it enables or a named obligation declared in
the spec's constraints. Do not accept free-text task exemptions. One task may name
several references, and several tasks may name the same reference. Keep the human
coverage section as a derived explanation. Do not infer links by semantic similarity.

Keep the legacy reader for existing cycles through 7.x. Add the demonstrated dangling
mapping regression before changing the new-format gate, and test the real PLAN egress
with both formats. Legacy format support does not allow a new cycle to choose weaker
validation by removing metadata.

### The driver owns execution observations

Extend the current observed-command producer (EVID-006). New-format records contain an
execution ID, spec owner, requirement revision, scenario ID, command, exit status,
output digest, code identity, and execution-environment identity. They reference the
captured output rather than accept caller-supplied PASS. Markdown verification rows
reference these records; gates cross-check them and reject extra unknown references.

Use a clean examined source revision for 7.0 rather than add a general filesystem
fingerprinting engine. Before and after a command, require the same HEAD and no changed
tracked or non-ignored untracked inputs. Exempt only the exact driver-owned output
files and feature-state storage; never exempt an arbitrary directory containing source.
Fingerprint authoritative spec, plan, and command inputs separately, including any
permitted uncommitted authoring artifacts. Output paths may not overlap those inputs.
Commands that change source or tracked test inputs leave failed evidence and an
actionable instruction to commit or restore the inputs and rerun verification.

Environment identity records the explicitly configured toolchain versions and declared
external input identities without storing secrets. Lockfiles describe intended dependency
resolution, not installed bytes. Each command's declared input contract also covers
installed dependency trees, ignored generated executables, and ignored local configuration
that the command reads. Hash declared local runtime inputs before and after execution,
streaming file contents in a deterministic path order. Resolve symlinks against declared
roots; reject escapes, unreadable inputs, and changes during observation. An input-set
declaration is part of the reviewed plan and its digest is bound into the observation.

For an isolated prepared environment, a trusted preparation receipt plus validation of
the actual installed inputs may supply these identities. A receipt or lockfile alone
cannot stand in for that validation. External services require an observable immutable
identity appropriate to the check; otherwise report the unsupported input and block a
current verified result. Sensitive configuration requires a trusted non-secret version
identity; do not log its contents or a guessable secret digest. There is no claim that
the driver can infer arbitrary shell dependencies: supported checks must declare their
inputs, the review checks completeness, and undeclared or unknown required inputs block
publication. Test changed ignored dependencies with an unchanged lockfile, changed
ignored configuration, an escaping symlink, and an unavailable external identity.

Capture output as a bounded stream instead of buffering subprocess.PIPE to completion.
Incrementally hash and spool output while retaining a bounded display tail; configure a
finite byte ceiling and execution timeout. On overflow or timeout, terminate and reap
the command process group and publish a non-PASS observation with the reason. A partial
output digest is explicitly labeled partial. Test a verbose child process and ensure
bounded memory, no orphaned child, and no passing result after truncation by the ceiling.

Observed records are driver-owned and protected by the existing tool-write guards;
extend each harness adapter's coverage of this boundary. Hashes detect changed content,
not the identity of a writer with unrestricted host access. The guarantee applies to
the supported guarded driver path, not an adversary who can replace both the runtime
and its records. Final verification observes the integrated revision; this release
does not reuse old evidence to avoid executing checks.

### Migration preserves originals and publishes under a transaction gate

Provide preview, apply, status/resume, and rollback operations for incomplete legacy
cycles. Preview writes no repository state, assigns IDs in original source order,
derives scenario candidates only from explicit existing criteria/examples, and reports
unresolved relationships instead of inventing them. Output a digest of every source
artifact and relevant feature-state field plus the proposed changes. Applying requires
that preview digest and matching current inputs.

Before replacing any active artifact, acquire the shared feature publication lock,
validate the whole candidate, preserve exact originals and their hashes in an immutable
generation, and publish a migration-in-progress marker. All cycle entry, phase exit,
verification, and delivery consumers reject an unfinished migration. Replace the working SPEC and
PLAN only after the marker is durable, then publish the versioned state and completed
receipt last. Keep old verification as historical output and require fresh new-format
observations. Preserve Goal/Boundary bytes and specApproval exactly; if conversion
cannot do that, refuse it rather than rewrite the approval.

A marker check at phase start is insufficient. Each consumer records an artifact
generation and input hashes on entry. Producers stage outputs outside the authoritative
paths; publication takes the shared lock, rechecks that generation and those hashes,
and fails without replacing artifacts or state if either changed. Every accepted
artifact/state mutation and phase acknowledgement uses that check, including legacy
consumers participating in migration. Migration advances the generation before releasing
the lock, so a consumer started earlier cannot later acknowledge or publish stale work.

Coordinate the publication lock with the existing feature-state lock using one lock
order: publication first, state second. Centralize the locked write primitive rather
than recursively acquiring the same lock through a subprocess. Do not hold the
publication lock across model or command execution. Unsupported legacy participants
without the generation-aware publication path must stop before migration is permitted.
Test an old-generation reader that starts before the marker and attempts to publish
after migration, simultaneous apply attempts, and ordinary state updates at the boundary.

Resume uses the recorded generation and expected hashes to finish or restore the same
transaction. It does not reallocate IDs. Rollback restores originals only if the current
files still match the migration's published versions; later edits require an explicit
conflict resolution rather than destructive overwrite. A completed-cycle check rejects
migration before any write. Backup generations and journals travel with durable feature
state so a resumed checkout does not lose recovery material.

The existing atomic state publisher is a reusable single-file primitive (EVID-007),
not proof that a multi-file migration is atomic. Failure injection must cover every
publication boundary and concurrent phase readers. Bound preview memory by artifact
size, stream file hashing, and reject unsupported input shapes with file/line diagnostics.

### Corner test and implementation sequence

The likely next change is a scenario format or a capability-owned requirement. A shared
inventory interface contains that change in the parser and owner resolver; gates consume
the same identity/revision objects. Do not build the 7.1 capability store now.

PLAN should separate parser/format tests, producer updates, coverage integration,
observation integration, migration, and release documentation into dependent tasks.
Retain the current feature-state schema number if its declared extension points can
express the required fields; every new field still needs graph-schema declarations
and validation. Update release version files only after the implementation and gates pass.
