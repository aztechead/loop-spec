# Address real-run audit findings in PR 94 - Implementation Plan

For maintainers implementing and verifying the audit fixes without changing approved intent.

**Spec:** `docs/loop-spec/features/fastapi-audit-fixes/SPEC.md`
**Created:** 2026-09-10

## Architecture overview

Extend the existing review-route probe and task intake, and correct mode fallback at the shared terminal writer. PATTERNS identifies the durable publisher at lib/feature_write.py:24-42; reuse that primitive and publish tasks before acknowledging the pending snapshot. A new queue service or a two-file transaction framework would add state and recovery machinery; the existing queue, atomic replacement, and replay identity can meet the same criteria with a smaller change.

The likely next change is another remediation producer. Keep normalization, retry identity, and acknowledgment in the intake boundary, with feature and sidecar paths supplied as arguments. Keep result-mode precedence in the result writer so a new early-exit caller inherits it.

## User decisions (already made)

- **Use detected project commands?** → yes — autonomous run trusts detection; LOOP_SPEC_CMD_* still wins
- **Should autonomous runs bypass approved Goal and Boundary checks to repair implementation wording?** → No; preserve the immutable approval and distinguish outcomes from implementation choices before approval. — The supplied audit explicitly identifies this as intended safety behavior; fix the execution and telemetry bugs without weakening it.
- **How should the existing request be carried through unattended implementation?** → Proceed within the supplied audit scope using autonomous approval; do not label inferred decisions human approval. — The user explicitly requests fixing the findings and updating PR 94; no additional product choice is needed.
- **Prose review suggests removing the audience preface as outside the template.** → Keep the single audience line. — The repository human-docs contract asks each document to name its reader; the line serves that requirement without duplicating acceptance criteria.

These decisions are copied from SPEC's recorded autonomous decisions. They remain binding; none is labeled human approval.

## System design

- Architecture: existing graph selects recovery; EXECUTE owns intake and dispatch; result writer owns terminal telemetry.
- Component structure: a named stdlib Python intake module owns normalization and durable publication; the Bash launcher supplies paths. Reuse existing state reader/writer interfaces.
- Data flows: VERIFY queue -> atomic task-sidecar publication -> acknowledgment of only the published queue snapshot -> dispatch -> published task evidence -> exit.
- API design: preserve graph probe answers, prepare JSON, task shape, and result flags; add the remediation route answer to the existing probe contract.
- Database schema: none; existing JSON queue and sidecar remain the stores. Any private replay evidence stays with intake state, without a new store.
- Interface architecture: existing phase and terminal interfaces report failures and recovery; no new UI.
- Caching strategy: none; read durable state at routing, intake, and exit boundaries.
- Scale bound: intake uses O(P+T) task records and indexed ID lookup for P pending and T sidecar tasks; no per-task subprocesses or unbounded retry loop. Existing dispatch conflict analysis is unchanged.

## Global constraints

- Never weaken approved Goal/Boundary checks, alter approval records to hide drift, or bypass the plugin repository dependency restriction.
- Never discard remediation on intake failure, claim queued work was executed, or describe offline checks as proof of live delivery.
- Use existing graph, task, and result interfaces with the shipped Bash/jq/Python dependencies.
- **When you would add a package.json, requirements.txt, or brew formula to shipped code**, don't. Runtime is `bash >= 3.2`, `git`, `jq >= 1.5`, and `python3 >= 3.7` (Alpine/distroless: `apk add jq python3`). Shipped code is markdown, Bash, jq, and Python. Keep substantial Python in named `.py` modules; shell launchers own only argument and path setup. If the work cannot be expressed in those, put it in the matching exception directory and stop: `extensions/opencode/loop-spec.ts` imports node builtins ONLY (no npm/bun; `tests/opencode-plugin.test.sh`). `extensions/adk/loop_spec_adk/*.py` may import `google-adk>=2.7,<3` on Python >=3.10 — the only third-party import in the tree — and `lib/adk-install.sh` wires it into a user's project rather than generating a copy (`tests/adk-harness-coverage.test.sh`, `tests/adk-extension.test.sh`). `extensions/sessions/session_run.py` is stdlib-only Python >=3.11 (`tomllib`); `lib/harness.sh session-layer` answers `in-harness` below that, so the base floor does not move (`tests/sessions-extension.test.sh`). `examples/` holds reference consumers nothing in the plugin imports; one may import the SDK it demonstrates (`examples/supervisor/supervisor.py` imports `claude-agent-sdk`) and says in its README that it is not a supported surface.
- **When you would run `evals/run.sh`, or any `claude -p` that drives the plugin end to end**, don't unless the user asked for a live eval in this session. It spends real money per task. `tests/run-all.sh` never registers it. Records land in `evals/results/`, which is ignored, and findings documents stay out of the tree. Read `evals/README.md` before proposing a run.
- **When a hook blocks the commit**, fix the finding or extend the hook with a test in the same change. Do not pass `--no-verify`.

## File map

- Create: `lib/execute_remediation.py` - bounded normalization, publication, and retry bookkeeping invoked by execute-prepare.
- Modify: `graph/cycle.graph.json`, `lib/graph/probes/review-route.sh` - queued-remediation recovery before ordinary VERIFY successors.
- Modify: `lib/execute-prepare.sh`, `lib/execute-exit-gate.sh` - fail-closed intake and exit.
- Modify: `lib/feature_write.py`, `lib/feature-write.sh` - minimal locked snapshot acknowledgment through the existing writer, if required to preserve concurrent appends.
- Create: `tests/fixtures/remediation-marker.py.txt` - negative-test input copied into a temporary repository.
- Modify: `tests/lib/execute-prepare.test.sh`, `tests/lib/graph-run.test.sh`, `tests/lib/phase-exit.test.sh`, `tests/lib/feature-write.test.sh`, `tests/graph-conformance.test.sh` - routing, bounded recovery, publication failure, replay, and acknowledgment evidence.
- Modify: `skills/verify/SKILL.md` - operator guidance for remediation recovery.
- Modify: `lib/cycle-result.sh`, `tests/lib/cycle-result.test.sh` - early terminal mode preservation.
- Modify: `.gitignore`, `lib/runtime-ignore.sh`, `tests/lib/runtime-ignore.test.sh` - explicit launcher and session ignores with visibility controls.
- Modify: `skills/spec/SKILL.md`, `skills/shared/autonomous-mode.md`, `skills/execute/SKILL.md` - outcome wording, immutable intent, and queue intake failure guidance.

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | Preserve and execute VERIFY remediation | - | graph, intake, exit, shared writer, regression tests, VERIFY guidance | medium |
| task-002 | Preserve mode on early terminal results | - | result writer and tests | small |
| task-003 | Ignore runtime artifacts and clarify frozen intent | - | ignore policy, tests, SPEC and autonomous guidance | small |

## Tasks

### task-001: Preserve and execute VERIFY remediation

**Goal:** Route queued fixes back to EXECUTE and retain them until durable registration, including retry and repeated findings.

**Files:**
- graph/cycle.graph.json
- lib/graph/probes/review-route.sh
- lib/execute-prepare.sh
- lib/execute_remediation.py
- lib/execute-exit-gate.sh
- lib/feature_write.py
- lib/feature-write.sh
- tests/lib/execute-prepare.test.sh
- tests/fixtures/remediation-marker.py.txt
- tests/lib/graph-run.test.sh
- tests/graph-conformance.test.sh
- tests/lib/phase-exit.test.sh
- tests/lib/feature-write.test.sh
- skills/verify/SKILL.md

**read_first:**
- docs/loop-spec/features/fastapi-audit-fixes/PATTERNS.md
- lib/graph/probes/review-route.sh:4-15
- graph/cycle.graph.json:971-982
- lib/graph/validate.py:481-523
- lib/graph/engine.py:203-214
- tests/graph-conformance.test.sh:120-137
- lib/execute-prepare.sh:63-103
- lib/feature_write.py:24-42
- lib/feature_write.py:69-117
- lib/feature-read.sh
- lib/feature-write.sh
- lib/verify-gate.sh:88-108
- lib/verify-prepare.sh:79-87
- lib/task-progress.sh:43-98
- lib/execute-exit-gate.sh:25-36
- tests/lib/execute-prepare.test.sh
- tests/lib/graph-run.test.sh
- tests/graph-conformance.test.sh
- tests/lib/phase-exit.test.sh
- tests/lib/feature-write.test.sh
- skills/verify/SKILL.md:118-126

**Interfaces:**
- consumes: existing pendingRemediationTasks array, artifacts.tasks path, commands.test fallback, feature reader/writer and task sidecar; existing review=bad-spec routing retains priority.
- produces: review=remediate route, durable dispatchable tasks, and visible intake/exit failure through existing JSON/FLAG and nonzero status contracts.

**Verify:** `rtk proxy bash lib/graph/validate.sh --strict graph/cycle.graph.json && rtk proxy bash tests/graph-conformance.test.sh && rtk proxy bash tests/lib/execute-prepare.test.sh && rtk proxy bash tests/lib/graph-run.test.sh && rtk proxy bash tests/lib/phase-exit.test.sh && rtk proxy bash tests/lib/feature-write.test.sh && rtk proxy bash tests/lib/phase-bundles.test.sh && rtk proxy bash tests/lib/verify-prepare.test.sh` -> every suite exits 0.

**Acceptance criteria:**
- [ ] rtk proxy bash lib/graph/validate.sh --strict graph/cycle.graph.json and tests/graph-conformance.test.sh exit 0; conformance checks an actual verify-to-execute remediation route and an exact verify-to-execute loop with ceiling 5 and strategy contain, rather than accepting an iterate-to-execute route.
- [ ] tests/lib/graph-run.test.sh exits 0: at five persisted verify-to-execute traversals, the next matching route exits 5 with loop-ceiling-exhausted, keeps pendingRemediationTasks unchanged, and does not advance to ITERATE or DELIVER.
- [ ] tests/lib/graph-run.test.sh exits 0: two tasks produced by real VERIFY failure intake reach EXECUTE before ITERATE through the actual VERIFY resume boundary, and bad-spec still routes to DISCUSS first.
- [ ] tests/lib/execute-prepare.test.sh exits 0: both queued tasks appear in dispatch, missing verifyCommand uses commands.test when present, and absent verification or invalid task shape returns exit 1 with an actionable diagnostic and unchanged pending work.
- [ ] tests/lib/execute-prepare.test.sh exits 0: failed publication preserves old readable sidecar and pending work; failed acknowledgment never reports ready; replay after sidecar publication before acknowledgment adds zero duplicates and retains task progress.
- [ ] tests/lib/execute-prepare.test.sh exits 0: a new queued recurrence of a completed fallback ID becomes executable again; an ID collision with different work cannot silently discard either task; a concurrent append survives acknowledgment.
- [ ] tests/lib/phase-exit.test.sh exits 0: pending remediation, invalid queue, unreadable sidecar, and malformed sidecar each block EXECUTE exit; empty queue plus all published tasks exits 0.
- [ ] tests/lib/feature-write.test.sh exits 0, including existing immutable specApproval and persistence-failure behavior; writer changes do not replace unrelated state.

**BlockedBy:** []

**Steps (TDD where applicable):**

- [ ] Step 1: Add failing cases to the named suites. Use PATTERNS analogs tests/lib/execute-prepare.test.sh:60-73 and tests/lib/graph-run.test.sh:1017-1030, with fresh feature fixtures at each graph resume. Queue two real review findings through verify-gate, then prove route and dispatch, not merely probe text. Capture red output before implementation.
- [ ] Step 2: Extend lib/graph/probes/review-route.sh:4-15 and the real VERIFY route in graph/cycle.graph.json:971-982. Declare the matching exact verify-to-execute loop edge with ceiling 5 and strategy contain, following the existing verify-to-discuss recovery loop. Five recovery traversals retain the existing VERIFY recovery budget; a separate larger retry policy is outside this repair. lib/graph/validate.py:481-523 requires that exact pair. Keep bad-spec priority and ordinary empty-queue progress; malformed or unreadable queue must fail visibly instead of looking empty. Preserve oneshot and review-continue callers. Extend tests/graph-conformance.test.sh:120-137 to check the actual VERIFY route, loop pair, ceiling, and strategy. Use lib/graph/engine.py:203-214 and 799-813 as the exhaustion contract: repeated resumes consume the durable bound, then exit 5 with loop-ceiling-exhausted, retaining the queue and blocking onward execution. Prove strict validation and real-resume exhaustion in the named suites; do not add a second retry counter or clear work at the limit.
- [ ] Step 3: Move substantial intake Python into lib/execute_remediation.py. Supply feature/sidecar paths and existing collaborators through arguments; follow neighboring Python naming and exception style. Reuse lib/feature_write.py:24-42 for atomic sidecar publication. Validate the whole intake batch before writing; do not coerce bad input into an empty queue or use registration failure as count zero.
- [ ] Step 4: Publish the sidecar before acknowledging only the exact queue snapshot. Use the existing locked writer boundary at lib/feature_write.py:69-117 for acknowledgment if needed; preserve store adapter persistence and immutable approval checks. Do not hold a writer lock while recursively invoking that writer. Preserve tasks appended after the intake snapshot. Retry must recognize a published snapshot without resetting already recorded progress; a newly enqueued completed fallback ID must reopen/update work or receive an attempt identity, not disappear. Prove both cases independently with injected publication/acknowledgment failures and the real repeated IDs from verify-gate and verify-prepare.
- [ ] Step 5: Extend lib/execute-exit-gate.sh:25-36 to read pending work and propagate reader failures. A failed task-progress pipeline cannot count as an empty remaining set. Follow sibling callers from task-progress and gate routing; exercise same-cause cases in the assigned regression files.
- [ ] Step 6: Update the existing VERIFY guidance for operators: accepted remediation returns to EXECUTE; invalid intake must be repaired before advancing. Keep hard intent checks. Scale: O(P+T) intake records and memory, dictionary/set lookups for IDs, bounded whole-batch publication; no new service, dependency, or retry daemon.
- [ ] Step 7: Exercise the named intake module through the already registered execute-prepare suite; no unregistered standalone test is sufficient. Run the Verify command for green evidence and required code/doc probes on changed files. Commit this coherent routing/intake/exit fix.

### task-002: Preserve mode on early terminal results

**Goal:** Record autonomous mode correctly when no feature exists, while honoring an explicit false override.

**Files:**
- lib/cycle-result.sh
- tests/lib/cycle-result.test.sh

**read_first:**
- docs/loop-spec/features/fastapi-audit-fixes/PATTERNS.md
- docs/loop-spec/features/fastapi-audit-fixes/EVIDENCE.md
- lib/cycle-result.sh:299-326
- lib/cycle-result.sh:360-386
- lib/cycle-result.sh:550-587
- lib/cycle-result.sh:916
- tests/lib/cycle-result.test.sh:495-509
- lib/cycle-driver.sh
- lib/cycle-reconcile.sh

**Interfaces:**
- consumes: --autonomous true|false, feature/active-run boolean when available, and LOOP_SPEC_AUTONOMOUS=1 for missing mode context.
- produces: existing terminal result autonomous boolean; no schema change.

**Verify:** `rtk proxy bash tests/lib/cycle-result.test.sh && rtk proxy bash tests/lib/cycle-driver.test.sh && rtk proxy bash tests/terminal-result-coverage.test.sh` -> every suite exits 0.

**Acceptance criteria:**
- [ ] tests/lib/cycle-result.test.sh exits 0: the EVID-001 no-feature early refusal writes autonomous=true under LOOP_SPEC_AUTONOMOUS=1, and the explicit --autonomous false case writes false in the same environment.
- [ ] tests/lib/cycle-result.test.sh exits 0: absent mode context defaults false, explicit true remains true, and stored false remains false without jq fallback treating it as missing.
- [ ] tests/lib/cycle-driver.test.sh and tests/terminal-result-coverage.test.sh exit 0; terminal publication failures, result aliases, and reconciliation retain their existing outcomes.

**BlockedBy:** []

**Steps (TDD where applicable):**

- [ ] Step 1: Extend the existing terminal fixtures using PATTERNS lib/cycle-result.sh:299-326 and tests/lib/cycle-result.test.sh:495-509. Reproduce EVID-001 directly with no feature, then add explicit true/false, missing environment, active-run mode, and feature-mode cases. Run the result suite and record red evidence.
- [ ] Step 2: Track explicit flag presence in the shared terminal writer. Use explicit argument first, then a valid stored mode where that entrypoint already has run context, then environment fallback, then false. Distinguish boolean false from missing; preserve normalization for invalid flags. Inspect feature-based write and aliases for the same fallback mechanism and cover applicable siblings in this file.
- [ ] Step 3: Follow driver decline and reconciler callers; the driver already passes environment mode, so keep the root correction in the shared writer. Match neighboring Bash and jq style. Update the existing usage/header only if its described behavior becomes false; no separate operator guide is needed. Scale: none (fixed-size mode inputs).
- [ ] Step 4: Run the Verify command for green evidence and required code probes; commit the metadata fix.

### task-003: Ignore runtime artifacts and clarify frozen intent

**Goal:** Keep launcher artifacts out of status and prevent avoidable implementation choices from entering approved outcome intent.

**Files:**
- .gitignore
- lib/runtime-ignore.sh
- tests/lib/runtime-ignore.test.sh
- skills/spec/SKILL.md
- skills/shared/autonomous-mode.md
- skills/execute/SKILL.md

**read_first:**
- docs/loop-spec/features/fastapi-audit-fixes/PATTERNS.md
- .gitignore:20-26
- lib/runtime-ignore.sh
- tests/lib/runtime-ignore.test.sh:61-70
- skills/spec/SKILL.md:125-164
- skills/shared/autonomous-mode.md:111-116
- lib/spec_intent.py:21-42
- tests/lib/spec-intent.test.sh:57-68

**Interfaces:**
- consumes: existing .gitignore and info/exclude policies, approved Goal/Boundary digest contract.
- produces: three explicit runtime ignore paths and pre-approval wording guidance; no approval API or hash change.

**Verify:** `rtk proxy bash tests/lib/runtime-ignore.test.sh && rtk proxy bash tests/lib/spec-intent.test.sh && rtk proxy bash tests/run-unit.sh` -> every suite exits 0.

**Acceptance criteria:**
- [ ] tests/lib/runtime-ignore.test.sh exits 0: a clean temporary repository loading only the root .gitignore ignores .loop-spec/sessions/run/state.json, .loop-spec/launcher-result.json, and .loop-spec/launcher.lock; lib/cycle-result.sh and a .loop-spec source/config fixture remain visible.
- [ ] tests/lib/runtime-ignore.test.sh exits 0: runtime-ignore ensure covers the same three artifacts, remains byte-idempotent, and preserves source visibility.
- [ ] tests/lib/spec-intent.test.sh exits 0: implementation-section edits remain allowed and approved Goal/Boundary edits still fail even under autonomous mode.
- [ ] rtk proxy bash lib/doc-tells.sh scan skills/spec/SKILL.md skills/shared/autonomous-mode.md exits 0; reviewer confirms the SPEC guidance places path-versus-query choices outside frozen outcomes and autonomous guidance sends genuine post-approval intent changes to the human.

**BlockedBy:** []

**Steps (TDD where applicable):**

- [ ] Step 1: Add failing behavior cases to tests/lib/runtime-ignore.test.sh using PATTERNS tests/lib/runtime-ignore.test.sh:61-70. Test root .gitignore in an isolated repository without managed excludes, then the runtime-ignore sibling separately. Run red before changing the runtime helper.
- [ ] Step 2: Add explicit sessions directory, launcher-result.json, and launcher.lock patterns to .gitignore and the existing runtime-ignore pattern array. Follow the neighboring layout and keep source/configuration visible; never ignore the whole .loop-spec tree. Remove stale root ignore negations for feature.json and PROGRESS.md now that runtime state lives on refs/loop-spec/state; preserve source/configuration fixtures. Scale: none (fixed ignore patterns).
- [ ] Step 3: Edit the existing SPEC author guidance for maintainers: state outcomes such as returning all accepted strings in Goals; put a revisable path-versus-query design in an implementation section before approval, unless the user explicitly required that interface. Follow PATTERNS lib/spec_intent.py:37-42 and tests/lib/spec-intent.test.sh:57-68. Explain to autonomous operators that self-answering cannot change already frozen intent or rewrite the approval digest. Update skills/execute/SKILL.md to remove the obsolete instruction that tasks lacking a verify command are omitted; describe retained queue and failed intake. Handle the deterministic remediation-error field before the malformed-sidecar recovery instruction; never rebuild tasks from PLAN to repair an intake failure. Preserve the existing section structure; docs/config changes themselves are exempt from TDD.
- [ ] Step 4: Run Verify, required code probes on the runtime helper/test, and doc-tells on the two guidance files. Existing spec-intent tests supply the safety regression; do not modify the guard. Commit the ignore and guidance fix.

## Spec coverage

- [ ] GE-001: Offline regression proves two VERIFY tasks route to EXECUTE before ITERATE, become dispatchable, and cannot be silently cleared or bypassed on registration failure or exit. -> task-001
- [ ] GE-002: Offline regressions prove early autonomous terminal results and explicit non-autonomous results preserve their correct modes without feature state. -> task-002
- [ ] GE-003: Git ignore checks cover sessions, launcher-result.json, and launcher.lock while source files remain visible. -> task-003
- [ ] GE-004: Guidance separates outcome intent from implementation choices and retains hard failure for post-approval intent edits; existing intent regressions pass. -> task-003
- [ ] GE-005: Full offline suite and required repository probes pass; fixes are committed and pushed to PR 94 with an accurate description and observed check state. -> task-001, task-002, task-003; lead-owned Test strategy and Delivery audit

- Exceptional: Offline transition coverage exercises remediation intake again after interruption without losing or duplicating tasks. -> task-001.

## Test strategy

Run each task's red-to-green regression commands and the registered coupling suites selected by rtk proxy bash tests/run-unit.sh. After integration the lead runs rtk proxy bash tests/run-all.sh from repository root, records its exit code and complete log, and resolves failures before delivery.

Each implementer runs the required indirection-scan, duplication-scan, house-style compare, comment-tells, and failure-tells probes on its changed code files. Run doc-tells on changed markdown. The lead records final diff-scoped probe results during VERIFY and preserves existing baseline findings separately from introduced findings. Dependency scans must remain free of newly introduced third-party runtime dependencies. No stack or version change is planned.

## Delivery audit

GE-005 is a lead-owned VERIFY/DELIVER gate after all three implementation tasks, not another implementation dispatch. Inspect the actual PR 94 head/base and branch before publishing. Commit and push the verified fixes to that PR's branch, update its title/description to describe the final behavior, enumerate observed offline validation, and state that the audited FastAPI application was not delivered and no paid rerun was performed. Read back the PR description, head SHA, remote branch SHA, and required-check state. Delivery requires equal local/remote/PR SHAs and the repository's passed-or-none required-check gate; report pending or failing checks as observed and keep working.

## Verification repair

The full offline run exposed an existing fixture-isolation defect in hooks/team/phase-handoff-guard.test.sh: the current checkout's active cycle outranked the fixture state. Resolve the hook path absolutely and execute it from each fixture project directory. Preserve every assertion and leave the production guard unchanged. The isolated proof passed all 16 checks; rerun the full suite after committing this correction.

## Rollback plan

If VERIFY exposes a defect, fix the owning task and rerun its regressions plus affected coupling tests before delivery. If a committed fix must be withdrawn, revert that task's commit; retain the pending queue and its durable sidecar so recovery remains possible. Never clear pending tasks or rewrite approved intent to make rollback pass. The three tasks have no logical dependencies; file-overlap serialization is left to EXECUTE.

## Implementation notes

- graph/cycle.graph.json:971 - VERIFY currently has a bad-spec route but no queued-remediation route.
- lib/execute-prepare.sh:82 - intake drops tasks without verify commands and clears pending work after registration failure.
- lib/execute-exit-gate.sh:26 - exit checks the sidecar rather than the pending queue.
- lib/cycle-result.sh:916 - feature-based terminal output defaults autonomous to false.
- lib/spec_intent.py:41 - post-approval intent edits fail regardless of mode.
- .gitignore:26 - current telemetry ignores omit launcher and session artifacts.
## Grounding

- EVID-001: Direct write-terminal early refusal with LOOP_SPEC_AUTONOMOUS=1 and no feature wrote autonomous=false; the shared writer requires correction.
- EVID-002: The review-route probe returned review=continue with two pending tasks; queue-aware routing must be added.
- ASSUMPTION: PR 94 remains the authorized update target; its current head and check state will be revalidated before delivery. | verify: rtk proxy gh pr view 94 --json number,headRefName,headRefOid,baseRefName,statusCheckRollup,url
