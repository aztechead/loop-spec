# 6.x reports plan audit

For the implementer and reviewer of `docs/loop-spec/6x-reports-plan.md`: corrections needed before implementation.

References below use `P/` for `skills/loop-spec/program/loop_spec/`, `R/` for `skills/loop-spec/roles/`, and `Plan` for `docs/loop-spec/6x-reports-plan.md`. Tracked files match the stated HEAD. This is a source audit; no live runs or test suite were executed.

## W1 — Repo checks

### 1. Blocking: adding the probe does not deliver it to PLAN

**References:** Plan:20–25; `P/probes.py:1849`; `P/controller.py:438`; `P/defaults.py:51`; `P/revise.py:72`.

**Assumption:** Adding `repoChecks` to `plan_probes` makes `probes.repoChecks` available to the planner.

**Actual:** The controller supplies an empty probes object. The default PLAN implementation merely forwards it. `plan_probes` has no production caller in the Python program. REVISE constructs separate inputs without probes. Consequently, the proposed live expectation cannot hold.

**Fix:** Explicitly collect and pass check facts for each resolved repository, including compact PLAN producers. Include repository identity and the observed source location; a flat `{tool, source}` list cannot distinguish identical filenames in different repositories. Pass the repository map too: `defaults.py:51` currently omits it despite the planner instructions referring to `inputs.repos`.

Keep command selection with the planner; the program should report configuration facts.

### 2. Blocking: the schema changes omit REVISE’s role schema and DEBUG

**References:** Plan:26–33; `P/schemas/plan.json:11`; `R/planner/schema.json:11`; `P/schemas/revise.json:73`; `R/reviser/schema.json:73`; `P/schemas/debug.json:121`; `R/debugger/schema.json:121`; `P/defaults.py:68`; `P/revise.py:88`; `P/roles.py:63`; `P/controller.py:667`.

**Assumption:** Updating whichever PLAN schema validates the product, plus `schemas/revise.json`, covers PLAN production.

**Actual:** All those product objects reject additional properties. Default PLAN issues the program schema; REVISE issues the role schema. DEBUG also emits a compact PLAN, which subsequently passes through normal PLAN acceptance. Leaving DEBUG unchanged either prevents it emitting `checks` or makes its compact PLAN fail the newly required field.

**Fix:** Update both program and role schemas for planner, reviser, and debugger, along with their prompts/examples. Specify the nested check schema, including required `repo` and `command`, nonempty strings, and `additionalProperties: false`. Preserve these contracts for bound roles.

### 3. Blocking: old accepted products and pending submissions need an upgrade policy

**References:** Plan:26; `P/state.py:59`; `P/postconditions.py:39`; `P/controller.py:570`; `P/controller.py:688`; `P/defaults.py:29`.

**Assumption:** Making `checks` required is sufficient; W2’s deserialization default handles older state.

**Actual:** State loading does not migrate products. Old accepted plans, pending planner results, and compact plans lack `checks`. Adding `checks: []` changes `plan_revision`, because the hash includes every field except `inputsDigest` and `boundTo`. That can invalidate baseline identities, critic decisions, and downstream bindings.

**Fix:** Specify compatibility explicitly. A simpler approach is to preserve legacy accepted products and hashes, interpret missing checks as legacy coverage, and require the new field on newly issued plans. Alternatively, implement a controller-owned migration/replanning path that invalidates affected evidence and bindings together. Do not silently mutate an accepted product while retaining its old revision.

The plan’s assertion that checks participate in hashing is otherwise correct.

### 4. Unknown check repositories can bypass the pre-capture validation gate

**References:** Plan:44–50; `P/postconditions.py:437`; `P/controller.py:847`; `P/controller.py:965`; `P/controller.py:558`; `P/postconditions.py:389`.

**Assumption:** Adding check commands to baseline capture and P3 is enough for workspace correctness.

**Actual:** P6 validates task repositories only. An unknown `checks[].repo` can reach the direct repository lookup during capture. Single-repository normalization also handles tasks only. P4 considers only repositories named by tasks.

**Fix:** Validate check repositories before capture, preferably by extending P6 and its contract text. Define whether checks may name repositories without tasks; then either reject that case or include those repositories in P4’s baseline checks. Decide explicitly whether the single-repository alias normalization applies to checks.

### 5. Check/verify command collisions can make P3 impossible to satisfy

**References:** Plan:44–49; `P/baseline.py:492`; `P/postconditions.py:369`.

**Assumption:** Appending `(command, None, None)` safely adds every check baseline.

**Actual:** Baseline entries are keyed solely by command, and the first occurrence wins. If a feature-added task uses the same command as a repo check, the existing task entry is `no-baseline`. The check then requires `ran`, while the task requires `no-baseline`.

**Fix:** Reject incompatible uses of the same `(repo, command)` during PLAN validation with a clear correction, or introduce separately identified baseline uses. Reordering the commands merely reverses which requirement fails.

### 6. Check-only plan changes and legacy `executeRuns` retain stale evidence

**References:** Plan:49–56; `P/execute.py:249`; `P/execute.py:954`; `P/controller.py:988`; `P/postconditions.py:640`.

**Assumption:** Integration checks plus the fallback for tasks without `executeRuns` cover re-entry.

**Actual:** Task reconciliation compares task snapshots, not top-level checks. Changing only checks leaves completed tasks untouched. The fallback skips any task that already has an execution record, including old records without checks. Current E7 examines only a stored comparison verdict.

**Fix:** Bind check evidence to repository, command, candidate SHA, and baseline/plan identity. Fill missing evidence even when a task’s verify record exists, and invalidate/recompare evidence when relevant inputs change. E7 should require the current expected check set and matching evidence identities, not simply a favorable stored verdict.

Keep task adoption separate from check validity: an unchanged adopted task need not be reimplemented merely to run newly required checks.

### 7. Close-outs are expressly excluded, despite the stated every-integration goal

**References:** Plan:16–18, 49–56; `P/execute.py:1317`; `P/postconditions.py:645`; `P/controller.py:990`; `skills/loop-spec/program/tests/test_execute.py:994`.

**Assumption:** Non-close-out integration checks satisfy the goal.

**Actual:** Close-outs can commit source changes but bypass task verification. The fallback skips them because they are absent from PLAN tasks. E7 explicitly exempts them. A close-out can therefore introduce a repo-check regression after ordinary tasks passed.

**Fix:** Separate repo checks from task verify commands. Run repo checks for committing close-outs and enforce that evidence in E7, while preserving their exemption from a nonexistent task verify command. Update the contract’s exemption wording and the existing close-out test.

### 8. Task-head checks do not prove the integrated merge is clean

**References:** Plan:16, 52; `P/execute.py:1331`; `P/execute.py:1350`; `P/execute.py:1384`; `P/controller.py:988`.

**Assumption:** Checking `run_cwd/task_head` detects integration regressions.

**Actual:** Divergent same-wave tasks are subsequently merged into a new commit. Neither task-head check covers the combined tree, and existing execution records suppress the fallback.

**Fix:** Retain early task feedback, but also check the resulting combined candidate or final integrated head. Define how a failure is attributed and remediated through the existing controller route. Share one deterministic check-execution helper rather than maintaining inconsistent integration and fallback implementations.

### 9. Diagnostics support needs a narrower, explicit contract

**References:** Plan:34–43; `P/baseline.py:103`; `P/baseline.py:410`; `P/baseline.py:575`; `P/baseline.py:602`; `P/controller.py:795`.

**Assumption:** Tool-name detection plus generic line parsing covers the listed commands.

**Actual/missing:**

- Detection is based on argv tokens. A package script such as `npm run lint` does not identify its underlying tool.
- Parser registration in `PARSERS` is necessary because `run_command` indexes it directly.
- A diagnostics runner with permanently zero `tests_ran` changes the behavior of any feature-added verify command classified that way: even exit zero fails the meaningful-success check.
- The critic receives task baseline facts only, so it cannot judge check baselines or their incomplete-parser status.

**Fix:** Define supported command/output forms and wrapper behavior. Normalize diagnostic paths relative to each execution root before comparing different worktrees. Register parser and count behavior together. Decide explicitly whether diagnostics are allowed as feature-added verification. Supply check baseline facts to the critic.

A smaller initial set of tested output formats, with fingerprint fallback for other commands, is simpler than claiming broad support without fixtures.

## W2 — Retry failure details

### 1. The proposed router signature cannot access the diagnostic map

**References:** Plan:70–75; `P/execute.py:189`; `P/execute.py:1336`; `P/baseline.py:558`.

**Assumption:** Adding `command` lets `_route_verify_comparison` show fingerprint lines.

**Actual:** The router receives execution/task state and a `Comparison`. None contains the proposed `CommandRun.fingerprint_lines`.

**Fix:** Pass the candidate `CommandRun`, or pass a prepared diagnostic list. Serialize the map consistently in `to_dict`/`from_dict`, give newly added dataclass fields a compatible default, and retain readable fallback behavior for old records.

### 2. Important failures have no `new_identities`

**References:** Plan:74–75; `P/baseline.py:595`; `P/baseline.py:602`; `P/baseline.py:624`; `P/baseline.py:638`.

**Assumption:** Listing new identities supplies the failure details.

**Actual:** Must-flip failures, feature-added nonzero exits, and incomplete candidate runs can all return empty identity lists. They would still produce the generic reasons this work item aims to improve.

**Fix:** When identities are absent, include bounded candidate failure lines or an error/log reference. Derive display lines and hashes from the same normalization helper; hash the full normalized line before truncating display text. Report omitted entries when the 50-entry cap hides requested hashes.

## W3 — Count normalization and upgrade resume

### 1. The version guard misses an earlier fingerprint comparison

**References:** Plan:84–87; `P/baseline.py:624`; `P/baseline.py:645`.

**Assumption:** Guarding the final fallback branch prevents incomparable hashes from being compared.

**Actual:** The incomplete-run branch compares fingerprints first, including for recognized runners. Version-mismatched runs can therefore be compared before reaching the proposed guard.

**Fix:** Apply version compatibility checks wherever fingerprints determine a verdict. Preserve the independent must-flip and feature-added semantics where no fingerprint comparison is needed.

### 2. “Re-capture baseline” has no guaranteed recovery path

**References:** Plan:85–87; `P/controller.py:850`; `P/controller.py:988`; `P/controller.py:1046`; `P/execute.py:197`.

**Assumption:** Returning `baseline-error` leads to a refreshed baseline.

**Actual:** Capture is triggered by a missing baseline or changed plan revision—not normalization version. An unchanged plan can retain v1 indefinitely. Existing EXECUTE and VERIFY caches can also prevent a new v2 run from occurring.

**Fix:** Define version-aware recapture and cache invalidation. Recapture at the original base SHA, refresh affected critic facts, and recompute execution comparisons. Do not require the planner to make an unrelated plan edit merely to force recapture.

### 3. The count rule does not cover every summary shape promised by the docs

**References:** Plan:79–83; `P/baseline.py:145`; `P/baseline.py:172`; `docs/loop-spec/ROADMAP-7.0.md:583`.

**Assumption:** The proposed regex fulfills the summary-banner guarantee.

**Actual:** It handles `9 failed | 690 passed`, but not label-first text such as `FAILED (failures=1, errors=2)` or `Tests: 9 total`. Failure-marked lines remain fingerprint candidates.

**Fix:** State the supported summary forms and test them. Prefer targeted summary normalization to broad numeric replacement that could erase meaningful assertion differences.

## W4 — Self-inflicted regression provenance

### 1. Blocking: the normal failing VERIFY route does not populate fresh reruns

**References:** Plan:94–100; `P/controller.py:607`; `P/controller.py:1021`; `P/verify.py:368`; `P/postconditions.py:83`.

**Assumption:** On implementation-gap rewind, `verifyRuns[c]` contains the current failing run.

**Actual:** `_run_verify_reruns` is called only for a `passed` exit. A normal `implementation gap` may have no record or retain a prior passing record. The proposed trigger therefore cannot reliably identify the current failing files.

**Fix:** Establish program-observed failure evidence before consuming provenance, either during acceptance of relevant failing verdicts or through a dedicated controller-owned collection step. Respect non-repeatable evidence exceptions. Bind observations to the actual attempt, repository, SHA, and command; never treat the model’s claimed identities as program observations.

### 2. `{repo, sha}` is insufficient to establish a comparable prior pass

**References:** Plan:94–96; `P/controller.py:1228`; `P/controller.py:1040`; `P/postconditions.py:755`; `P/controller.py:1127`.

**Assumption:** Any matched record under the criterion ID establishes its latest pass.

**Actual:** Accepted gap products can include passing criteria without fresh reruns. Exceptions skip reruns and may leave older records. Criterion IDs may persist after requirements changes. A recorded match alone does not establish that it belongs to the current claim or approved behavior.

**Fix:** Store requirements revision and evidence identity/provenance with each pass, and verify the current claim against the record before updating history. Exclude exception-only claims from program-observed pass history. Before comparing, require the same repository, applicable requirements, and an ancestor pass SHA. Missing legacy history should disable the hint, not fabricate a pass.

Preserve the existing evidence acceptance rules; command observation is not a substitute for required review attestation.

### 3. Failure identities are not uniformly file paths

**References:** Plan:98–100; `P/baseline.py:48`; `P/baseline.py:71`; `P/baseline.py:89`; `P/repo.py:319`.

**Assumption:** Splitting on `::` or ` > ` extracts the failing file.

**Actual:** Some JS identities are bare test names, Go identities are package/test names, and Cargo identities are symbols. Absolute paths also will not match repository-relative added-file names. `files_added_by` correctly reports paths added anywhere in the range; it does not establish that a remediation commit introduced them.

**Fix:** Use parser-specific path extraction and normalize paths into the named repository. Skip unsupported identity formats. Describe the fact narrowly: “this failing file was added after the recorded pass.” Keep test-versus-implementation judgment with the model.

This scoped implementation is consistent with W4’s proposed ROADMAP correction.

## W5 — Accepted remote extensions

### 1. Preserve the verified identity on both D1 alternatives

**References:** Plan:134–136; `P/postconditions.py:923`.

**Assumption:** Remote equality with `deliveredSha`, or an accepted extension, is sufficient.

**Actual:** Existing D1 also requires `deliveredSha == EXECUTE head`. The proposed replacement does not explicitly preserve that condition. An external product could otherwise select another delivered identity.

**Fix:** Require `deliveredSha == expected EXECUTE head` before either remote-head alternative. Recompute extensions from that verified identity, not a product-selected substitute. Preserve D2’s open-state, head-ref, and base-target checks.

### 2. Schema extension is mandatory; config validation is missing

**References:** Plan:119, 136–139; `P/schemas/deliver.json:45`; `P/contract.py:41`; `README.md:146`.

**Assumption:** Add the product field “if” a schema exists and read the new config key.

**Actual:** The schema exists and delivery rows reject additional properties. Config loading does not validate this new value.

**Fix:** Explicitly update `schemas/deliver.json` with a constrained `acceptedRemote` shape. Validate `acceptRemotePaths` as a list of strings, with absent/empty preserving strict behavior. Document whether patterns apply globally across a workspace and that matching is against repository-relative paths.

### 3. Net diffs do not prove that every accepted commit is disjoint

**References:** Plan:116–125, 129–130.

**Assumption:** Endpoint `diff --name-only` establishes that accepted commits never touch verified paths.

**Actual:** An extension can change a protected path and subsequently restore it; the endpoint diff omits that path. Rename reporting also requires deliberate handling of both source and destination.

**Fix:** Decide which guarantee is intended. For “commits never touch verified paths,” inspect changed paths throughout the extension range, including rename endpoints and defined merge handling. For a weaker final-tree guarantee, say so explicitly in the contract and repair text. Do not report the stronger historical guarantee from endpoint facts.

### 4. Failure and race handling need to be part of the helper contract

**References:** Plan:120–133; `P/repo.py:21`; `P/repo.py:31`; `P/deliver.py:170`; `P/postconditions.py:935`.

**Assumption:** Extension-or-`None` covers remote outcomes.

**Actual/missing:** Network/authentication failure is not branch absence. The remote can also advance between fetch, push, PR observation, and boundary validation. Acceptance based on a later fetched head does not prove that an earlier PR observation named that same head.

**Fix:** Distinguish fetch errors from absence/equality/non-descendance and convert operational failures into per-repository failed rows. Require the fetched extension head to equal the observed PR head. Consider one bounded recheck after a non-fast-forward push; otherwise document that this race requires re-entry.

### 5. Accepted-extension history can disappear after a later failure

**References:** Plan:127–133; `P/deliver.py:85`; `P/deliver.py:99`; `P/deliver.py:178`.

**Assumption:** Recording `acceptedRemote` on the successful row preserves publication facts.

**Actual:** Cumulative publication history currently stores only SHA, PR, and attempt information. A subsequent PR-step or delivery failure can lose the accepted extension’s identity and caveat.

**Fix:** Persist observed extension facts in publication history and carry them into failed rows as historical observations. Revalidate them before treating them as current acceptance. Ensure a push-skipped path records truthful wording rather than claiming it pushed.

### 6. The ROADMAP would still promise exact-head delivery

**References:** Plan:138–139; `docs/loop-spec/ROADMAP-7.0.md:150`; `CLAUDE.md:38`.

**Assumption:** Editing D1/D2 and the config reference covers contract documentation.

**Actual:** The ROADMAP DELIVER row still requires remote head equality with the verified SHA.

**Fix:** Update that row in the same diff, describing the opt-in extension and distinguishing verified SHA from observed remote/PR SHA.

## W6 — Rejected Critical findings in the PR body

### 1. Rendering the section does not update an existing PR

**References:** Plan:143–144; `P/render.py:57`; `P/controller.py:923`; `P/deliver.py:50`; `P/deliver.py:68`.

**Assumption:** Changing `render.pr_body` makes the findings visible in the PR.

**Actual:** The finding fields and rejection reason exist as assumed. However, `_reconcile_pr` supplies the body only when creating a PR. An existing PR is viewed without editing its body. REVISE and delivery re-entry therefore retain the old description.

**Fix:** Add an explicit existing-PR body update, with failure handling, if this work item covers those paths. Otherwise narrow the promise to newly created PRs. Test the update path, not only renderer output.

### 2. Current critic state is not historical rejection storage

**References:** Plan:143–144; `P/controller.py:879`.

**Assumption:** `state["critic"]["findings"]` contains all relevant rejected Critical findings.

**Actual:** A new critic submission replaces that list.

**Fix:** Define scope as findings for the current accepted plan, which the proposed rendering can support simply. If the report requires historical rejected findings, preserve revision-tagged history first and distinguish superseded findings in the PR.

## W7 — Documentation drift

The two specified corrections are grounded:

- `docs/loop-spec/migration-inventory-7.0.md:403` still names `commitArtifacts`; `P/render.py:5` confirms artifacts remain outside the consumer repository.
- `docs/loop-spec/ROADMAP-7.0.md:598` lists stale reason codes; actual verdicts are in `P/baseline.py:558`, and the cited already-satisfied behavior exists at `P/execute.py:1241`.

### 1. The release target lacks a release work item

**References:** Plan:3; `CLAUDE.md:44`; `.claude-plugin/plugin.json:5`; `.claude-plugin/marketplace.json:12`; `README.md:7`; `skills/loop-spec/manifest.toml:2`; `P/__init__.py:12`.

**Assumption:** W1–W7 collectively deliver version 7.1.0.

**Actual:** No work item updates the required release metadata.

**Fix:** Add coordinated updates to both plugin JSON files, README, and every skill manifest. The Python version derives from the manifest; no separate constant change is needed.

### 2. Related check-detection wording remains stale

**References:** Plan:60–63, 146–153; `docs/loop-spec/migration-inventory-7.0.md:251`; `docs/loop-spec/ROADMAP-7.0.md:596`; `P/controller.py:968`.

**Assumption:** The listed inventory replacements cover affected command configuration claims.

**Actual:** Another inventory row still describes “baseline detection plus config prepare,” and the ROADMAP calls `prepare` repo configuration although capture reads it from the PLAN product.

**Fix:** Reconcile these adjacent descriptions with probe facts, planner-selected commands, and PLAN-owned preparation. Avoid describing every command-related variable in the grouped inventory row as a PLAN check.

## Test/live plan

### 1. Add tests for the actual seams, not only isolated helpers

**References:** Plan:155–169; `P/controller.py:438`; `P/revise.py:88`; `P/controller.py:988`; `P/execute.py:954`.

**Assumption:** The listed focused tests cover the behavior.

**Missing coverage:** The current list can pass while probes never reach PLAN, compact products fail validation, old execution records bypass checks, or check-only plan amendments retain stale evidence.

**Fix:** Add deterministic tests for:

- Probe delivery and repository attribution in PLAN, REVISE, and DEBUG inputs.
- All affected schemas, including additional-property rejection.
- Legacy products/pending results and stable revision handling.
- Unknown check repositories and command-use collisions.
- Check-only amendments, legacy execution records, adopted tasks, close-outs, and combined merge heads.
- W2 empty-identity failures and bounded diagnostic serialization.
- W3 incomplete-run version mismatch and actual recapture recovery.
- W4 real acceptance/rewind data flow, stale records, exceptions, changed requirements, and unsupported identity formats.
- W5 strict defaults, malformed config, verified-SHA preservation, D2 mismatch, remote races/errors, and history after partial failure.
- Existing-PR body updates for W6.

Use unit-level program seams, not a fake model-driven cycle, consistent with `CLAUDE.md:13`.

### 2. L2 does not pause on the first D3 failure under the stated policy

**References:** Plan:171–180; `P/postconditions.py:948`; `P/controller.py:1261`; `P/questions.py:90`.

**Assumption:** D3 fails, DELIVER pauses, and the operator answers after modifying the remote.

**Actual:** D3 failure rejects the product and retries DELIVER. A blocked question appears only after the retry limit; its default is `stop`. The default answer policy answers that immediately, removing the intended intervention window.

**Fix:** Specify an operator-controlled question policy for L2 and the exact intervention point. Distinguish product rejection from `delivery blocked`. Assert the fixture actually produces nonzero `gh pr checks`; the program keys on that exit status.

### 3. The negative-then-positive scenario requires rewriting the remote

**References:** Plan:129–131, 181–183.

**Assumption:** The negative case can be followed by resetting to the accepted extension in the same live run.

**Actual:** Removing an already-pushed unwanted commit requires a non-fast-forward update; a revert preserves that commit in history. This also affects whether acceptance is historical or endpoint-based.

**Fix:** Use separate disposable branches/runs for negative and positive cases. That is simpler and preserves the planned “never force” behavior without special fixture repair.

### 4. Deterministic tests cannot establish W4’s model judgment

**References:** Plan:101–105, 184; `CLAUDE.md:13`; `P/steps.py:176`.

**Assumption:** W4 is fully demonstrated by deterministic tests.

**Actual:** Tests can prove provenance collection and prompt construction. They cannot show that an implementer correctly decides whether a test contradicts approved criteria or preserves required assertions.

**Fix:** Label the evidence narrowly or add a targeted live case for the judgment behavior. Record normal critic/reviewer attestation or explicit waivers; do not treat a result file as accepted judgment evidence.

### 5. Specify durable live evidence and freeze the implementation

**References:** Plan:173–184; `CLAUDE.md:34`; `docs/loop-spec/live-runs-7.0.md:3`.

**Assumption:** The expectations alone define completion.

**Missing:** Exact revision, fixture/run identity, retained evidence locations, attestation levels, observed terminal result, and a stop condition if the expected intervention is unavailable.

**Fix:** Add those recording requirements and freeze the plugin tree during each run. L1 should prove the full probe-to-plan-to-baseline-to-integration chain, including actual prompt inputs, rather than merely showing configuration files exist.

VERDICT: revise — (1) wire repository-scoped probes and all compact PLAN schemas; (2) define upgrade, hashing, baseline refresh, and execution-cache behavior; (3) cover close-outs, adopted tasks, and integrated merge heads; (4) establish fresh, revision-bound W4 evidence; (5) preserve verified identity and fully specify remote-extension validation/history; (6) update existing PR bodies and release/docs metadata; (7) repair the unit/live coverage and L2 intervention protocol.


## Later rounds

- Rev 2: VERDICT revise (V9 id collision, collector lifecycle, D1/D2 single head, summary regex scope, W4 guards, docs/tests).
- Rev 3: VERDICT revise (resume guard after submission work; pipe-separator regex).
- Rev 4: VERDICT revise (1): guard at controller store-opening branches.
- Rev 4 + R4-1a: VERDICT: go
