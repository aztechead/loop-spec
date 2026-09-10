# 7.0: stable requirements and verifiable coverage - Implementation Plan

For maintainers implementing and reviewing the complete approved 7.0 release.

**Spec:** `docs/loop-spec/features/release-7-0/SPEC.md`
**Created:** 2026-09-10

## Architecture overview

Retain the approved shared stdlib inventory behind existing Bash entry points. `lib/feature_read.py:60-93` demonstrates the shared Python/shell reader seam, while independent positional readers in `lib/graph/driver.py:2016-2028,2434-2435` demonstrate why separately patching regexes cannot satisfy stable identity. Reuse `lib/feature_write.py:24-43` for durable single-file replacement, but add a generation-aware publication boundary because that primitive alone cannot make migration safe across several files.

## System design

- Architecture: requirement parsing owns Markdown meaning; state owns issued identity history and publication generation; the driver owns command observations and authoritative artifact publication. Existing phase gates remain the consumers and existing harness adapters remain the enforcement boundary.
- Component structure: new `lib/requirements.py` and `lib/requirements.sh` expose the inventory; `lib/artifact_publication.py` and `lib/artifact-publication.sh` own capture/stage/commit; `lib/execution_inputs.py` owns declared input identities; `lib/execution_observation.py` owns bounded process capture; `lib/requirements_migrate.py` and `lib/requirements-migrate.sh` own legacy conversion and recovery. Each boundary receives paths/contracts, not hidden global collaborators.
- Data flows: authored SPEC -> inventory -> ledger reconciliation -> PLAN task references -> derived tasks.json -> dispatch -> driver observation -> guarded VERIFICATION publication -> grounding/floor/phase exit -> exact-SHA delivery. Migration preview -> approved digest -> publication lock -> preserved generation -> durable marker -> replacements -> state and receipt -> fresh observations.
- API design: Python `parse_spec(text, source, contract)` returns `{version, owner, requirements, obligations, locations}`; requirement objects contain `{id, revision, text, scenarios, location}` and scenarios contain `{id, text, examples, location}`. `load_inventory(spec_path, feature_state)` validates the persisted format boundary and ledger. Both are pure readers; `reconcile_inventory(previous_contract, inventory)` returns a candidate ledger and never writes. CLI `requirements.sh inventory --spec PATH --feature-dir DIR` prints JSON; validation failure exits 1 with file/line/ID; bad invocation exits 2. Legacy dispatch is explicit through the persisted contract, never guessed by a gate.
- Database schema: no database. Keep feature schema 7 and add declared, nested-validated top-level `requirementsContract` and `artifactPublication` objects. `requirementsContract={version:1, format:"legacy"|"v1", owner:{repository,feature}, inventoryDigest:null|sha256, nextRequirementId:positive-int, issued:{GE-ID:{revision:sha256,nextScenarioId:positive-int,scenarios:[SC-ID]}}, retired:[GE-ID], retiredScenarios:{GE-ID:[SC-ID]}}`. `artifactPublication={version:1,generation:nonnegative-int,evidenceEpoch:nonnegative-int,migration:null|{id,previewDigest,phase,originalGeneration,publishedHashes},participantsVersion:1}`. Ledger entries persist after retirement. All hashes are lowercase SHA-256; all IDs and nested keys are validated. Old schema-7 state without these fields is legacy only after the trusted existing-cycle bootstrap records that fact; new-cycle initialization writes v1 only after task-009 activates the complete integration. Tasks 001–008 expose fixture-only opt-in internals while ordinary new cycles retain the pre-release behavior; this transitional build condition is removed at activation and is not a shipped user downgrade switch. Once recorded, format/version/owner cannot be removed or downgraded by ordinary writes, including whole-state replacement. Completed old cycles are read without bootstrap mutation.
- Interface architecture: humans edit staging SPEC/PLAN and review migration preview; driver publication validates and replaces authoritative paths. Command `artifact-publication.sh capture --feature-dir DIR` returns a token containing generation and authoritative input hashes; `publish --feature-dir DIR --token PATH --manifest PATH` commits staged paths and permitted state changes after revalidation. No caller supplies a PASS result. Migration CLI is `requirements-migrate.sh preview|apply|status|resume|rollback --feature-dir DIR`; apply additionally requires `--preview PATH --digest SHA256`, resume/rollback require `--transaction ID`. Preview stdout contains source digests, exact proposed replacements, unresolved file/line relationships, and preview digest; preview creates no repository files.
- Caching strategy: no verification reuse or new cache. Inventories are derived on demand; immutable migration backups and observation output are provenance/recovery records, not editable requirements.
- Scale bound: reject SPEC/PLAN inputs above a documented 16 MiB each; parse one artifact at a time. Stream all file hashes in 64 KiB chunks and deterministic relative-path order. Observations default to a 16 MiB output ceiling, 64 KiB display tail and existing finite phase timeout; positive bounded configuration is validated. Kill and reap the entire process group on timeout/overflow, label partial digests, and never emit PASS for either.

### Exact artifact grammar

SPEC frontmatter declares exactly once `requirements_version: 1` and `requirements_owner: {"repository":"<stable-repository-id>","feature":"<slug>"}` on individual lines; structured values are single-line JSON, parsed with duplicate-key rejection. Resolve repository identity at cycle creation from the existing declared workspace repository identity when present, otherwise an explicit operator repository ID or a driver-generated UUID persisted once; do not use an absolute checkout path or infer provider ownership from a remote URL. The owner object is thereafter immutable and travels with state across checkout/path renames.

Exactly one `### Good Enough` section contains required items `- [ ] GE-001: requirement prose`. IDs follow `GE-[0-9]{3,}` with a positive numeric value and canonical zero-padding to at least three digits. Continuation prose is indented two spaces. Each required item contains one or more `  - SC-001: observable scenario prose`, with scenario continuation indented four spaces. Scenario IDs use the corresponding `SC-[0-9]{3,}` grammar and are local to their requirement, monotonic and never reused after retirement. Optional executable examples are fenced blocks indented four spaces beneath the scenario. A fence is opened/closed by at least three identical backticks or tildes, with the closing run at least as long as its opener. Fence content is literal: headings, checkboxes, and apparent identities inside it never create records. Invalid indentation, unclosed fences, duplicate sections, duplicate IDs, empty text/scenarios, and ambiguous nesting fail with file/line diagnostics. `### Exceptional` remains separate and cannot satisfy required coverage.

Revision is `sha256(UTF-8(canonical JSON))` of `{text,scenarios:[{id,text,examples}]}`: JSON keys sorted, separators `(',', ':')`, ensure_ascii false, scenario list sorted by numeric identity. Normalize CRLF/CR to LF, strip structural indentation and join prose wrapping with one space; preserve paragraph boundaries, meaningful inline spacing and fenced example bytes except line endings/structural indentation. Exclude checkbox state, locations, order, commands and owner from the requirement revision; identity is the separate tuple `(owner,GE-ID)`. Inventory digest sorts requirements/scenarios by identity and includes owner/version. Commands have their own digest, so a command edit stales evidence without changing outcome revision.

PLAN task blocks add `**Requirements:**` followed by single-line JSON bullets `- {"owner":{"repository":"...","feature":"..."},"requirement":"GE-001","revision":"<sha256>","scenarios":["SC-001"]}`. Supporting tasks either use these references or `**Obligations:**` with bullets naming `OBL-...` IDs explicitly declared as `- OBL-runtime: ...` under SPEC `## Constraints`. No free-text exemption exists. Tasks additionally declare `**Execution inputs:**` followed by one single-line JSON object with `version:1`, `toolchains`, `localInputs`, `externalInputs`, `sensitiveInputs`, and optional `preparationReceipt`. The extractor emits `requirements[]`, `obligations[]`, and `executionInputs`; the renderer round-trips them. The command is each task's existing verifyCommand. Short routes put the same scenario/command/input-contract objects in the single-line JSON `scenario_checks` frontmatter map keyed by `GE-ID/SC-ID`; no numeric row aliases are accepted in v1. Full-route checks derive from the reviewed task relation; duplicate commands may share a single execution only when the complete input contract and all bound identities are identical and the record explicitly lists every covered scenario.

Toolchains are `{name,argv,expectedIdentity}` version probes run without shell expansion and with bounded output/time; store only reviewed non-secret version output. Local inputs are `{root,paths}` sets including installed trees, ignored generated executables and non-sensitive ignored config actually read by the check. Traverse paths deterministically, hash path/type/content, resolve symlinks within their declared root, and reject escapes/unreadable files or pre/post changes. External inputs use `{name,argv,expectedIdentity}` probes returning `{identity,immutable:true}`; empty, unavailable or mutable identity blocks current evidence. Sensitive inputs use the same trusted non-secret version probe, never contents or a content digest. A preparation receipt is optional context and never replaces installed-input validation. The reviewed input-set digest, actual environment digest and probe implementation identities are recorded; arbitrary dependency discovery is explicitly unsupported.

Observation records live at exact driver-owned paths under feature state: `observations/<execution-id>.json` plus `observations/<execution-id>.output`. Record schema 1 includes execution ID, owner, requirement/scenario/revision bindings, command and command digest, exit status, failure reason, output path/digest/completeness, clean HEAD identity, authoritative SPEC/PLAN/command-input hashes, input-set digest, environment identity, publicationGenerationAtCapture, evidenceEpoch and timestamps. VERIFICATION rows name owner/requirement/revision/scenario/execution ID/status; the gate loads the record and captured output and rechecks bindings. Before/after execution require identical HEAD and no tracked or non-ignored untracked input changes, excluding only individually enumerated driver output/state files and separately fingerprinted authoring artifacts. No directory-wide source exemption and no input/output path overlap. Multi-repository checks record each examined repository HEAD; an unknown input makes the record non-PASS.

### Publication and execution setup

Capture generation plus SPEC/PLAN/tasks/command-input hashes on entry. Every producer stages outside authoritative paths; final publication and phase acknowledgement take publication lock first and state lock second, validate token/current hashes and migration status, then commit through one in-process locked primitive. A producer's own accepted changes return a refreshed token; unrelated changes invalidate the old token. Never refresh silently to accept stale output. Do not hold either lock across commands/model work. Register supported participants version 1; migration refuses a runtime/participant that lacks this path. Durable migration journal/backups stay under `migration-generations/<transaction-id>/` in feature state. Extend state-ref snapshot/restore as well as store-mirror coverage so recovery and observations survive a resumed checkout. Increment generation for every accepted publication and migration/rollback transition; never roll the generation counter backward. This counter is compare-and-swap protection for pending work, not an evidence freshness test. Evidence validity compares owner, requirement/scenario revision, command/input-set digests, examined HEADs, actual environment/local input identities, output integrity and evidenceEpoch. Increment evidenceEpoch only on migration/rollback or an explicit provenance-invalidating reset; ordinary output, VERIFICATION and unrelated state publication never advance it. A record may remain valid across later publication generations when all evidence inputs remain identical. A still-running producer must nevertheless hold its original ingress token and fail publication after an intervening generation change; it cannot recapture a token to legitimize old work.

### Final candidate observations

Task-008 integrates the real finalization sequence: `lib/deliver.sh:140-160` currently invokes `finalize-delivery-candidate.sh run --commit` and then selects HEAD, while `lib/finalize-delivery-candidate.sh:214-238` can commit docs, rules, ignore changes and optional telemetry after VERIFY. Therefore ordinary VERIFY observations on A never authorize a later candidate B, even when B changed only a report. First finalize all tracked artifacts using the existing finalizer (including artifact-sink mode), resolve the exact candidate SHA set, then run every required scenario and mandatory final command fresh against that clean final candidate. Add driver `verification run --final-candidate SHA` (single repo) or `--final-candidates PATH` (reviewed workspace name/SHA JSON) and write its final VERIFICATION projection only to `observations/final/<candidate-digest>/VERIFICATION.md` in durable runtime state. Final output records and this projection are driver-owned and never staged onto the feature branch. The tracked VERIFICATION is the preceding phase report and may link by stable runtime record location; do not rewrite it after the final candidate is formed. This breaks the commit-evidence-commit cycle without treating a changed HEAD as equivalent or exempting a source directory.

For artifact-sink mode, resolve preserved SPEC/PLAN/command inputs from its manifest and bind their exact hashes in the final observations; validate that store before running. Workspace delivery uses the existing per-target branch validation and freshly observes each bound target; no workspace bypass through the single-repo finalizer's early return. `deliver.sh` must validate the final runtime report and observations against the selected target SHA before invoking `pr-delivery.sh final`; it also rechecks HEAD/input identity and ingress token before accepting delivery/result state. On a missing/stale final report it runs the supported final-candidate observer before invoking delivery, not a source-equality shortcut. `delivery-reconcile.sh` and terminal cycle-result consumers require the same checked target binding. Existing exact-SHA retries remain observation-only with respect to remote delivery; they cannot turn stale A evidence into B proof. A newly selected candidate requires fresh executions. Any source/authoritative-input change after final observations fails the delivery gate; do not generate another tracked report or silently rebind the candidate.

Before EXECUTE edits this self-hosting repository, pin an immutable copy of the driver/plugin runtime and instructions from the approved starting revision and execute the cycle through that copy. `lib/phase_snapshot.py:20-26` snapshots every skills/agents source; modifying the runtime in place would invalidate that contract. Validate the copy and route the existing cycle through it before dispatch; do not weaken source-hash checks or add a new product-level runtime manager. The lead must add every planned path below to SPEC footprint before dispatch, because this planner writes PLAN only. PLAN authoring makes no commits. EXECUTE follows the cycle commit contract; it does not run live evals, merge, or publish a release.

## User decisions (already made)

- **Which release is being started?** → The 7.0 foundation on feat/7.x.x — The requested first new release follows the committed 7.x roadmap.
- **How long should existing incomplete cycles remain readable?** → Keep legacy readers through the 7.x series; new cycles use the new format — A bounded major-series compatibility window preserves existing work without adding legacy writers.
- **Which schema should version requirement artifacts?** → Prefer a separate artifact version; change feature-state schema only if its own shape requires it — Product release and feature-state schema are distinct contracts.

## Global constraints

- Do not rewrite completed feature artifacts, approval hashes, or historical verification records to manufacture new provenance.
- Do not treat a copied PASS, a matching requirement ID, or a source citation as proof that a command ran successfully.
- Do not relax approved intent, maker/checker separation, existing mandatory gates, retry bounds, or exact-SHA delivery.
- Do not require a new third-party runtime dependency, daemon, database, persistent code map, or live model evaluation to use the feature.
- Do not silently migrate an active legacy cycle or silently fall back to legacy validation for an explicitly versioned but malformed new artifact.
- Do not merge or publish a release automatically as part of implementation.

- Keep Markdown specifications and PLAN authoritative; machine-readable inventories are derived views, not separately editable sources of intent.
- Separate product version, feature-state schema, and artifact-contract version. Change each only when its own compatibility contract requires it.
- Preserve current eligible short routes as well as the full cycle. The same requirement cannot acquire a different identity because its execution route changed.
- Unknown dependency or environment identity cannot be represented as verified current evidence.
- Record implementation choices outside Goals and Boundaries so better designs can replace them without changing the approved outcome.

## File map

Task Files lists below are the exact write ownership map; paths described as new are created by their first owner. No source file is deleted. New modules/commands: requirements (task-001), artifact publication (task-003), execution inputs (task-006), observation (task-007), and migration (task-010). New docs: `docs/loop-spec/requirements-format.md` (task-001) and `docs/loop-spec/requirements-migration.md` (task-010). Every new helper has a registered test in its creating task.

Shared-file sequencing: tests/run-all.sh is updated by each creator after its predecessors; driver.py belongs successively to task-004, task-007, task-008 and task-009; artifact-lint.sh to task-001, task-005 and task-008; graph/cycle.graph.json to task-002, task-004 and task-008; feature_write.py to task-002, task-003 and activation task-009; requirements_migrate.py to task-010 then task-011. Logical dependencies below also make these successive integrations executable; EXECUTE may add file-overlap edges but must not remove these dependencies.

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | Define the versioned inventory and grammar | - | see task Files | medium |
| task-002 | Declare and enforce driver-owned identity state | task-001 | see task Files | medium |
| task-003 | Add generation-aware publication transactions | task-002 | see task Files | medium |
| task-004 | Integrate staging and stable identities into every producer route | task-003 | see task Files | medium |
| task-005 | Validate coverage against the complete dispatch representation | task-004 | see task Files | medium |
| task-006 | Implement declared environment and runtime input identities | task-005 | see task Files | medium |
| task-007 | Produce bounded driver-owned execution observations | task-006 | see task Files | medium |
| task-008 | Enforce observed scenario evidence in VERIFY and ITERATE | task-007 | see task Files | medium |
| task-009 | Protect authoritative publication on all four harnesses | task-008 | see task Files | medium |
| task-010 | Provide deterministic read-only migration previews | task-009 | see task Files | medium |
| task-011 | Publish, resume and roll back migration safely | task-010 | see task Files | medium |
| task-012 | Verify the complete release and declare 7.0.0 readiness | task-011 | see task Files | medium |

## Tasks

### task-001: Define the versioned inventory and grammar

**Goal:** Introduce one tested inventory reader and structural v1 validation without changing existing cycle writers.

**Files:**
- lib/requirements.py
- lib/requirements.sh
- lib/artifact-lint.sh
- tests/lib/requirements.test.sh
- tests/lib/artifact-lint.test.sh
- tests/run-all.sh
- docs/loop-spec/requirements-format.md

**read_first:**
- lib/feature_read.py
- lib/spec_intent.py
- lib/artifact-lint.sh
- tests/lib/spec-intent.test.sh
- docs/loop-spec/features/release-7-0/PATTERNS.md
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

**Interfaces:**
- consumes: approved SPEC and existing shared-reader interface
- produces: Pure versioned inventory API and documented grammar used by all later tasks.

**Verify:** `rtk bash tests/lib/requirements.test.sh && rtk bash tests/lib/artifact-lint.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] requirements.test.sh proves reordering, checkbox changes, CRLF and prose wrapping retain revision; scenario text or example edits change revision; command-only edits do not.
- [ ] requirements.test.sh exits 1 with source line for duplicate/malformed IDs, sections, metadata or JSON keys, empty scenarios, fenced decoys, unknown versions and removed metadata against a v1 contract.
- [ ] artifact-lint.test.sh accepts legacy fixtures under legacy context and rejects malformed explicit v1 without legacy fallback.

**BlockedBy:** []

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: add parser/normalization and artifact-lint fixtures first; run both suites red before implementing.
- [ ] Step 2: Apply shared-reader seam from PATTERNS lib/feature_read.py:60-93; implement the exact API/grammar above in a named stdlib module, preserving shell interfaces.
- [ ] Step 3: Document authoritative grammar and diagnostics; register requirements.test.sh; run green.

### task-002: Declare and enforce driver-owned identity state

**Goal:** Persist immutable format/owner and monotonic issued/retired histories while retaining feature schema 7.

**Files:**
- graph/schema.json
- graph/cycle.graph.json
- lib/feature_read.py
- lib/feature_write.py
- lib/requirements.py
- skills/shared/feature-state-schema.md
- tests/lib/feature-read.test.sh
- tests/lib/feature-write.test.sh
- tests/lib/feature-init.test.sh
- tests/lib/graph-schema.test.sh
- tests/lib/requirements.test.sh

**read_first:**
- graph/schema.json
- lib/feature_read.py
- lib/feature_write.py
- lib/feature-init.sh
- skills/shared/feature-state-schema.md
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

**Interfaces:**
- consumes: task-001
- produces: Typed requirementsContract/artifactPublication and reconciliation rules.

**Verify:** `rtk bash tests/lib/feature-read.test.sh && rtk bash tests/lib/feature-write.test.sh && rtk bash tests/lib/feature-init.test.sh && rtk bash tests/lib/graph-schema.test.sh && rtk bash tests/lib/requirements.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] feature-write.test.sh rejects malformed nested state, removal/downgrade of a recorded v1 contract, owner changes, retired requirement/scenario reuse and next-ID rollback, including whole-state replacement.
- [ ] feature-init.test.sh proves fixture-only v1 contracts have stable owner while ordinary single/workspace initialization remains unchanged until task-009; imported incomplete pre-7 fixtures record legacy through explicit trusted bootstrap and completed legacy state remains byte-identical.
- [ ] feature-read.test.sh validates the two declared fields and rejects unknown nested keys; graph-schema.test.sh validates every added read/write/egress declaration.

**BlockedBy:** [task-001]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: write state lifecycle and legacy fixture tests and run red.
- [ ] Step 2: Reuse PATTERNS lib/feature_read.py:189-193 and lib/feature_write.py:114-117; put nested requirements/publication field validation in requirements.py and call it at state load and before writer publication. Add graph stateKey entries and phase read/write declarations; do not claim the enum validates nested types.
- [ ] Step 3: Reconcile accepted inventory under state lock for explicit test fixtures; retain specApproval immutability and schemaVersion 7. Do not enable default v1 or missing-token enforcement for ordinary cycles yet; run green and the existing legacy cycle fixture.

### task-003: Add generation-aware publication transactions

**Goal:** Create a shared locked publication primitive that refuses stale generations before authoritative mutation.

**Files:**
- lib/artifact_publication.py
- lib/artifact-publication.sh
- lib/feature_write.py
- lib/state-ref.sh
- tests/lib/state-ref.test.sh
- tests/lib/artifact-publication.test.sh
- tests/lib/feature-write.test.sh
- tests/lib/supervisor-store.test.sh
- tests/run-all.sh

**read_first:**
- lib/feature_write.py
- lib/supervisor/store.sh
- lib/supervisor/store-mirror.sh
- lib/state-ref.sh
- tests/lib/feature-write.test.sh
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

**Interfaces:**
- consumes: task-002
- produces: Capture/token/staged publication interface shared by producers, state updates and migration.

**Verify:** `rtk bash tests/lib/artifact-publication.test.sh && rtk bash tests/lib/feature-write.test.sh && rtk bash tests/lib/supervisor-store.test.sh && rtk bash tests/lib/state-ref.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] artifact-publication.test.sh starts two readers, publishes one, then proves the stale reader exits 1 without replacing artifact/state bytes or acknowledging a phase.
- [ ] feature-write.test.sh races ordinary state updates with publication and proves lock order publication-first/state-second completes without deadlock or lost updates; recursive writer acquisition is absent from the executed path.
- [ ] artifact-publication.test.sh injects failure after staging and each single-file replace, rejects active migration to ordinary callers, and verifies durable recovery metadata through store-mirror reopen.

**BlockedBy:** [task-002]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: use subprocess barriers/failure injection and run concurrency tests red.
- [ ] Step 2: Apply PATTERNS lib/feature_write.py:24-43 for atomic replacement; factor an in-process state update primitive that accepts already-held locks. Implement capture and manifest publication, validated exact paths, fsync journals and monotonically advancing generations.
- [ ] Step 3: Extend lib/state-ref.sh snapshot/restore allow-list to observations and migration-generations (journal and immutable originals), excluding transient staging/locks; state-ref.test.sh must restore identical hashes, permissions and recovery state into a fresh checkout, and supervisor-store.test.sh proves parity for mirror/local persistence. Register the new suite. Fixture participants use their original ingress token and refresh it only from their own successful publication. Do not recapture inside feature-write or at egress. Keep ordinary-cycle behavior runnable until the caller sweep and guards land in tasks 004–009; strict missing-token enforcement activates with task-009. Run green.

### task-004: Integrate staging and stable identities into every producer route

**Goal:** Route full and eligible short authoring through the same identity and publication contracts.

**Files:**
- lib/graph/driver.py
- lib/phase-entry.sh
- lib/phase-exit.sh
- lib/cycle-preflight.sh
- lib/deliver.sh
- lib/cycle-result.sh
- graph/cycle.graph.json
- skills/spec/SKILL.md
- skills/spec-lite/SKILL.md
- skills/oneshot/SKILL.md
- skills/plan/SKILL.md
- agents/spec-writer.md
- agents/planner.md
- skills/shared/artifact-templates/SPEC.md.template
- skills/shared/artifact-templates/SPEC-oneshot.md.template
- tests/lib/cycle-driver.test.sh
- tests/lib/phase-entry.test.sh
- tests/lib/phase-exit.test.sh
- tests/lib/deliver.test.sh
- tests/lib/cycle-result.test.sh
- tests/lib/spec-intent.test.sh

- lib/graph/state.sh
- lib/graph/engine.py
- lib/graph/gate.sh
- lib/artifact-sink.sh
- lib/quality-loop-state.sh
- lib/iterate-judged.sh
- lib/execute_remediation.py
- lib/execute-step.sh
- lib/verify-gate.sh
- lib/verify-prepare.sh
- lib/checkpoint-pr.sh
- lib/revise-state.sh
- lib/feature-bootstrap.sh
- lib/feature-init.sh
- tests/lib/graph-state.test.sh
- tests/lib/graph-run.test.sh
- tests/lib/graph-gate.test.sh
- tests/lib/artifact-sink.test.sh
- tests/lib/quality-loop-state.test.sh
- tests/lib/execute-prepare.test.sh
- tests/lib/execute-step.test.sh
- tests/lib/verify-prepare.test.sh
- tests/lib/checkpoint-pr.test.sh
- tests/lib/revise-state.test.sh
- tests/lib/feature-init.test.sh
- tests/lib/publication-callers.test.sh
- tests/run-all.sh

**read_first:**
- lib/graph/driver.py
- lib/phase-entry.sh
- lib/phase-exit.sh
- lib/cycle-preflight.sh
- lib/deliver.sh
- lib/cycle-result.sh
- lib/phase_snapshot.py
- skills/spec/SKILL.md
- skills/spec-lite/SKILL.md
- skills/oneshot/SKILL.md
- skills/plan/SKILL.md
- agents/spec-writer.md
- agents/planner.md
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

- lib/graph/state.sh:118
- lib/graph/engine.py:610-620
- lib/artifact-sink.sh:91-112
- lib/quality-loop-state.sh:42-73
- lib/execute_remediation.py:16-36

**Interfaces:**
- consumes: task-003
- produces: All-route staging producers and generation-aware lifecycle consumers.

**Verify:** `rtk bash tests/lib/cycle-driver.test.sh && rtk bash tests/lib/phase-entry.test.sh && rtk bash tests/lib/phase-exit.test.sh && rtk bash tests/lib/deliver.test.sh && rtk bash tests/lib/cycle-result.test.sh && rtk bash tests/lib/spec-intent.test.sh && rtk bash tests/lib/publication-callers.test.sh && rtk bash tests/lib/graph-state.test.sh && rtk bash tests/lib/graph-run.test.sh && rtk bash tests/lib/graph-gate.test.sh && rtk bash tests/lib/artifact-sink.test.sh && rtk bash tests/lib/quality-loop-state.test.sh && rtk bash tests/lib/execute-prepare.test.sh && rtk bash tests/lib/execute-step.test.sh && rtk bash tests/lib/verify-prepare.test.sh && rtk bash tests/lib/checkpoint-pr.test.sh && rtk bash tests/lib/revise-state.test.sh && rtk bash tests/lib/feature-init.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] cycle-driver.test.sh exercises new full/spec-lite/oneshot creation, spec ingest/write/fill, replacement by stable ID, route escalation and reordered criteria; all preserve owner/IDs and reject numeric positional aliases for v1.
- [ ] phase-exit.test.sh starts before a generation change and proves subsequent exit cannot acknowledge work; cycle-driver/deliver/cycle-result fixtures reject migration-in-progress before any side effect and again before accepted state/result publication.
- [ ] spec-intent.test.sh verifies byte-preserved Goals/Boundaries and unchanged specApproval through implementation-only writes; legacy completion remains supported with no new legacy writer selected at creation.

- [ ] publication-callers.test.sh executes each enumerated state writer with a valid original ingress token and then with a stale token; valid writes succeed and stale writes leave state/artifact hashes and acknowledgements unchanged. It registers a source-callsite completeness check for feature-write shell calls, feature_write Python imports and direct phase-state publishers, so newly discovered callers fail the test until explicitly handled.
- [ ] graph-state/graph-run/graph-gate tests prove graph transitions preserve the original node ingress token across subprocesses. Artifact-sink and quality-loop-state tests hold old read results across a migration and prove stale publication cannot overwrite current artifacts or mark findings clean.
- [ ] cycle-driver.test.sh resumes an incomplete legacy fixture through SPEC/PLAN/EXECUTE/VERIFY/ITERATE and ordinary new-cycle fixtures remain runnable at this intermediate revision; no default v1 activation occurs.

**BlockedBy:** [task-003]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: extend real driver and phase entry/exit route fixtures before modifying producers.
- [ ] Step 2: Use PATTERNS lib/graph/driver.py:2180-2198 as the positional sibling sweep target and lib/spec_intent.py:12-42 for intent separation. Replace all current-criterion enumerations and criteria command writers with inventory IDs, exact scenario_checks metadata and ledger allocation.
- [ ] Step 3: Make skill/agent dispatch target staging paths; use capture at ingress and shared publication for spec/plan/verification skeletons, state changes, phase acknowledgement and terminal/delivery records. Thread refreshed tokens only after this producer succeeds; preflight/entry checks alone are insufficient. Preserve legacy participants through the same publication boundary.
- [ ] Step 4: Update templates and producer instructions in the same diff; test from the pinned runtime copy and run green.

- [ ] Step 10: Sweep all actual writer callsites with rg before editing. Thread the original operation/phase ingress token through graph/state.sh, engine.py and gate.sh; driver fset/fappend/whole replacements; feature-init activation; feature-bootstrap/revise initialization; execute-step/remediation; verify-prepare/gate; iterate-judged; checkpoint-pr; deliver and cycle-result. Initial creation is a narrow atomic create-if-absent operation, never a missing-token bypass for existing state. Group a caller's consecutive writes or return a refreshed token from its own accepted transaction; never capture again to make stale computation pass.
- [ ] Step 11: quality-loop-state.sh writes a separate quality-loop JSON, not feature.json: preserve standalone non-cycle use, but require the owning feature ingress token when its findings/clean state participate in a cycle. Stage artifact-sink copies/restoration and quality-loop state then commit under the same publication protocol; do not delete authoritative docs before checking the token. Register publication-callers.test.sh and retain original token in supported legacy participants.

### task-005: Validate coverage against the complete dispatch representation

**Goal:** Make explicit scenario relations and named obligations the executable coverage authority.

**Files:**
- lib/plan-tasks.sh
- lib/plan-render.sh
- lib/criteria-coverage.sh
- lib/plan-exit-gate.sh
- lib/artifact-lint.sh
- skills/shared/artifact-templates/PLAN.md.template
- tests/lib/plan-tasks.test.sh
- tests/lib/plan-render.test.sh
- tests/lib/criteria-coverage.test.sh
- tests/lib/phase-exit.test.sh
- tests/lib/artifact-lint.test.sh

**read_first:**
- lib/plan-tasks.sh
- lib/plan-render.sh
- lib/criteria-coverage.sh
- lib/plan-exit-gate.sh
- lib/artifact-lint.sh
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

**Interfaces:**
- consumes: task-004
- produces: Reviewed task relation plus executionInputs and exact sidecar comparison.

**Verify:** `rtk bash tests/lib/plan-tasks.test.sh && rtk bash tests/lib/plan-render.test.sh && rtk bash tests/lib/criteria-coverage.test.sh && rtk bash tests/lib/phase-exit.test.sh && rtk bash tests/lib/artifact-lint.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] criteria-coverage.test.sh reproduces and rejects legacy dangling task-999 mappings and notes-only criterion copies while valid legacy coverage remains accepted.
- [ ] phase-exit.test.sh drives actual PLAN egress: v1 missing scenario/revision, dangling task, unsupported exemption, unknown obligation, and tasks.json with same IDs but altered command/files/coverage all exit 1.
- [ ] plan-tasks/plan-render fixtures round-trip requirements, obligations and executionInputs; multiline criteria and valid many-to-many/scaffolding mappings pass without deriving coverage from summary prose.

**BlockedBy:** [task-004]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: add demonstrated dangling mapping regression and real egress failures first.
- [ ] Step 2: Apply PATTERNS lib/plan-tasks.sh:1-26 and lib/plan-exit-gate.sh:21: extend the existing extractor and renderer rather than a second PLAN parser. Compare canonical complete dispatch fields, including dependencies, files, commands, acceptance criteria and new input/coverage contracts; ignore only explicitly non-dispatch presentation fields.
- [ ] Step 3: Have coverage consume requirements.py inventory, validate every scenario relation and revision, and derive the human coverage explanation. Update template; run green.

### task-006: Implement declared environment and runtime input identities

**Goal:** Compute actual declared input identities without treating lockfiles or receipts as installed-byte proof.

**Files:**
- lib/execution_inputs.py
- tests/lib/execution-inputs.test.sh
- tests/lib/prepare-environment.test.sh
- tests/run-all.sh
- docs/loop-spec/requirements-format.md

**read_first:**
- lib/prepare-environment.sh
- tests/lib/prepare-environment.test.sh
- lib/requirements.py
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

**Interfaces:**
- consumes: task-005
- produces: capture_inputs(root, contract, outputs) identity/result API for observed execution.

**Verify:** `rtk bash tests/lib/execution-inputs.test.sh && rtk bash tests/lib/prepare-environment.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] execution-inputs.test.sh changes an ignored installed dependency with unchanged lockfile and changes ignored config; both produce different identity and pre/post failure.
- [ ] execution-inputs.test.sh rejects escaping symlink, unreadable input, unavailable external identity, mutable external response, absent required declaration and overlapping input/output paths with actionable diagnostics.
- [ ] execution-inputs.test.sh verifies deterministic streaming directory hashes, bounded argv probes and non-secret sensitive version identity; fixture secret bytes and guessable secret digests are absent from output/records.
- [ ] prepare-environment.test.sh shows receipt-only validation cannot authorize PASS and an unchanged actual installed-input set can.

**BlockedBy:** [task-005]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: create offline filesystem/argv probe fixtures and run red.
- [ ] Step 2: Use PATTERNS shared-reader lib/feature_read.py:60-93 for a pure module boundary; receive root, input contract, probe runner and permitted output files explicitly. No suitable installed-byte identity analog exists: implement only the declared local/toolchain/external/sensitive contract above.
- [ ] Step 3: Bind hashes of probe implementations and input-set declaration, stream contents, and bound probe output/time; document unsupported unknown inputs and register tests; run green.

### task-007: Produce bounded driver-owned execution observations

**Goal:** Replace buffered command capture with actual bounded records bound to clean code and current reviewed inputs.

**Files:**
- lib/execution_observation.py
- lib/graph/driver.py
- tests/lib/execution-observation.test.sh
- tests/lib/cycle-driver.test.sh
- tests/run-all.sh


**read_first:**
- lib/graph/driver.py
- lib/execution_inputs.py
- lib/artifact_publication.py
- tests/lib/cycle-driver.test.sh
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)


**Interfaces:**
- consumes: task-006
- produces: Driver-observed schema-1 records and output files, no caller-written status.

**Verify:** `rtk bash tests/lib/execution-observation.test.sh && rtk bash tests/lib/cycle-driver.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] execution-observation.test.sh proves exit 0 creates PASS only with identical before/after HEAD, input identity and generation; source edits, new non-ignored inputs, changed authoring artifacts or unknown environment yield non-PASS.
- [ ] execution-observation.test.sh runs a verbose child and a timed-out child with grandchildren; output spool stays within byte ceiling, retained tail stays within 64 KiB, partial digest is marked and no child survives reaping.
- [ ] cycle-driver.test.sh rejects caller PASS/evidence injection and altered output bytes; full/short checks record execution ID, owner/revision/scenario, command, actual exit, code/environment identities and captured output digest.

- [ ] execution-observation.test.sh executes two distinct required commands in sequence, then publishes VERIFICATION and ordinary state updates: both records remain eligible when semantic inputs/evidenceEpoch are unchanged despite increasing publication generations. A concurrent old-token producer still fails publication; migration/rollback evidenceEpoch changes invalidate both records.

**BlockedBy:** [task-006]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: extend PATTERNS observed PASS/FAIL test at tests/lib/cycle-driver.test.sh:458-469; add process-group and filesystem mutation regressions and run red.
- [ ] Step 2: Extract observation concern from PATTERNS lib/graph/driver.py:2407-2497 into execution_observation.py; stream/hash/spool binary output with bounded tail and finite timeout, then use shared publication to publish record/output and refreshed token.
- [ ] Step 3: Run each integrated revision check fresh; represent failed clean/input checks as failed observations and actionable commit/restore/rerun diagnostics. Register suite and run green.

- [ ] Step 10: Keep publicationGenerationAtCapture diagnostic and CAS-only. Evidence validation uses the explicit freshness tuple and evidenceEpoch above, never equality with the latest artifactPublication.generation. Add multi-command integration regression before implementation.

### task-008: Enforce observed scenario evidence in VERIFY and ITERATE

**Goal:** Cross-check current required scenarios against actual observations at real exit and convergence gates.

**Files:**
- lib/verification-grounding-lint.sh
- lib/converged-floor.sh
- lib/artifact-lint.sh
- lib/oneshot-exit-gate.sh
- lib/graph/driver.py
- graph/cycle.graph.json
- agents/verifier.md
- skills/shared/artifact-templates/VERIFICATION.md.template
- skills/shared/artifact-templates/VERIFICATION-oneshot.md.template
- tests/lib/verification-grounding-lint.test.sh
- tests/lib/converged-floor.test.sh
- tests/lib/artifact-lint.test.sh
- tests/lib/oneshot-exit-gate.test.sh
- tests/lib/cycle-driver.test.sh
- tests/lib/phase-exit.test.sh
- tests/verification-grounding-coverage.test.sh

- lib/deliver.sh
- lib/finalize-delivery-candidate.sh
- lib/delivery-reconcile.sh
- lib/cycle-result.sh
- lib/artifact-sink.sh
- tests/lib/deliver.test.sh
- tests/lib/delivery-reconcile.test.sh
- tests/lib/cycle-result.test.sh
- tests/lib/artifact-sink.test.sh
- tests/lib/final-candidate-observations.test.sh
- tests/run-all.sh

**read_first:**
- lib/verification-grounding-lint.sh
- lib/converged-floor.sh
- lib/oneshot-exit-gate.sh
- lib/graph/driver.py
- agents/verifier.md
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

- lib/deliver.sh:140-160
- lib/finalize-delivery-candidate.sh:214-238
- lib/delivery-reconcile.sh:100-118
- lib/pr-delivery.sh:223-240
- lib/artifact-sink.sh:91-112

**Interfaces:**
- consumes: task-007
- produces: Current-evidence requirement at shape, grounding, convergence and real phase exit.

**Verify:** `rtk bash tests/lib/verification-grounding-lint.test.sh && rtk bash tests/lib/converged-floor.test.sh && rtk bash tests/lib/artifact-lint.test.sh && rtk bash tests/lib/oneshot-exit-gate.test.sh && rtk bash tests/lib/cycle-driver.test.sh && rtk bash tests/lib/phase-exit.test.sh && rtk bash tests/verification-grounding-coverage.test.sh && rtk bash tests/lib/final-candidate-observations.test.sh && rtk bash tests/lib/deliver.test.sh && rtk bash tests/lib/delivery-reconcile.test.sh && rtk bash tests/lib/cycle-result.test.sh && rtk bash tests/lib/artifact-sink.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] verification-grounding-lint.test.sh rejects fabricated PASS text, missing/unknown/extra scenario references, missing output, altered output digest, stale revision/command/HEAD/environment/input contract and numeric aliases; valid fresh observed rows pass.
- [ ] phase-exit.test.sh and oneshot-exit-gate.test.sh exercise v1 VERIFY shape and actual egress; converged-floor.test.sh refuses convergence for any uncovered or stale required scenario on both routes.
- [ ] cycle-driver.test.sh proves reordered required items keep verification association, changed scenario behavior needs a fresh run, and legacy incomplete fixtures finish unchanged under legacy validation through the 7.x window.

- [ ] final-candidate-observations.test.sh drives the real finalizer plus offline delivery adapter: successful observations on A, followed by a source commit B or a post-VERIFY artifact-only finalizer commit B, cannot authorize B; no push/final adapter call occurs before fresh final-candidate checks on B pass.
- [ ] deliver/delivery-reconcile/cycle-result tests prove all terminal paths require final observations for the exact target SHA, including workspace targets and artifact-sink mode; unchanged final B observations pass without creating another tracked commit.
- [ ] final-candidate-observations.test.sh changes HEAD or declared inputs after final observation and before delivery acknowledgement and asserts failure with no success result; two passing commands plus final runtime report publication retain valid evidence.

**BlockedBy:** [task-007]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: add gate-level failure fixtures before replacing positional readers.
- [ ] Step 2: Use PATTERNS lib/graph/driver.py:2434-2435 as the sibling sweep; grounding, floor and verification writers consume requirements.py and the same observation validator instead of indexing checkbox rows.
- [ ] Step 3: Update verifier/templates and graph gate arguments to provide feature contract context; retain maker/checker judgment and mandatory final suite/review gates; run green.

- [ ] Step 10: TDD: register final-candidate-observations.test.sh with temporary repositories and injected existing PR delivery binaries. Preserve the pr-delivery --sha API; the feature adapter supplies a target only after the common observation validator accepts it.
- [ ] Step 11: Implement the finalization sequence specified above: finish tracked output/optional telemetry/artifact-sink first, select candidate SHA(s), execute checks fresh, and write the final projection only under durable observations/final. Bind stored authoritative inputs when artifact-sink removes the working docs. Reconcile and terminal-result paths validate the same candidate record; never authorize a later commit by tree similarity or by the phase having previously passed.

### task-009: Protect authoritative publication on all four harnesses

**Goal:** Enforce driver-owned records and staged artifacts through each supported harness tool boundary.

**Files:**
- lib/harness.sh
- hooks/pre-tool-guard.py
- hooks/restrict-agent-paths.sh
- hooks/team/result-forgery-guard.sh
- extensions/opencode/loop-spec.ts
- extensions/adk/loop_spec_adk/plugin.py
- skills/shared/claude-harness.md
- skills/shared/opencode-harness.md
- skills/shared/adk-harness.md
- skills/shared/codex-harness.md
- tests/opencode-plugin.test.sh
- tests/adk-extension.test.sh
- tests/codex-harness-coverage.test.sh
- tests/opencode-harness-coverage.test.sh
- tests/adk-harness-coverage.test.sh
- hooks/team/result-forgery-guard.test.sh
- hooks/restrict-agent-paths.test.sh

- lib/feature-init.sh
- lib/feature_write.py
- lib/graph/driver.py
- tests/lib/feature-init.test.sh
- tests/lib/feature-write.test.sh
- tests/lib/cycle-driver.test.sh

**read_first:**
- lib/harness.sh
- hooks/pre-tool-guard.py
- hooks/restrict-agent-paths.sh
- hooks/team/result-forgery-guard.sh
- extensions/opencode/loop-spec.ts
- extensions/adk/loop_spec_adk/plugin.py
- skills/shared/codex-harness.md
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)


**Interfaces:**
- consumes: task-008
- produces: Guarded publication participant coverage required before migration can be enabled.

**Verify:** `rtk bash hooks/team/result-forgery-guard.test.sh && rtk bash hooks/restrict-agent-paths.test.sh && rtk bash tests/opencode-plugin.test.sh && rtk bash tests/adk-extension.test.sh && rtk bash tests/codex-harness-coverage.test.sh && rtk bash tests/opencode-harness-coverage.test.sh && rtk bash tests/adk-harness-coverage.test.sh && rtk bash tests/lib/feature-init.test.sh && rtk bash tests/lib/feature-write.test.sh && rtk bash tests/lib/cycle-driver.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] Guard tests execute Write/Edit/patch/move and shell-redirection attempts against SPEC/PLAN/VERIFICATION, feature contract, observations and migration journal; each authoritative bypass exits 2 while permitted staging edits and validated driver publication succeed.
- [ ] Adapter tests inject native tool payloads for Claude, opencode, ADK and Codex and prove denial reaches the caller; unknown harness/probe failure fails safe rather than reporting protected evidence.
- [ ] Harness coverage suites exercise short and full route records with identical owner/revision/scenario format and describe only the supported guarded path, without an unrestricted-host adversary guarantee.

- [ ] Only after tasks 004–008 and this task's guard tests pass, ordinary new single/workspace/full/short cycles initialize v1 automatically; a registered cycle-driver fixture proves authoring, PLAN, execution observations and actual egress complete. Existing legacy cycles still resume, and removing v1 metadata cannot select legacy.
- [ ] feature-write.test.sh now rejects missing original-token mutations for every enrolled participant, including resumed legacy cycles; test fixture setup uses explicit create-if-absent/bootstrap APIs, not an operator downgrade switch.

**BlockedBy:** [task-008]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: extend actual adapter/guard invocation fixtures before guard changes.
- [ ] Step 2: Apply the shared-boundary pattern from PATTERNS lib/feature_read.py:60-93 to harness capability dispatch; route any harness-specific capability through lib/harness.sh with deterministic answer/reason for all four peers.
- [ ] Step 3: Extend existing guards instead of relying on regex presence; protect exact driver-owned paths for v1/full as well as oneshot, retain legitimate staged maker writes, and document operational guard prerequisites; run green.

- [ ] Step 10: Activate default v1 and strict enrolled-participant token enforcement as the last change in this task, after all producer/consumer/adapter integration fixtures pass. Remove temporary fixture opt-in activation plumbing from normal initialization and test that no shipped new-cycle legacy selector exists.

### task-010: Provide deterministic read-only migration previews

**Goal:** Generate inspectable conversion candidates and source digests without touching repository state.

**Files:**
- lib/requirements_migrate.py
- lib/requirements-migrate.sh
- tests/lib/requirements-migrate.test.sh
- tests/run-all.sh
- docs/loop-spec/requirements-migration.md

**read_first:**
- lib/requirements.py
- lib/artifact_publication.py
- lib/spec_intent.py
- lib/decisions.sh
- tests/lib/decisions.test.sh
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

**Interfaces:**
- consumes: task-009
- produces: Canonical preview JSON, approved digest and candidate validation for transaction apply.

**Verify:** `rtk bash tests/lib/requirements-migrate.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] requirements-migrate.test.sh runs preview twice and compares identical JSON/digest while all repository and feature-state bytes remain unchanged.
- [ ] Preview fixtures allocate IDs by original order, preserve Goal/Boundary bytes and approval, derive scenarios only from explicit examples and report ambiguous criteria/task relationships by file/line without invented commands or evidence.
- [ ] Preview rejects completed cycles, unsupported shapes, oversized artifacts and unsupported participants before any write; old VERIFICATION remains historical and candidate requires fresh observations.

**BlockedBy:** [task-009]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: create incomplete/complete/ambiguous legacy fixtures and run red.
- [ ] Step 2: Use PATTERNS lib/spec_intent.py:12-42 to prove immutable approval, and acknowledge PATTERNS lib/decisions.sh:109-120 is only a command-shape analog, not safe migration logic. Use parser/coverage APIs for candidate validation.
- [ ] Step 3: Implement preview/status and define exact journal/receipt schema for apply/resume/rollback; stream source hashing, include all relevant state and participant identity in digest, document commands/failure behavior and register suite; run green.

### task-011: Publish, resume and roll back migration safely

**Goal:** Apply only approved current previews and make every publication boundary recoverable.

**Files:**
- lib/requirements_migrate.py
- lib/requirements-migrate.sh
- lib/artifact_publication.py
- tests/lib/requirements-migrate.test.sh
- tests/lib/artifact-publication.test.sh
- tests/lib/phase-exit.test.sh
- tests/lib/supervisor-store.test.sh
- docs/loop-spec/requirements-migration.md

**read_first:**
- lib/requirements_migrate.py
- lib/artifact_publication.py
- lib/feature_write.py
- lib/supervisor/store-mirror.sh
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

**Interfaces:**
- consumes: task-010
- produces: Explicit recoverable migration available only to generation-aware guarded participants.

**Verify:** `rtk bash tests/lib/requirements-migrate.test.sh && rtk bash tests/lib/artifact-publication.test.sh && rtk bash tests/lib/phase-exit.test.sh && rtk bash tests/lib/supervisor-store.test.sh` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] Migration tests reject changed source inputs or preview digest, simultaneous apply and completed-cycle apply without replacing artifacts; originals and approval hashes are preserved byte-for-byte in immutable generation storage.
- [ ] Failure injection after backup persistence, marker persistence, each SPEC/PLAN replacement, state publication and receipt persistence proves status/resume finishes or restores the same transaction without reallocated IDs; replay is idempotent.
- [ ] A legacy reader started before the marker cannot publish/acknowledge after migration; ordinary state-update concurrency completes without deadlock and unfinished migration blocks cycle entry/exit/verification/delivery.
- [ ] Rollback restores originals only when current migrated files still equal recorded published hashes, refuses later edits with actionable conflicts, preserves journal/history, increments generation and survives durable store reopen.

**BlockedBy:** [task-010]

**Steps (TDD where applicable):**
- [ ] Step 1: TDD: implement deterministic barriers/failure injection for every boundary before apply logic.
- [ ] Step 2: Reuse PATTERNS lib/feature_write.py:24-43 through artifact_publication.py, never recursively invoke feature-write while locked. Under publication-first/state-second lock recheck digest, preserve originals durably, persist marker, replace artifacts, then publish versioned state and completed receipt last.
- [ ] Step 3: Resume/rollback inspect journal plus expected hashes, never fabricate historical observations or alter specApproval; persist journal/backups with feature state and update recovery docs in this diff; run green.

### task-012: Verify the complete release and declare 7.0.0 readiness

**Goal:** Pass all registered offline gates and publish accurate local readiness documentation before the synchronized version bump.

**Files:**
- CHANGELOG.md
- README.md
- docs/loop-spec/reliability.md
- docs/loop-spec/7.x-roadmap.md
- docs/loop-spec/requirements-format.md
- docs/loop-spec/requirements-migration.md
- .claude-plugin/plugin.json
- .claude-plugin/marketplace.json
- .codex-plugin/plugin.json
- tests/release-7-0-coverage.test.sh
- tests/run-all.sh

**read_first:**
- lib/bump-version.sh
- tests/run-all.sh
- tests/README.md
- docs/loop-spec/reliability.md
- docs/loop-spec/7.x-roadmap.md
- CHANGELOG.md
- README.md
- docs/loop-spec/features/release-7-0/SPEC.md (Design decisions)
- docs/loop-spec/features/release-7-0/PLAN.md (System design)

**Interfaces:**
- consumes: task-011
- produces: Locally verified 7.0.0 readiness, documentation and synchronized declarations.

**Verify:** `rtk bash tests/run-all.sh && rtk bash lib/bump-version.sh --check` -> exit 0; named offline suites pass.

**Acceptance criteria:**
- [ ] tests/run-all.sh passes every registered suite including new parsing, publication, input, observation, migration and release-coverage suites; no live eval is invoked.
- [ ] release-7-0-coverage.test.sh exercises the four-harness/full-short contract wiring and fails if any new helper suite is unregistered; required source probes report no unresolved blocking finding.
- [ ] After the pre-bump suite passes, bump-version.sh 7.0.0 updates all three manifests and README together; bump-version.sh --check exits 0 and all declarations read 7.0.0.
- [ ] Operator docs contain runnable preview/apply/status/resume/rollback commands, prerequisites, success/failure examples, 7.x legacy window, clean-source and declared-input limits; changelog makes no unmeasured latency/cost claim.

**BlockedBy:** [task-011]

**Steps (TDD where applicable):**
- [ ] Step 1: Add registered release coverage regression first, run red, and complete only wiring missing from this task scope; implementation failures go back to their owning task before readiness.
- [ ] Step 2: Use PATTERNS observed-execution tests and intent-preservation tests as final contract anchors. Run the full offline suite before version mutation, and all required scans below over touched source/doc files; resolve blocking findings.
- [ ] Step 3: Update operator docs/release notes/roadmap status, run bash lib/bump-version.sh 7.0.0 only when implementation is ready, then rerun the exact Verify command. Do not merge, publish, or run live evals. Follow the existing per-task commit contract.

## Spec coverage

Each Good Enough statement below is copied verbatim from SPEC; these mappings explain this legacy-format implementation plan and do not substitute for future v1 task-block references.

- [ ] GE-001: New-format requirements retain their IDs when reordered; edits to behavior or acceptance scenarios change their revision, and duplicate, malformed, reused retired, or unknown IDs fail with an actionable diagnostic.
  - Tasks: task-001, task-002, task-004.

- [ ] GE-002: Every required outcome has explicit observable acceptance scenarios or an equivalent executable example; missing scenario coverage is detected, while stretch goals remain distinct from required outcomes.
  - Tasks: task-001, task-004, task-005.

- [ ] GE-003: PLAN egress rejects criterion text copied only into notes, mappings to nonexistent tasks, missing mappings, and mismatches with the dispatch plan; valid many-to-many mappings, multiline criteria, and supported infrastructure tasks pass.
  - Tasks: task-005.

- [ ] GE-004: New-format verification binds each required scenario to its requirement revision and observed execution record, including command, result, and examined code state; fabricated PASS text, unknown scenario IDs, missing observations, and changed requirements or code cannot satisfy the evidence gate.
  - Tasks: task-006, task-007, task-008, task-009.

- [ ] GE-005: Short and full routes use the same requirement identities and revision checks; VERIFY shape checks and ITERATE convergence exercise the new contract without accepting numeric positional aliases as new-format identities.
  - Tasks: task-004, task-008.

- [ ] GE-006: Completed legacy artifacts and approval records remain byte-for-byte unchanged; incomplete legacy cycles can finish under their original contract during the 7.x compatibility window, and unsupported or malformed new versions fail explicitly.
  - Tasks: task-002, task-004, task-008, task-010, task-011.

- [ ] GE-007: Migration provides a deterministic read-only preview, checks that approved source inputs still match before applying, stops on ambiguous mappings, preserves originals, resumes interrupted publication safely, is idempotent on replay, and supports rollback without manufacturing historical execution evidence.
  - Tasks: task-003, task-004, task-010, task-011.

- [ ] GE-008: All four harness contracts consume the same artifact format and gates; new typed state fields, if needed, are declared and validated rather than stored as untyped extensions.
  - Tasks: task-002, task-004, task-009.

- [ ] GE-009: Registered offline regressions exercise parsing, actual phase egress, stale evidence, legacy compatibility, migration interruption, and rollback; the complete offline gate passes and required source probes have no unresolved blocking findings.
  - Tasks: task-001, task-002, task-003, task-004, task-005, task-006, task-007, task-008, task-009, task-010, task-011, task-012.

- [ ] GE-010: Version declarations consistently identify 7.0.0 when implementation is ready, and release notes plus operator documentation explain the new format, migration, compatibility window, limitations, and recovery commands without claiming unmeasured cost or latency savings.
  - Tasks: task-012.

## Test strategy

Through task-008, existing ordinary full/short cycle fixtures must still run using the pre-release format; v1 integration fixtures opt into internal contracts only. Task-009 activates v1 by default after all consumers and guards are present. Each code task writes behavioral regressions before implementation and runs its exact Verify command red then green. Tests use temporary repositories, injected commands and local offline fixtures; migration concurrency uses barriers, not timing guesses. Newly created helpers are registered in tests/run-all.sh in the same task. Existing consumer tests stay registered and retain legacy fixtures. The final task runs the complete offline suite before and after readiness/version changes; no evals/run.sh or model/provider call is authorized.

For each task's touched lib/hooks/skills/extensions/tests files, run `rtk bash lib/indirection-scan.sh scan` and `rtk bash lib/duplication-scan.sh scan` with that task's concrete Files paths as arguments; likewise `rtk bash lib/house-style.sh compare`, `rtk bash lib/comment-tells.sh scan`, and `rtk bash lib/failure-tells.sh scan`. For each touched shipped Markdown file run `rtk bash lib/doc-tells.sh scan` with those paths. These command prefixes are followed by the task's actual paths, not literal placeholders. Findings must be fixed or explicitly adjudicated as non-blocking with evidence before task completion. Final release coverage tests register all new helpers and verify wiring; they do not stand in for behavioral suites.

## Rollback plan

Before execution preserve the original checkout state and run through the immutable pinned runtime. If a task fails, keep release declarations at their pre-release value and repair/revert only that task's edits; do not reset unrelated user work. If integrated VERIFY fails, reopen the owning task with its failing fixture and rerun dependents that consume its contract. No migration is automatic. An operator who applied a preview uses the documented status/resume/rollback command and transaction ID; never manually overwrite a changed migrated artifact or restore an old generation counter. Preserved originals and approval remain available in durable state, and legacy verification remains historical output. Implementation itself performs no release merge/publication.

## Grounding

- EVID-001: The dangling task and notes-only coverage reproduction motivates task-005, not a claim of a complete-cycle bypass.
- EVID-002: Independent positional consumers require shared inventory integration in tasks 001, 004, 005 and 008.
- EVID-003: Immutable approved intent is preserved through producer and migration tests.
- EVID-004: Feature schema remains 7; separate artifact contract fields receive explicit nested validation.
- EVID-005: Four baseline suites were passing before implementation; task-012 still requires the entire offline suite.
- EVID-006: The existing driver executes commands; task-007 extends that producer rather than accepting caller-authored PASS.
- EVID-007: Existing fsync/replace handles a single file; tasks 003 and 011 provide the additional multi-file journal/generation protocol.
